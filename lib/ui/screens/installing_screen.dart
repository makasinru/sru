import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/server/protocol_presets.dart';
import '../../core/server/remote_shell.dart';
import '../../core/server/xui_installer.dart';
import '../../state/app_state.dart';
import '../theme.dart';

/// Аналог PageSetupWizardInstalling: шаги + лог для продвинутых.
class InstallingScreen extends StatefulWidget {
  const InstallingScreen({
    super.key,
    required this.credentials,
    required this.protocols,
    required this.ports,
    required this.realityTarget,
    this.panelVersion,
  });

  final SshCredentials credentials;
  final List<ServerProtocol> protocols;
  final Map<ServerProtocol, int> ports;
  final String realityTarget;
  final String? panelVersion;

  @override
  State<InstallingScreen> createState() => _InstallingScreenState();
}

class _InstallingScreenState extends State<InstallingScreen> {
  static const _titles = {
    InstallStep.connect: 'Подключение к серверу',
    InstallStep.checkServer: 'Проверка сервера',
    InstallStep.installPanel: 'Установка 3x-ui',
    InstallStep.secure: 'Защита панели',
    InstallStep.protocols: 'Включение протоколов',
    InstallStep.finish: 'Готово',
  };

  InstallStep _step = InstallStep.connect;
  String _message = '';
  final _log = <String>[];
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _progress(InstallStep s, String m) {
    if (!mounted) return;
    setState(() {
      _step = s;
      _message = m;
      _log.add(m);
    });
  }

  Future<void> _run() async {
    final state = context.read<AppState>();
    RemoteShell? shell;
    try {
      _progress(InstallStep.connect, 'Подключаемся к ${widget.credentials.host}');
      final (ssh, hostKey) = await DartSshShell.connect(widget.credentials);
      shell = ssh;
      final installer = XuiInstaller(ssh, sudoPassword: widget.credentials.password, panelVersion: widget.panelVersion);
      final result = await installer.install(
        protocols: widget.protocols,
        ports: widget.ports,
        realityTarget: widget.realityTarget,
        onProgress: _progress,
      );
      await state.addInstalled(result, widget.credentials, hostKey);
      if (!mounted) return;
      setState(() => _done = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      await shell?.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final advanced = context.watch<AppState>().advanced;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройка сервера'), automaticallyImplyLeading: _done || _error != null),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final s in InstallStep.values) _stepRow(s),
              const SizedBox(height: 16),
              if (_error != null)
                Text(_error!, style: const TextStyle(color: SruColors.destructive))
              else if (!_done)
                Text(_message, style: const TextStyle(color: SruColors.textTertiary), maxLines: 2),
              if (advanced) ...[
                const SizedBox(height: 16),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: SruColors.bgSurface, borderRadius: BorderRadius.circular(12)),
                    child: ListView(
                      reverse: true,
                      children: [
                        for (final l in _log.reversed)
                          Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              const SizedBox(height: 16),
              if (_done)
                FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Подключиться'))
              else if (_error != null)
                FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Назад')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepRow(InstallStep s) {
    final idx = s.index;
    final cur = _step.index;
    final Widget icon;
    if (_done || idx < cur) {
      icon = const Icon(Icons.check_circle, color: SruColors.success);
    } else if (idx == cur && _error != null) {
      icon = const Icon(Icons.error, color: SruColors.destructive);
    } else if (idx == cur) {
      icon = const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2));
    } else {
      icon = const Icon(Icons.radio_button_unchecked, color: SruColors.border);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 12),
          Text(_titles[s]!, style: const TextStyle(fontSize: 16)),
        ],
      ),
    );
  }
}
