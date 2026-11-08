# Radxa Rock 5B HA Cluster (`rock5b-but`, `rock5b-first`, `rock5b-coffee`)

The core control plane and distributed storage layer of `sloth` runs on a 3-node **Radxa Rock 5B** (`Rockchip RK3588`, 8-core `linux/arm64` Cortex-A76/A55, 2.5GbE LAN, M.2 PCIe Gen3x4 NVMe) cluster:

| Node | LAN IPv4 | Roles | Boot / OS / Storage Layout |
|------|----------|-------|----------------------------|
| `rock5b-but` | `192.168.1.21` | `control-plane,etcd,monitoring,speaker,storage` | 4 GiB SD `/boot` (`/dev/mmcblk1p1`) + `94 GiB` Btrfs `/` (`/dev/nvme0n1p1`) + `~837 GiB` `ext4` Longhorn (`/dev/nvme0n1p2`) |
| `rock5b-first` | `192.168.1.22` | `control-plane,etcd,monitoring,speaker,storage` | 4 GiB SD `/boot` (`/dev/mmcblk1p1`) + `94 GiB` Btrfs `/` (`/dev/nvme0n1p1`) + `~837 GiB` `ext4` Longhorn (`/dev/nvme0n1p2`) |
| `rock5b-coffee` | `192.168.1.23` | `control-plane,etcd,monitoring,speaker,storage` | 4 GiB SD `/boot` (`/dev/mmcblk1p1`) + `94 GiB` Btrfs `/` (`/dev/nvme0n1p1`) + `~837 GiB` `ext4` Longhorn (`/dev/nvme0n1p2`) |

---

## 1. Install Armbian & Prepare NVMe Partitions (`date: 2023-08-06`)

> [!NOTE]
> **Historical Context (`date: 2023-08-06`)**: The initial `armbian-install` instructions below reflect how the 3 Rock 5B nodes were originally provisioned in August 2023 (`Armbian 23.08` with legacy `5.10.160-rockchip-rk3588` kernel). Several defaults from that 2023 installer (such as the 256 MiB SD `/boot` partition, nested `/media/mmcboot/boot` bind mount, and full-disk Btrfs layout) are now outdated and were remediated in place (`date: 2026-11-07` – `2026-11-08`); see [Section 2 (Kernel Switches)](#2-kernel-switches-510160-legacy-rightarrow-61115-vendor-rightarrow-mainline-618y-lts-date-2026-11-07--2026-11-08) for the modern state.

1. Download the Armbian CLI image from [Armbian Rock 5B](https://www.armbian.com/rock-5b/).
2. Complete first-boot setup (password, user, hostname, network via first-login assistant or `armbian-config`; default initial SSH credentials: `root:1234`).
3. Partition the NVMe drive (`/dev/nvme0n1`) with a `~94 GiB` root partition (`/dev/nvme0n1p1`) and a dedicated `ext4` partition (`/dev/nvme0n1p2`) for Longhorn:
   ```bash
   sudo apt update && sudo apt upgrade
   ```
   > [!IMPORTANT]
   > **Longhorn Filesystem Requirement (`date: 2023-08-08`)**: Longhorn does not support `btrfs` for replica storage disks. Carve out `/dev/nvme0n1p1` (`~94 GiB`) for the root filesystem and `/dev/nvme0n1p2` (`ext4`, mounted at `/var/lib/longhorn/disk0/`) for Longhorn replicas up front. If you already created a full-disk `btrfs` partition, follow [Shrinking an Existing Full-Disk Btrfs Partition for Longhorn](#42-shrinking-an-existing-full-disk-btrfs-partition-for-longhorn-date-2023-08-08) below.
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

## 2. Kernel Switches (`5.10.160-legacy` $\rightarrow$ `6.1.115-vendor` $\rightarrow$ Mainline `6.18.y` LTS — `date: 2026-11-07` – `2026-11-08`)

The 3 Rock 5B nodes were migrated in-place across two kernel generations without reinstalling the OS or losing Longhorn/etcd state:

### 2.1 Fixing the Legacy `armbian-install` `/boot` Bind Mount & SD Partition Size (`date: 2026-11-07`)
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

### 2.2 Step-Stone Upgrade: `5.10.160-rockchip-rk3588` $\rightarrow$ `6.1.115-vendor-rk35xx` (`date: 2026-11-07` – `2026-11-08`)
Armbian retired the 2023 `linux-image-legacy-rockchip-rk3588` (`5.10.160`) package name in favor of `linux-image-vendor-rk35xx` (`6.1.115`). Installing `linux-image-vendor-rk35xx` + `linux-dtb-vendor-rk35xx` validated the `/boot` bind mount and Btrfs superblock alignment across all 3 nodes.

### 2.3 In-Place Jump to Mainline Linux `6.18.y-current-rockchip64` LTS (`date: 2026-11-08`)
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

## 3. Install K3s HA Control Plane (`date: 2023-08-06`) & `kube-vip` (`192.168.1.20` — `date: 2026-11-08`)

Because `sloth` uses MetalLB (`192.168.1.30–99`) for `LoadBalancer` services and Traefik for ingress, K3s runs with `--disable traefik --disable servicelb`. In addition, [`kube-vip`](../../cluster-essentials/kube-vip.yaml) floats **`192.168.1.20`** (`api.internal.k8s.vogelherdweg.de`, `api.rock.k8s.vogelherdweg.de`) across the 3 control-plane nodes on `enP4p65s0` in ARP leader-election mode (`cp_enable: true`, `svc_enable: false`).

1. **On every Rock 5B node**, pin its LAN IPv4 `node-ip` (so boot-time IPv6 SLAAC never races DHCPv4 when `etcd` starts) and include the VIP SANs in `/etc/rancher/k3s/config.yaml`:
   ```bash
   sudo mkdir -p /etc/rancher/k3s
   # Replace 192.168.1.21 with .22 on rock5b-first and .23 on rock5b-coffee:
   sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<'EOF'
   node-ip: "192.168.1.21"
   tls-san:
     - "192.168.1.20"
     - "api.internal.k8s.vogelherdweg.de"
     - "api.rock.k8s.vogelherdweg.de"
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

## 4. Longhorn Prerequisites & Shrinking an Existing Full-Disk Btrfs Partition (`date: 2023-08-08`)

### 4.1 Standard Longhorn Node Prerequisites (`date: 2023-08-08`)
```bash
sudo apt-get update -q -y
sudo apt-get install -q -y open-iscsi
sudo systemctl -q enable iscsid && sudo systemctl start iscsid && sudo modprobe iscsi_tcp

# Verify Longhorn environment requirements (note: v1.3.2 URL from date: 2023-08-08; cluster currently runs Longhorn v1.13.0):
curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/v1.3.2/scripts/environment_check.sh | sudo bash

# Create mountpoint for the dedicated ext4 Longhorn partition (/dev/nvme0n1p2):
sudo mkdir -p /var/lib/longhorn/disk0/
```

### 4.2 Shrinking an Existing Full-Disk Btrfs Partition for Longhorn (`date: 2023-08-08`)

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
