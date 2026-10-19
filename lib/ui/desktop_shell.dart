import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/vpn/vpn_engine.dart';
import '../state/app_state.dart';

/// Windows/Linux: значок в трее и сворачивание в трей вместо закрытия.
/// Левый клик по значку — открыть окно, правый — меню (подключить/отключить,
/// открыть, выйти). «Выход» отключает VPN и возвращает настройки прокси.
class DesktopShell with TrayListener, WindowListener {
  DesktopShell._(this.state);

  final AppState state;

  static Future<DesktopShell> init(AppState state) async {
    final shell = DesktopShell._(state);
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(const Size(360, 560));
    windowManager.addListener(shell);
    trayManager.addListener(shell);
    await trayManager.setIcon(Platform.isWindows ? 'assets/tray.ico' : 'assets/tray.png');
    state.addListener(shell._update);
    await shell._update();
    return shell;
  }

  VpnStatus? _shown;

  Future<void> _update() async {
    final s = state.status;
    if (s == _shown) return;
    _shown = s;
    final connected = s == VpnStatus.connected;
    await trayManager.setToolTip('SruNaZapret — ${connected ? 'подключено' : 'не подключено'}');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'toggle', label: connected ? 'Отключить' : 'Подключить'),
          MenuItem(key: 'show', label: 'Открыть'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: 'Выход'),
        ],
      ),
    );
  }

  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() => unawaited(show());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'toggle':
        unawaited(state.toggle());
      case 'show':
        unawaited(show());
      case 'exit':
        unawaited(exitApp());
    }
  }

  /// Крестик окна: прячем в трей, VPN продолжает работать.
  @override
  void onWindowClose() => unawaited(windowManager.hide());

  Future<void> exitApp() async {
    await state.shutdown();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }
}
