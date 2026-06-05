# z620-a4000-srv — OS install + NVIDIA driver

Step 0 of bring-up: bare metal → **Ubuntu Server 24.04 LTS installed**, NVIDIA
driver loaded, `nvidia-smi` showing the RTX A4000, ssh access working. After
this doc, jump to [SETUP.md](SETUP.md) Part A.

We pick **Ubuntu Server 24.04 LTS** because:
- Current LTS (Apr 2024 release, supported through Apr 2029) — longest runway.
- `ubuntu-drivers` makes the NVIDIA install a one-liner.
- Headless saves ~1.5-2 GB RAM versus Desktop — meaningful at 24 GB.
- Matches the bundle's `apt-get` / systemd / journald assumptions.
- Consistent with the DGX Spark sibling (DGX OS = Ubuntu-derived).

Ubuntu Server **22.04 LTS** is a fine alternative if org policy mandates it;
everything below works identically apart from driver version numbers.

## 1. Pre-install: ISO + USB

On any other machine:

```bash
# Download (verify with the SHA256 published on the same page).
curl -O https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso
sha256sum ubuntu-24.04-live-server-amd64.iso
# Compare against https://releases.ubuntu.com/24.04/SHA256SUMS

# Write to USB. Adjust /dev/sdX — DOUBLE-CHECK with `lsblk` first; this WIPES
# the target drive.
sudo dd if=ubuntu-24.04-live-server-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Or use **Rufus** (Windows) / **balenaEtcher** (any OS) if you'd rather.

## 2. HP Z620 BIOS / boot prep

Plug in keyboard + monitor. Power on, tap **F10** repeatedly to enter BIOS
Setup, **F9** at the same screen picks a one-time boot device.

In BIOS:

| Setting | Value | Why |
|---|---|---|
| Boot Mode | **UEFI Native** (not "Legacy") | Modern, larger-disk-friendly, what the installer expects |
| Secure Boot | **Disabled** | Lets you install the unsigned NVIDIA driver without MOK-enrolling a key. Re-enable later if needed. |
| SATA Mode | **AHCI** | Required for the SSD to be seen as a normal SATA disk |
| Virtualization Technology (VT-x) | **Enabled** | Required for containers' performance + future KVM use |
| VT-d (Intel IOMMU) | **Enabled** | Better with GPU passthrough / IOMMU isolation (harmless if unused) |
| Wake on LAN | optional | Handy for a headless box you might want to power on remotely |
| TPM | **Enabled** (if present) | Reserved for future FDE / Secure Boot use |
| Boot order | USB before SSD/HDD (one-time only — restore SSD-first later) | Installer boots from USB |

Save & exit (**F10**), the box reboots, USB boots into the Ubuntu installer.

If F10/F9 don't respond, try **ESC** at the HP splash — older Z620 BIOS
revisions used ESC to bring up the menu.

## 3. Ubuntu Server installer

The Subiquity (server) installer screens, in order:

1. **Language**: English.
2. **Keyboard**: match your layout.
3. **Installation type**: **Ubuntu Server** (NOT "Ubuntu Server (minimized)" —
   we want the standard tooling).
4. **Network**: configure your wired interface (DHCP usually). Note the IP
   from the summary — you'll ssh to it shortly.
5. **Proxy**: enter corp proxy URL if you're behind one; otherwise leave blank.
6. **Mirror**: accept default; the installer tests it for you.
7. **Guided storage** — **use the custom layout option ("Custom storage layout")**.
   We need to control which disk gets touched, because the bundle expects:
   - SSD has the OS and Docker
   - HDD is left untouched (we format it later via `setup-storage.sh`)

   In the partitioner:

   | Device | Partition | Size | Format | Mount | Bootable |
   |---|---|---|---|---|---|
   | SSD (~250 GB) | 1 | 1 GB | fat32 | `/boot/efi` | yes (ESP) |
   | SSD (~250 GB) | 2 | rest (~230 GB) | ext4 | `/` | — |
   | HDD (~1 TB) | — | leave entirely unallocated | — | — | — |

   No swap partition — we'll add a swapfile after install (16 GB on the SSD).

   Confirm the destructive write when prompted.

8. **Profile setup**:
   - Your name: e.g. `Mohan`
   - Server's name: **`z620-a4000`** (matches `SITE_HOST=z620-a4000.local` in `.env.example`)
   - Pick a username — the bundle assumes you'll run `make` commands as this user.
   - Password: pick something strong; you'll also add an ssh key shortly.

9. **SSH setup**: **Install OpenSSH server: Yes**. If you have a GitHub
   username with ssh keys uploaded, you can have the installer import them
   here — saves a step.

10. **Featured server snaps**: select **none**. Snap-anything you don't need
    is RAM you don't get back. (Docker, NVIDIA, etc. all go in via apt, not
    snap.)

11. Wait for install to finish (~5–15 min), then **remove USB and reboot**.

## 4. First boot — base system updates

Once it boots and shows the login prompt, log in at the console (or ssh in
from your daily-driver machine — `ssh <user>@<ip>` works immediately).

```bash
# Full update + reboot to pick up any new kernel.
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove --purge -y
sudo reboot
```

Reconnect after the reboot.

```bash
# Sanity.
uname -a                  # kernel version
lsb_release -a            # Ubuntu 24.04
free -h                   # 24 GB RAM visible
lscpu | head -20          # Xeon E5 cores visible
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL   # SSD has /, HDD has no FS
lspci | grep -i nvidia    # Should show "NVIDIA Corporation … RTX A4000"
```

The `lspci` line confirms the card is electrically seen even without a
driver. If it's missing, the card isn't seated properly or the PCIe slot is
disabled in BIOS.

## 5. NVIDIA driver

Use the Ubuntu packaging path — it ties driver kernel modules to apt's
kernel updates, so a kernel upgrade doesn't break CUDA.

```bash
# What does Ubuntu recommend for this card?
sudo apt install -y ubuntu-drivers-common
sudo ubuntu-drivers list --gpgpu
# Expect lines like:
#   nvidia-driver-550-server, (kernel modules provided by nvidia-dkms-550-server)
#   nvidia-driver-555, ...
# Pick the highest "*-server" version flagged "recommended" (or the highest
# overall server-variant). The "-server" variant skips X module deps — right
# choice on a headless box.

