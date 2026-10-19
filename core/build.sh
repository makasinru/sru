#!/usr/bin/env bash
# Собирает ядро (Xray-core + обёртка) для Android и кладёт geo-базы в assets.
# Нужен только Go (версия из go.mod); Android NDK не требуется: ядро —
# чистый Go (CGO_ENABLED=0), который Go умеет собирать для android/arm64.
# android/arm и android/amd64 в Go требуют cgo (NDK), поэтому поддерживается
# только arm64-v8a — это все 64-битные ARM-устройства.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app="$here/../android/app/src/main"
jni="$app/jniLibs/arm64-v8a"
geo="$app/assets/geo"
mkdir -p "$jni" "$geo"

echo "sru-core: сборка arm64-v8a"
(
  cd "$here"
  GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -buildvcs=false \
    -ldflags='-s -w -buildid= -checklinkname=0' -o "$jni/libsrucore.so" .
)

"$here/fetch_geo.sh" "$geo"
echo "sru-core: готово"
