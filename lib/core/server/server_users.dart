import 'dart:math';

import 'xui_api.dart';

/// Пользователь сервера = все клиенты 3x-ui с одним subId (одна подписка).
/// Новые пользователи — это один клиент на всех протоколах; у тех, кого создал
/// установщик, на каждый протокол свой email (`<имя>-<протокол>`).
class ServerUser {
  ServerUser({required this.subId, required this.clients});

  final String subId;
  final List<Map<String, dynamic>> clients;

  List<String> get emails => [for (final c in clients) c['email'] as String];

  String get name {
    final comment = clients.first['comment'] as String?;
    if (comment != null && comment.isNotEmpty) return comment;
    final e = emails.first;
    if (clients.length == 1) return e;
    // общий префикс без суффикса протокола
    final i = e.lastIndexOf('-');
    return i > 0 ? e.substring(0, i) : e;
  }

  int _traffic(String k) => clients.fold(0, (s, c) => s + (((c['traffic'] as Map?)?[k] as num?)?.toInt() ?? 0));

  int get up => _traffic('up');
  int get down => _traffic('down');
  int get used => up + down;

  /// Лимит в байтах, 0 — без ограничения (берётся у первого клиента:
  /// приложение задаёт его одинаковым для всех клиентов пользователя).
  int get limitBytes => (clients.first['totalGB'] as num?)?.toInt() ?? 0;

  DateTime? get expiry {
    final ms = (clients.first['expiryTime'] as num?)?.toInt() ?? 0;
    return ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  bool get enabled => clients.any((c) => c['enable'] == true);

  bool isOnline(Set<String> online) => emails.any(online.contains);

  static List<ServerUser> group(List<Map<String, dynamic>> clients) {
    final bySub = <String, List<Map<String, dynamic>>>{};
    for (final c in clients) {
      final sub = (c['subId'] as String?)?.isNotEmpty == true ? c['subId'] as String : 'email:${c['email']}';
      bySub.putIfAbsent(sub, () => []).add(c);
    }
    return [for (final e in bySub.entries) ServerUser(subId: e.key, clients: e.value)]
      ..sort((a, b) => a.name.compareTo(b.name));
  }
}

/// Операции над пользователями поверх API панели.
class ServerUsers {
  ServerUsers(this.api, {Random? random}) : _random = random ?? Random.secure();

  final XuiApi api;
  final Random _random;

  Future<List<ServerUser>> list() async => ServerUser.group(await api.listClients());

  /// Новый пользователь на всех протоколах сервера. Возвращает его ключи.
  Future<(ServerUser, List<String>)> create(String name, {int limitGb = 0, int days = 0}) async {
    final inbounds = await api.listInbounds();
    final ids = [
      for (final ib in inbounds)
        if (_shareable.contains(ib['protocol'])) ib['id'] as int,
    ];
    if (ids.isEmpty) throw XuiApiException('На сервере нет протоколов для пользователей');
    final subId = _id(16);
    final email = _email(name);
    await api.addClient({
      'email': email,
      'subId': subId,
      'flow': 'xtls-rprx-vision',
      'totalGB': limitGb * _gb,
      'expiryTime': days > 0 ? DateTime.now().add(Duration(days: days)).millisecondsSinceEpoch : 0,
      'limitIp': 0,
      'tgId': 0,
      'comment': name,
      'enable': true,
    }, ids);
    final user = (await list()).firstWhere((u) => u.subId == subId);
    return (user, await api.subLinks(subId));
  }

  Future<List<String>> links(ServerUser u) => api.subLinks(u.subId);

  Future<void> setLimits(ServerUser u, {required int limitGb, required int days, bool? enable}) async {
    for (final c in u.clients) {
      await api.updateClient(c['email'] as String, {
        ..._writable(c),
        'totalGB': limitGb * _gb,
        'expiryTime': days > 0 ? DateTime.now().add(Duration(days: days)).millisecondsSinceEpoch : 0,
        'enable': enable ?? c['enable'] ?? true,
      });
    }
  }

  Future<void> setEnabled(ServerUser u, bool enable) async {
    for (final c in u.clients) {
      await api.updateClient(c['email'] as String, {..._writable(c), 'enable': enable});
    }
  }

  Future<void> resetTraffic(ServerUser u) async {
    for (final e in u.emails) {
      await api.resetClientTraffic(e);
    }
  }

  Future<void> delete(ServerUser u) async {
    for (final e in u.emails) {
      await api.deleteClient(e);
    }
  }

  /// Поля для clients/update. Отправляем только то, что панель принимает на
  /// запись: в clients/list часть полей в другом виде (`id` — номер записи,
  /// UUID лежит в `uuid`; `allowedIPs` — строка вместо списка).
  static Map<String, dynamic> _writable(Map<String, dynamic> c) {
    const keep = [
      'email', 'subId', 'password', 'auth', 'flow', 'security', 'totalGB', 'expiryTime', 'limitIp', //
      'limitHwid', 'tgId', 'comment', 'enable', 'reset', 'privateKey', 'publicKey', 'preSharedKey',
    ];
    final m = <String, dynamic>{
      for (final k in keep)
        if (c[k] != null && c[k] != '') k: c[k],
    };
    final uuid = c['uuid'];
    if (uuid is String && uuid.isNotEmpty) m['id'] = uuid;
    final ips = c['allowedIPs'];
    if (ips is List && ips.isNotEmpty) m['allowedIPs'] = ips;
    if (ips is String && ips.isNotEmpty) m['allowedIPs'] = ips.split(',').map((e) => e.trim()).toList();
    return m;
  }

  static const _gb = 1 << 30;
  static const _shareable = {'vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria', 'amneziawg'};

  /// Email в 3x-ui уникален и служит идентификатором: латиница + случайный хвост.
  String _email(String name) {
    final base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return '${base.isEmpty ? 'user' : base}-${_id(4)}';
  }

  String _id(int n) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(n, (_) => chars[_random.nextInt(chars.length)]).join();
  }
}
