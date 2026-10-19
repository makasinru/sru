import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/links/deep_link.dart';
import '../../core/links/subscription.dart';
import '../../core/models/proxy_profile.dart';
import '../../core/xray/xray_config_builder.dart';
import '../../state/app_state.dart';
import '../../state/server_entry.dart';
import '../theme.dart';
import '../widgets/share_qr_dialog.dart';
import 'server_users_screen.dart';
import 'add_server_screen.dart';

/// Продвинутый режим: серверы, протоколы с пингом, конфиги, доступ к панели.
class ServersScreen extends StatelessWidget {
  const ServersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Серверы', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () =>
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AddServerScreen())),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final s in state.servers) ...[
          Card(
            child: ListTile(
              title: Text(s.name),
              subtitle: Text('${_kindLabel(s.kind)} · ${s.profiles.length} протокол(а)'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ServerDetailsScreen(server: s))),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  static String _kindLabel(ServerKind k) => switch (k) {
    ServerKind.own => 'Свой сервер (3x-ui)',
    ServerKind.key => 'Ключ',
    ServerKind.subscription => 'Подписка',
  };
}

class ServerDetailsScreen extends StatefulWidget {
  const ServerDetailsScreen({super.key, required this.server});
  final ServerEntry server;

  @override
  State<ServerDetailsScreen> createState() => _ServerDetailsScreenState();
}

class _ServerDetailsScreenState extends State<ServerDetailsScreen> {
  final Map<int, int?> _pings = {};

  Future<void> _pingAll() async {
    for (var i = 0; i < widget.server.profiles.length; i++) {
      final ms = await AppState.tcpPing(widget.server.profiles[i]);
      if (mounted) setState(() => _pings[i] = ms);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = widget.server;
    final info = s.subscriptionInfo;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.name),
        actions: [
          IconButton(tooltip: 'Пинг', icon: const Icon(Icons.speed), onPressed: _pingAll),
          if (s.refreshable)
            IconButton(
              tooltip: 'Обновить подписку',
              icon: const Icon(Icons.refresh),
              onPressed: () => state.refreshSubscription(s),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (info != null) _SubscriptionCard(info: info),
          const _Header('Протоколы'),
          if (s.unsupported.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Пропущены (ядро их не поддерживает): ${s.unsupported.join(', ')}',
                style: const TextStyle(color: SruColors.textTertiary, fontSize: 13),
              ),
            ),
          for (var i = 0; i < s.profiles.length; i++)
            _ProfileTile(
              profile: s.profiles[i],
              ping: _pings[i],
              selected: s.selectedProfile == i,
              onSelect: () => state.selectProfile(s, i),
              onShowConfig: () => _showConfig(context, s.profiles[i], state.xrayOptions),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Скопировать все ключи'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: s.profiles.map((p) => p.raw).join('\n')));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Ключи скопированы — их можно открыть в Happ, v2rayNG, Hiddify')),
              );
            },
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.qr_code),
            label: const Text('Поделиться через QR-код'),
            onPressed: () => showShareQr(
              context,
              title: s.name,
              data: s.profiles.length == 1 ? s.profiles.first.raw : DeepLink.importLink(s.profiles.map((p) => p.raw)),
            ),
          ),
          if (s.panel != null && s.ssh != null) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.people_outline),
              label: const Text('Пользователи и трафик'),
              onPressed: () =>
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ServerUsersScreen(server: s))),
            ),
            const _Header('Панель 3x-ui'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  'Панель доступна только через SSH-туннель:\n'
                  'ssh -L 2053:127.0.0.1:${s.panel!.port} ${s.ssh!.username}@${s.ssh!.host} -p ${s.ssh!.port}\n'
                  'затем откройте http://127.0.0.1:2053/${s.panel!.webBasePath}/\n\n'
                  'Логин: ${s.panel!.username}\nПароль: ${s.panel!.password}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: SruColors.destructive),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Удалить сервер из приложения'),
            onPressed: () async {
              await state.removeServer(s);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  void _showConfig(BuildContext context, ProxyProfile p, XrayOptions o) {
    final json = XrayConfigBuilder.buildJson(p, o);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Конфиг Xray', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  icon: const Icon(Icons.copy),
                  onPressed: () => Clipboard.setData(ClipboardData(text: json)),
                ),
              ],
            ),
            SelectableText(json, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.ping,
    required this.selected,
    required this.onSelect,
    required this.onShowConfig,
  });

  final ProxyProfile profile;
  final int? ping;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onShowConfig;

  @override
  Widget build(BuildContext context) {
    final pingText = switch (ping) {
      null => '',
      -1 => 'недоступен',
      final ms => '$ms мс',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onSelect,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          color: selected ? SruColors.accent : SruColors.textTertiary,
        ),
        title: Text('${profile.protocol.title} · ${profile.transportLabel}'),
        subtitle: Text('${profile.host}:${profile.port}${pingText.isEmpty ? '' : ' · $pingText'}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.qr_code),
              tooltip: 'QR-код ключа',
              onPressed: () => showShareQr(context, title: profile.name, data: profile.raw),
            ),
            IconButton(icon: const Icon(Icons.code), tooltip: 'Конфиг', onPressed: onShowConfig),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.info});
  final SubscriptionInfo info;

  @override
  Widget build(BuildContext context) {
    String gb(int b) => (b / (1 << 30)).toStringAsFixed(1);
    final total = info.total;
    final expire = info.expire;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Трафик: ${gb(info.used)} ГБ${total > 0 ? ' из ${gb(total)} ГБ' : ''}'),
            if (total > 0) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: (info.used / total).clamp(0, 1).toDouble()),
            ],
            if (expire != null) ...[
              const SizedBox(height: 8),
              Text('Действует до ${expire.toLocal().toString().split(' ').first}'),
            ],
            if (info.announce != null) ...[
              const SizedBox(height: 8),
              Text(info.announce!, style: const TextStyle(color: SruColors.accent)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
  );
}
