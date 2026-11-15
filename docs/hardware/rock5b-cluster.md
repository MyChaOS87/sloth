# Radxa Rock 5B HA Cluster (`rock5b-but`, `rock5b-first`, `rock5b-coffee`)

The core control plane and distributed storage layer of `sloth` runs on a 3-node **Radxa Rock 5B** (`Rockchip RK3588`, 8-core `linux/arm64` Cortex-A76/A55, 2.5GbE LAN, M.2 PCIe Gen3x4 NVMe) cluster:

| Node | LAN IPv4 | Roles | Boot / OS / Storage Layout |
|------|----------|-------|----------------------------|
| `rock5b-but` | `192.168.1.21` | `control-plane,etcd,monitoring,speaker,storage` | SPI NOR `/dev/mtd0` (Mainline U-Boot `v2026.10`) + full-disk NVMe (`COS_GRUB`, `COS_OEM`, `COS_RECOVERY`, `COS_STATE`, `COS_PERSISTENT`, `/var/lib/longhorn/disk0`) |
| `rock5b-first` | `192.168.1.22` | `control-plane,etcd,monitoring,speaker,storage` | SPI NOR `/dev/mtd0` (Mainline U-Boot `v2026.10`) + full-disk NVMe (`COS_GRUB`, `COS_OEM`, `COS_RECOVERY`, `COS_STATE`, `COS_PERSISTENT`, `/var/lib/longhorn/disk0`) |
| `rock5b-coffee` | `192.168.1.23` | `control-plane,etcd,monitoring,speaker,storage` | SPI NOR `/dev/mtd0` (Mainline U-Boot `v2026.10`) + full-disk NVMe (`COS_GRUB`, `COS_OEM`, `COS_RECOVERY`, `COS_STATE`, `COS_PERSISTENT`, `/var/lib/longhorn/disk0`) |

