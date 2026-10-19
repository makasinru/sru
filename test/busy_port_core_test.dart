// С настоящим ядром:
//   SRU_CORE_BIN=/path/to/sru-core SRU_GEO_DIR=build/core/linux/geo flutter test test/busy_port_core_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/core/vpn/vpn_engine.dart';
import 'package:sru/state/app_state.dart';
import 'package:sru/state/server_entry.dart';

void main() {
  final core = Platform.environment['SRU_CORE_BIN'];

  test('10808 занят другим VPN-клиентом — ядро всё равно запускается', () async {
    SharedPreferences.setMockInitialValues({});
    final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 10808);
    final engine = DesktopXrayEngine(corePath: core, assetDir: Platform.environment['SRU_GEO_DIR'])
      ..useSystemProxy = false;
    final state = AppState(engine: engine);
    final s = ServerEntry(
      id: 's',
      name: 't',
      kind: ServerKind.key,
      profiles: LinkParser.parseMany('trojan://p@127.0.0.1:9#t'),
    );
    state.servers = [s];
    state.selectedServerId = 's';
    await state.toggle();
    expect(engine.current, VpnStatus.connected, reason: engine.lastError);
    expect(state.ports.socks, isNot(10808));
    await state.toggle();
    await busy.close();
  }, skip: core == null ? 'нет SRU_CORE_BIN' : null);
}
