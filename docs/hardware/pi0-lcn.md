# Raspberry Pi Zero 2 W Edge Node (`pi0-lcn` — `date: 2026-11-07` – `2026-11-08`)

`pi0-lcn` (`192.168.1.24`) is a dedicated **512 MB RAM** Raspberry Pi Zero 2 W (`Broadcom BCM2710A1`, 4-core `linux/arm64` Cortex-A53) running **DietPi 64-bit (`ARMv8` Debian Trixie, Mainline Linux `6.18.y+rpt-rpi-v8`)** over Wi-Fi.

It is physically located downstairs at the electrical distribution sub-panel and connected via USB to the **LCN-PKU** serial coupler (`/dev/lcn-pku`, `9600 8N1`), bridging Local Control Network (LCN) bus telegrams to and from Mosquitto (`192.168.1.30:1883`) via the [`reverselcn`](../../deployments/smarthome/reverselcn.yaml) (`lcn2mqtt`) DaemonSet.

---

## 1. Special Engineering Challenges: Running K3s on 512 MB RAM

Running a 64-bit Kubernetes node on **512 MB physical LPDDR2 RAM** leaves almost zero margin for default Linux or kubelet settings:
* After carving out the minimum headless VideoCore GPU memory (`gpu_mem=16`), the kernel sees **`462 MiB` total usable RAM**.
* The `k3s-agent` binary (`containerd` + `kubelet` + `flannel` + `runc` shims) consumes **`~165–185 MiB` RSS** at baseline.
* **The DietPi `tmpfs` Trap**: By default, DietPi mounts `/tmp` and `/var/log` in RAM (`tmpfs`) with a default ceiling of **50% of physical RAM (`~231 MiB` each)**. During first-boot provisioning or heavy logging, writes to `/tmp` or `/var/log` can consume over `200 MiB` of RAM and trigger the Linux OOM-killer against `k3s-agent` or `sshd`.

### Memory Hardening Layers (Codified in [`node-bootstrap/pi0-lcn/`](../../node-bootstrap/pi0-lcn/))

| Layer | Configuration | Effect on 512 MB RAM Budget |
|-------|---------------|-----------------------------|
| **1. Headless GPU & Bluetooth Disable** ([`config.txt`](../../node-bootstrap/pi0-lcn/config.txt)) | `gpu_mem=16`, `max_framebuffers=0`, `dtoverlay=disable-bt` | Reclaims VideoCore GPU RAM (`462 MiB` usable) and frees UART/Bluetooth background services. |
| **2. In-RAM `zram` Swap** ([`dietpi.txt`](../../node-bootstrap/pi0-lcn/dietpi.txt)) | `AUTO_SETUP_SWAPFILE_LOCATION=zram` | Creates a `~255 MiB` compressed in-RAM `/dev/zram0` swap device to absorb transient `apt` / K3s startup spikes with **zero microSD wear**. |
| **3. Strict `tmpfs` & `journald` Caps** ([`playbook.yml`](../../node-bootstrap/pi0-lcn/playbook.yml)) | `/tmp` capped at `64M`, `/var/log` capped at `32M`, `systemd-journald` `Storage=volatile` + `RuntimeMaxUse=16M` | Prevents RAM-backed logs or temporary files from ever starving `k3s-agent`. |
| **4. Kubelet Reservations & Eviction** ([`playbook.yml`](../../node-bootstrap/pi0-lcn/playbook.yml)) | `kube-reserved=memory=128Mi`, `system-reserved=memory=64Mi`, `eviction-hard=memory.available<32Mi`, `image-gc-high-threshold=70` | Protects the OS and kubelet from pod memory growth and prunes unused container images early. |
| **5. Taint & Role Isolation** ([`nodes/pi0-lcn.yaml`](../../nodes/pi0-lcn.yaml)) | Taint `dedicated=lcn-serial:NoExecute` + roles `lcn-serial,monitoring` only | Blocks heavy cluster DaemonSets (`longhorn`, `metallb-speaker`, `kube-vip`) from scheduling onto `pi0-lcn`; only `reverselcn` and `prometheus-node-exporter` run on the node. |

With all 5 layers active in production (`reverselcn` + `prometheus-node-exporter` running), `pi0-lcn` uses **`~196 MiB` RAM** with **`~266 MiB` (`58%`) available** and **`0 MiB` swap used**.

---

## 2. Unprivileged USB Serial Access (`/dev/lcn-pku`)

Rather than running `reverselcn` with `privileged: true`, [`node-bootstrap/pi0-lcn/playbook.yml`](../../node-bootstrap/pi0-lcn/playbook.yml) configures two host-level rules so `reverselcn` runs completely unprivileged (`runAsNonRoot: true`, `runAsUser: 10001`, `supplementalGroups: [20]`, `capabilities.drop: ["ALL"]`):
1. **Deterministic udev symlink** ([`99-lcn-pku.rules`](../../node-bootstrap/pi0-lcn/99-lcn-pku.rules)): Matches FTDI (`0403:6001`) or `/dev/ttyUSB*` / `/dev/ttyACM*` and creates `/dev/lcn-pku` owned by `root:dialout` (`0660`, group ID `20`).
2. **Containerd v3 OCI base spec device whitelist**: Adds character device majors `188` (`ttyUSB*`) and `166` (`ttyACM*`) (`rwm`) to `/etc/containerd/cri-base.json` and wires it via `/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/10-serial.toml` so Linux cgroups v2 permits the unprivileged container to open `/dev/lcn-pku`.

---

## 3. Zero-Touch SD Card Provisioning & Day-2 Ansible Updates

1. Download the **DietPi Raspberry Pi 2/3/4/Zero 2 (ARMv8 64-bit Trixie)** image from [dietpi.com](https://dietpi.com/#download) and flash it to a microSD card.
2. Mount the flashed SD card's FAT32 `boot` partition on your workstation.
3. Run [`./node-bootstrap/pi0-lcn/prepare-boot.sh`](../../node-bootstrap/pi0-lcn/prepare-boot.sh) (prompts interactively for `WIFI_SSID`, `WIFI_KEY`, `DIETPI_PASSWORD`, and `K3S_TOKEN` without writing secrets to local disk, or reads `.secrets/pi0-lcn.env` if present, defaulting `K3S_URL` to the HA VIP `https://192.168.1.20:6443`):
   ```bash
   ./node-bootstrap/pi0-lcn/prepare-boot.sh /run/media/$USER/boot
   ```
4. Insert the SD card into `pi0-lcn` with the LCN-PKU USB coupler attached and power it on:
   * On first boot, DietPi applies `config.txt`, `cmdline.txt`, `dietpi.txt`, and `dietpi-wifi.txt`, then executes [`Automation_Custom_Script.sh`](../../node-bootstrap/pi0-lcn/Automation_Custom_Script.sh) (`AUTO_SETUP_CUSTOM_SCRIPT_EXEC=0`), which installs `ansible-core`, runs [`playbook.yml`](../../node-bootstrap/pi0-lcn/playbook.yml) locally (`ansible-playbook --connection=local`), and deletes `/boot/firmware/k3s-vars.yml`.
5. **Day-2 Remote Reconciliation**:
   Any future configuration changes in [`node-bootstrap/pi0-lcn/playbook.yml`](../../node-bootstrap/pi0-lcn/playbook.yml) can be applied idempotently over SSH from your workstation without reflashing:
   ```bash
   ansible-playbook -i pi0-lcn.lan, -u kasch --become node-bootstrap/pi0-lcn/playbook.yml
   ```
