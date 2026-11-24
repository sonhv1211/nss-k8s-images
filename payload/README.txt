nss-k8s-images -- Kubernetes v1.34.13 offline cho Ubuntu 24.04 amd64
=====================================================================

Noi dung /usr/share/nss-images/
  debs/                containerd.io 2.2.1, kubeadm/kubelet/kubectl 1.34.13,
                       cri-tools, kubernetes-cni + tien ich conntrack, socat,
                       ethtool (kem thu vien)
  k8s-images.tar       image control-plane + Flannel   (danh sach: IMAGES.txt)
  addons-images.tar    image addon + test              (IMAGES-addons.txt)
  kube-flannel.yml     CNI Flannel, Pod CIDR 10.244.0.0/16
  manifests/           metrics-server.yaml   (da them --kubelet-insecure-tls)
                       local-path-storage.yaml (helper pod -> busybox:1.37)
                       metallb-native.yaml
  setup-node.sh        cai goi + cau hinh node + nap image
  SHA256SUMS           doi chieu: cd /usr/share/nss-images && sha256sum -c SHA256SUMS

1. Tren MOI node (master + worker)
   sudo dpkg -i nss-k8s-images_1.34.13-3_amd64.deb
   sudo /usr/share/nss-images/setup-node.sh
   -> cai containerd/kubeadm/kubelet/kubectl tu debs/, nap module overlay +
      br_netfilter, sysctl ip_forward, tat swap, containerd SystemdCgroup=true
      va sandbox pause:3.10.1, nap toan bo image vao containerd (ns k8s.io),
      bat kubelet. Goi phu tro/thu vien chi cai khi node chua co -- script
      khong bao gio nang cap goi he thong dang co tren node.

2. Tren master
   sudo kubeadm init --kubernetes-version v1.34.13 \
        --pod-network-cidr 10.244.0.0/16 \
        --apiserver-advertise-address <IP_MASTER>
   mkdir -p $HOME/.kube
   sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
   sudo chown $(id -u):$(id -g) $HOME/.kube/config
   kubectl apply -f /usr/share/nss-images/kube-flannel.yml

   Luon truyen --kubernetes-version: neu khong, kubeadm se thu hoi dl.k8s.io.
   Node co nhieu card mang (vd ens18 + ens19): dat --apiserver-advertise-address
   va kubelet --node-ip theo IP cua card noi cum, va them "- --iface=<card>"
   vao args cua container kube-flannel trong kube-flannel.yml truoc khi apply.
   CoreDNS forward ra DNS cua node: node phai co it nhat 1 nameserver KHONG phai
   loopback (Ubuntu dung systemd-resolved thi kubeadm tu lay
   /run/systemd/resolve/resolv.conf). DNS loopback -> CoreDNS CrashLoop (loop).

3. Tren worker
   Chay lenh "kubeadm join ..." in ra o buoc 2
   (in lai: kubeadm token create --print-join-command tren master).

4. Kiem tra
   kubectl get nodes -o wide          # 3 node Ready
   kubectl get pods -A                # coredns, kube-flannel, kube-proxy Running
   sudo crictl images

5. Addon (tuy chon, deu chay offline)
   kubectl apply -f /usr/share/nss-images/manifests/metrics-server.yaml
   kubectl apply -f /usr/share/nss-images/manifests/local-path-storage.yaml
   kubectl apply -f /usr/share/nss-images/manifests/metallb-native.yaml
     (MetalLB can them IPAddressPool + L2Advertisement theo dai IP cua lab)
   Image test: nginx:1.27-alpine, nginx:1.30-alpine (rolling update),
     busybox:1.37, curlimages/curl:8.23.0, e2e-test-images/agnhost:2.67.0
