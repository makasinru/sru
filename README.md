# SruNaZapret

VPN-клиент для Android и Windows 10/11.

Два режима для разных пользователей:

* **Простой режим** — интерфейс как у AmneziaVPN: одна кнопка «Подключиться», выбор сервера в нижней шторке, «Автоматически» вместо выбора протокола.
* **Продвинутый режим** — как Happ: выбор конкретного протокола, пинг, конфиг Xray, маршрутизация, реклама, данные панели 3x-ui.

Главная функция — **«Настроить свой сервер»**. Пользователь вводит IP, логин и пароль VPS, а приложение по SSH:

1. проверяет права (root или sudo) и систему (systemd);
2. ставит **3x-ui** в неинтерактивном режиме со случайными логином, паролем, портом и путём;
3. закрывает панель от интернета (`listenIP 127.0.0.1`) — дальше приложение ходит в неё через SSH-туннель;
4. через API 3x-ui включает протоколы с общим `subId`, сам выбирая свободные порты и открывая их в ufw/firewalld;
5. забирает ссылки из подписки панели и добавляет сервер.

| Протокол | Простой режим | Продвинутый режим |
|---|---|---|
| VLESS + Reality + Vision (TCP 443) | ✅ | ✅ |
| VLESS + Reality + XHTTP (TCP 8443) | ✅ | ✅ |
| Hysteria2 (UDP 443, самоподписанный сертификат с пиннингом) | ✅ | ✅ |
| Trojan + Reality | | ✅ |
| Shadowsocks 2022 | | ✅ |
| VMess + WebSocket | | ✅ |

Клиент также принимает любые ключи и подписки: `vless://`, `vmess://`, `trojan://`, `ss://`, `hysteria2://`/`hy2://`, `wireguard://`, `socks://`, http(s)-подписки с заголовками `subscription-userinfo`/`profile-title`.

Подробный разбор Amnezia, Happ и 3x-ui — в [docs/ANALYSIS.md](docs/ANALYSIS.md).

| Онбординг | Простой режим | Продвинутый режим |
|---|---|---|
| ![](docs/screenshots/onboarding.png) | ![](docs/screenshots/home_simple.png) | ![](docs/screenshots/home_advanced.png) |

## Структура

```
lib/core/links/        разбор ссылок и подписок
lib/core/xray/         сборка конфига Xray-core (TUN/прокси, маршрутизация «кроме РФ»)
lib/core/server/       SSH, установщик 3x-ui, API панели, пресеты протоколов
lib/core/vpn/          движок: MethodChannel (Android) и процесс sru-core + системный прокси (Windows)
core/                  ядро: Xray-core + обёртка (Android и десктоп)
lib/state/             состояние, хранение (секреты — в flutter_secure_storage)
lib/ui/                экраны
```

## Сборка и тесты

```bash
flutter pub get
flutter test                       # юнит-тесты
flutter run -d linux               # или android / windows / macos
```

Живой тест на настоящей панели 3x-ui и Xray: создаёт все 6 протоколов, собирает клиентские конфиги и пропускает через каждый HTTPS-запрос.

```bash
XUI_TEST_URL=http://127.0.0.1:<порт>/<путь> XUI_TEST_TOKEN=<apiToken> XRAY_BIN=/path/to/xray \
  flutter test test/integration/xui_live_test.dart
```

## Android

Нативная часть — `android/app/src/main/kotlin/ru/sru/sru/`:

* `vpn/SruVpnService.kt` — `VpnService`: поднимает TUN (IPv4 + IPv6, DNS внутри туннеля), исключает само приложение из VPN (`addDisallowedApplication`), запускает ядро и передаёт ему TUN-дескриптор через unix-сокет (SCM_RIGHTS). Показывает уведомление с кнопкой «Отключить» и реагирует на отзыв VPN системой и на падение ядра.
* `MainActivity.kt` — канал `ru.sru/vpn` для Flutter: запрос разрешения на VPN, `start`/`stop`/`coreVersion` и поток статусов.
* `vpn/CoreAssets.kt` — копирует geoip/geosite из APK для правил «кроме РФ» и блокировки рекламы.

Ядро — `core/`: Xray-core v26.10.10 с небольшой обёрткой на Go. Собирается без Android NDK (чистый Go, `CGO_ENABLED=0`) и попадает в APK как `libsrucore.so`. Gradle сам вызывает `core/build.sh` перед сборкой, нужен только Go 1.27+. Поддерживается только **arm64-v8a**: для armv7/x86 Go требует cgo и NDK.

```bash
flutter build apk --release --target-platform android-arm64
```

Тесты ядра: `cd core && go test -ldflags=-checklinkname=0 ./...`. Там же лежит e2e-тест (`e2e_test.go`), который на Linux повторяет путь пакетов Android: TUN → дескриптор через сокет → Xray → сервер → сайт.

## Windows 10/11

Приложение запускает то же ядро (`sru-core.exe`, режим `desktop`) как локальный прокси — SOCKS `127.0.0.1:10808`, HTTP `127.0.0.1:10809` — и включает **системный прокси Windows**. Через него идут браузеры и большинство программ. Права администратора не нужны.

* Прежние настройки прокси сохраняются и возвращаются при отключении. Если приложение закрылось аварийно, они восстанавливаются при следующем запуске или при удалении программы.
* Ядро завершается вместе с приложением (следит за своим stdin), поэтому висящих процессов не остаётся.
* Системный прокси можно выключить в настройках и прописать прокси в нужной программе вручную.

Сборка (на Windows):

```bash
bash core/build_desktop.sh windows   # sru-core.exe + geo → build/core/windows
flutter build windows --release      # CMake кладёт их рядом с SruNaZapret.exe
```

## Готовые сборки

GitHub Actions (`.github/workflows/build.yml`) на каждый push собирает:

* `SruNaZapret-android-arm64.apk`;
* `SruNaZapret-Setup-<версия>.exe` — установщик для Windows 10/11, ставится без прав администратора;
* `SruNaZapret-windows-x64-portable.zip` — версия без установки.

Файлы лежат в Artifacts нужного запуска на вкладке Actions. Для тега `v*` они публикуются в Releases.

Подпись APK: чтобы обновления ставились поверх старой версии, добавьте в секреты репозитория `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` и `ANDROID_KEY_PASSWORD`. Без них APK подписывается временным debug-ключом.

## Что ещё не сделано

* **iOS**: нужен `NetworkExtension` (Packet Tunnel) с Xray, собранным через gomobile.
* Android: armv7, Quick Settings плитка, запрос разрешения на уведомления (Android 13+), выбор приложений для обхода VPN.
* AmneziaWG: 3x-ui уже поддерживает inbound, но клиенту нужен отдельный движок amneziawg-go.
* Windows: режим TUN для программ, которые игнорируют системный прокси (игры и т. п.; нужны права администратора и wintun), значок в трее, автозапуск.
* Сканирование QR, диплинки, управление пользователями и трафиком сервера из приложения.
