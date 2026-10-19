import 'dart:math';

import '../links/link_parser.dart';
import '../models/proxy_profile.dart';
import 'protocol_presets.dart';
import 'remote_shell.dart';
import 'xui_api.dart';

class InstallException implements Exception {
  InstallException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Данные панели, которые приложение хранит, чтобы потом управлять сервером
/// (добавлять протоколы, пользователей, смотреть трафик) из продвинутого режима.
class PanelInfo {
  PanelInfo({
    required this.port,
    required this.webBasePath,
    required this.username,
    required this.password,
    required this.apiToken,
  });

  final int port;
  final String webBasePath;
  final String username;
  final String password;
  final String apiToken;

  Map<String, dynamic> toJson() => {
    'port': port,
    'webBasePath': webBasePath,
    'username': username,
    'password': password,
    'apiToken': apiToken,
  };

  factory PanelInfo.fromJson(Map<String, dynamic> j) => PanelInfo(
    port: j['port'] as int,
    webBasePath: j['webBasePath'] as String,
    username: j['username'] as String,
    password: j['password'] as String,
    apiToken: j['apiToken'] as String,
  );
}

class InstallResult {
  InstallResult({required this.panel, required this.subId, required this.links, required this.profiles});
  final PanelInfo panel;
  final String subId;
  final List<String> links;
  final List<ProxyProfile> profiles;
}

enum InstallStep { connect, checkServer, installPanel, secure, protocols, finish }

typedef ProgressCallback = void Function(InstallStep step, String message);
typedef ApiFactory = XuiApi Function(Uri baseUrl, String token);

/// Установка 3x-ui на чистый VPS и включение протоколов — аналог
/// «Настроить свой сервер» в Amnezia, только вместо docker-контейнеров
/// Amnezia ставится панель 3x-ui (её же можно открыть в браузере через SSH-туннель).
class XuiInstaller {
  XuiInstaller(
    this.shell, {
    this.sudoPassword,
    this.installScriptUrl = 'https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh',
    this.panelVersion,
    ApiFactory? apiFactory,
    Random? random,
  }) : _apiFactory = apiFactory ?? ((u, t) => XuiApi(baseUrl: u, token: t)),
       _random = random ?? Random.secure();

  final RemoteShell shell;

  /// Пароль для sudo, если пользователь не root (обычно совпадает с SSH-паролем).
  final String? sudoPassword;
  final String installScriptUrl;

  /// null — последняя версия, иначе тег, например v3.1.0 (продвинутый режим).
  final String? panelVersion;
  final ApiFactory _apiFactory;
  final Random _random;

  static const xuiBin = '/usr/local/x-ui/x-ui';
  static const resultFile = '/etc/x-ui/install-result.env';
  static const certDir = '/etc/sru';

  String _sudo = '';

  static String q(String s) => "'${s.replaceAll("'", r"'\''")}'";

  Future<CommandResult> _run(String cmd, {void Function(String)? onLine}) => shell.exec('$_sudo$cmd', onLine: onLine);

