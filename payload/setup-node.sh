#!/bin/bash
# setup-node.sh -- bien 1 may Ubuntu 24.04 tron thanh node Kubernetes v1.34.13, KHONG can internet.
# Chay giong het nhau tren master va worker, sau khi da `dpkg -i nss-k8s-images_*.deb`:
#
#   sudo /usr/share/nss-images/setup-node.sh              # cai + nap toan bo image
#   sudo /usr/share/nss-images/setup-node.sh --no-addons  # chi nap image core (k8s-images.tar)
#
# Chay lai nhieu lan khong sao (idempotent). Khong tu kubeadm init/join -- xem README.txt.
set -euo pipefail

D=/usr/share/nss-images
K8S_VERSION=v1.34.13
SANDBOX_IMAGE=registry.k8s.io/pause:3.10.1
CORE_PKGS="containerd.io kubeadm kubelet kubectl cri-tools kubernetes-cni"
HOLD_PKGS="containerd.io kubeadm kubelet kubectl"
IMPORT_ADDONS=1

for a in "$@"; do
  case "$a" in
    --no-addons) IMPORT_ADDONS=0 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Tham so khong hop le: $a" >&2; exit 2 ;;
  esac
done

log()  { echo "[nss-setup] $*"; }
warn() { echo "[nss-setup] CANH BAO: $*" >&2; }
die()  { echo "[nss-setup] LOI: $*" >&2; exit 1; }
trap 'echo "[nss-setup] LOI: lenh that bai o dong $LINENO: $BASH_COMMAND" >&2' ERR
installed_version() {   # in ra version neu goi da cai ("install|hold ok installed"), khong thi rong
  { dpkg-query -W -f='${Status}|${Version}' "$1" 2>/dev/null || true; } |
    sed -nE 's/^(install|hold) ok installed\|//p'
}
norm() {                # nginx:x -> docker.io/library/nginx:x (giong cach containerd dat ten)
  local i=$1 first=${1%%/*}
  if [[ $i != */* ]]; then echo "docker.io/library/$i"
  elif [[ $first != *.* && $first != *:* && $first != localhost ]]; then echo "docker.io/$i"
  elif [[ $first == docker.io && ${i#docker.io/} != */* ]]; then echo "docker.io/library/${i#docker.io/}"
  else echo "$i"; fi
}

[ "$(id -u)" -eq 0 ] || die "can chay bang root (sudo)"
[ "$(dpkg --print-architecture)" = amd64 ] || die "goi chi ho tro amd64"

# ------------------------------------------------------------------------------------------
log "1/7 Doi chieu SHA256SUMS"
(cd "$D" && sha256sum -c --quiet SHA256SUMS) || die "checksum sai -- payload trong $D bi hong"

# ------------------------------------------------------------------------------------------
log "2/7 Cai containerd + kubeadm/kubelet/kubectl tu $D/debs"
for p in containerd runc; do
  [ -z "$(installed_version "$p")" ] ||
    die "may dang co goi Ubuntu '$p' -- xung dot voi containerd.io. Go truoc: apt-get remove $p"
done
debs=()
for f in "$D"/debs/*.deb; do
  p=$(dpkg-deb -f "$f" Package)
  v=$(dpkg-deb -f "$f" Version)
  cur=$(installed_version "$p")
  case " $CORE_PKGS " in
    *" $p "*)   # goi k8s/containerd: cai neu chua co hoac dang co ban cu hon
      if [ -n "$cur" ] && dpkg --compare-versions "$cur" ge "$v"; then continue; fi ;;
    *)          # goi phu tro / thu vien: CHI cai khi node chua co, khong nang cap goi he thong
      [ -z "$cur" ] || continue ;;
  esac
  debs+=("$f")
done
if [ ${#debs[@]} -gt 0 ]; then
  log "  dpkg -i ${#debs[@]} goi: $(for f in "${debs[@]}"; do basename "$f" | cut -d_ -f1; done | tr '\n' ' ')"
  DEBIAN_FRONTEND=noninteractive dpkg -i --force-confdef --force-confold "${debs[@]}"
else
  log "  tat ca goi da duoc cai"
fi
for p in $CORE_PKGS; do [ -n "$(installed_version "$p")" ] || die "goi $p chua duoc cai"; done
apt-mark hold $HOLD_PKGS >/dev/null
[ "$(kubeadm version -o short)" = "$K8S_VERSION" ] || die "kubeadm khong phai $K8S_VERSION"

# ------------------------------------------------------------------------------------------
log "3/7 Kernel module + sysctl"
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay      || warn "khong modprobe duoc overlay"
modprobe br_netfilter || warn "khong modprobe duoc br_netfilter"
cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null 2>&1 || warn "sysctl --system bao loi (chay lai tay de xem)"
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || warn "net.ipv4.ip_forward chua = 1"

# ------------------------------------------------------------------------------------------
log "4/7 Tat swap"
swapoff -a || warn "swapoff -a that bai"
sed -ri '/^[^#][^[:space:]]*[[:space:]]+[^[:space:]]+[[:space:]]+swap[[:space:]]/ s/^/#/' /etc/fstab

# ------------------------------------------------------------------------------------------
log "5/7 Cau hinh containerd (SystemdCgroup=true, sandbox=$SANDBOX_IMAGE)"
CFG=/etc/containerd/config.toml
mkdir -p /etc/containerd
if [ -f "$CFG" ] && ! grep -q '^# nss-k8s-images' "$CFG"; then
  cp "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)"
fi
{ echo "# nss-k8s-images setup-node.sh -- sinh tu 'containerd config default'"; containerd config default; } > "$CFG.new"
sed -i -e 's/SystemdCgroup = false/SystemdCgroup = true/' \
       -e "s#^\([[:space:]]*sandbox = \).*#\1'$SANDBOX_IMAGE'#" "$CFG.new"
grep -q 'SystemdCgroup = true' "$CFG.new"            || die "khong dat duoc SystemdCgroup = true"
grep -q "sandbox = '$SANDBOX_IMAGE'" "$CFG.new"      || die "khong dat duoc sandbox image"
mv "$CFG.new" "$CFG"
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF
systemctl daemon-reload
systemctl enable containerd >/dev/null 2>&1
systemctl restart containerd
for _ in $(seq 1 30); do ctr version >/dev/null 2>&1 && break; sleep 1; done
ctr version >/dev/null 2>&1 || die "containerd khong chay -- xem: journalctl -u containerd"

# ------------------------------------------------------------------------------------------
log "6/7 Nap image vao containerd (namespace k8s.io)"
lists=("$D/IMAGES.txt")
ctr -n k8s.io images import --platform linux/amd64 "$D/k8s-images.tar" >/dev/null
if [ "$IMPORT_ADDONS" = 1 ]; then
  ctr -n k8s.io images import --platform linux/amd64 "$D/addons-images.tar" >/dev/null
  lists+=("$D/IMAGES-addons.txt")
fi
have=$(ctr -n k8s.io images ls -q)
missing=0
while read -r img; do
  [ -z "$img" ] && continue
  grep -qxF "$(norm "$img")" <<<"$have" || { warn "thieu image $img"; missing=1; }
done < <(cat "${lists[@]}")
[ "$missing" = 0 ] || die "nap image chua du"

# ------------------------------------------------------------------------------------------
log "7/7 Bat kubelet (se restart lien tuc cho toi khi kubeadm init/join -- binh thuong)"
systemctl enable kubelet >/dev/null 2>&1

# CoreDNS forward ra DNS cua node: canh bao som cac cau hinh lam CoreDNS khong chay
RC=/etc/resolv.conf
systemctl is-active --quiet systemd-resolved && RC=/run/systemd/resolve/resolv.conf
ns=$(awk '/^nameserver/{print $2}' "$RC" 2>/dev/null || true)
if [ -z "$ns" ]; then
  warn "$RC khong co nameserver -> CoreDNS co the loi 'no nameservers found'." \
       "Khai DNS cho node (netplan) truoc khi kubeadm init"
elif ! grep -qvE '^(127\.|::1$)' <<<"$ns"; then
  warn "$RC chi co DNS loopback ($(echo $ns)) -> CoreDNS se CrashLoop (plugin loop)." \
       "Dat resolvConf cua kubelet toi file co DNS khong phai loopback"
fi

log "XONG: containerd $(containerd --version | awk '{print $3}'), kubeadm $(kubeadm version -o short)," \
    "$(cat "${lists[@]}" | grep -c .) image da nap"
log "Buoc tiep theo (xem $D/README.txt):"
log "  master: kubeadm init --kubernetes-version $K8S_VERSION --pod-network-cidr 10.244.0.0/16 ..."
log "  worker: kubeadm join ... (lenh in ra sau khi init tren master)"
