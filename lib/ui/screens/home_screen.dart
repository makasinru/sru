import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/vpn/connectivity_check.dart';
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
        if (state.probeResults.isNotEmpty) ...[const SizedBox(height: 12), _ProbeList(state: state)],
        if (state.status == VpnStatus.connected && !state.busy) ...[
          const SizedBox(height: 16),
          _ChecksRow(state: state),
        ],
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
    final connected = s == VpnStatus.connected && !state.busy;
    final busy = state.busy || s == VpnStatus.connecting || s == VpnStatus.disconnecting;
    return Semantics(
      button: true,
      label: connected ? 'Отключиться' : 'Подключиться',
      child: GestureDetector(
        onTap: busy ? null : state.toggle,
        // Кольцо: серое, при подключении — в цветах логотипа.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 200,
          height: 200,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: connected ? null : SruColors.border,
            gradient: connected ? const SweepGradient(colors: SruColors.logoGradient) : null,
            boxShadow: [
              if (connected) BoxShadow(color: const Color(0xFF7466C4).withValues(alpha: 0.45), blurRadius: 60),
            ],
          ),
          child: Container(
            decoration: const BoxDecoration(shape: BoxShape.circle, color: SruColors.bgSurface),
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
      ),
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final text =
        state.autoStatus ??
        switch (state.status) {
          VpnStatus.connected =>
            'Подключено${state.activeProfile != null ? ' · ${state.activeProfile!.displayName}' : ''}',
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

/// Итоги автоподбора: какой протокол сколько показал, выбранный отмечен.
class _ProbeList extends StatelessWidget {
  const _ProbeList({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final chosen = state.busy ? null : state.activeProfile;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final (p, ms) in state.probeResults)
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: Icon(
                ms == null ? Icons.cancel : (identical(p, chosen) ? Icons.star : Icons.check_circle),
                size: 16,
                color: ms == null
                    ? SruColors.destructive
                    : (identical(p, chosen) ? SruColors.accent : SruColors.success),
              ),
              label: Text('${p.displayName} · ${ms == null ? 'нет' : '$ms мс'}', style: const TextStyle(fontSize: 12)),
              backgroundColor: SruColors.bgSurface,
              side: BorderSide(color: identical(p, chosen) ? SruColors.accent : SruColors.border),
            ),
        ],
      ),
    );
  }
}

/// Проверка «работает ли на самом деле»: Telegram, YouTube, Microsoft и задержка.
class _ChecksRow extends StatelessWidget {
  const _ChecksRow({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (state.activeProfile?.protocol == ProxyProtocol.amneziawg) {
      return const Chip(
        avatar: Icon(Icons.check_circle, size: 18, color: SruColors.success),
        label: Text('AmneziaWG · рукопожатие с сервером есть'),
        backgroundColor: SruColors.bgSurface,
        side: BorderSide(color: SruColors.border),
      );
    }
    final results = {for (final r in state.checks) r.target.name: r};
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [for (final t in ConnectivityChecker.targets) _chip(t.name, results[t.name])],
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: state.checking ? null : state.runChecks,
          icon: state.checking
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh, size: 18),
          label: Text(state.checking ? 'Проверяем…' : 'Проверить подключение'),
        ),
      ],
    );
  }

  Widget _chip(String name, CheckResult? r) {
    final (icon, color, text) = switch (r) {
      null => (Icons.more_horiz, SruColors.textTertiary, name),
      CheckResult(ok: true) => (Icons.check_circle, SruColors.success, '$name · ${r.ms} мс'),
      _ => (Icons.cancel, SruColors.destructive, '$name · нет'),
    };
    return Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(text),
      backgroundColor: SruColors.bgSurface,
      side: const BorderSide(color: SruColors.border),
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