  Future<InstallResult> install({
    required List<ServerProtocol> protocols,
    String realityTarget = 'www.microsoft.com',
    Map<ServerProtocol, int> ports = const {},
    String email = 'sru',
    ProgressCallback? onProgress,
  }) async {
    void progress(InstallStep s, String m) => onProgress?.call(s, m);

    progress(InstallStep.checkServer, 'Проверяем права и систему');
    await _ensureRoot();
    await _checkSystem();

    final panel = await _ensurePanel(onLine: (l) => progress(InstallStep.installPanel, l));

    progress(InstallStep.secure, 'Закрываем панель от интернета (доступ только через SSH)');
    await _bindPanelToLocalhost(panel);

    progress(InstallStep.protocols, 'Подключаемся к панели');
    final localPort = await shell.forwardToLocal('127.0.0.1', panel.port);
    final api = _apiFactory(Uri.parse('http://127.0.0.1:$localPort/${panel.webBasePath}'), panel.apiToken);
    try {
      final subId = _randomId(16);
      final needsReality = protocols.any(
        (p) => p != ServerProtocol.hysteria2 && p != ServerProtocol.shadowsocks2022 && p != ServerProtocol.vmessWs,
      );
      final keys = needsReality ? await api.newX25519() : null;

      String? certFile, keyFile, certSha;
      if (protocols.contains(ServerProtocol.hysteria2)) {
        progress(InstallStep.protocols, 'Создаём сертификат для Hysteria2');
        (certFile, keyFile, certSha) = await _selfSignedCert(realityTarget);
      }

      final ctx = PresetContext(
        subId: subId,
        email: '$email-${_randomId(4)}',
        realityTarget: realityTarget,
        realityKeys: keys,
        hysteriaCertFile: certFile,
        hysteriaKeyFile: keyFile,
        hysteriaCertSha256: certSha,
        random: _random,
      );

      for (final proto in protocols) {
        final port = await _freePort(ports[proto] ?? proto.defaultPort, udp: proto.isUdp);
        progress(InstallStep.protocols, 'Включаем ${proto.title} (порт $port)');
        await api.addInbound(ProtocolPresets.inbound(proto, ctx, port: port));
        await _openFirewall(port, udp: proto.isUdp);
      }

      progress(InstallStep.finish, 'Получаем ключи подключения');
      final links = await api.subLinks(subId);
      final profiles = LinkParser.parseMany(links.join('\n'));
      if (profiles.isEmpty) {
        throw InstallException('Панель не вернула ни одной ссылки подключения');
      }
      return InstallResult(panel: panel, subId: subId, links: links, profiles: profiles);
    } finally {
      api.close();
    }
  }

  Future<void> _ensureRoot() async {
    final id = await shell.exec('id -u');
    if (id.stdout.trim() == '0') return;
    if ((await shell.exec('sudo -n true')).ok) {
      _sudo = 'sudo -n ';
      return;
    }
    if (sudoPassword != null) {
      // printf — встроенная команда shell, пароль не попадает в список процессов.
      // Тикет sudo без TTY не кэшируется, поэтому пароль передаётся каждой команде.
      final prefix = "printf '%s\\n' ${q(sudoPassword!)} | sudo -S -p '' ";
      if ((await shell.exec('${prefix}true')).ok) {
        _sudo = prefix;
        return;
      }
    }
    throw InstallException('Нужен пользователь root или с правами sudo');
  }

  Future<void> _checkSystem() async {
    final os = await shell.exec('. /etc/os-release && echo "\$ID \$VERSION_ID"');
    if (!os.ok) throw InstallException('Не удалось определить ОС сервера');
    final systemd = await shell.exec('command -v systemctl');
    if (!systemd.ok) {
      throw InstallException('На сервере нет systemd — 3x-ui не поддерживает такую систему (${os.stdout.trim()})');
    }
  }

  Future<PanelInfo> _ensurePanel({required void Function(String) onLine}) async {
    final installed = (await _run('test -x $xuiBin')).ok;
    if (!installed) {
      onLine('Устанавливаем 3x-ui…');
      final env = {
        'XUI_NONINTERACTIVE': '1',
        'XUI_SSL_MODE': 'none',
        'XUI_USERNAME': _randomId(10),
        'XUI_PASSWORD': _randomId(20),
        'XUI_PANEL_PORT': '${20000 + _random.nextInt(40000)}',
        'XUI_WEB_BASE_PATH': _randomId(18),
      };
      final envStr = env.entries.map((e) => '${e.key}=${q(e.value)}').join(' ');
      final script = '/tmp/sru-3x-ui-install.sh';
      final dl = await _run('curl -fsSL ${q(installScriptUrl)} -o $script');
      if (!dl.ok) throw InstallException('Не удалось скачать установщик 3x-ui: ${dl.stderr.trim()}');
      final version = panelVersion == null ? '' : ' ${q(panelVersion!)}';
      // stdin закрываем внутри sh -c: редирект снаружи перехватил бы stdin
      // у `sudo -S`, и тот не получил бы пароль.
      final res = await _run('env $envStr sh -c ${q('bash $script$version < /dev/null')}', onLine: onLine);
      if (!res.ok) throw InstallException('Установка 3x-ui завершилась с ошибкой (код ${res.exitCode})');
    } else {
      onLine('3x-ui уже установлена, используем её');
    }
    return _readPanelInfo();
  }

