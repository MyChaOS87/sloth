# Raspberry Pi CM4 Single Node (Historic / Outdated — `date: 2022-12-16`)

> [!WARNING]
> **Historic / Retired Hardware Setup (`date: 2022-12-16` – `2023-08-06`)**: This single-node Raspberry Pi Compute Module 4 (`cm4-01.lan` on a Waveshare CM4-NANO-B carrier board) setup was the original December 2022 prototype for `sloth` and is kept here strictly for historical reference. After adding Longhorn (`date: 2022-12-19`) and observability/SSO workloads, it hit hard CPU, RAM, and I/O performance boundaries and was replaced on `date: 2023-08-06` by the 3-node [Radxa Rock 5B HA Cluster](./rock5b-cluster.md) and later complemented by the dedicated [Raspberry Pi Zero 2 W Edge Node (`pi0-lcn`)](./pi0-lcn.md) (`date: 2026-11-07`).

---

## 1. Install Raspberry Pi OS onto CM4 eMMC (`date: 2022-12-16`)

Reference: [How to flash Raspberry Pi OS onto the Compute Module 4 eMMC with usbboot](https://www.jeffgeerling.com/blog/2020/how-flash-raspberry-pi-os-compute-module-4-emmc-usbboot)

```bash
# Clone usbboot
git clone --depth=1 https://github.com/raspberrypi/usbboot

# Build
cd usbboot
make

# Set RPI CM4 into usbboot mode and plug into USB
# Waveshare CM4-NANO-B has a switch for that; other boards have jumpers... rtfm

# Run ./rpiboot
sudo ./rpiboot
```

Once mounted as an external USB mass-storage disk, flash **Raspberry Pi OS Lite (64-bit)** using `rpi-imager`, enable SSH, and set the hostname.

---

## 2. Install K3s on Raspberry Pi CM4

```bash
# Enable cgroups
sudo vi /boot/cmdline.txt
# Append the following flags at the end of the first line (without #):
# cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1

# Reboot into the updated kernel cmdline
systemctl reboot

# Install k3s
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
# NOTE: --write-kubeconfig-mode 644 allows any local user to read the K3s root kubeconfig.
# Used on the original prototype only so ./kubectl-config-remote.sh could pull credentials via the default "pi" user.
```
