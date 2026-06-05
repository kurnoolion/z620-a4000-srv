# z620-a4000-srv — storage layout

The box has two disks. The design is deliberately simple — single partition
per role, no LVM, no quotas. (Contrast with `dgx-spark-srv`, which uses LVM
+ XFS project quotas on a 4 TB NVMe; that complexity earns its keep at 100+
GB scale but not here.)

## Layout

| Mount | Backing | Filesystem | Size | Holds |
|---|---|---|---|---|
| `/` | SSD (e.g. `/dev/sda2`) | ext4 | ~230 GB | OS, `/var/lib/docker`, `/home`, `/data/active` |
| swap | SSD swapfile `/swapfile` | (swap) | 16 GB | overflow only |
| `/archive` | HDD (e.g. `/dev/sdb1`) | ext4, `LABEL=ARCHIVE` | 1 TB | HF cache, downloaded models, backups |

`/data/active` is **just a directory under `/`** — not a separate mount. It
exists to give compose volume mounts a clean path that can be moved to its
own LV later if needed.

### Tree

```
/                          (SSD root, ~230 GB)
├── var/lib/docker/        Docker images + named volumes (caddy-data/-config)
└── data/active/
    ├── models/local/      "Hot" model copies for fast vLLM cold-start (optional)
    └── srv/data/          Service state if anything ever needs SSD bind-mount

/archive                   (HDD, 1 TB, LABEL=ARCHIVE)
├── models/
│   ├── hf-cache/          HuggingFace cache (huggingface-hub default layout)
│   ├── local/             Flat-dir model snapshots (vLLM loads directly)
│   └── ollama/            Ollama blob store (mounted as /root/.ollama)
└── backups/
    └── staging/<ts>/      Local backup snapshots (restic pushes off-box if configured)
```

## Where each thing reads/writes

| Service | What it touches | Path |
|---|---|---|
| vLLM | model | resolver checks `$ACTIVE_ROOT/models/local/<name>` → `$ARCHIVE_ROOT/models/local/<name>` → HF cache |
| vLLM | HF cache (only for repo-id form) | `/archive/models/hf-cache` |
| Ollama | blobs + manifests | `/archive/models/ollama` |
| TEI (embed + reranker) | HF cache for the model | `/archive/models/hf-cache` |
| Caddy | TLS state, config | named volumes `caddy-data`, `caddy-config` (on `/`) |
| Backups | snapshots | `/archive/backups/staging/<ts>/` |

## SSD vs HDD trade-off for models

**Why this design:** models read pattern is "huge sequential read at startup,
then memory-mapped". After the first load, the kernel page cache holds the
hot model in RAM and the disk doesn't matter. So:

- **First-load cold start** off HDD (~150 MB/s):
  - 7B AWQ (~5 GB) → ~35 s
  - 14B AWQ (~9 GB) → ~60 s
  - bge-m3 (~2 GB) → ~15 s
- **Warm reload** (model in page cache): seconds.

The 24 GB RAM is enough to keep ~12-15 GB of model data in cache at once,
which is fine for one vLLM + one TEI + one TEI-reranker.

If you reboot frequently, or the working set exceeds page cache, **promote
the hot model to SSD**:

```bash
cp -a /archive/models/local/Qwen2.5-7B-Instruct-AWQ \
      /data/active/models/local/Qwen2.5-7B-Instruct-AWQ
```

The vLLM resolver checks `/data/active/models/local/` before
`/archive/models/local/`, so just having both copies present makes vLLM use
the faster one. To save SSD space, only promote your *currently-served*
vLLM model — switch back to HDD when rotating to a different one.

## Capacity planning

**SSD ~230 GB usable on `/`:**

| Consumer | Typical | Cap reasoning |
|---|---|---|
| Ubuntu + tools | ~15 GB | normal |
| `/var/lib/docker` images | ~30-50 GB | vLLM image ~10 GB, Ollama ~2 GB, TEI ~2 GB, Caddy ~50 MB, plus base layers |
| Docker volumes (caddy + tmp) | ~1 GB | small |
| `/data/active/models/local` | up to 50 GB | hold 1-2 promoted models |
| Swap | 16 GB | overflow |
| Free | ~80 GB | breathing room |

If `/var/lib/docker` grows past 100 GB, you're not pruning. `make prune`
weekly via cron.

**HDD 1 TB usable on `/archive`:**

| Consumer | Typical | Cap reasoning |
|---|---|---|
| `/archive/models/hf-cache` | 200-400 GB | bge-m3 + reranker + a few LLMs at full precision adds up |
| `/archive/models/local` | 50-200 GB | each AWQ snapshot is 5-10 GB |
| `/archive/models/ollama` | 50-200 GB | each GGUF is 2-8 GB |
| `/archive/backups` | 10-100 GB | mostly restic snapshots if configured |
| Free | ~300+ GB | room to grow |

If `/archive` starts to fill, see the cleanup table below.

## Cleanup

```bash
# Disk usage by model.
du -sh /archive/models/hf-cache/* | sort -h | tail
du -sh /archive/models/local/*    | sort -h
du -sh /archive/models/ollama/blobs 2>/dev/null

# Remove a specific HF-cached model (canonical via huggingface-cli).
hf cache delete --repo Qwen/Qwen2.5-14B-Instruct-AWQ
# (or nuke a flat-dir snapshot)
rm -rf /archive/models/local/Qwen2.5-14B-Instruct-AWQ

# Remove an Ollama model.
docker exec ollama ollama rm llama3:70b

# Trim old backup snapshots (if NOT using restic — restic does this via
# `forget` automatically).
find /archive/backups/staging -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
```

## When to grow

This single-disk-per-tier layout has **no online resize headroom**. If you
outgrow it:

- **SSD full** — usually `/var/lib/docker`. Prune harder, or replace the SSD
  with a larger one (clean reinstall — there's no LVM to shrink/migrate).
- **HDD full** — most likely model accumulation. Hand-prune cold models, or
  add a second HDD mounted at e.g. `/archive2` and split the model dirs.

If you ever need quotas / online resize (e.g. multiple users sharing the
HDD), borrow the LVM + XFS-project-quota pattern from
`~/work/dgx-spark-srv/setup-storage.sh` (it's heavier than this box wants
right now).
