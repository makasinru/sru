import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/links/deep_link.dart';
import '../../core/server/server_session.dart';
import '../../core/server/server_users.dart';
import '../../state/server_entry.dart';
import '../theme.dart';
import '../widgets/share_qr_dialog.dart';

String _gb(int bytes) => (bytes / (1 << 30)).toStringAsFixed(bytes < (10 << 30) ? 2 : 1);

/// Пользователи своего сервера: трафик, лимиты, срок, онлайн; добавить и
/// поделиться ключами через QR, отключить, сбросить трафик, удалить.
class ServerUsersScreen extends StatefulWidget {
  const ServerUsersScreen({super.key, required this.server});
  final ServerEntry server;

  @override
  State<ServerUsersScreen> createState() => _ServerUsersScreenState();
}

class _ServerUsersScreenState extends State<ServerUsersScreen> {
  ServerSession? _session;
  ServerUsers? _users;
  List<ServerUser> _list = [];
  Set<String> _online = {};
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  Future<void> _connect() async {
    final s = widget.server;
    try {
      _session = await ServerSession.open(s.ssh!, s.panel!, hostKey: s.hostKey);
      _users = ServerUsers(_session!.api);
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось подключиться к серверу: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    final list = await _users!.list();
    final online = await _session!.api.onlineClients().catchError((_) => <String>{});
    if (mounted) {
      setState(() {
        _list = list;
        _online = online;
      });
    }
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      await _refresh();
      _toast(done);
    } catch (e) {
      _toast('Ошибка: $e');
    }
  }

  void _toast(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final total = _list.fold(0, (s, u) => s + u.used);
    return Scaffold(
      appBar: AppBar(title: const Text('Пользователи и трафик')),
      floatingActionButton: _users == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.person_add),
              label: const Text('Добавить'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  Text(
                    'Всего: ${_list.length} · трафик ${_gb(total)} ГБ · онлайн ${_list.where((u) => u.isOnline(_online)).length}',
                    style: const TextStyle(color: SruColors.textTertiary),
                  ),
                  const SizedBox(height: 12),
                  for (final u in _list) _tile(u),
                ],
              ),
            ),
    );
  }

  Widget _tile(ServerUser u) {
    final limit = u.limitBytes;
    final online = u.isOnline(_online);
    final expiry = u.expiry;
    final expired = expiry != null && expiry.isBefore(DateTime.now());
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => _actions(u),
        leading: Icon(Icons.circle, size: 12, color: online ? SruColors.success : SruColors.border),
        title: Text(u.name, style: TextStyle(color: u.enabled ? null : SruColors.textTertiary)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              '${_gb(u.used)} ГБ${limit > 0 ? ' из ${_gb(limit)} ГБ' : ''}'
              '${expiry != null ? ' · до ${expiry.toLocal().toString().split(' ').first}' : ''}'
              '${!u.enabled
                  ? ' · отключён'
                  : expired
                  ? ' · срок истёк'
                  : ''}',
            ),
            if (limit > 0) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: (u.used / limit).clamp(0, 1).toDouble()),
            ],
          ],
        ),
        trailing: const Icon(Icons.more_vert),
      ),
    );
  }

  Future<void> _actions(ServerUser u) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(u.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.qr_code),
              title: const Text('Ключи и QR-код'),
              onTap: () => Navigator.pop(ctx, 'qr'),
            ),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Лимит и срок'),
              onTap: () => Navigator.pop(ctx, 'limits'),
            ),
            ListTile(
              leading: Icon(u.enabled ? Icons.block : Icons.check_circle_outline),
              title: Text(u.enabled ? 'Отключить' : 'Включить'),
              onTap: () => Navigator.pop(ctx, 'toggle'),
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('Сбросить трафик'),
              onTap: () => Navigator.pop(ctx, 'reset'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: SruColors.destructive),
              title: const Text('Удалить', style: TextStyle(color: SruColors.destructive)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    final users = _users!;
    switch (action) {
      case 'qr':
        try {
          await _shareLinks(u.name, await users.links(u));
        } catch (e) {
          _toast('Ошибка: $e');
        }
      case 'limits':
        final r = await _limitsDialog(title: u.name, gb: u.limitBytes ~/ (1 << 30));
        if (r != null) await _run(() => users.setLimits(u, limitGb: r.$1, days: r.$2), 'Сохранено');
      case 'toggle':
        await _run(() => users.setEnabled(u, !u.enabled), u.enabled ? 'Отключён' : 'Включён');
      case 'reset':
        await _run(() => users.resetTraffic(u), 'Трафик сброшен');
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Удалить «${u.name}»?'),
            content: const Text('Его ключи перестанут работать.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
            ],
          ),
        );
        if (ok == true) await _run(() => users.delete(u), 'Удалён');
    }
  }

  Future<void> _add() async {
    final name = TextEditingController();
    final r = await _limitsDialog(title: 'Новый пользователь', name: name);
    if (r == null || !mounted) return;
    try {
      final (user, links) = await _users!.create(
        name.text.trim().isEmpty ? 'Пользователь' : name.text.trim(),
        limitGb: r.$1,
        days: r.$2,
      );
      await _refresh();
      if (mounted) await _shareLinks(user.name, links);
    } catch (e) {
      _toast('Ошибка: $e');
    }
  }

  Future<void> _shareLinks(String title, List<String> links) async {
    if (links.isEmpty) return _toast('У пользователя нет ключей');
    final data = links.length == 1 ? links.first : DeepLink.importLink(links);
    await Clipboard.setData(ClipboardData(text: links.join('\n')));
    if (mounted) await showShareQr(context, title: title, data: data);
  }

  /// Диалог лимита (ГБ, 0 — без ограничения) и срока (дней, 0 — бессрочно).
  Future<(int, int)?> _limitsDialog({required String title, TextEditingController? name, int gb = 0}) {
    final gbCtrl = TextEditingController(text: gb > 0 ? '$gb' : '');
    final daysCtrl = TextEditingController();
    return showDialog<(int, int)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (name != null) ...[
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Имя (например, «Мама»)'),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: gbCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Лимит трафика, ГБ (пусто — без лимита)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: daysCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Срок, дней (пусто — бессрочно)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, (int.tryParse(gbCtrl.text) ?? 0, int.tryParse(daysCtrl.text) ?? 0)),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }
}
