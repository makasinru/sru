#!/usr/bin/env bash
# Собирает ядро sru-core для десктопа в build/core/<os>/ вместе с geo-базами.
# CMake (windows/CMakeLists.txt, linux/CMakeLists.txt) копирует их рядом с
# исполняемым файлом приложения. Использование: core/build_desktop.sh windows|linux
set -euo pipefail
os="${1:?windows или linux}"
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../build/core/$os"
mkdir -p "$out"

ldflags='-s -w -buildid='
exe=sru-core
if [[ "$os" == "windows" ]]; then
  exe=sru-core.exe
  # Без консольного окна: ядро запускается из GUI-приложения, stdin/stdout — пайпы.
  ldflags="$ldflags -H=windowsgui"
else
  ldflags="$ldflags -checklinkname=0"
fi

echo "sru-core: сборка $os/amd64"
(cd "$here" && GOOS="$os" GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -buildvcs=false \
  -ldflags="$ldflags" -o "$out/$exe" .)
"$here/fetch_geo.sh" "$out/geo"

# Windows: драйвер wintun для режима TUN (подписан WireGuard LLC).
if [[ "$os" == "windows" && ! -s "$out/wintun.dll" ]]; then
  wintun_zip="$out/wintun.zip"
  wintun_sha="07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51"
  if curl -fsSL "https://www.wintun.net/builds/wintun-0.14.1.zip" -o "$wintun_zip" \
      && echo "$wintun_sha  $wintun_zip" | sha256sum -c --quiet; then
    if command -v unzip >/dev/null; then
      unzip -o -j -q "$wintun_zip" wintun/bin/amd64/wintun.dll -d "$out"
    else
      7z e -y -o"$out" "$wintun_zip" wintun/bin/amd64/wintun.dll >/dev/null
    fi
  else
    echo "sru-core: не удалось скачать wintun.dll — режим TUN на Windows работать не будет" >&2
  fi
  rm -f "$wintun_zip"
fi
echo "sru-core: готово ($out)"
