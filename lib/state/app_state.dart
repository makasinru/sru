import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/links/amnezia_wg.dart';
import '../core/links/link_parser.dart';
import '../core/links/subscription.dart';
import '../core/models/proxy_profile.dart';
import '../core/platform/windows_admin.dart';
import '../core/server/remote_shell.dart';
import '../core/server/xui_installer.dart';
import '../core/vpn/connectivity_check.dart';
import '../core/vpn/local_ports.dart';
import '../core/vpn/vpn_engine.dart';
import '../core/xray/split_tunnel.dart';
import '../core/xray/xray_config_builder.dart';
import 'server_entry.dart';

/// Простой режим — как Amnezia: одна кнопка, «Автоматически», минимум настроек.
/// Продвинутый — как Happ: выбор протокола, маршрутизация, конфиги, панель.
enum UiMode { simple, advanced }

class AppState extends ChangeNotifier {
  AppState({VpnEngine? engine, FlutterSecureStorage? secure})
    : engine = engine ?? VpnEngine.platformDefault(),
      _secure = secure ?? const FlutterSecureStorage() {
    _sub = this.engine.status.listen((s) {
      status = s;
      notifyListeners();
    });
  }

  final VpnEngine engine;
  final FlutterSecureStorage _secure;
  StreamSubscription<VpnStatus>? _sub;

  UiMode mode = UiMode.simple;
  RoutingPreset routing = RoutingPreset.bypassRu;
  bool blockAds = false;

  /// Windows: включать системный прокси при подключении.
  bool systemProxy = true;

  /// Windows: режим TUN — через VPN идут все программы, включая игры, которые
  /// не смотрят на системный прокси. Нужны права администратора.
  bool windowsTun = false;

  /// Windows: подключаться при запуске (вместе с автозапуском).
  bool connectOnStart = false;

  /// Раздельное туннелирование (продвинутый режим), как в Amnezia.
  SplitMode siteSplit = SplitMode.off;
  List<String> splitSites = [];
  SplitMode appSplit = SplitMode.off;
  List<String> splitApps = [];

  /// Результат последней проверки (Telegram, YouTube, Microsoft).
  List<CheckResult> checks = [];
  bool checking = false;
  String? autoStatus;

  /// Идёт подключение с перебором и проверкой протоколов.
  bool busy = false;

  /// Пароль локальных прокси-входов на Android — новый на каждое подключение.
  String? _proxyUser;
  String? _proxyPassword;
  List<ServerEntry> servers = [];
  String? selectedServerId;
  VpnStatus status = VpnStatus.disconnected;
  ProxyProfile? activeProfile;

  bool get advanced => mode == UiMode.advanced;

  ServerEntry? get selectedServer {
    for (final s in servers) {
      if (s.id == selectedServerId) return s;
    }
    return servers.isEmpty ? null : servers.first;
  }

  // ---------- хранение ----------

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    mode = UiMode.values.byName(prefs.getString('mode') ?? UiMode.simple.name);
    routing = RoutingPreset.values.byName(prefs.getString('routing') ?? RoutingPreset.bypassRu.name);
    blockAds = prefs.getBool('blockAds') ?? false;
    systemProxy = prefs.getBool('systemProxy') ?? true;
    windowsTun = prefs.getBool('windowsTun') ?? false;
    connectOnStart = prefs.getBool('connectOnStart') ?? false;
    siteSplit = SplitMode.values.byName(prefs.getString('siteSplit') ?? SplitMode.off.name);
    splitSites = prefs.getStringList('splitSites') ?? [];
    appSplit = SplitMode.values.byName(prefs.getString('appSplit') ?? SplitMode.off.name);
    splitApps = prefs.getStringList('splitApps') ?? [];
    _applyEngineSettings();
    selectedServerId = prefs.getString('selectedServer');
    final raw = prefs.getString('servers');
    if (raw != null) {
      servers = (jsonDecode(raw) as List)
          .map((e) => ServerEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    }
    for (final s in servers) {
      final secret = await _readSecret(s.id);
      if (secret == null) continue;
      if (secret['ssh'] != null) s.ssh = SshCredentials.fromJson(Map<String, dynamic>.from(secret['ssh'] as Map));
      if (secret['panel'] != null) s.panel = PanelInfo.fromJson(Map<String, dynamic>.from(secret['panel'] as Map));
    }
    notifyListeners();
  }

