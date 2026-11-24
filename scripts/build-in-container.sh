#!/bin/bash
# Chay ben trong container ubuntu:24.04 (do build.sh goi). Repo duoc mount tai /src.
set -euo pipefail

K8S_VERSION=1.34.13
PKG_REV=${PKG_REV:-2}
PKG_VERSION=$K8S_VERSION-$PKG_REV
MAINTAINER=${MAINTAINER:-Son <sonhv1211@users.noreply.github.com>}

# Goi .deb cot loi -- pin chinh xac phien ban
K8S_DEB=1.34.13-1.1
CRI_TOOLS_DEB=1.34.0-1.1
CNI_DEB=1.7.1-1.1
CONTAINERD_DEB=2.2.1-1~ubuntu.24.04~noble
# Goi phu tro: setup-node.sh chi cai neu node chua co (hoac dang co ban cu hon)
EXTRA_DEBS="conntrack socat ethtool ebtables iptables iproute2 kmod"

FLANNEL_VERSION=v0.28.11
METRICS_SERVER_VERSION=v0.9.1
LOCAL_PATH_VERSION=v0.0.37
METALLB_VERSION=v0.16.2
CRANE_VERSION=v0.22.1

SRC=/src
WORK=$SRC/work
DIST=$SRC/dist
ROOT=/build/root
D=$ROOT/usr/share/nss-images
export DEBIAN_FRONTEND=noninteractive

log() { echo "==> $*"; }
die() { echo "LOI: $*" >&2; exit 1; }

