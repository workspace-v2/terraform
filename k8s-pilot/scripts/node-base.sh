#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
swapoff -a
printf '%s\n' overlay br_netfilter > /etc/modules-load.d/k8s-pilot.conf
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/99-k8s-pilot.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
SYSCTL
sysctl --system >/dev/null

apt-get -qq -o Acquire::Retries=4 update
apt-get -qq -o DPkg::Lock::Timeout=180 install -y ca-certificates curl gpg containerd conntrack nfs-common
install -d /etc/containerd /etc/apt/keyrings
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
systemctl enable containerd
systemctl restart containerd

kubernetes_repo=https://pkgs.k8s.io/core:/stable:/v1.35/deb
curl -fsSL --retry 4 "$kubernetes_repo/Release.key" |
  gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] %s/ /\n' "$kubernetes_repo" > /etc/apt/sources.list.d/kubernetes.list
apt-get -qq -o Acquire::Retries=4 update
apt-get -qq -o DPkg::Lock::Timeout=180 install -y   kubelet=1.35.10-1.1 kubeadm=1.35.10-1.1 kubectl=1.35.10-1.1
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet
