import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/platform/single_instance.dart';
import 'core/platform/windows_integration.dart';
import 'core/vpn/windows_proxy.dart';
import 'state/app_state.dart';
import 'state/link_handler.dart';
import 'ui/desktop_shell.dart';
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
  // Лицензии ядра (Xray-core, amneziawg-go, gVisor…), wintun и geo-данных —
  // в экран «Лицензии» вместе с лицензиями Flutter-пакетов.
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/licenses/THIRD_PARTY_NOTICES.txt');
    yield LicenseEntryWithLineBreaks(['sru-core (Xray-core, amneziawg-go и др.)'], text);
  });
  final desktop = Platform.isWindows || Platform.isLinux;

  // Второй запуск передаёт аргументы (например, ссылку sru://) первому.
  SingleInstance? instance;
  if (desktop) {
    instance = await SingleInstance.claim(
      args,
      wait: args.contains('--elevated') ? const Duration(seconds: 5) : Duration.zero,
    );
    if (instance == null) exit(0);
  }

  // В релизе Flutter вместо упавшего виджета рисует пустоту — на тёмной теме
  // это выглядит как чёрный экран. Показываем саму ошибку, чтобы её можно было прислать.
  ErrorWidget.builder = (details) => Material(
    color: const Color(0xFF101012),
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Ошибка интерфейса:\n${details.exceptionAsString()}',
          style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 13),
        ),
      ),
    ),
  );

  final state = AppState();
  // На телефоне не ждём чтения настроек до первого кадра: если хранилище
  // зависнет, пользователь иначе видит только чёрный экран запуска.
  final loaded = state.load().timeout(const Duration(seconds: 5), onTimeout: () {});
  if (desktop) await loaded;
  if (Platform.isWindows) {
    try {
      WindowsIntegration.registerUrlProtocol();
    } catch (_) {}
  }
  final links = LinkHandler(state, messengerKey, navigatorKey);
  DesktopShell? shell;
  if (desktop) {
    try {
      shell = await DesktopShell.init(state);
    } catch (_) {
      // нет трея (например, Linux без appindicator) — обычное окно
    }
    instance!.messages.listen((other) async {
      await shell?.show();
      for (final a in other) {
        await links.handle(a);
      }
    });
  }
  runApp(
    ChangeNotifierProvider.value(
      value: state,
      child: SruApp(shell: shell),
    ),
  );
  await loaded;
  unawaited(links.init(args));
  // Новые протоколы с сервера (добавленные в панели 3x-ui) — сразу при запуске.
  unawaited(state.refreshAll());

  // Автозапуск с Windows: окно скрыто, при желании сразу подключаемся.
  if (args.contains('--autostart') && state.connectOnStart && state.selectedServer != null) {
    unawaited(state.toggle());
  }
}

/// Для сообщений вне экранов (диплинки).
final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// Для диалогов вне экранов (подтверждение сервера из диплинка).
final navigatorKey = GlobalKey<NavigatorState>();

class SruApp extends StatefulWidget {
  const SruApp({super.key, this.shell});

  /// Трей и окно на десктопе (null на Android).
  final DesktopShell? shell;

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
      scaffoldMessengerKey: messengerKey,
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const RootScreen(),
    );
  }
}
