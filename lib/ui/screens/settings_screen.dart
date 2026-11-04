import 'dart:io';

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../app_version.dart';
import '../../core/platform/windows_admin.dart';
import '../../core/platform/windows_integration.dart';
import '../../core/vpn/local_ports.dart';
import '../../core/xray/xray_config_builder.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'split_tunnel_screen.dart';

/// Режим TUN требует администратора: предлагаем перезапуск с запросом UAC.
Future<void> _setTun(BuildContext context, AppState state, bool on) async {
  state.setWindowsTun(on);
  if (!on || WindowsAdmin.isAdmin) return;
  final restart = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Нужны права администратора'),
      content: const Text(
        'Режиму TUN нужны права администратора, чтобы создать сетевой адаптер и маршруты. '
        'Перезапустить приложение от администратора?',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Позже')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Перезапустить')),
      ],
    ),
  );
  if (restart != true) return;
  await state.shutdown();
  if (WindowsAdmin.relaunchElevated(['--elevated'])) exit(0);
}

class _WindowsStartup extends StatefulWidget {
  const _WindowsStartup();

  @override
  State<_WindowsStartup> createState() => _WindowsStartupState();
}

class _WindowsStartupState extends State<_WindowsStartup> {
  bool _autostart = WindowsIntegration.autostart;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            value: _autostart,
            onChanged: (v) {
              WindowsIntegration.autostart = v;
              setState(() => _autostart = WindowsIntegration.autostart);
            },
            title: const Text('Запускать вместе с Windows'),
            subtitle: const Text('Приложение стартует свёрнутым в трей'),
          ),
          if (_autostart)
            SwitchListTile(
              value: state.connectOnStart,
              onChanged: state.setConnectOnStart,
              title: const Text('Сразу подключаться'),
            ),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Настройки', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        Card(
          child: SwitchListTile(
            value: state.advanced,
            onChanged: (v) => state.setMode(v ? UiMode.advanced : UiMode.simple),
            title: const Text('Режим Pro'),
            subtitle: const Text('Выбор протоколов, ручная установка, конфиги, доступ к панели 3x-ui'),
          ),
        ),
        const SizedBox(height: 16),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text('Какие сайты открывать через VPN', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        Card(
          child: RadioGroup<RoutingPreset>(
            groupValue: state.routing,
            onChanged: (v) => state.setRouting(v!),
            child: Column(
              children: [
                RadioListTile<RoutingPreset>(
                  value: RoutingPreset.bypassRu,
                  title: const Text('Все, кроме российских'),
                  subtitle: const Text('Госуслуги, банки и маркетплейсы работают напрямую'),
                ),
                RadioListTile<RoutingPreset>(value: RoutingPreset.global, title: const Text('Все сайты')),
              ],
            ),
          ),
        ),
        if (Platform.isWindows) ...[
          const SizedBox(height: 16),
          const _WindowsStartup(),
          const SizedBox(height: 16),
          Card(
            child: SwitchListTile(
              value: state.windowsTun,
              onChanged: (v) => _setTun(context, state, v),
              title: const Text('Режим TUN — все программы'),
              subtitle: Text(
                state.windowsTun && !WindowsAdmin.isAdmin
                    ? 'Включён, но нужны права администратора — перезапустите приложение от администратора'
                    : 'Через VPN пойдут и программы, которые игнорируют прокси (игры, некоторые клиенты). '
                          'Нужны права администратора',
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: SwitchListTile(
              value: state.systemProxy,
              onChanged: state.setSystemProxy,
              title: const Text('Системный прокси Windows'),
              subtitle: Text(
                'Браузеры и большинство программ пойдут через VPN. Если выключить — '
                'укажите в программе вручную SOCKS 127.0.0.1:${state.ports.socks} или HTTP 127.0.0.1:${state.ports.http}'
                '${state.ports.socks != LocalPorts.preferred.socks ? ' (стандартные 10808/10809 заняты другой программой)' : ''}',
              ),
            ),
          ),
        ],
        if (state.advanced) ...[
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.call_split),
              title: const Text('Раздельное туннелирование'),
              subtitle: Text(
                Platform.isAndroid
                    ? 'Сайты: ${state.siteSplit.title.toLowerCase()} · Приложения: ${state.appSplit.title.toLowerCase()}'
                    : 'Сайты: ${state.siteSplit.title.toLowerCase()}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SplitTunnelScreen())),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: SwitchListTile(
              value: state.blockAds,
              onChanged: state.setBlockAds,
              title: const Text('Блокировать рекламу'),
              subtitle: const Text('geosite:category-ads-all'),
            ),
          ),
          const SizedBox(height: 16),
          FutureBuilder<String?>(
            future: state.engine.coreVersion(),
            builder: (_, snap) => Card(
              child: ListTile(title: const Text('Ядро'), subtitle: Text(snap.data ?? 'Xray-core не найден')),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Лицензии'),
            subtitle: const Text('Исходный код — GPL-3.0; Xray-core, AmneziaWG и другие компоненты'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'SruNaZapret',
              applicationVersion: appVersion,
              applicationLegalese: '© 2026 SruNaZapret. GPL-3.0-or-later.',
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Center(
          child: Text('SruNaZapret $appVersion', style: TextStyle(color: SruColors.textTertiary)),
        ),
      ],
    );
  }
}