  Future<PanelInfo> _readPanelInfo() async {
    final env = <String, String>{};
    final res = await _run('cat $resultFile');
    if (res.ok) env.addAll(parseEnvFile(res.stdout));

    if ((env['XUI_API_TOKEN'] ?? '').isEmpty || (env['XUI_PANEL_PORT'] ?? '').isEmpty) {
      // Панель ставили вручную или старой версией — достаём данные из CLI.
      final show = await _run('$xuiBin setting -show true');
      final tok = await _run('$xuiBin setting -getApiToken');
      String field(String text, String key) => RegExp('$key:\\s*(\\S+)').firstMatch(text)?.group(1) ?? '';
      env['XUI_PANEL_PORT'] = field(show.stdout, 'port');
      env['XUI_WEB_BASE_PATH'] = field(show.stdout, 'webBasePath');
      env['XUI_API_TOKEN'] = field(tok.stdout, 'apiToken');
    }
    final port = int.tryParse(env['XUI_PANEL_PORT'] ?? '');
    final token = env['XUI_API_TOKEN'] ?? '';
    if (port == null || token.isEmpty) {
      throw InstallException('Не удалось получить порт и API-токен панели 3x-ui');
    }
    return PanelInfo(
      port: port,
      webBasePath: (env['XUI_WEB_BASE_PATH'] ?? '').replaceAll(RegExp(r'^/+|/+$'), ''),
      username: env['XUI_USERNAME'] ?? '',
      password: env['XUI_PASSWORD'] ?? '',
      apiToken: token,
    );
  }

  /// Значения в install-result.env записаны через printf %q.
  static Map<String, String> parseEnvFile(String text) {
    final out = <String, String>{};
    for (final line in text.split('\n')) {
      final i = line.indexOf('=');
      if (i <= 0) continue;
      var v = line.substring(i + 1).trim();
      if (v.length >= 2 && v.startsWith("'") && v.endsWith("'")) {
        v = v.substring(1, v.length - 1);
      } else {
        v = v.replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);
      }
      out[line.substring(0, i).trim()] = v;
    }
    return out;
  }

  Future<void> _bindPanelToLocalhost(PanelInfo panel) async {
    await _run('$xuiBin setting -listenIP 127.0.0.1 >/dev/null && systemctl restart x-ui');
    for (var i = 0; i < 20; i++) {
      final r = await _run(
        "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${panel.port}/${panel.webBasePath}/",
      );
      if (r.stdout.trim().isNotEmpty && r.stdout.trim() != '000') return;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw InstallException('Панель 3x-ui не запустилась');
  }

  Future<(String, String, String)> _selfSignedCert(String cn) async {
    const crt = '$certDir/hysteria.crt';
    const key = '$certDir/hysteria.key';
    final gen = await _run(
      'sh -c ${q('mkdir -p $certDir && test -s $crt || '
      'openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 '
      '-subj /CN=$cn -keyout $key -out $crt >/dev/null 2>&1')}',
    );
    if (!gen.ok) throw InstallException('Не удалось создать сертификат (нужен openssl)');
    final sha = await _run("sh -c ${q("openssl x509 -in $crt -outform der | sha256sum | cut -d' ' -f1")}");
    return (crt, key, sha.stdout.trim());
  }

  Future<int> _freePort(int preferred, {required bool udp}) async {
    var port = preferred;
    for (var i = 0; i < 10; i++) {
      final r = await _run("ss -Hln${udp ? 'u' : 't'} 'sport = :$port'");
      // Нет ss (iproute2) — проверить нечем, конфликт порта покажет сама панель.
      if (r.exitCode == 127 || (r.ok && r.stdout.trim().isEmpty)) return port;
      port = 20000 + _random.nextInt(40000);
    }
    throw InstallException('Не нашлось свободного порта');
  }

  Future<void> _openFirewall(int port, {required bool udp}) async {
    final proto = udp ? 'udp' : 'tcp';
    await _run(
      'sh -c ${q('if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then '
      'ufw allow $port/$proto >/dev/null; fi; '
      'if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then '
      'firewall-cmd --permanent --add-port=$port/$proto >/dev/null && firewall-cmd --reload >/dev/null; fi')}',
    );
  }

  String _randomId(int len) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(len, (_) => chars[_random.nextInt(chars.length)]).join();
  }
}
