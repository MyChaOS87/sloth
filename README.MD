# SLOTH (SLightly Over engineered "Trivial" Home automation)
## Introduction
This is my personal home-server/cluster, which I build mainly for home-automation. This project is also my k3s and argocd playground.

I started running it on a [Raspberry PI CM4 Single Node](#raspberry-pi-cm4-single-node), but hit some hard performance boundaries with the current setup, so decided to give it a bit more flesh using a three node [Radxa Rock5B HA cluster](#radxa-rock5b-ha-cluster), as it is also easier to source at the time of writing and has a couple more features.

I try to keep as much as possible hardware independent. Just skip the Hardware chapters and start with [Bootstrapping Secrets and argo-cd](#bootstrapping-secrets-and-argo-cd). Remember to provide a cluster and have prerequisites for longhorn available.

### Repository structure
* `.secrets/` used for temporary secret files, those should never get checked in
* `argocd-base/` charts to bootstrap the cluster, base functionality of argo-cd & sealed-secrets only.
* `./*` some scripts used in this guide and the public key part of the deploy key for this repo so argo-cd is able to retrieve it.

### The project currently uses:
* Kubernetes ([K3s](https://k3s.io)) 
* [Helm](https://helm.sh/)
* [argo-cd](https://argo-cd.readthedocs.io/en/stable/) for continuous delivery, basically controlling everything in this cluster. The general idea is, there should be no other interaction necessary to manage anything on the cluster, except this git-repo and argocd...
* [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) to solve the problem: "I can manage all my K8s config in git, except Secrets."
* [longhorn](https://longhorn.io) as persistent storage provider
* [MetalLB](https://metallb.universe.tf/) for bare-metal LoadBalancer IP allocation across k3s nodes
* [Traefik](https://traefik.io/traefik/) as ingress controller
* [cert-manager](https://cert-manager.io/) & [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) for automated Let's Encrypt TLS certificates and DNS synchronization
* [Keycloak](https://www.keycloak.org/) for OIDC Single Sign-On (SSO)
* [Prometheus](https://prometheus.io/), [Grafana](https://grafana.com/), [InfluxDB](https://www.influxdata.com/), and [Telegraf](https://www.influxdata.com/time-series-platform/telegraf/) for cluster and smarthome monitoring
* [mosquitto](https://mosquitto.org/) as MQTT broker
* [automqttion](https://github.com/MyChaOS87/automqttion) for declarative MQTT automations
* [reverseLCN](https://github.com/MyChaOS87/reverseLCN) (`lcn2mqtt`) for bidirectional LCN-PKU USB serial $\leftrightarrow$ MQTT bridging on the `pi0-lcn` edge node

It's a hobby project, so see [Disclaimer](#disclaimer).

### Planned additions (in no particular order):
* PodDisruptionBudgets, multiple pods...
* mosquitto authentication
* hardening security
* making it more reusable - complete proper separation of values and templates(which currently are sometimes more plain yaml files and not templates), to pulling values into a different repository, so this could be universally used for bootstrapping any clusters with the base argocd stuff.
* ...

## Raspberry Pi CM4 Single Node
### Install RaspberryPi OS
[Source: How to flash Raspberry Pi OS onto the Compute Module 4 eMMC with usbboot](https://www.jeffgeerling.com/blog/2020/how-flash-raspberry-pi-os-compute-module-4-emmc-usbboot)

```bash
# Clone usbboot
git clone --depth=1 https://github.com/raspberrypi/usbboot

# Build
cd usbboot
make

# Set RPI CM4 into usbboot mode and plug into usb
# Waveshare CM4-NANO-B has a switch for that other boards have jumpers... rtfm

#Run ./rpiboot
sudo ./rpiboot
```
Now it should be mounted as an external disk and rpi-imager should find it.

Install "Raspberry PI OS Lite (64-bit)", enable ssh, set hostname...

### Install k3s on RPi
```bash
# Enable cgroups
sudo vi /boot/cmdline.txt
# Append the following line at the end of first line (without # of course): 
# cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1

# Reboot the kernel
systemctl reboot

# Install k3s
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
# --write-kubeconfig-mode 644 is a huge potential security risk as it allows every user to read these files including the kubernetes root credentials! use at your own discretion! On my first test, I used that so that the kubectl-config-remote script can retrieve the credentials via the "pi" default user.
```


## Radxa Rock5b HA cluster
### Install Armbian
* Download Armbian CLI Image from [Armbian Rock5b](https://www.armbian.com/rock-5b/)
* do your base config: password, user, hostname, network,... (assistant on first login or via `armbian-config`) 
  * default ssh credentials: `root:1234`
* Installation to NVM preparation:
```bash
# upgrade packages (optional)
sudo apt update && sudo apt upgrade

# Create partition 
(echo g; echo n; echo 1; echo ""; echo ""; echo w) | sudo fdisk /dev/nvme0n1
```
> [!IMPORTANT] 
> **Longhorn compatibility!**: Probably already a good idea to carve out space for a longhorn partition here. At the time of writing longhorn has no support for btrfs. So probably carving out space here, or using ext4 instead of btrfs in the next step is a good idea. If you miss it like me, there is a guide in [Longhorn Preparation](#longhorn-preparation) on how to shrink and prepare it.

* run `armbian-install`, choose: 
  * 1 -Boot from SD - System on NVME
  * 2 - /dev/nvme0n1p1
  * Confirm erasure
  * 2 - btrfs
  * Reboot
* optional check for right mounts on NVME and SD `/boot`: 
```bash
% mount | grep -E 'nvme|mmc'
# should return:
/dev/nvme0n1p1 on / type btrfs (rw,noatime,compress=lzo,ssd,space_cache=v2,commit=600,subvolid=5,subvol=/)
/dev/nvme0n1p1 on /var/log.hdd type btrfs (rw,noatime,compress=lzo,ssd,space_cache=v2,commit=600,subvolid=5,subvol=/)
/dev/mmcblk1p1 on /media/mmcboot type ext4 (rw,noatime,errors=remount-ro,commit=600,x-gvfs-hide)
/dev/mmcblk1p1 on /boot type ext4 (rw,noatime,errors=remount-ro,commit=600)
```
> [!IMPORTANT]
> **`/boot` Bind Mount & `vendor-rk35xx` Kernel Branch**: Legacy `armbian-install` ("Boot from SD - System on NVMe") creates `/media/mmcboot/boot /boot none bind` in `/etc/fstab` even though U-Boot loads `/boot.scr`, `/armbianEnv.txt`, `/Image`, `/uInitrd`, and `/dtb` from the root of `/media/mmcboot/`. Ensure `/etc/fstab` bind-mounts `/media/mmcboot` directly to `/boot` (`/media/mmcboot /boot none bind 0 0`) and that the active `6.1.y` LTS kernel branch (`linux-image-vendor-rk35xx` + `linux-dtb-vendor-rk35xx`) is installed in place of the retired 2023 `linux-image-legacy-rockchip-rk3588` (`5.10.160`) package so `apt dist-upgrade` updates `/boot` in place.

### Install some common utils
```bash 
sudo apt install vim net-tools tshark tcpdump iftop
```

### Install K3s on Rock 5B cluster
as this is a HA cluster, we want to use metalLB so we disable the serviceLB, and pin each node's LAN IPv4 address in `/etc/rancher/k3s/config.yaml` so IPv6 SLAAC never races DHCPv4 when `etcd` starts at boot:
```bash
# On each node, pin its IPv4 address (.21, .22, .23):
sudo mkdir -p /etc/rancher/k3s
echo 'node-ip: "192.168.1.21"' | sudo tee /etc/rancher/k3s/config.yaml

# On the first node:
curl -sfL https://get.k3s.io | sh -s - server --disable traefik --disable servicelb --cluster-init


# retrieve token
sudo cat /var/lib/rancher/k3s/server/token | sed -e "s/.*::server://g" 
```
```bash
# on the other nodes (after setting their respective node-ip in /etc/rancher/k3s/config.yaml):
curl -sfL https://get.k3s.io | K3S_TOKEN=<SECRET FROM ABOVE> sh -s - server --disable traefik --disable servicelb --server https://rock5b-but.lan:6443
```
*(Node roles `storage`, `speaker`, and `monitoring` are reconciled declaratively by Argo CD via [`argocd-base/nodes.yaml`](./argocd-base/nodes.yaml) and [`nodes/`](./nodes/)).*

## Raspberry Pi Zero 2 W Edge Node (`pi0-lcn`)
`pi0-lcn` (`192.168.1.24`) is a dedicated 512 MB Raspberry Pi Zero 2 W (`linux/arm64`) running **DietPi 64-bit (`ARMv8` Trixie)** that hosts the physical LCN-PKU USB serial coupler (`/dev/lcn-pku`) for `reverseLCN` (`lcn2mqtt`).

### Zero-Touch SD Card Provisioning
1. Download the **DietPi Raspberry Pi 2/3/4/Zero 2 (ARMv8 64-bit Trixie)** image from [dietpi.com](https://dietpi.com/#download) and flash it to your microSD card.
2. Mount the flashed SD card's FAT32 `boot` partition on your workstation.
3. Populate the SD card boot partition using [`./node-bootstrap/pi0-lcn/prepare-boot.sh`](./node-bootstrap/pi0-lcn/prepare-boot.sh) (it prompts interactively for `WIFI_SSID`, `WIFI_KEY`, `DIETPI_PASSWORD`, and `K3S_TOKEN` without writing secrets to local disk, or optionally reads `.secrets/pi0-lcn.env` if present):
   ```bash
   ./node-bootstrap/pi0-lcn/prepare-boot.sh /run/media/$USER/boot
   ```
4. Unmount the SD card, insert it into the Raspberry Pi Zero 2 W with the LCN-PKU USB coupler attached, and power it on.
   - On first boot, DietPi configures headless GPU memory (`gpu_mem=16`, `max_framebuffers=0`), in-RAM `zram` swap (`AUTO_SETUP_SWAPFILE_LOCATION=zram`, zero SD card swap), and RAM-backed `/var/log`, then runs [`node-bootstrap/pi0-lcn/Automation_Custom_Script.sh`](./node-bootstrap/pi0-lcn/Automation_Custom_Script.sh) (`AUTO_SETUP_CUSTOM_SCRIPT_EXEC=0`) which installs `ansible-core` and executes [`node-bootstrap/pi0-lcn/playbook.yml`](./node-bootstrap/pi0-lcn/playbook.yml) locally (`ansible-playbook --connection=local`) before deleting `/boot/firmware/k3s-vars.yml`.
   - The playbook configures `sshd`, user `kasch` (`sudo` + `dialout`, `NOPASSWD:ALL`, `kasch@cirilla` SSH key), `/tmp=64M` and `/var/log=32M` `tmpfs` caps, `systemd-journald` `RuntimeMaxUse=16M`, `/etc/udev/rules.d/99-lcn-pku.rules` (`/dev/lcn-pku` `0660` `root:dialout`), unprivileged containerd v3 USB serial cgroup permissions (`/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/10-serial.toml` $\rightarrow$ `c 188:* rwm`, `c 166:* rwm`), and joins `sloth` as `pi0-lcn` (tainted `dedicated=lcn-serial:NoExecute`).
   - Day-2 updates can be applied idempotently over SSH from your workstation using the exact same playbook:
     ```bash
     ansible-playbook -i pi0-lcn.lan, -u kasch --become node-bootstrap/pi0-lcn/playbook.yml
     ```
   - Argo CD's `nodes` Application applies `ROLES: lcn-serial,monitoring` via [`nodes/pi0-lcn.yaml`](./nodes/pi0-lcn.yaml) and schedules the `reverselcn` (`node-role.kubernetes.io/lcn-serial: "true"`) and `prometheus-node-exporter` (`node-role.kubernetes.io/monitoring: "true"`) DaemonSets onto `pi0-lcn` while keeping `longhorn` (`storage`) and `metallb-speaker` (`speaker`) constrained to the Rock5B nodes.

## Prepare Cluster Prerequisites
### Longhorn Preparation
```bash
sudo apt-get update -q -y 
sudo apt-get install -q -y open-iscsi 
sudo systemctl -q enable iscsid && sudo systemctl start iscsid && sudo modprobe iscsi_tcp

### Check requirements
curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/v1.3.2/scripts/environment_check.sh | sudo bash

### create folder for data disk:
sudo mkdir -p /var/lib/longhorn/disk0/ #and depending on your desired config mount another disk there
```
>[!WARNING]
> Longhorn **doesn't support** btrfs at the time of writing. So if you like me missed that wen creating your full disk *btrfs* partition :skull: and want to use that for longhorn, you *should* change that asap, best before running anything, or best start over with deploying everything with the right partitions already. 
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
> * shrink the Btrfs filesystem and `/` partition - (**CRITICAL**: always run `btrfs filesystem resize 1:max /` so the Btrfs superblock `devid 1 size` matches the partition size; Linux 6.0+ refuses to mount `/` with `-EINVAL` if the Btrfs device size exceeds `/dev/nvme0n1p1`): 
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
> 
>  ---



### Access k3s from remote (skip if you run everything from the k3s server)
Run the following from your remote host you want to control the cluster from: 
```bash
# adjust the k8sHost to your setup...
./kubectl-config-remote.sh -s <k8sHost> # -c <cluster> -u <user> # -h for help!
```

The user needs to be able to access the k3s config files, which can either be done via the `--write-kubeconfig-mode 644` bodge mentioned under [Install k3s on RPi](#install-k3s-on-rpi)

## Bootstrapping Secrets and argo-cd
### Local Prerequisites for the rest of the install  
* kubectl (configured to be used against your k3s "cluster")
* helm 
* kubeseal - for sealing secrets (guide in [Prepare Secret](#prepare-secret))
* yq

### Prepare Secret
as we use [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) my secret checked into the repository will not help you, as your cluster cannot decrypt it.

If you delete the sealed-secrets deployment from your cluster you have to redo this step.

Start by [installing kubeseal](https://github.com/bitnami-labs/sealed-secrets#homebrew). Don't worry about the controller in that guide, we will deploy that via helm from the makefile. Also this only needs to be controlled once by the makefile, later this can be as well managed via argocd.
```bash
make sealed-secrets.install

# Ensure you have kubeseal installed before the following command
make sealed-secrets.seal.sshDeployKey
```

The command will show you your deploy key, you probably want to add this via your github repository settings so argocd could access it.

### Install argocd and bootstrap the cluster...
```bash
make argocd.install
```

### Updates & Lifecycle
From here on Argocd can be used to control the whole deployment (including argocd itself and the sealed-secrets)...
Use `make argocd.password` to retrieve your initial admin password from the cluster.

Happy Deploying ...


## Disclaimer
This is a hobby home project for home use only, it is not intended to be used in potentially hazardous environments...

Security hardening is not a current design goal at the moment!

Consider this explicitly as **NOT PRODUCTION READY!**

At the current stage I am not shy to break stuff!

## License
[MIT License](LICENSE)
