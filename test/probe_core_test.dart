// Живая проверка параллельного автоподбора на настоящем ядре:
//   SRU_CORE_BIN=/path/to/sru-core SRU_GEO_DIR=build/core/linux/geo flutter test -j 1 test/probe_core_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/core/vpn/connectivity_check.dart';
import 'package:sru/core/vpn/local_ports.dart';
import 'package:sru/core/vpn/vpn_engine.dart';
import 'package:sru/state/app_state.dart';
import 'package:sru/state/server_entry.dart';

/// Проверяет локальный сайт вместо Telegram/YouTube (в песочнице нет интернета).
class LocalChecker extends ConnectivityChecker {
  LocalChecker(int port, this.site) : super(proxyPort: port);
  final String site;

  @override
  Future<List<CheckResult>> checkAll({
    List<CheckTarget> sites = ConnectivityChecker.targets,
    Duration timeout = const Duration(seconds: 8),
  }) => super.checkAll(sites: [CheckTarget('local', site)], timeout: const Duration(seconds: 3));

  @override
  Future<double?> speedTest({Duration duration = const Duration(seconds: 4)}) async => null;
}

void main() {
  final core = Platform.environment['SRU_CORE_BIN'];

  test('из нескольких профилей выбирается тот, что работает, за один запуск ядра', () async {
    SharedPreferences.setMockInitialValues({});
    final site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    site.listen((r) => r.response.close());

    // Настоящий VLESS-сервер на том же ядре.
    final vlessPort = (await LocalPorts.pickMany(1)).single;
    final serverEngine = DesktopXrayEngine(corePath: core)..useSystemProxy = false;
    await serverEngine.start(
      jsonEncode({
        'inbounds': [
          {
            'listen': '127.0.0.1',
            'port': vlessPort,
            'protocol': 'vless',
            'settings': {
              'clients': [
                {'id': '11111111-1111-1111-1111-111111111111'},
              ],
              'decryption': 'none',
            },
          },
        ],
        'outbounds': [
          {
            'protocol': 'freedom',
            // Xray по умолчанию не пускает на локальные адреса, а сайт здесь локальный.
            'settings': {
              'finalRules': [
                {'action': 'allow'},
              ],
            },
          },
        ],
      }),
      sessionName: 'server',
    );
    expect(serverEngine.current, VpnStatus.connected, reason: serverEngine.lastError);

    final engine = DesktopXrayEngine(corePath: core, assetDir: Platform.environment['SRU_GEO_DIR'])
      ..useSystemProxy = false;
    final state = AppState(engine: engine)
      ..checkerFactory = (port) => LocalChecker(port, 'http://127.0.0.1:${site.port}/');
    final id = '11111111-1111-1111-1111-111111111111';
    final s = ServerEntry(
      id: 's',
      name: 't',
      kind: ServerKind.subscription,
      profiles: LinkParser.parseMany(
        'vless://$id@127.0.0.1:9?security=none#dead1\n'
        'vless://$id@127.0.0.1:$vlessPort?security=none#ok\n'
        'trojan://x@127.0.0.1:9#dead2',
      ),
    );
    state.servers = [s];
    state.selectedServerId = 's';
    await state.toggle();
    expect(engine.current, VpnStatus.connected, reason: engine.lastError ?? state.autoStatus);
    expect(state.activeProfile, s.profiles[1]);
    expect(state.probeResults.map((r) => r.$2 != null), [false, true, false]);
    await state.toggle();
    await serverEngine.stop();
    await site.close(force: true);
  }, skip: core == null ? 'нет SRU_CORE_BIN' : null);
}
