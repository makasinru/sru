import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/vpn/vpn_engine.dart';
import '../../state/app_state.dart';
import '../../state/server_entry.dart';
import '../theme.dart';
import 'add_server_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final server = state.selectedServer;
    return Column(
      children: [
        const SizedBox(height: 16),
        _ModeChip(state: state),
        const Spacer(),
        _ConnectButton(state: state),
        const SizedBox(height: 24),
        _StatusText(state: state),
        const Spacer(),
        if (server != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: _ServerCard(server: server, onTap: () => _showServerPicker(context, state)),
          ),
      ],
    );
  }

  void _showServerPicker(BuildContext context, AppState state) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => ServerPickerSheet(state: state),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<UiMode>(
      segments: const [
        ButtonSegment(value: UiMode.simple, label: Text('Просто')),
        ButtonSegment(value: UiMode.advanced, label: Text('Продвинуто')),
      ],
      selected: {state.mode},
      showSelectedIcon: false,
      onSelectionChanged: (s) => state.setMode(s.first),
    );
  }
}

class _ConnectButton extends StatelessWidget {
  const _ConnectButton({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.status;
    final connected = s == VpnStatus.connected;
    final busy = s == VpnStatus.connecting || s == VpnStatus.disconnecting;
    final ring = connected ? SruColors.accent : SruColors.border;
    return Semantics(
      button: true,
      label: connected ? 'Отключиться' : 'Подключиться',
      child: GestureDetector(
        onTap: busy ? null : state.toggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 200,
          height: 200,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: SruColors.bgSurface,
            border: Border.all(color: ring, width: 6),
            boxShadow: [if (connected) BoxShadow(color: SruColors.accentDark.withValues(alpha: 0.45), blurRadius: 60)],
          ),
          child: Center(
            child: busy
                ? const SizedBox(width: 48, height: 48, child: CircularProgressIndicator(strokeWidth: 3))
                : Text(
                    connected ? 'Отключиться' : 'Подключиться',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: connected ? SruColors.accent : SruColors.textPrimary,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final text = switch (state.status) {
      VpnStatus.connected =>
        'Подключено${state.advanced && state.activeProfile != null ? ' · ${state.activeProfile!.protocol.title}' : ''}',
      VpnStatus.connecting => 'Подключение…',
      VpnStatus.disconnecting => 'Отключение…',
      VpnStatus.error => state.engine.lastError ?? 'Ошибка подключения',
      VpnStatus.disconnected => 'Не подключено',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 16,
          color: state.status == VpnStatus.error ? SruColors.destructive : SruColors.textTertiary,
        ),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.server, required this.onTap});
  final ServerEntry server;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        leading: const Icon(Icons.public, color: SruColors.textTertiary),
        title: Text(server.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(server.subtitle),
        trailing: const Icon(Icons.expand_less),
      ),
    );
  }
}

/// Нижняя шторка выбора сервера (как в Amnezia). В продвинутом режиме
/// у каждого сервера раскрывается список протоколов.
class ServerPickerSheet extends StatelessWidget {
  const ServerPickerSheet({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Серверы', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    RadioGroup<String>(
                      groupValue: state.selectedServer?.id,
                      onChanged: (id) => state.selectServer(id!),
                      child: Column(children: [for (final s in state.servers) _serverTile(context, s)]),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Добавить сервер'),
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AddServerScreen()));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _serverTile(BuildContext context, ServerEntry s) {
    final selected = state.selectedServer?.id == s.id;
    final tile = RadioListTile<String>(value: s.id, title: Text(s.name), subtitle: Text(s.subtitle));
    if (!state.advanced || s.profiles.length < 2 || !selected) return tile;
    return Column(
      children: [
        tile,
        Padding(
          padding: const EdgeInsets.only(left: 32),
          child: RadioGroup<int?>(
            groupValue: s.selectedProfile,
            onChanged: (v) => state.selectProfile(s, v),
            child: Column(
              children: [
                const RadioListTile<int?>(dense: true, value: null, title: Text('Автоматически')),
                for (var i = 0; i < s.profiles.length; i++)
                  RadioListTile<int?>(
                    dense: true,
                    value: i,
                    title: Text(s.profiles[i].protocol.title),
                    subtitle: Text('${s.profiles[i].transportLabel} · порт ${s.profiles[i].port}'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
