#cloud-config
# Declarative Kairos cloud-config template for sloth Radxa Rock 5B HA control-plane & storage nodes.
# Rendered per node via ./node-bootstrap/rock5b/render-node-config.sh <rock5b-coffee|rock5b-first|rock5b-but>

hostname: __NODE_HOSTNAME__

users:
  - name: kasch
    groups:
      - admin
      - sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAMmYsSPJEdaCH02B3S3cFkZLNgR+N2nCmsIiUNDHpYK kasch@cirilla

install:
  # Clean full-disk Kairos installation on the 1 TB M.2 NVMe SSD.
  # poweroff: true avoids rebooting back into the MicroSD installer before the card is removed.
  device: /dev/nvme0n1
  auto: true
  poweroff: true
  grub_options:
    extra_cmdline: "console=ttyS2,1500000 console=tty1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory net.ifnames=1"

stages:
  initramfs:
    - name: "Configure passwordless sudo for operator kasch"
      files:
        - path: /etc/sudoers.d/90-kasch
          permissions: 0440
          owner: 0
          group: 0
          content: |
            kasch ALL=(ALL) NOPASSWD: ALL
    - name: "Configure static IPv4, DNS via systemd-resolved, and K3s server parameters before services start"
      files:
        - path: /etc/systemd/network/10-lan.network
          permissions: 0644
          owner: 0
          group: 0
          content: |
            [Match]
            Driver=r8169

            [Network]
            Address=__NODE_IP__/24
            Gateway=192.168.1.1
            DNS=192.168.1.1
        - path: /etc/rancher/k3s/config.yaml
          permissions: 0600
          owner: 0
          group: 0
          content: |
            node-ip: "__NODE_IP__"
            node-label:
              - "kairos.io/managed=true"
            tls-san:
              - "192.168.1.20"
              - "api.internal.k8s.example.com"
              - "api.rock.k8s.example.com"
              - "192.168.1.21"
              - "192.168.1.22"
              - "192.168.1.23"

  boot:
    - name: "Initialize Longhorn disk0/replicas directory and preserve existing diskUUID on COS_PERSISTENT"
      commands:
        - |
          mkdir -p /var/lib/longhorn/disk0/replicas
          if [ ! -f /var/lib/longhorn/disk0/longhorn-disk.cfg ]; then
            printf '{"diskUUID":"__LONGHORN_DISK_UUID__"}\n' > /var/lib/longhorn/disk0/longhorn-disk.cfg
          fi

k3s:
  enabled: true
  args:
    - --server
    - https://192.168.1.20:6443
    - --disable=traefik
    - --disable=servicelb
  env:
    K3S_TOKEN: "__K3S_TOKEN__"
