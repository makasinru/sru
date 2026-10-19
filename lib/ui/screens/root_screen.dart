import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import 'add_server_screen.dart';
import 'home_screen.dart';
import 'servers_screen.dart';
import 'settings_screen.dart';

/// Как в Amnezia: пока серверов нет — мастер подключения, потом вкладки.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.servers.isEmpty) return const AddServerScreen(isOnboarding: true);

    final pages = [const HomeScreen(), if (state.advanced) const ServersScreen(), const SettingsScreen()];
    final tab = _tab.clamp(0, pages.length - 1);
    return Scaffold(
      body: SafeArea(child: pages[tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.power_settings_new), label: 'Главная'),
          if (state.advanced) const NavigationDestination(icon: Icon(Icons.dns_outlined), label: 'Серверы'),
          const NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Настройки'),
        ],
      ),
    );
  }
}