  Future<Map<String, dynamic>?> _readSecret(String id) async {
    try {
      final v = await _secure.read(key: 'server.$id');
      return v == null ? null : jsonDecode(v) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mode', mode.name);
    await prefs.setString('routing', routing.name);
    await prefs.setBool('blockAds', blockAds);
    await prefs.setBool('systemProxy', systemProxy);
    await prefs.setBool('windowsTun', windowsTun);
    await prefs.setBool('connectOnStart', connectOnStart);
    await prefs.setString('siteSplit', siteSplit.name);
    await prefs.setStringList('splitSites', splitSites);
    await prefs.setString('appSplit', appSplit.name);
    await prefs.setStringList('splitApps', splitApps);
    if (selectedServerId != null) await prefs.setString('selectedServer', selectedServerId!);
    await prefs.setString('servers', jsonEncode(servers.map((s) => s.toJson()).toList()));
  }

  Future<void> _saveSecret(ServerEntry s) async {
    if (s.ssh == null && s.panel == null) return;
    try {
      await _secure.write(
        key: 'server.${s.id}',
        value: jsonEncode({'ssh': s.ssh?.toJson(), 'panel': s.panel?.toJson()}),
      );
    } catch (_) {
      // Нет системного хранилища ключей — секреты останутся только до перезапуска.
    }
  }

  // ---------- настройки ----------

  void setMode(UiMode m) {
    mode = m;
    if (m == UiMode.simple) {
      // В простом режиме всегда «Автоматически».
      for (final s in servers) {
        s.selectedProfile = null;
      }
    }
    _changed();
  }

  void setRouting(RoutingPreset r) {
    routing = r;
    _changed();
  }

  void setBlockAds(bool v) {
    blockAds = v;
    _changed();
  }

  void setSiteSplit(SplitMode m) {
    siteSplit = m;
    _changed();
  }

  void addSplitSites(Iterable<String> entries) {
    for (final e in entries.map((e) => e.trim()).where((e) => e.isNotEmpty)) {
      if (!splitSites.contains(e)) splitSites.add(e);
    }
    _changed();
  }

  void removeSplitSite(String e) {
    splitSites.remove(e);
    _changed();
  }

  void setAppSplit(SplitMode m) {
    appSplit = m;
    _changed();
  }

  void toggleSplitApp(String pkg, bool on) {
    on ? (splitApps.contains(pkg) ? null : splitApps.add(pkg)) : splitApps.remove(pkg);
    _changed();
  }

  void setSystemProxy(bool v) {
    systemProxy = v;
    _applyEngineSettings();
    _changed();
  }

  void setWindowsTun(bool v) {
    windowsTun = v;
    _applyEngineSettings();
    _changed();
  }

  void setConnectOnStart(bool v) {
    connectOnStart = v;
    _changed();
  }

  /// TUN на Windows включён и приложение запущено от администратора.
  bool get windowsTunActive => Platform.isWindows && windowsTun && WindowsAdmin.isAdmin;

  void _applyEngineSettings() {
    final e = engine;
    // В режиме TUN системный прокси не нужен: трафик и так идёт через туннель.
    if (e is DesktopXrayEngine) e.useSystemProxy = systemProxy && !windowsTunActive;
  }

  /// Перед закрытием приложения: отключить VPN и вернуть настройки прокси.
  Future<void> shutdown() async {
    if (busy) return;
    if (status == VpnStatus.connected || status == VpnStatus.connecting) {
      await engine.stop();
    }
  }

  void selectServer(String id) {
    selectedServerId = id;
    _changed();
  }

  void selectProfile(ServerEntry s, int? index) {
    s.selectedProfile = index;
    _changed();
  }

  void renameServer(ServerEntry s, String name) {
    s.name = name;
    _changed();
  }

  Future<void> removeServer(ServerEntry s) async {
    servers.remove(s);
    if (selectedServerId == s.id) selectedServerId = servers.isEmpty ? null : servers.first.id;
    try {
      await _secure.delete(key: 'server.${s.id}');
    } catch (_) {}
    _changed();
  }

  void _changed() {
    notifyListeners();
    unawaited(_save());
  }

  // ---------- добавление серверов ----------

  /// Принимает что угодно, что вставил пользователь: одну ссылку, несколько
  /// ссылок, base64-подписку или http(s)-ссылку на подписку.
  Future<ServerEntry> addFromText(String text) async {
    final t = text.trim();
    if (t.startsWith('http://') || t.startsWith('https://')) {
      final url = Uri.parse(t);
      final res = await SubscriptionParser.fetch(url);
      if (res.profiles.isEmpty) throw const FormatException('В подписке нет поддерживаемых серверов');
      return _add(
        ServerEntry(
          id: const Uuid().v4(),
          name: res.info.title ?? url.host,
          kind: ServerKind.subscription,
          profiles: res.profiles,
          subscriptionUrl: t,
          subscriptionInfo: res.info,
        ),
      );
    }
    final profiles = SubscriptionParser.parseBody(t);
    if (profiles.isEmpty) throw const FormatException('Не удалось распознать ключ');
    return _add(
      ServerEntry(
        id: const Uuid().v4(),
        name: profiles.length == 1 ? profiles.first.name : profiles.first.host,
        kind: ServerKind.key,
        profiles: profiles,
      ),
    );
  }

  Future<void> refreshSubscription(ServerEntry s) async {
    if (s.subscriptionUrl == null) return;
    final res = await SubscriptionParser.fetch(Uri.parse(s.subscriptionUrl!));
    if (res.profiles.isNotEmpty) s.profiles = res.profiles;
    s.subscriptionInfo = res.info;
    _changed();
  }

  Future<ServerEntry> addInstalled(InstallResult r, SshCredentials ssh, String hostKey) {
    final entry = ServerEntry(
      id: const Uuid().v4(),
      name: ssh.host,
      kind: ServerKind.own,
      profiles: r.profiles,
      ssh: ssh,
      hostKey: hostKey,
      panel: r.panel,
      subId: r.subId,
    );
    return _add(entry);
  }

  Future<ServerEntry> _add(ServerEntry e) async {
    servers.add(e);
    selectedServerId = e.id;
    await _saveSecret(e);
    _changed();
    return e;
  }

  // ---------- подключение ----------

  bool get _mobile => Platform.isAndroid || Platform.isIOS;

  /// Порты локального прокси: выбираются при подключении (см. [LocalPorts]).
  LocalPorts ports = LocalPorts.preferred;

  XrayOptions get xrayOptions => XrayOptions(
    socksPort: ports.socks,
    httpPort: ports.http,
    tun: _mobile || windowsTunActive,
    windowsTun: windowsTunActive,
    routing: routing,
    blockAds: blockAds,
    // Раздельное туннелирование работает только в продвинутом режиме.
    siteSplit: advanced ? siteSplit : SplitMode.off,
    splitSites: splitSites,
    proxyUser: _proxyUser,
    proxyPassword: _proxyPassword,
  );

  /// Для тестов: подменить проверку подключения.
  ConnectivityChecker Function(XrayOptions o)? checkerFactory;

  ConnectivityChecker get _checker =>
      checkerFactory?.call(xrayOptions) ??
      ConnectivityChecker(proxyPort: xrayOptions.httpPort, proxyUser: _proxyUser, proxyPassword: _proxyPassword);

  /// Порядок перебора: выбранный профиль (только в продвинутом режиме)
  /// или все по очереди («Автоматически»), начиная с прошлого лучшего.
  List<ProxyProfile> candidates(ServerEntry s) {
    final sel = s.selectedProfile;
    if (advanced && sel != null && sel < s.profiles.length) return [s.profiles[sel]];
    final list = [...s.profiles];
    final last = s.lastGoodProfile;
    if (last != null && last < list.length) list.insert(0, list.removeAt(last));
    return list;
  }

  /// Результаты последнего автоподбора: профиль → задержка (null — не работает).
  List<(ProxyProfile, int?)> probeResults = [];

  Future<bool> _startProfile(ServerEntry s, ProxyProfile p) async {
    activeProfile = p;
    notifyListeners();
    final awg = p.protocol == ProxyProtocol.amneziawg;
    if (awg && Platform.isWindows && !WindowsAdmin.isAdmin) return false;
    await engine.start(
      // AmneziaWG — сам .conf: ядро поднимает amneziawg-go вместо Xray.
      awg ? p.params['conf']! : XrayConfigBuilder.buildJson(p, xrayOptions),
      sessionName: s.name,
      appSplit: advanced ? appSplit : SplitMode.off,
      apps: splitApps,
      tun: awg ? AmneziaWg.tunParams(p.params['conf']!) : null,
    );
    return engine.current == VpnStatus.connected;
  }

  /// У AmneziaWG нет локального прокси для проверки сайтов, зато ядро сообщает
  /// о подключении только после рукопожатия с сервером — это и есть проверка.
  bool get _activeIsAwg => activeProfile?.protocol == ProxyProtocol.amneziawg;

  Future<void> toggle() async {
    if (status == VpnStatus.connected || status == VpnStatus.connecting) {
      await engine.stop();
      activeProfile = null;
      checks = [];
      probeResults = [];
      autoStatus = null;
      notifyListeners();
      return;
    }
    final s = selectedServer;
    if (s == null) return;
    if (_mobile) {
      _proxyUser = 'sru';
      _proxyPassword = const Uuid().v4();
    }
    checks = [];
    probeResults = [];
    busy = true;
    try {
      ports = await LocalPorts.pick();
      await _connect(s);
    } finally {
      busy = false;
      notifyListeners();
    }
    if (engine.current == VpnStatus.connected) unawaited(runChecks());
  }

  /// Проверяет один профиль: запускает ядро и замеряет, открываются ли сайты.
  Future<(int?, List<CheckResult>)> _probe(ServerEntry s, ProxyProfile p) async {
    final sw = Stopwatch()..start();
    if (!await _startProfile(s, p)) return (null, <CheckResult>[]);
    // AmneziaWG: ядро сообщает «подключено» только после рукопожатия.
    if (p.protocol == ProxyProtocol.amneziawg) return (sw.elapsedMilliseconds, <CheckResult>[]);
    final quick = await _checker.checkAll(
      sites: ConnectivityChecker.targets.take(2).toList(),
      timeout: const Duration(seconds: 6),
    );
    return (ConnectivityChecker.bestMs(quick), quick);
  }

  Future<void> _connect(ServerEntry s) async {
    final list = candidates(s);
    if (list.length == 1) {
      final (_, quick) = await _probe(s, list.single);
      checks = quick;
      autoStatus = null;
      return;
    }

    // Перебираем все протоколы: ядро запустилось ещё не значит, что протокол
    // не режется. Подключаемся к тому, через который сайты открылись быстрее.
    ProxyProfile? best;
    int? bestMs;
    var bestChecks = <CheckResult>[];
    for (var i = 0; i < list.length; i++) {
      final p = list[i];
      autoStatus = 'Проверяю ${i + 1} из ${list.length}: ${p.displayName}…';
      notifyListeners();
      final (ms, quick) = await _probe(s, p);
      probeResults = [...probeResults, (p, ms)];
      if (ms != null && (bestMs == null || ms < bestMs)) {
        best = p;
        bestMs = ms;
        bestChecks = quick;
      }
    }

    if (best == null) {
      await engine.stop();
      activeProfile = null;
      autoStatus = 'Ни один протокол не открыл сайты. Возможно, сервер недоступен.';
      notifyListeners();
      return;
    }
    if (activeProfile != best) {
      autoStatus = 'Подключаюсь: ${best.displayName}…';
      notifyListeners();
      await _startProfile(s, best);
    }
    checks = bestChecks;
    s.lastGoodProfile = s.profiles.indexOf(best);
    unawaited(_save());
    autoStatus = null;
  }

  /// Полная проверка для экрана: Telegram, YouTube, Microsoft.
  Future<void> runChecks() async {
    if (status != VpnStatus.connected || checking || _activeIsAwg) return;
    checking = true;
    notifyListeners();
    checks = await _checker.checkAll();
    checking = false;
    notifyListeners();
  }

  /// Задержка TCP-рукопожатия до сервера (для UDP-протоколов не измеряется).
  static Future<int?> tcpPing(ProxyProfile p) async {
    if (p.protocol == ProxyProtocol.hysteria2 || p.protocol == ProxyProtocol.wireguard) return null;
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(p.host, p.port, timeout: const Duration(seconds: 3));
      s.destroy();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return -1;
    }
  }

  static bool isKeyText(String s) =>
      LinkParser.looksLikeLink(s.trim()) || s.trim().startsWith('http') || AmneziaWg.isConf(s);

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
