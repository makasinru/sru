# SRU VPN

VPN-клиент для двух типов пользователей:

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
lib/core/vpn/          движок: MethodChannel (Android/iOS) и процесс xray (десктоп)
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

На десктопе приложение запускает бинарник `xray`, который лежит рядом с исполняемым файлом или находится в `PATH`, в режиме локального прокси: SOCKS `127.0.0.1:10808`, HTTP `127.0.0.1:10809`.

## Что ещё не сделано

* **Нативный VPN для Android/iOS.** Dart-часть и контракт канала `ru.sru/vpn` готовы (см. `lib/core/vpn/vpn_engine.dart`). Осталось собрать [libXray](https://github.com/XTLS/libXray) через gomobile и написать `VpnService` (Kotlin) и `NetworkExtension` (Swift) — так же устроен Happ.
* AmneziaWG: 3x-ui уже поддерживает inbound, но клиенту нужен отдельный движок amneziawg-go.
* Сканирование QR, диплинки, системный прокси и TUN на десктопе, управление пользователями и трафиком сервера из приложения.
