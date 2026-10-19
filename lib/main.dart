import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/vpn/windows_proxy.dart';
import 'state/app_state.dart';
import 'ui/screens/root_screen.dart';
import 'ui/theme.dart';

Future<void> main(List<String> args) async {
  // Вызывается деинсталлятором Windows: вернуть настройки прокси и выйти
  // до первого кадра (окно так и не появится).
  if (args.contains('--restore-proxy')) {
    if (Platform.isWindows) WindowsSystemProxy().restoreIfStale();
    exit(0);
  }
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.load();
  runApp(ChangeNotifierProvider.value(value: state, child: const SruApp()));
}

class SruApp extends StatefulWidget {
  const SruApp({super.key});

  @override
  State<SruApp> createState() => _SruAppState();
}

class _SruAppState extends State<SruApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Закрытие окна на Windows/Linux: сначала отключаем VPN и системный прокси.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await context.read<AppState>().shutdown();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SruNaZapret',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const RootScreen(),
    );
  }
}
