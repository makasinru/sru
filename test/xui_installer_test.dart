import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sru/core/models/proxy_profile.dart';
import 'package:sru/core/server/protocol_presets.dart';
import 'package:sru/core/server/remote_shell.dart';
import 'package:sru/core/server/xui_api.dart';
import 'package:sru/core/server/xui_installer.dart';

/// Имитирует чистый Ubuntu-сервер: отвечает на команды установщика по шаблонам.
class FakeShell implements RemoteShell {
  FakeShell({this.uid = '0', this.passwordlessSudo = false, this.busyPorts = const {}});

  final String uid;
  final bool passwordlessSudo;
  final Set<int> busyPorts;
  final commands = <String>[];
  bool installed = false;

  @override
  Future<CommandResult> exec(String command, {void Function(String line)? onLine}) async {
    commands.add(command);
    CommandResult r(int code, [String out = '']) => CommandResult(code, out, '');
    final cmd = command
        .replaceFirst(RegExp(r"^printf '%s\\n' '.*' \| sudo -S -p '' "), '')
        .replaceFirst('sudo -n ', '');
    if (cmd == 'id -u') return r(0, '$uid\n');
    if (command == 'sudo -n true') return r(passwordlessSudo ? 0 : 1);
    if (command.startsWith("printf '%s\\n' 'secret' | sudo -S")) {
      if (cmd == 'true') return r(0);
    }
    if (command.startsWith("printf '%s\\n'") && !command.contains("'secret'")) return r(1);
    if (cmd.startsWith('. /etc/os-release')) return r(0, 'ubuntu 24.04\n');
    if (cmd == 'command -v systemctl') return r(0, '/usr/bin/systemctl\n');
    if (cmd.startsWith('test -x')) return r(installed ? 0 : 1);
    if (cmd.startsWith('curl -fsSL')) return r(0);
    if (cmd.startsWith("env XUI_NONINTERACTIVE='1'")) {
      onLine?.call('Installing x-ui...');
      installed = true;
      return r(0);
    }
    if (cmd.startsWith('cat /etc/x-ui/install-result.env')) {
      return r(
        0,
        "XUI_USERNAME=adm\nXUI_PASSWORD=p\\ w\nXUI_PANEL_PORT=31337\nXUI_WEB_BASE_PATH=secretpath\n"
        "XUI_ACCESS_URL=http://1.2.3.4:31337/secretpath\nXUI_API_TOKEN=tok123\nXUI_DB_TYPE=sqlite\n",
      );
    }
    if (cmd.contains('setting -listenIP 127.0.0.1')) return r(0);
    if (cmd.startsWith('curl -s -o /dev/null')) return r(0, '200');
    if (cmd.contains('openssl x509')) return r(0, 'aa' * 32);
    if (cmd.contains('openssl req')) return r(0);
    final ss = RegExp(r"ss -Hln[tu] 'sport = :(\d+)'").firstMatch(cmd);
    if (ss != null) return r(0, busyPorts.contains(int.parse(ss.group(1)!)) ? 'LISTEN ...' : '');
    if (cmd.contains('ufw')) return r(0);
    return r(127);
  }

  int? forwardedPort;

  @override
  Future<int> forwardToLocal(String remoteHost, int remotePort) async {
    forwardedPort = remotePort;
    return 40000;
  }

  @override
  Future<void> close() async {}
}

/// Имитация API панели: сохраняет inbound'ы и отдаёт ссылки по subId.
MockClient fakePanel(List<Map<String, dynamic>> added) => MockClient((req) async {
  expect(req.headers['Authorization'], 'Bearer tok123');
  expect(req.url.toString(), startsWith('http://127.0.0.1:40000/secretpath/panel/api/'));
  final path = req.url.path.replaceFirst('/secretpath/panel/api/', '');
  Object? obj;
  switch (path) {
    case 'server/getNewX25519Cert':
      obj = {'privateKey': 'PRIV', 'publicKey': 'PUB'};
    case 'inbounds/add':
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      added.add(body);
      obj = {'id': added.length};
    default:
      if (path.startsWith('clients/subLinks/')) {
        obj = [
          for (final ib in added)
            if (ib['protocol'] == 'vless')
              'vless://${ib['settings']['clients'][0]['id']}@1.2.3.4:${ib['port']}?security=reality&pbk=PUB#v'
            else if (ib['protocol'] == 'hysteria')
              'hysteria2://${ib['settings']['clients'][0]['auth']}@1.2.3.4:${ib['port']}?sni=x&pinSHA256=${'aa' * 32}#h',
        ];
      } else {
        return http.Response('{"success":false,"msg":"unknown $path"}', 404);
      }
  }
  return http.Response(jsonEncode({'success': true, 'msg': '', 'obj': obj}), 200);
});

