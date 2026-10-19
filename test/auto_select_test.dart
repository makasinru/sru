import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sru/core/links/link_parser.dart';
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
  String? lastConfig;
  SplitMode? lastAppSplit;

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
  }) async {
    lastConfig = cfg;
    lastAppSplit = appSplit;
    started.add(RegExp(r'"port": (\d+)').allMatches(cfg).map((m) => m.group(1)).last!);
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
  FakeChecker(this.engine, this.msByPort) : super(proxyPort: 0);
  final FakeEngine engine;
  final Map<String, int?> msByPort;

  @override
  Future<List<CheckResult>> checkAll({
    List<CheckTarget> sites = ConnectivityChecker.targets,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final ms = msByPort[engine.started.last];
    return [for (final t in sites) CheckResult(t, ms)];
  }
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
    final state = AppState(engine: engine)..checkerFactory = (_) => FakeChecker(engine, ms);
    final s = server();
    state.servers = [s];
    state.selectedServerId = s.id;
    return (state, engine, s);
  }

  test('пропускает заблокированный протокол и останавливается на быстром', () async {
    final (state, engine, s) = await setup({'1001': null, '1002': 120, '1003': 50});
    await state.toggle();
    expect(engine.started.take(2), ['1001', '1002']); // 1002 уже достаточно быстрый
    expect(state.activeProfile, s.profiles[1]);
    expect(s.lastGoodProfile, 1);
  });

  test('если все медленные — выбирает самый быстрый и переподключается к нему', () async {
    final (state, engine, s) = await setup({'1001': 900, '1002': 600, '1003': 700});
    await state.toggle();
    expect(engine.started, ['1001', '1002', '1003', '1002']);
    expect(state.activeProfile, s.profiles[1]);
  });

  test('в следующий раз начинает с прошлого лучшего', () async {
    final (state, engine, s) = await setup({'1001': 100, '1002': 100, '1003': 100});
    s.lastGoodProfile = 2;
    await state.toggle();
    expect(engine.started, ['1003']);
  });

  test('ни один не открыл сайты — отключается с понятным сообщением', () async {
    final (state, engine, _) = await setup({'1001': null, '1002': null, '1003': null});
    await state.toggle();
    expect(engine.current, VpnStatus.disconnected);
    expect(state.autoStatus, contains('Ни один протокол'));
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