# Install the recommended set. The line below picks the recommended driver
# automatically; specify a version if you want to pin one.
sudo ubuntu-drivers install --gpgpu

# Reboot so the new kernel module loads cleanly.
sudo reboot
```

After reboot:

```bash
nvidia-smi
# Should show:
#   - Driver Version: 550+ (or whatever you installed)
#   - CUDA Version: 12.x  (the CUDA version the driver supports — host CUDA toolkit not installed yet)
#   - One GPU: NVIDIA RTX A4000, 16384 MiB total, ~0 MiB used

nvidia-smi -L
# NVIDIA RTX A4000 (UUID: GPU-...)
```

If `nvidia-smi` complains "NVIDIA-SMI has failed because it couldn't
communicate with the NVIDIA driver":

```bash
# Check the module loaded.
lsmod | grep nvidia
# If empty, the kernel didn't load it. Common causes:
#   - Secure Boot still on (disable in BIOS — see section 2)
#   - Old kernel still running (re-check `uname -r` after the reboot)
#   - DKMS build failed: `sudo dkms status`, look for "installed" lines per
#     kernel; rebuild with `sudo dkms autoinstall`.
sudo dmesg | grep -iE 'nvidia|nvrm' | tail -20
```

To **upgrade** the driver later (e.g. R550 → R555):

```bash
sudo apt update
sudo apt install -y nvidia-driver-555-server   # or whatever ubuntu-drivers shows
sudo apt autoremove --purge -y
sudo reboot
nvidia-smi   # verify new version
```

Don't mix the apt path with the `.run` installer from nvidia.com on the same
box — pick one and stick with it. The apt path wins on maintainability.

### Optional: GPU persistence daemon

Without it, the driver tears down the GPU context every time the last
process exits; the first request after idle pays a 1-2 s warm-up. With it,
the GPU stays initialized:

```bash
sudo systemctl enable --now nvidia-persistenced
nvidia-smi -q | grep "Persistence Mode"      # should say "Enabled"
```

## 6. SSH key access (recommended)

If you skipped the installer's GitHub key import:

```bash
# From your daily-driver machine, copy your pubkey to the box:
ssh-copy-id <user>@<box-ip>

# Then on the box, lock down password auth:
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

Verify you can still ssh in with the key before closing your existing
session.

## 7. (Optional but recommended) Set static IP / reservation

The box's IP needs to be stable, because clients add it to `/etc/hosts` for
the `z620-a4000.local` hostname (see README "Reaching the stack"). Two
options:

- **DHCP reservation** on the router (easiest — bind the box's MAC to a
  fixed IP).
- **Static IP via netplan** on the box:

  ```bash
  # /etc/netplan/01-static.yaml — adjust to your network.
  sudoedit /etc/netplan/01-static.yaml
  ```
  ```yaml
  network:
    version: 2
    ethernets:
      eno1:                       # check yours with: ip -br link
        dhcp4: no
        addresses: [192.168.1.50/24]
        routes:
          - to: default
            via: 192.168.1.1
        nameservers:
          addresses: [192.168.1.1, 1.1.1.1]
  ```
  ```bash
  sudo chmod 600 /etc/netplan/01-static.yaml
  sudo netplan try     # 120 s window to confirm — applies, you confirm, or it reverts
  ```

mDNS on the LAN (`avahi-daemon`) gets installed in **SETUP.md A2** and gives
you the `z620-a4000.local` name without needing DNS — but a stable IP is
still useful for the `/etc/hosts` fallback on clients that don't speak mDNS.

## 8. (Optional) Corp proxy environment

If you're behind a corp proxy that intercepts HTTPS, set it both for shell
and for apt now — it'll save you running into mid-install stalls later:

```bash
# Shell.
cat >> ~/.bashrc <<'EOF'
export http_proxy=http://proxy.corp.example:8080
export https_proxy=http://proxy.corp.example:8080
export no_proxy=localhost,127.0.0.1,.local,.corp.example
EOF

# apt.
echo 'Acquire::http::Proxy "http://proxy.corp.example:8080";' \
  | sudo tee /etc/apt/apt.conf.d/95proxy
echo 'Acquire::https::Proxy "http://proxy.corp.example:8080";' \
  | sudo tee -a /etc/apt/apt.conf.d/95proxy
```

Docker daemon gets its own proxy config later (in SETUP.md A4) — separate
mechanism, also needed.

## 9. Snapshot of where you should be

Before moving to SETUP.md, confirm all of these:

```bash
uname -r                                    # 6.8+ kernel
lsb_release -d                              # Ubuntu 24.04 LTS
nvidia-smi -L                               # RTX A4000 detected
nvidia-smi --query-gpu=driver_version,cuda_version --format=csv,noheader
                                            # Driver 550+, CUDA 12.x
hostname                                    # z620-a4000
ssh-add -l 2>/dev/null || cat ~/.ssh/authorized_keys  # key access works
df -h /                                     # / on SSD, ~80%+ free
lsblk | grep -i sdb                         # HDD visible, no mounts
free -h                                     # 24 GB RAM, swap line still 0 (we add it in SETUP.md A3)
```

If every line above looks right, **continue to [SETUP.md](SETUP.md) Part A**.