void main() {
  test('полная установка: root, чистый сервер, «Автоматически»', () async {
    final shell = FakeShell(busyPorts: {8443});
    final added = <Map<String, dynamic>>[];
    final installer = XuiInstaller(
      shell,
      apiFactory: (u, t) => XuiApi(baseUrl: u, token: t, client: fakePanel(added)),
    );
    final steps = <InstallStep>{};
    final res = await installer.install(protocols: casualProtocols, onProgress: (s, _) => steps.add(s));

    expect(shell.commands.any((c) => c.startsWith("env XUI_NONINTERACTIVE='1' XUI_SSL_MODE='none'")), isTrue);
    expect(shell.commands.any((c) => c.contains('setting -listenIP 127.0.0.1')), isTrue);
    expect(shell.forwardedPort, 31337);
    expect(res.panel.apiToken, 'tok123');
    expect(res.panel.password, 'p w');
    expect(res.panel.webBasePath, 'secretpath');

    expect(added.map((i) => i['protocol']), ['vless', 'vless', 'hysteria']);
    expect(added[0]['port'], 443);
    expect(added[1]['port'], isNot(8443), reason: 'порт 8443 занят — должен быть выбран другой');
    expect(added[2]['port'], 443, reason: 'UDP 443 свободен, хотя TCP 443 уже занят VLESS');
    expect(added.every((i) => i['settings']['clients'][0]['subId'] == res.subId), isTrue);
    expect(added[0]['streamSettings']['realitySettings']['privateKey'], 'PRIV');
    expect(added[2]['streamSettings']['tlsSettings']['settings']['pinnedPeerCertSha256'], ['aa' * 32]);

    expect(res.profiles.map((p) => p.protocol), [ProxyProtocol.vless, ProxyProtocol.vless, ProxyProtocol.hysteria2]);
    expect(steps, containsAll(InstallStep.values.where((s) => s != InstallStep.connect)));
  });

  test('не root без sudo — понятная ошибка', () async {
    final installer = XuiInstaller(FakeShell(uid: '1000'));
    expect(
      () => installer.install(protocols: casualProtocols),
      throwsA(isA<InstallException>().having((e) => e.message, 'message', contains('sudo'))),
    );
  });

  test('sudo по паролю добавляется к каждой команде', () async {
    final shell = FakeShell(uid: '1000');
    final added = <Map<String, dynamic>>[];
    final installer = XuiInstaller(
      shell,
      sudoPassword: 'secret',
      apiFactory: (u, t) => XuiApi(baseUrl: u, token: t, client: fakePanel(added)),
    );
    await installer.install(protocols: [ServerProtocol.vlessRealityVision]);
    final install = shell.commands.firstWhere((c) => c.contains('XUI_NONINTERACTIVE'));
    expect(install, startsWith("printf '%s\\n' 'secret' | sudo -S -p '' env "));
    // stdin закрывается внутри sh -c, иначе sudo не прочитает пароль из пайпа
    expect(install, endsWith("< /dev/null'"));
  });

  test('parseEnvFile понимает printf %q', () {
    final env = XuiInstaller.parseEnvFile("A=plain\nB=with\\ space\nC='quoted value'\n");
    expect(env, {'A': 'plain', 'B': 'with space', 'C': 'quoted value'});
  });

  test('пресеты: SS-2022 и VMess WS', () {
    final ctx = PresetContext(subId: 's', email: 'e');
    final ss = ProtocolPresets.inbound(ServerProtocol.shadowsocks2022, ctx);
    expect(ss['settings']['method'], '2022-blake3-aes-256-gcm');
    expect(base64.decode(ss['settings']['password'] as String).length, 32);
    final vm = ProtocolPresets.inbound(ServerProtocol.vmessWs, ctx);
    expect(vm['streamSettings']['network'], 'ws');
    expect(() => ProtocolPresets.inbound(ServerProtocol.vlessRealityVision, ctx), throwsArgumentError);
  });
}
