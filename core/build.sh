#!/usr/bin/env bash
# Собирает ядро (Xray-core + обёртка) для Android и кладёт geo-базы в assets.
# Нужен только Go (версия из go.mod); Android NDK не требуется: ядро —
# чистый Go (CGO_ENABLED=0), который Go умеет собирать для android/arm64.
# arm64 собирается без NDK; armv7 (android/arm) требует cgo и собирается,
# если найден Android NDK.
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

# armv7: Go для android/arm требует cgo, поэтому нужен Android NDK (на раннерах
# GitHub он есть в $ANDROID_NDK_HOME). Без NDK armv7 пропускается.
ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$ndk" && -d "${ANDROID_HOME:-/nonexistent}/ndk" ]]; then
  ndk="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1)"
fi
cc="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi26-clang"
if [[ -n "$ndk" && -x "$cc" ]]; then
  echo "sru-core: сборка armeabi-v7a (NDK: $ndk)"
  mkdir -p "$app/jniLibs/armeabi-v7a"
  (
    cd "$here"
    GOOS=android GOARCH=arm GOARM=7 CGO_ENABLED=1 CC="$cc" go build -trimpath -buildvcs=false \
      -ldflags='-s -w -buildid= -checklinkname=0' -o "$app/jniLibs/armeabi-v7a/libsrucore.so" .
  )
else
  echo "sru-core: Android NDK не найден — armeabi-v7a пропущен (соберётся только arm64-v8a)" >&2
fi

"$here/fetch_geo.sh" "$geo"
echo "sru-core: готово"
