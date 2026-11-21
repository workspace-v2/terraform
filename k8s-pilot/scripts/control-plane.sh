# Appended to node-base.sh by Terraform.
export KUBECONFIG=/etc/kubernetes/admin.conf

kubeadm init --kubernetes-version v1.35.10 --node-name k8s-pilot-control \
  --pod-network-cidr=10.244.0.0/16 --cri-socket=unix:///run/containerd/containerd.sock \
  --skip-token-print
kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.27.4/kube-flannel.yml
kubectl taint node k8s-pilot-control node-role.kubernetes.io/control-plane:NoSchedule-
kubectl label node k8s-pilot-control monitoring=yes kubernetes.io/hostname=ip-172-31-35-123 --overwrite
kubectl wait node/k8s-pilot-control --for=condition=Ready --timeout=360s
kubectl -n kube-system rollout status deployment/coredns --timeout=240s
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.32/deploy/local-path-storage.yaml
