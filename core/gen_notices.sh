#!/usr/bin/env bash
# Собирает лицензии всех Go-модулей, которые попадают в ядро sru-core
# (Android, Windows, Linux), плюс данные и бинарники, которые кладутся рядом.
# Результат: assets/licenses/THIRD_PARTY_NOTICES.txt (показывается в приложении:
# Настройки → Лицензии). Запускать после обновления зависимостей в go.mod.
set -euo pipefail
cd "$(dirname "$0")"
out=../assets/licenses/THIRD_PARTY_NOTICES.txt
mkdir -p "$(dirname "$out")"
sep="================================================================"
{
  echo "SruNaZapret — сторонние компоненты и их лицензии"
  echo "Third-party components bundled with SruNaZapret and their licenses."
  echo
  echo "Исходники Go-модулей: https://pkg.go.dev/<модуль>@<версия>"
  echo "Лицензии Flutter и Dart-пакетов перечислены отдельно в этом же экране."
  echo
  echo "$sep"
  echo "wintun.dll (Windows, режим TUN) — WireGuard LLC, https://www.wintun.net"
  echo "$sep"
  echo "Распространяется без изменений, в подписанном виде, как часть программы."
  echo "Полный текст лицензии — файл wintun-LICENSE.txt рядом с программой."
  echo
  echo "$sep"
  echo "geoip.dat, geosite.dat — https://github.com/Loyalsoldier/v2ray-rules-dat"
  echo "$sep"
  echo "This product includes GeoLite2 data created by MaxMind, available from"
  echo "https://www.maxmind.com (CC BY-SA 4.0). Domain lists: v2fly/domain-list-community (MIT)."
  echo
} > "$out"
for os in android windows linux; do
  GOOS=$os GOARCH=arm64 go list -deps -f '{{with .Module}}{{.Path}}@{{.Version}} {{.Dir}}{{end}}' .
done | sort -u | awk 'NF==2' | grep -v '^ru\.sru/' | while read -r mod dir; do
  lic=$(ls "$dir" | grep -iE '^(LICEN[CS]E|COPYING)(\.md|\.txt)?$' | head -1 || true)
  {
    echo "$sep"; echo "$mod"; echo "$sep"
    if [[ -n "$lic" ]]; then cat "$dir/$lic"; else echo "(license file not found in module)"; fi
    nf=$(ls "$dir" | grep -iE '^NOTICE' | head -1 || true)
    if [[ -n "$nf" ]]; then echo; echo "--- NOTICE ---"; cat "$dir/$nf"; fi
    echo
  } >> "$out"
done
echo "$(grep -c "^$sep\$" "$out") записей → $out"