# Chuan hoa ten image giong containerd: nginx:x -> docker.io/library/nginx:x
norm() {
  local i=$1 first=${1%%/*}
  if [[ $i != */* ]]; then echo "docker.io/library/$i"
  elif [[ $first != *.* && $first != *:* && $first != localhost ]]; then echo "docker.io/$i"
  elif [[ $first == docker.io && ${i#docker.io/} != */* ]]; then echo "docker.io/library/${i#docker.io/}"
  else echo "$i"; fi
}
list_images() { grep -vE '^[[:space:]]*(#|$)' "$1"; }

# ---------------------------------------------------------------- cong cu
log "Chuan bi cong cu build"
cp /var/lib/dpkg/status /tmp/status.base   # trang thai ubuntu:24.04 tron -> tinh dependency
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl gpg >/dev/null

install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq

CRANE_URL=https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION
curl -fsSL -o /tmp/go-containerregistry_Linux_x86_64.tar.gz "$CRANE_URL/go-containerregistry_Linux_x86_64.tar.gz"
curl -fsSL -o /tmp/crane-checksums.txt "$CRANE_URL/checksums.txt"
(cd /tmp && grep ' go-containerregistry_Linux_x86_64.tar.gz$' crane-checksums.txt | sha256sum -c --quiet -)
tar -xzf /tmp/go-containerregistry_Linux_x86_64.tar.gz -C /usr/local/bin crane

rm -rf /build
install -d -m 0755 "$ROOT/DEBIAN" "$D/debs" "$D/manifests"

# ---------------------------------------------------------------- .deb
log "Tai goi .deb (dependency tinh tren ubuntu:24.04 tron)"
apt-get clean
apt-get install -y -qq --download-only --no-install-recommends \
  -o Dir::State::status=/tmp/status.base \
  "containerd.io=$CONTAINERD_DEB" "kubeadm=$K8S_DEB" "kubelet=$K8S_DEB" "kubectl=$K8S_DEB" \
  "cri-tools=$CRI_TOOLS_DEB" "kubernetes-cni=$CNI_DEB" $EXTRA_DEBS >/dev/null
cp /var/cache/apt/archives/*.deb "$D/debs/"
ls "$D/debs"

# ---------------------------------------------------------------- image
pull_set() {   # $1 = core|addons ; $2 = ten tar
  local list=$SRC/images-$1.txt tar=$WORK/$2
  if [ -s "$tar" ] && cmp -s "$list" "$WORK/$1.list"; then
    log "Dung lai $tar (cache)"
  else
    log "Pull image tu images-$1.txt -> $2"
    mapfile -t imgs < <(list_images "$list")
    rm -f "$tar"
    crane pull --platform linux/amd64 "${imgs[@]}" "$tar.part"
    mv "$tar.part" "$tar"
    cp "$list" "$WORK/$1.list"
  fi
  cp "$tar" "$D/$2"
}
pull_set core k8s-images.tar
pull_set addons addons-images.tar
list_images "$SRC/images-core.txt" > "$D/IMAGES.txt"
list_images "$SRC/images-addons.txt" > "$D/IMAGES-addons.txt"

# ---------------------------------------------------------------- manifest
log "Tai manifest"
curl -fsSL -o "$D/kube-flannel.yml" \
  "https://github.com/flannel-io/flannel/releases/download/$FLANNEL_VERSION/kube-flannel.yml"
curl -fsSL -o "$D/manifests/metrics-server.yaml" \
  "https://github.com/kubernetes-sigs/metrics-server/releases/download/$METRICS_SERVER_VERSION/components.yaml"
curl -fsSL -o "$D/manifests/local-path-storage.yaml" \
  "https://raw.githubusercontent.com/rancher/local-path-provisioner/$LOCAL_PATH_VERSION/deploy/local-path-storage.yaml"
curl -fsSL -o "$D/manifests/metallb-native.yaml" \
  "https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml"

# Va cho lab offline:
#  - metrics-server: kubelet cua kubeadm dung cert tu ky -> --kubelet-insecure-tls
#  - local-path: helper pod dung busybox khong tag (=latest) -> busybox:1.37 co san trong goi
sed -i 's#^\([[:space:]]*\)- --metric-resolution=15s$#&\n\1- --kubelet-insecure-tls#' "$D/manifests/metrics-server.yaml"
sed -i 's#image: docker.io/library/busybox$#image: docker.io/library/busybox:1.37#' "$D/manifests/local-path-storage.yaml"
grep -q -- '- --kubelet-insecure-tls' "$D/manifests/metrics-server.yaml" || die "va metrics-server that bai"
grep -q 'image: docker.io/library/busybox:1.37' "$D/manifests/local-path-storage.yaml" || die "va local-path that bai"

# Moi image ma manifest tham chieu phai co trong goi
mapfile -t have < <(list_images "$SRC/images-core.txt"; list_images "$SRC/images-addons.txt")
have_norm=" "; for i in "${have[@]}"; do have_norm+="$(norm "$i") "; done
for img in $(grep -hoE 'image:[[:space:]]*[^[:space:]]+' "$D/kube-flannel.yml" "$D"/manifests/*.yaml | awk '{print $2}' | tr -d '"' | sort -u); do
  [[ $have_norm == *" $(norm "$img") "* ]] || die "manifest can image $img nhung goi khong co"
done
log "Tat ca image trong manifest deu co trong goi"

# ---------------------------------------------------------------- payload + control
install -m 0755 "$SRC/payload/setup-node.sh" "$D/setup-node.sh"
install -m 0644 "$SRC/payload/README.txt" "$D/README.txt"

find "$ROOT" -type d -exec chmod 0755 {} +
find "$D" -type f ! -name setup-node.sh -exec chmod 0644 {} +
(cd "$D" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum > SHA256SUMS)
chmod 0644 "$D/SHA256SUMS"

ver_of() { dpkg-deb -f "$(ls "$D"/debs/"$1"_*.deb)" Version; }
cat > "$ROOT/DEBIAN/control" <<EOF
Package: nss-k8s-images
Version: $PKG_VERSION
Section: misc
Priority: optional
Architecture: amd64
Maintainer: $MAINTAINER
Installed-Size: $(du -sk "$ROOT/usr" | cut -f1)
Description: Kubernetes v$K8S_VERSION offline bundle (containerd + kubeadm + images)
 Bo cai Kubernetes v$K8S_VERSION cho Ubuntu 24.04 amd64 khong co internet,
 dat tai /usr/share/nss-images/:
   debs/              containerd.io $(ver_of containerd.io), kubeadm/kubelet/kubectl
                      $(ver_of kubeadm), cri-tools, kubernetes-cni + goi phu tro
   k8s-images.tar     image control-plane + Flannel (IMAGES.txt)
   addons-images.tar  metrics-server, local-path, MetalLB, image test
   kube-flannel.yml   manifest CNI; manifests/ cho cac addon
   setup-node.sh      cai runtime + k8s, cau hinh containerd, nap image
 Goi nay khong chay maintainer script -- chi giai nen payload. Sau khi cai:
   sudo /usr/share/nss-images/setup-node.sh
EOF
chmod 0644 "$ROOT/DEBIAN/control"

OUT=$DIST/nss-k8s-images_${PKG_VERSION}_amd64.deb
log "dpkg-deb --build -> $OUT"
dpkg-deb --root-owner-group -Zzstd -z19 --threads-max="$(nproc)" --build "$ROOT" "$OUT"
dpkg-deb -I "$OUT"
ls -l "$OUT"
sha256sum "$OUT"
