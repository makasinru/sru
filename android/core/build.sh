#!/usr/bin/env bash
# Собирает ядро (Xray-core + обёртка) для Android и кладёт geo-базы в assets.
# Нужен только Go (версия из go.mod); Android NDK не требуется: ядро —
# чистый Go (CGO_ENABLED=0), который Go умеет собирать для android/arm64.
# android/arm и android/amd64 в Go требуют cgo (NDK), поэтому поддерживается
# только arm64-v8a — это все 64-битные ARM-устройства.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app="$here/../app/src/main"
jni="$app/jniLibs/arm64-v8a"
geo="$app/assets/geo"
mkdir -p "$jni" "$geo"

echo "sru-core: сборка arm64-v8a"
(
  cd "$here"
  GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -buildvcs=false \
    -ldflags='-s -w -buildid= -checklinkname=0' -o "$jni/libsrucore.so" .
)

# geoip:ru, geosite:category-ru, category-ads-all и др. — правила маршрутизации.
geo_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
for f in geoip.dat geosite.dat; do
  if [[ ! -s "$geo/$f" || "${SRU_REFRESH_GEO:-0}" == "1" ]]; then
    echo "sru-core: загрузка $f"
    curl -fsSL "$geo_url/$f" -o "$geo/$f.tmp"
    curl -fsSL "$geo_url/$f.sha256sum" -o "$geo/$f.sha256sum"
    (cd "$geo" && sed "s/ $f\$/ $f.tmp/" "$f.sha256sum" | sha256sum -c --quiet)
    mv "$geo/$f.tmp" "$geo/$f"
    rm -f "$geo/$f.sha256sum"
  fi
done
echo "sru-core: готово"
