import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/vpn/vpn_engine.dart';
import '../../core/xray/split_tunnel.dart';
import '../../state/app_state.dart';
import '../theme.dart';

/// Раздельное туннелирование, как в AmneziaVPN: по сайтам (все платформы)
/// и по приложениям (Android).
class SplitTunnelScreen extends StatelessWidget {
  const SplitTunnelScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final apps = Platform.isAndroid;
    return DefaultTabController(
      length: apps ? 2 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Раздельное туннелирование'),
          bottom: apps
              ? const TabBar(
                  tabs: [
                    Tab(text: 'Сайты'),
                    Tab(text: 'Приложения'),
                  ],
                )
              : null,
        ),
        body: TabBarView(children: [const _SitesTab(), if (apps) const _AppsTab()]),
      ),
    );
  }
}

class _ModePicker extends StatelessWidget {
  const _ModePicker({required this.value, required this.onChanged, required this.hint});
  final SplitMode value;
  final ValueChanged<SplitMode> onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: RadioGroup<SplitMode>(
        groupValue: value,
        onChanged: (v) => onChanged(v!),
        child: Column(
          children: [
            for (final m in SplitMode.values)
              RadioListTile<SplitMode>(
                value: m,
                title: Text(m.title),
                subtitle: m == SplitMode.off ? null : Text(hint),
              ),
          ],
        ),
      ),
    );
  }
}

class _SitesTab extends StatefulWidget {
  const _SitesTab();

  @override
  State<_SitesTab> createState() => _SitesTabState();
}

class _SitesTabState extends State<_SitesTab> {
  final _input = TextEditingController();

  void _add(AppState state) {
    final entries = _input.text.split(RegExp(r'[\s,;]+')).where((e) => e.isNotEmpty);
    state.addSplitSites(entries);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ModePicker(value: state.siteSplit, onChanged: state.setSiteSplit, hint: 'Сайты и IP из списка ниже'),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                decoration: const InputDecoration(hintText: 'youtube.com, 1.2.3.0/24, geosite:…'),
                onSubmitted: (_) => _add(state),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: () => _add(state), icon: const Icon(Icons.add)),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in sitePresets.entries)
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: Text(e.key),
                onPressed: () => state.addSplitSites(e.value),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (state.splitSites.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Список пуст. Добавьте домены (поддомены учитываются автоматически), '
              'IP-адреса или подсети.',
              style: TextStyle(color: SruColors.textTertiary),
            ),
          ),
        for (final site in state.splitSites)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              title: Text(site),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => state.removeSplitSite(site),
              ),
            ),
          ),
      ],
    );
  }
}

class _AppsTab extends StatefulWidget {
  const _AppsTab();

  @override
  State<_AppsTab> createState() => _AppsTabState();
}

class _AppsTabState extends State<_AppsTab> {
  late Future<List<InstalledApp>> _apps;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _apps = context.read<AppState>().engine.installedApps();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: _ModePicker(value: state.appSplit, onChanged: state.setAppSplit, hint: 'Отмеченные приложения'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Поиск приложения'),
            onChanged: (v) => setState(() => _filter = v.toLowerCase()),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<InstalledApp>>(
            future: _apps,
            builder: (context, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final apps = snap.data!
                  .where(
                    (a) =>
                        _filter.isEmpty || a.label.toLowerCase().contains(_filter) || a.packageName.contains(_filter),
                  )
                  .toList();
              return ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: apps.length,
                itemBuilder: (_, i) {
                  final a = apps[i];
                  return CheckboxListTile(
                    value: state.splitApps.contains(a.packageName),
                    onChanged: (v) => state.toggleSplitApp(a.packageName, v ?? false),
                    title: Text(a.label),
                    subtitle: Text(a.packageName, style: const TextStyle(fontSize: 12)),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
