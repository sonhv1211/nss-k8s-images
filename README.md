# nss-k8s-images
Offline Kubernetes v1.34.13 bundle for Ubuntu 24.04 amd64, packaged as a single `.deb`:
containerd, kubeadm/kubelet/kubectl, all kubeadm + Flannel images, and a few basic add-ons.

## Noi dung goi (tu 1.34.13-2)

Payload nam o `/usr/share/nss-images/`. Goi khong co maintainer script -- `dpkg -i` chi giai nen.

| Duong dan | Noi dung |
|---|---|
| `debs/` | containerd.io 2.2.1, kubeadm/kubelet/kubectl 1.34.13-1.1, cri-tools 1.34.0, kubernetes-cni 1.7.1 + goi phu tro (conntrack, socat, ethtool, ebtables, iptables, iproute2, kmod va thu vien) |
| `k8s-images.tar` | 12 image: control-plane v1.34.13, coredns, etcd, pause, Flannel, nginx, busybox ([images-core.txt](images-core.txt)) |
| `addons-images.tar` | metrics-server, local-path-provisioner, MetalLB, agnhost, curl, nginx 1.30 ([images-addons.txt](images-addons.txt)) |
| `kube-flannel.yml`, `manifests/` | Manifest CNI + addon, da va de chay offline |
| `setup-node.sh` | Cai goi, cau hinh kernel/swap/containerd, nap image, bat kubelet |

## Cach dung

Tren moi node (master + worker):

```bash
sudo dpkg -i nss-k8s-images_1.34.13-2_amd64.deb
sudo /usr/share/nss-images/setup-node.sh
```

Master:

```bash
sudo kubeadm init --kubernetes-version v1.34.13 --pod-network-cidr 10.244.0.0/16 \
     --apiserver-advertise-address <IP_MASTER>
mkdir -p $HOME/.kube && sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config && sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl apply -f /usr/share/nss-images/kube-flannel.yml
```

Worker: chay lenh `kubeadm join ...` in ra tren master. Chi tiet, gom ca addon: [payload/README.txt](payload/README.txt).

## Build

Can Docker (Linux, WSL hoac Git Bash tren Windows):

```bash
./build.sh            # -> dist/nss-k8s-images_1.34.13-2_amd64.deb
```

Phien ban goi .deb, addon va manifest duoc pin trong [scripts/build-in-container.sh](scripts/build-in-container.sh).
Image duoc pull bang `crane --platform linux/amd64` va cache trong `work/`.
