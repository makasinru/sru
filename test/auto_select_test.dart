import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/core/models/proxy_profile.dart';
import 'package:sru/core/vpn/connectivity_check.dart';
import 'package:sru/core/vpn/vpn_engine.dart';
import 'package:sru/core/xray/split_tunnel.dart';
import 'package:sru/state/app_state.dart';
import 'package:sru/state/server_entry.dart';

/// Ядро, которое «подключается» к любому профилю и запоминает порядок запусков.
class FakeEngine implements VpnEngine {
  final _c = StreamController<VpnStatus>.broadcast();
  VpnStatus _s = VpnStatus.disconnected;
  final started = <String>[];
  final httpToServer = <int, String>{};
  String? lastConfig;
  SplitMode? lastAppSplit;
  Map<String, Object>? lastTun;

  @override
  Stream<VpnStatus> get status => _c.stream;
  @override
  VpnStatus get current => _s;
  @override
  String? get lastError => null;
  @override
  Future<void> start(
    String cfg, {
    required String sessionName,
    SplitMode appSplit = SplitMode.off,
    List<String> apps = const [],
    Map<String, Object>? tun,
  }) async {
    lastTun = tun;
    lastConfig = cfg;
    lastAppSplit = appSplit;
    httpToServer.clear();
    if (cfg.startsWith('[Interface]')) {
      started.add('awg');
    } else {
      final j = jsonDecode(cfg) as Map<String, dynamic>;
      final outs = {
        for (final o in (j['outbounds'] as List).cast<Map<String, dynamic>>())
          o['tag']: (o['settings']?['vnext'] as List?)?.first['port'].toString(),
      };
      final rules = (j['routing']['rules'] as List).cast<Map<String, dynamic>>();
      final probe = rules.any((r) => r.containsKey('inboundTag'));
      for (final i in (j['inbounds'] as List).cast<Map<String, dynamic>>()) {
        if (i['protocol'] != 'http') continue;
        final out = probe
            ? rules.firstWhere((r) => (r['inboundTag'] as List?)?.contains(i['tag']) ?? false)['outboundTag']
            : 'proxy';
        httpToServer[i['port'] as int] = outs[out]!;
      }
      started.add(probe ? 'probe' : httpToServer.values.single);
    }
    _s = VpnStatus.connected;
    _c.add(_s);
  }

  @override
  Future<void> stop() async {
    _s = VpnStatus.disconnected;
    _c.add(_s);
  }

  @override
  Future<String?> coreVersion() async => null;
  @override
  Future<List<InstalledApp>> installedApps() async => const [];
}

/// Отвечает задержкой, заданной для порта текущего профиля (null — сайты не открываются).
class FakeChecker extends ConnectivityChecker {
  FakeChecker(this.engine, this.msByPort, int port) : super(proxyPort: port);
  final FakeEngine engine;
  final Map<String, int?> msByPort;

  @override
  Future<List<CheckResult>> checkAll({
    List<CheckTarget> sites = ConnectivityChecker.targets,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final ms = msByPort[engine.httpToServer[proxyPort]];
    return [for (final t in sites) CheckResult(t, ms)];
  }

  @override
  Future<double?> speedTest({Duration duration = const Duration(seconds: 6)}) async => null;
}

ServerEntry server() => ServerEntry(
  id: 's',
  name: 'test',
  kind: ServerKind.key,
  profiles: LinkParser.parseMany(
    'vless://a@h:1001?security=none#a\nvless://b@h:1002?security=none#b\nvless://c@h:1003?security=none#c',
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(AppState, FakeEngine, ServerEntry)> setup(Map<String, int?> ms) async {
    final engine = FakeEngine();
    final state = AppState(engine: engine)..checkerFactory = (port) => FakeChecker(engine, ms, port);
    final s = server();
    state.servers = [s];
    state.selectedServerId = s.id;
    return (state, engine, s);
  }

  test('проверяет все протоколы разом и подключается к самому быстрому', () async {
    final (state, engine, s) = await setup({'1001': null, '1002': 120, '1003': 50});
    await state.toggle();
    expect(engine.started, ['probe', '1003']);
    expect(state.activeProfile, s.profiles[2]);
    expect(s.lastGoodProfile, 2);
    expect(state.probeResults.map((r) => r.$2), [null, 120, 50]);
    expect(state.checks.first.ms, 50);
  });

  test('подписка на десятки серверов проверяется пачками, а не по одному', () async {
    final engine = FakeEngine();
    final ms = {for (var i = 0; i < 70; i++) '${2000 + i}': i == 55 ? 40 : 500};
    final state = AppState(engine: engine)..checkerFactory = (port) => FakeChecker(engine, ms, port);
    final s = ServerEntry(
      id: 'big',
      name: 'подписка',
      kind: ServerKind.subscription,
      profiles: LinkParser.parseMany(
        [for (var i = 0; i < 70; i++) 'vless://u@h$i:${2000 + i}?security=none#c$i'].join('\n'),
      ),
    );
    state.servers = [s];
    state.selectedServerId = s.id;
    await state.toggle();
    expect(engine.started, ['probe', 'probe', 'probe', '2055']);
    expect(state.probeResults, hasLength(70));
    expect(state.activeProfile, s.profiles[55]);
  });

  test('выбор протокола из продвинутого режима не мешает простому', () async {
    final (state, engine, s) = await setup({'1001': 500, '1002': 100, '1003': 500});
    s.selectedProfile = 0;
    await state.toggle();
    expect(engine.started, ['probe', '1002']);
    expect(state.activeProfile, s.profiles[1]);
    await state.toggle();
    state.mode = UiMode.advanced;
    engine.started.clear();
    await state.toggle();
    expect(engine.started, ['1001']);
  });

  test('ни один не открыл сайты — отключается с понятным сообщением', () async {
    final (state, engine, _) = await setup({'1001': null, '1002': null, '1003': null});
    await state.toggle();
    expect(engine.current, VpnStatus.disconnected);
    expect(state.autoStatus, contains('Ни один протокол'));
  });

  test('AmneziaWG: ядру уходит .conf и параметры интерфейса, сайты не проверяются', () async {
    final (state, engine, s) = await setup({'1001': null, '1002': null, '1003': null});
    s.profiles.add(
      LinkParser.parseMany(
        '[Interface]\nPrivateKey = x\nAddress = 10.8.1.2/32\nDNS = 1.1.1.1\nMTU = 1380\n[Peer]\nPublicKey = y\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:47521',
      ).single,
    );
    await state.toggle();
    expect(engine.started.last, 'awg');
    expect(state.activeProfile!.protocol, ProxyProtocol.amneziawg);
    expect(engine.lastTun!['mtu'], 1380);
    expect(engine.lastTun!['addresses'], ['10.8.1.2/32']);
    expect(state.checks, isEmpty);
  });

  test('раздельное туннелирование работает только в продвинутом режиме', () async {
    final (state, engine, _) = await setup({'1001': 100});
    state.siteSplit = SplitMode.onlyListed;
    state.splitSites = ['youtube.com'];
    state.appSplit = SplitMode.exceptListed;
    await state.toggle();
    expect(engine.lastConfig, isNot(contains('domain:youtube.com')));
    expect(engine.lastAppSplit, SplitMode.off);
    await state.toggle(); // отключить
    state.mode = UiMode.advanced;
    await state.toggle();
    expect(engine.lastConfig, contains('domain:youtube.com'));
    expect(engine.lastAppSplit, SplitMode.exceptListed);
  });
}