> [!NOTE]
> **Active Architecture (`date: 2026-11-14`)**: All 3 Radxa Rock 5B nodes run immutable **Kairos OS (`kairos-rock5b`)** built on pure **Debian 13 Trixie (`trixie-backports` mainline `7.2+` kernel)** with **Mainline U-Boot (`v2026.10`)** in onboard SPI NOR flash (`/dev/mtd0`) — see [Section 1](#1-immutable-kairos-os-provisioning--day-2-gitops-upgrades-preferred--date-2026-11-14). [Section 2](#2-historical-reference-legacy-armbian-provisioning--kernel-switches-20232026) preserves the historical **2023–2026 Armbian** setup and in-place kernel switches for reference.

---

## 1. Immutable Kairos OS Provisioning & Day-2 GitOps Upgrades (Preferred — `date: 2026-11-14`)

### 1.1 Bootloader, OS Image & NVMe Partition Layout

* **OS Image**: [`ghcr.io/mychaos87/kairos-rock5b`](https://github.com/MyChaOS87/kairos-rock5b) built with **Kairos (`v4.5.0`)** on pure `debian:trixie-slim` + `trixie-backports` (`linux-image-arm64` `7.2+`, `firmware-realtek`, `open-iscsi`, `nfs-common`, `cryptsetup`, with `multipathd.service` and `multipathd.socket` masked in both rootfs and initramfs for Longhorn) and **K3s (`v1.37.2+k3s1`)**.
* **Onboard SPI NOR Bootloader (`/dev/mtd0`, 16 MB)**: Upstream Denx **Mainline U-Boot (`v2026.10`)** (`u-boot-rockchip-spi.bin`) provides UEFI (`bootefi`) + device-tree (`/dtb/rockchip/rk3588-rock-5b.dtb`) handoff directly to GRUB2 (`BOOTAA64.EFI`) on NVMe so no MicroSD card stays inserted during normal operation.
* **Full-Disk NVMe GPT Layout (`/dev/nvme0n1`, 1 TB)**:
  * `COS_GRUB` (`nvme0n1p1`): FAT32 ESP holding `/EFI/BOOT/BOOTAA64.EFI` and `/dtb/rockchip/rk3588-rock-5b.dtb`.
  * `COS_OEM` (`nvme0n1p2`): Persistent `/oem/90_custom.yaml` node cloud-config (`0600`).
  * `COS_RECOVERY` (`nvme0n1p3`) & `COS_STATE` (`nvme0n1p4`): Immutable A/B root images (`active.img` / `passive.img`) and recovery system.
  * `COS_PERSISTENT` (`nvme0n1p5`): Remainder of NVMe bind-mounted across reboots and upgrades to `/etc/rancher`, `/var/lib/rancher`, `/var/lib/kubelet`, `/var/lib/longhorn`, `/var/lib/iscsi`, and `/etc/iscsi`. Longhorn uses `/var/lib/longhorn/disk0/` (`disk-0` in [`cluster-essentials/longhorn-config/`](../../cluster-essentials/longhorn-config/), `storageReserved: 53687091200` = 50 GiB reserved for OS/K3s).
* **Hardware Sync Hook (`/system/oem/20_rock5b_hardware.yaml` inside `kairos-rock5b`)**: Runs `/usr/sbin/rock5b-sync-boot --sync-dtb --sync-spi` during `after-install` and `after-upgrade-chroot` to copy the kernel's matching `rk3588-rock-5b.dtb` onto `COS_GRUB` (`findmnt`-safe) and perform an idempotent `cmp -s`-gated `flashcp` update of `/dev/mtd0` only when `u-boot-rockchip-spi.bin` changes.

### 1.2 Rendering Per-Node Cloud-Config (`node-bootstrap/rock5b/`)

1. Place `K3S_TOKEN=<cluster-join-token>` and `CLUSTER_DOMAIN=<your-domain>` in gitignored `.secrets/rock5b.env` (or `.secrets/sloth.env`) and render the per-node cloud-config (see [`render-node-config.sh`](../../node-bootstrap/rock5b/render-node-config.sh) and [`cloud-config.yaml.tpl`](../../node-bootstrap/rock5b/cloud-config.yaml.tpl)):
   ```bash
   ./node-bootstrap/rock5b/render-node-config.sh <rock5b-but|rock5b-first|rock5b-coffee>
   ```
   *(Outputs `node-bootstrap/rock5b/build/<node>-cloud-config.yaml` with `0600` permissions.)*
2. The rendered config sets static LAN IPv4 (`192.168.1.21–23/24` on `Driver=r8169` via `systemd-networkd`), `kasch` SSH authorized keys + passwordless `sudo`, `/etc/rancher/k3s/config.yaml` (`node-ip`, `node-label: kairos.io/managed=true`, `tls-san` for `192.168.1.20` / `api.internal.k8s.<CLUSTER_DOMAIN>` / `api.rock.k8s.<CLUSTER_DOMAIN>`, `--disable traefik --disable servicelb`), Longhorn `/var/lib/longhorn/disk0/longhorn-disk.cfg` preserving each node's `diskUUID`, and HA K3s control-plane join (`https://192.168.1.20:6443`, or `--cluster-init` if bootstrapping the very first control-plane node of a brand-new cluster before `kube-vip` is running).

### 1.3 Bare-Metal Provisioning & Rolling Node Replacement

1. **Check / Pre-Flash SPI NOR (`/dev/mtd0`) when migrating from legacy U-Boot**: RK3588 BootROM checks onboard SPI NOR (`/dev/mtd0`) before the MicroSD slot (`mmc1`). Erased/blank SPI (`0xff` at `0x8000`) falls through automatically to Mainline U-Boot on the MicroSD installer, whereas legacy vendor/Armbian SPI U-Boot (`2017.09-armbian`) lacks `bootefi` and stalls before booting the Kairos EFI installer. When migrating an existing Linux node over SSH, back up `/dev/mtd0` and pre-flash `u-boot-rockchip-spi.bin` via `flash-spi-uboot.sh` from `kairos-rock5b` before powering off.
2. **Drain & Clean Stale Node State (when replacing an existing cluster member)**: Cordon and drain the target node (`kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`), verify Longhorn volume health and `2/3` `etcd` quorum on the remaining nodes, and delete the stale node + node-password secret (`kubectl delete node <node> && kubectl -n kube-system delete secret <node>.node-password.k3s`) so `etcd` removes the old member identity before the wiped node rejoins at the same IP.
3. **Boot MicroSD Installer & Auto-Install to NVMe**: Flash the universal `kairos-rock5b` MicroSD installer image (`AuroraBoot v0.30.0`) and copy `node-bootstrap/rock5b/build/<node>-cloud-config.yaml` onto the `COS_LIVE` FAT32 partition as `/config.yaml` (reuse the same MicroSD card across nodes by overwriting `/config.yaml`). Boot from MicroSD; Kairos installs to `/dev/nvme0n1`, syncs `COS_GRUB` DTB + `/dev/mtd0` SPI U-Boot, and powers off (`install.poweroff: true` — blue heartbeat LED turns off; green 5V power LED stays lit while USB-C PD remains plugged in).
4. **Boot from NVMe**: Eject the MicroSD card and cycle USB-C PD power. The node boots Mainline U-Boot from `/dev/mtd0` $\rightarrow$ GRUB EFI on `COS_GRUB` $\rightarrow$ Kairos `COS_STATE` (`active`), joins `https://192.168.1.20:6443`, receives declarative role labels (`storage`, `speaker`, `monitoring`) from [`nodes/`](../../nodes/), and re-registers `disk-0` in Longhorn.

### 1.4 Day-2 Atomic Upgrades via `kairos-operator`

* [`cluster-essentials/kairos-operator.yaml`](../../cluster-essentials/kairos-operator.yaml) (`v0.3.0`, `sync-wave: "-10"`, `ServerSideApply=true`) deploys the operator and `node-labeler` (syncing `kairos.io/*` labels on Kairos nodes while leaving DietPi `pi0-lcn` untouched), and [`cluster-essentials/kairos-operator-config/kairos-os.yaml`](../../cluster-essentials/kairos-operator-config/kairos-os.yaml) defines the `NodeOpUpgrade` CR (`concurrency: 1`, `stopOnFailure: true`, `upgradeActive: true`).
* `NodeOpUpgrade` is a **one-shot** resource: its preflight pod compares the target OCI image's `/etc/kairos-release` against each node's `/etc/kairos-release` (skipping cordon/drain/reboot on nodes already at target version), and in-place spec edits to a completed `NodeOpUpgrade` are ignored — to roll out a new `kairos-rock5b` release, bump **both** `metadata.name` and `spec.image` in [`kairos-os.yaml`](../../cluster-essentials/kairos-operator-config/kairos-os.yaml). Non-Kairos nodes (`pi0-lcn`) continue upgrading K3s via [`system-upgrade-config/k3s.yaml`](../../cluster-essentials/system-upgrade-config/k3s.yaml) (`kairos.io/managed: DoesNotExist`).

---

## 2. Historical Reference: Legacy Armbian Provisioning & Kernel Switches (2023–2026)

> [!NOTE]
> Sections 2.1–2.4 below are preserved as historical documentation of the original August 2023 Armbian setup, Btrfs-to-ext4 Longhorn partition shrink, and November 2026 in-place kernel migrations (`5.10.160-legacy` $\rightarrow$ `6.1.115-vendor` $\rightarrow$ Mainline `6.18.y` LTS) that ran prior to the November 2026 Kairos OS migration.

### 2.1 Install Armbian & Prepare NVMe Partitions (`date: 2023-08-06`)

> [!NOTE]
> **Historical Context (`date: 2023-08-06`)**: The initial `armbian-install` instructions below reflect how the 3 Rock 5B nodes were originally provisioned in August 2023 (`Armbian 23.08` with legacy `5.10.160-rockchip-rk3588` kernel). Several defaults from that 2023 installer (such as the 256 MiB SD `/boot` partition, nested `/media/mmcboot/boot` bind mount, and full-disk Btrfs layout) are now outdated and were remediated in place (`date: 2026-11-07` – `2026-11-08`); see [Section 2.2 (Kernel Switches)](#22-kernel-switches-510160-legacy-rightarrow-61115-vendor-rightarrow-mainline-618y-lts--date-2026-11-07--2026-11-08) for that upgrade path.

1. Download the Armbian CLI image from [Armbian Rock 5B](https://www.armbian.com/rock-5b/).
2. Complete first-boot setup (password, user, hostname, network via first-login assistant or `armbian-config`; default initial SSH credentials: `root:1234`).
3. Partition the NVMe drive (`/dev/nvme0n1`) with a `~94 GiB` root partition (`/dev/nvme0n1p1`) and a dedicated `ext4` partition (`/dev/nvme0n1p2`) for Longhorn:
   ```bash
   sudo apt update && sudo apt upgrade
   ```
   > [!IMPORTANT]
   > **Longhorn Filesystem Requirement (`date: 2023-08-08`)**: Longhorn does not support `btrfs` for replica storage disks. Carve out `/dev/nvme0n1p1` (`~94 GiB`) for the root filesystem and `/dev/nvme0n1p2` (`ext4`, mounted at `/var/lib/longhorn/disk0/`) for Longhorn replicas up front. If you already created a full-disk `btrfs` partition, follow [Shrinking an Existing Full-Disk Btrfs Partition for Longhorn](#242-shrinking-an-existing-full-disk-btrfs-partition-for-longhorn-date-2023-08-08) below.
4. Run `armbian-install`:
   * `1` — Boot from SD - System on NVMe
   * `2` — `/dev/nvme0n1p1`
   * Confirm erasure
   * `2` — `btrfs`
   * Reboot
5. Verify the NVMe and SD `/boot` mounts:
   ```bash
   mount | grep -E 'nvme|mmc'
   # Expected:
   # /dev/nvme0n1p1 on / type btrfs (rw,noatime,compress=lzo,ssd,space_cache=v2,commit=600,subvolid=5,subvol=/)
   # /dev/nvme0n1p1 on /var/log.hdd type btrfs (rw,noatime,compress=lzo,ssd,space_cache=v2,commit=600,subvolid=5,subvol=/)
   # /dev/mmcblk1p1 on /media/mmcboot type ext4 (rw,noatime,errors=remount-ro,commit=600,x-gvfs-hide)
   # /dev/mmcblk1p1 on /boot type ext4 (rw,noatime,errors=remount-ro,commit=600)
   ```
6. Install common diagnostic utilities:
   ```bash
   sudo apt install vim net-tools tshark tcpdump iftop
   ```

---

### 2.2 Kernel Switches (`5.10.160-legacy` $\rightarrow$ `6.1.115-vendor` $\rightarrow$ Mainline `6.18.y` LTS — `date: 2026-11-07` – `2026-11-08`)

The 3 Rock 5B nodes were migrated in-place across two kernel generations without reinstalling the OS or losing Longhorn/etcd state:

#### 2.2.1 Fixing the Legacy `armbian-install` `/boot` Bind Mount & SD Partition Size (`date: 2026-11-07`)
Legacy `armbian-install` (`date: 2023-08-06`, "Boot from SD - System on NVMe") created two host pitfalls that prevented `apt` kernel upgrades from taking effect on reboot:
1. **Nested `/media/mmcboot/boot` bind mount (`date: 2023-08-06`)**: `/etc/fstab` mounted `/media/mmcboot/boot` onto `/boot`, whereas U-Boot on `/dev/mmcblk1p1` loads `/boot.scr`, `/armbianEnv.txt`, `/Image`, `/uInitrd`, and `/dtb` from the **root** of `/media/mmcboot/`. As a result, `dpkg` wrote new kernels into `/media/mmcboot/boot/` while U-Boot kept booting the stale 2023 `5.10.160` kernel in `/media/mmcboot/`.
   * **Fix (`date: 2026-11-07`)**: Bind-mount `/media/mmcboot` directly to `/boot` in `/etc/fstab`:
     ```fstab
     /media/mmcboot /boot none bind 0 0
     ```
2. **256 MiB `/dev/mmcblk1p1` SD partition (`date: 2023-08-06`)**: The original 256 MiB `/boot` partition could not hold multiple kernels and `uInitrd` images side-by-side during upgrades.
   * **Fix (`date: 2026-11-07`)**: Expand `/dev/mmcblk1p1` online to **4 GiB**:
     ```bash
     sudo parted /dev/mmcblk1 resizepart 1 4096MB
     sudo resize2fs /dev/mmcblk1p1
     ```
3. **Btrfs Superblock Size Alignment (`Linux 6.0+` strict check — `date: 2026-11-07`)**:
   When `/dev/nvme0n1p1` was originally shrunk with `parted` (`date: 2023-08-08`) without shrinking the Btrfs device in the superblock to match `1:max`, `5.10.160` tolerated the mismatch, but Linux `6.0+` (`fs/btrfs/volumes.c`) rejects mounting `/` with `-EINVAL` (`device total_bytes should be at most ...`) if the superblock's `devid 1 size` exceeds the partition size.
   * **Fix (`date: 2026-11-07`)**: Always align the Btrfs superblock to the partition boundary before booting `6.0+`:
     ```bash
     sudo btrfs filesystem resize 1:max /
     ```

#### 2.2.2 Step-Stone Upgrade: `5.10.160-rockchip-rk3588` $\rightarrow$ `6.1.115-vendor-rk35xx` (`date: 2026-11-07` – `2026-11-08`)
Armbian retired the 2023 `linux-image-legacy-rockchip-rk3588` (`5.10.160`) package name in favor of `linux-image-vendor-rk35xx` (`6.1.115`). Installing `linux-image-vendor-rk35xx` + `linux-dtb-vendor-rk35xx` validated the `/boot` bind mount and Btrfs superblock alignment across all 3 nodes.

#### 2.2.3 In-Place Jump to Mainline Linux `6.18.y-current-rockchip64` LTS (`date: 2026-11-08`)
All hardware required by `sloth` on the Radxa Rock 5B is now upstream in mainline `arm64` (`6.18+`):
* **M.2 PCIe Gen3x4 NVMe**: `CONFIG_PCIE_ROCKCHIP_DW_HOST=y`, `CONFIG_PHY_ROCKCHIP_SNPS_PCIE3=m`, `CONFIG_BLK_DEV_NVME=y`
* **2.5GbE LAN (Realtek RTL8125)**: `CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY=y`, `CONFIG_R8169=m`
* **RK3588 6-TOPS NPU & Mali-G610 GPU**: `CONFIG_DRM_ACCEL_ROCKET=m` (upstream `rocket` NPU driver) and `CONFIG_DRM_PANTHOR=m`

To run a clean mainline LTS kernel (`>= 6.18.56`, which patches the Linux multipath RCE) while keeping the rest of the Armbian userspace on stable `apt.armbian.com`, each Rock 5B node pins **only** `linux-image-current-rockchip64` and `linux-dtb-current-rockchip64` from `beta.armbian.com`:

```bash
echo "deb [signed-by=/usr/share/keyrings/armbian.gpg] http://beta.armbian.com noble main" | sudo tee /etc/apt/sources.list.d/armbian-beta.list >/dev/null
sudo tee /etc/apt/preferences.d/99-armbian-beta-kernel >/dev/null <<'EOF'
Package: *
Pin: origin "beta.armbian.com"
Pin-Priority: 100

Package: linux-image-current-rockchip64 linux-dtb-current-rockchip64
Pin: origin "beta.armbian.com"
Pin-Priority: 990
EOF

sudo apt-get update
sudo apt-get install -y linux-image-current-rockchip64 linux-dtb-current-rockchip64

# Verify /boot U-Boot symlinks before rebooting:
ls -l /boot/Image /boot/uInitrd /boot/dtb
readlink /boot/Image | grep -q 6.18
test -f /boot/dtb/rockchip/rk3588-rock-5b.dtb
```

Once verified across all 3 nodes, the old vendor/legacy kernel packages can be purged:
```bash
sudo apt-get purge -y linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx linux-image-legacy-rockchip-rk3588 linux-dtb-legacy-rockchip-rk3588
```

---

### 2.3 Install K3s HA Control Plane (`date: 2023-08-06`) & `kube-vip` (`192.168.1.20` — `date: 2026-11-08`)

Because `sloth` uses MetalLB (`192.168.1.30–99`) for `LoadBalancer` services and Traefik for ingress, K3s runs with `--disable traefik --disable servicelb`. In addition, [`kube-vip`](../../cluster-essentials/kube-vip.yaml) floats **`192.168.1.20`** (`api.internal.k8s.example.com`, `api.rock.k8s.example.com`) across the 3 control-plane nodes on `enP4p65s0` in ARP leader-election mode (`cp_enable: true`, `svc_enable: false`).

1. **On every Rock 5B node**, pin its LAN IPv4 `node-ip` (so boot-time IPv6 SLAAC never races DHCPv4 when `etcd` starts) and include the VIP SANs in `/etc/rancher/k3s/config.yaml`:
   ```bash
   sudo mkdir -p /etc/rancher/k3s
   # Replace 192.168.1.21 with .22 on rock5b-first and .23 on rock5b-coffee:
   sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<'EOF'
   node-ip: "192.168.1.21"
   tls-san:
     - "192.168.1.20"
     - "api.internal.k8s.example.com"
     - "api.rock.k8s.example.com"
   EOF
   ```
2. **Initialize the first control-plane node (`rock5b-but`)**:
   ```bash
   curl -sfL https://get.k3s.io | sh -s - server --disable traefik --disable servicelb --cluster-init

   # Retrieve the cluster join token:
   sudo cat /var/lib/rancher/k3s/server/token | sed -e "s/.*::server://g"
   ```
3. **Join the remaining two control-plane nodes (`rock5b-first`, `rock5b-coffee`)**:
   ```bash
   curl -sfL https://get.k3s.io | K3S_TOKEN=<SECRET_FROM_ABOVE> sh -s - server --disable traefik --disable servicelb --server https://rock5b-but.lan:6443
   ```
   *(Node scheduling roles `storage`, `speaker`, and `monitoring` are applied declaratively by Argo CD via [`argocd-base/nodes.yaml`](../../argocd-base/nodes.yaml) and [`nodes/`](../../nodes/).)*

---

### 2.4 Longhorn Prerequisites & Shrinking an Existing Full-Disk Btrfs Partition (`date: 2023-08-08`)

#### 2.4.1 Standard Longhorn Node Prerequisites (`date: 2023-08-08`)
```bash
sudo apt-get update -q -y
sudo apt-get install -q -y open-iscsi
sudo systemctl -q enable iscsid && sudo systemctl start iscsid && sudo modprobe iscsi_tcp

# Verify Longhorn environment requirements (note: v1.3.2 URL from date: 2023-08-08; cluster currently runs Longhorn v1.13.0):
curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/v1.3.2/scripts/environment_check.sh | sudo bash

# Create mountpoint for the dedicated ext4 Longhorn partition (/dev/nvme0n1p2):
sudo mkdir -p /var/lib/longhorn/disk0/
```

#### 2.4.2 Shrinking an Existing Full-Disk Btrfs Partition for Longhorn (`date: 2023-08-08`)

>[!WARNING]
> Longhorn **doesn't support** btrfs at the time of writing (`date: 2023-08-08`). So if you like me missed that wen creating your full disk *btrfs* partition :skull: and want to use that for longhorn, you *should* change that asap, best before running anything, or best start over with deploying everything with the right partitions already. 
>I took the following steps to fix it after already having already some stuff deployed (risk assessment felt fine :feelsgood:, in my case! - Really, start over with a fresh system as long as you can!):
> * :exclamation:DISCLAIMER:exclamation:: Potential full data-loss possible, Use at your own risk. Double check what you are doing.
> * Drain the node from K8s: 
> ```bash
> kubectl drain --delete-emptydir-data --ignore-daemonsets <NODE>
> ```
> * Stop K8s on the node completely: 
> ```bash
> k3s-killall.sh
> ```
> * shrink the Btrfs filesystem and `/` partition - (**CRITICAL (`date: 2026-11-07`)**: always run `btrfs filesystem resize 1:max /` so the Btrfs superblock `devid 1 size` matches the partition size; Linux 6.0+ refuses to mount `/` with `-EINVAL` if the Btrfs device size exceeds `/dev/nvme0n1p1`): 
>```bash
>sudo btrfs filesystem resize 1:93G /
>sudo parted /dev/nvme0n1 resizepart 1 100G
>sudo btrfs filesystem resize 1:max /
>```
> * recheck your btrfs :innocent::
>```
>btrfs check --force /dev/nvme0n1p1
>```
> * create new partition and create ext4 fs on it:
>```
>(echo n; echo 2; echo ""; echo ""; echo w) | sudo fdisk /dev/nvme0n1
>sudo mkfs.ext4 /dev/nvme0n1p2
>```
> * (optional) purge all longhorn stuff - in my case everything is unused here
>```
>sudo rm -rf /var/lib/longhorn
>sudo mkdir -p /var/lib/longhorn/disk0/
>```
> * mount your new partition
>```
>echo $(blkid /dev/nvme0n1p2 | cut -d\  -f2 | sed "s/\"//g")"\t"/var/lib/longhorn/disk0"\t"ext4"\t"defaults,noatime,commit=600,errors=remount-ro,x-gvfs-hide"\t"0"\t"1 | sudo tee -a /etc/fstab
>sudo mount -a
>mount | grep nvme0n1p2
>```
> * restart k3s
> ```
> sudo systemctl start k3s.service
>```
> * uncordon node
>```
> kubectl uncordon <NODE>
>```
> * disable scheduling for disk and delete disk in longhorn-ui, it will get recreated
