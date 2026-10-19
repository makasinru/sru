# Анализ AmneziaVPN, Happ и 3x-ui

Анализ сделан 19.10.2026. Код Happ (закрытый) разбирался через REA (Reverse Engineer Anything) и JADX, код AmneziaVPN и 3x-ui (оба открытые) — по исходникам.

## Happ (Android, `su.happ.proxyutility`)

Артефакт: `Happ.apk` (последний релиз с GitHub `Happ-proxy/happ-android`), SHA-256 `488923701e7d46e556b8566e50f03ef1b13ad807be0299feb892b83a2242a093`.

| Что выяснили | Как |
|---|---|
| Ядро — **Xray-core** (сборка от 2026-09-08), обёрнутое через gomobile в `libgojni.so` (`flyfrog-llc/android_wrapper_build`) | REA `inspect_go_binary`, evidence `ev_fb174e0c…` |
| Внутри ядра: `xtls/reality`, `refraction-networking/utls`, `apernet/quic-go` (Hysteria2), `golang.zx2c4.com/wireguard`, `sagernet/sing-shadowsocks`, gVisor | список Go-модулей оттуда же |
| TUN — встроенный `tun`-inbound Xray (шаблон `assets/xray_config_with_tun.json`) плюс `libhev-socks5-tunnel.so` как запасной вариант | REA `inspect_artifact` (`ev_a287c027…`) + содержимое APK |
| Протоколы клиента (`EConfigType`): VMESS, VLESS, TROJAN, SHADOWSOCKS, SOCKS, WIREGUARD, HYSTERIA (`hysteria2://` и `hy2://`), CUSTOM (сырой JSON) | JADX |
| Транспорты: tcp/raw, ws, grpc, httpupgrade, xhttp (splithttp), kcp; безопасность: tls, reality; `fragment`, `noises`, `finalmask` | строки в декомпилированном коде |
| Диплинки: `happ://add/<url>`, зашифрованные `happ://crypt…crypt5/` | JADX |
| Заголовки подписки: `profile-title`, `subscription-userinfo`, `profile-update-interval`, `support-url`, `announce`, `routing`, `hide-settings`, `subscription-autoconnect`, `fragmentation-*`, `ping-type` и т.д. | JADX |
| Экраны: main, ping, routing (профили/правила/подписки), excluded_routes, statistics, logs, custom_config, subscription_settings, vpn_settings, ui_settings, inbound_auth, deeplink | пакеты `su.happ.proxyutility.feature.*` |

Вывод: «все протоколы как в Happ» — это набор Xray-core. Наше приложение берёт то же ядро и тот же формат ссылок, поэтому ключи взаимозаменяемы: ключ с нашего сервера открывается в Happ и наоборот. Зашифрованные `happ://crypt` ссылки не поддерживаем — это закрытый формат Happ.

## AmneziaVPN (`amnezia-vpn/amnezia-client`, Qt/QML)

* **Онбординг** (`PageSetupWizardStart`, `ConfigSource`, `TextKey`, `QrReader`): «есть ключ» или «свой сервер».
* **Свой сервер** (`PageSetupWizardCredentials` → `Easy` → `Installing`): IP, логин, пароль или ключ; «Автоматически» ставит один протокол (сейчас AmneziaWG 2), «вручную» — любой.
* **Установка**: SSH + shell-скрипты из `client/server_scripts` (prepare_host, install_docker, отдельный docker-контейнер на каждый протокол).
* **Главная**: большая круглая кнопка, внизу шторка выбора сервера; вкладки Home / Share / Settings.
* **Палитра** (`Modules/Style/AmneziaStyle.qml`): фон `#101012`, поверхности `#18181B`/`#1F1F23`, акцент `#FDBA74`, кнопки `#E4E4E7`.

## 3x-ui (`MHSanaei/3x-ui`, версия 3.10.2)

* Установщик умеет **неинтерактивный режим**: `XUI_NONINTERACTIVE=1` и переменные `XUI_USERNAME/PASSWORD/PANEL_PORT/WEB_BASE_PATH/SSL_MODE`. Результат пишется в `/etc/x-ui/install-result.env`, в том числе `XUI_API_TOKEN`.
* REST API `/panel/api/*` с авторизацией `Authorization: Bearer <token>`, CSRF для токена не нужен. Используем `inbounds/add`, `inbounds/list`, `inbounds/del/:id`, `server/getNewX25519Cert`, `clients/subLinks/:subId`.
* Протоколы inbound'ов: vless, vmess, trojan, shadowsocks, hysteria (v2), wireguard, **amneziawg**, tuic, masque, mtproto, http, mixed, tunnel.
* Ссылки для клиентов генерирует сама панель (тот же движок, что у подписки) — приложению не нужно собирать их самостоятельно.
* `allowInsecure` удалён из Xray-core после 2026-06-01. Для Hysteria2 с самоподписанным сертификатом используется `pinnedPeerCertSha256` (в ссылке — `pinSHA256`).

## Что из этого взято в SRU

| | Amnezia | Happ | SRU |
|---|---|---|---|
| Интерфейс | кнопка + шторка серверов | списки, много настроек | как в Amnezia; продвинутый режим добавляет вкладку «Серверы» |
| Свой сервер | docker-контейнеры по SSH | нет | 3x-ui по SSH, панель закрыта от интернета (127.0.0.1), доступ через SSH-туннель |
| «Автоматически» | AmneziaWG | — | VLESS Reality Vision + VLESS Reality XHTTP + Hysteria2, клиент перебирает их сам |
| Протоколы | AWG, OpenVPN, WireGuard, Xray, IPsec | Xray-набор | Xray-набор; AmneziaWG — в планах |
| Ключи | свой формат `vpn://` | стандартные ссылки + happ:// | стандартные ссылки и подписки, совместимые с Happ, v2rayNG, Hiddify |
