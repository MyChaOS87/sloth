# SLOTH (SLightly Overengineered "Trivial" Homeautomation)
## Introduction
This is my personal homeserver, which I build mainly for Homeautomation. This project is also my k3s and argocd playground.

Currently its running on a Raspberry Pi CM4. Not an a RPi just skip that chapter ans start with [Bootstrapping Secrets and argo-cd](#bootstrapping-secrets-and-argo-cd)
I try to keep as much as possible hardware independent.

### Repository structure
* `.secrets/` used for temporary secret files, those should never get checked in
* `argocd/` charts to bootstrap the cluster, base functionality of argo-cd & sealed-secrets only.
* `./*` some scripts used in this guide and the public key part of the deploy key for this repo so argo-cd is able to retrieve it.

### The project currently uses:
* Kubernetes ([K3s](https://k3s.io)) 
* [Helm](https://helm.sh/)
* [argo-cd](https://argo-cd.readthedocs.io/en/stable/) for continuous delivery
* [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets)

It's a hobby project, so see [Disclaimer](#disclaimer).

### Planned additions (in no particular order):
* longhorn
* More CM4 RPis (but those are hard to find these days)
* mosqitto
* influxdb
* grafana
* SSO via Keycloak
* proper DNS - currently my local dns, managed by my firewall outside of the cluster is just a dnsmasq using `.lan` and has an entry to forward everything in `*.k8s.lan` to my host `address=/k8s.lan/192.168.XXX.YYY`.
* Let's Encrypt
* making it more reusable - complete seperation of values and templates. pulling values into a different repository, so this could be universally used for bootstrapping any clusters with the base argocd stuff.
* ...

## RPi Preparation
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


### Install k3s
```bash
# Enable cgroups
sudo vi /boot/cmdline.txt
# Append the following line at the end of first line (without # of course): 
# cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1

# Reboot the kernel
systemctl reboot

# Install k3s
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
```

### Access k3s from remote (skip if you run everything from the k3s server)
Run the following from your remote host you want to control the cluster from: 
```bash
# adjust the k8sHost to your setup...
k8sHost=cm4-01.lan ./kubectl-config-remote.sh 
```

## Bootstrapping Secrets and argo-cd
### Prequisites for the rest of the install 
* kubectl (configured to be used against your k3s "cluster")
* helm 
* kubeseal - for sealing secrets (guide in [Prepare Secret](#prepare-secret))

### Prepare Secret
as we use [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) my repository file will not help you, as your cluster cannot decrypt it.

If you delete the sealed-secrets deployment from your cluster you have to redo this step.

Start by [installing kubeseal](https://github.com/bitnami-labs/sealed-secrets#homebrew). Don't worry about the controller, we will deploy that via helm in the makefile.
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
From here on Argocd can be used to controll the whole deployment...
Use `make argocd.password` to retrieve your admin password from the cluster, as we have no SSO yet. ([see above](#planned-additions-in-no-particular-order))

Happy Deploying ...


## Disclaimer
This is a hobby home project for home use only, it is not intended to be used in malicious environments...

Consider this explicitly as **NOT PRODUCTION READY!**


## License
[MIT License](LICENSE)
