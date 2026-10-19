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
echo "sru-core: готово ($out)"
