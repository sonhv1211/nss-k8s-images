#!/usr/bin/env bash
# Build dist/nss-k8s-images_<k8s>-<rev>_amd64.deb ben trong container ubuntu:24.04.
# Can Docker (Linux, WSL, hoac Git Bash tren Windows).
#
#   ./build.sh                    # PKG_REV mac dinh = 3
#   PKG_REV=4 ./build.sh
#   MAINTAINER="Ten <email>" ./build.sh
#
# Cache: work/<ten>.tar duoc dung lai neu work/<ten>.list trung voi images-<ten>.txt.
# Xoa thu muc work/ de pull lai toan bo image.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p work dist
SRC=$(pwd -W 2>/dev/null || pwd)   # Git Bash tren Windows can duong dan dang C:/...

MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$SRC:/src" \
  -e PKG_REV="${PKG_REV:-3}" \
  -e MAINTAINER="${MAINTAINER:-Son <sonhv1211@users.noreply.github.com>}" \
  ubuntu:24.04 bash /src/scripts/build-in-container.sh
