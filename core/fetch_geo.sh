#!/usr/bin/env bash
# Скачивает geoip.dat / geosite.dat (правила «кроме РФ», реклама) в каталог $1
# и проверяет контрольные суммы. SRU_REFRESH_GEO=1 — скачать заново.
set -euo pipefail
dest="$1"
mkdir -p "$dest"
geo_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
for f in geoip.dat geosite.dat; do
  if [[ ! -s "$dest/$f" || "${SRU_REFRESH_GEO:-0}" == "1" ]]; then
    echo "sru-core: загрузка $f"
    curl -fsSL "$geo_url/$f" -o "$dest/$f.tmp"
    curl -fsSL "$geo_url/$f.sha256sum" -o "$dest/$f.sha256sum"
    (cd "$dest" && sed "s/ $f\$/ $f.tmp/" "$f.sha256sum" | sha256sum -c --quiet)
    mv "$dest/$f.tmp" "$dest/$f"
    rm -f "$dest/$f.sha256sum"
  fi
done
