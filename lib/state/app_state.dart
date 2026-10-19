import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/links/link_parser.dart';
import '../core/links/subscription.dart';
import '../core/models/proxy_profile.dart';
import '../core/server/remote_shell.dart';
import '../core/server/xui_installer.dart';
import '../core/vpn/vpn_engine.dart';
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

  void setSystemProxy(bool v) {
    systemProxy = v;
    _applyEngineSettings();
    _changed();
  }

  void _applyEngineSettings() {
    final e = engine;
    if (e is DesktopXrayEngine) e.useSystemProxy = systemProxy;
  }

  /// Перед закрытием приложения: отключить VPN и вернуть настройки прокси.
  Future<void> shutdown() async {
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

  XrayOptions get xrayOptions =>
      XrayOptions(tun: Platform.isAndroid || Platform.isIOS, routing: routing, blockAds: blockAds);

  /// Порядок перебора: выбранный профиль или все по очереди («Автоматически»).
  List<ProxyProfile> candidates(ServerEntry s) {
    if (s.selectedProfile != null && s.selectedProfile! < s.profiles.length) {
      return [s.profiles[s.selectedProfile!]];
    }
    return s.profiles;
  }

  Future<void> toggle() async {
    if (status == VpnStatus.connected || status == VpnStatus.connecting) {
      await engine.stop();
      activeProfile = null;
      notifyListeners();
      return;
    }
    final s = selectedServer;
    if (s == null) return;
    for (final p in candidates(s)) {
      activeProfile = p;
      notifyListeners();
      await engine.start(XrayConfigBuilder.buildJson(p, xrayOptions), sessionName: s.name);
      if (engine.current == VpnStatus.connected) return;
    }
    activeProfile = null;
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

  static bool isKeyText(String s) => LinkParser.looksLikeLink(s.trim()) || s.trim().startsWith('http');

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
