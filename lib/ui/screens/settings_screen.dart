import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/xray/xray_config_builder.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'split_tunnel_screen.dart';

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
            title: const Text('Продвинутый режим'),
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
          Card(
            child: SwitchListTile(
              value: state.systemProxy,
              onChanged: state.setSystemProxy,
              title: const Text('Системный прокси Windows'),
              subtitle: const Text(
                'Браузеры и большинство программ пойдут через VPN. Если выключить — '
                'укажите в программе вручную SOCKS 127.0.0.1:10808 или HTTP 127.0.0.1:10809',
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
        const SizedBox(height: 24),
        const Center(
          child: Text('SruNaZapret 0.1.0', style: TextStyle(color: SruColors.textTertiary)),
        ),
      ],
    );
  }
}
