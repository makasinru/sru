import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

/// Интеграция с Windows через HKCU (без прав администратора):
/// протокол `sru://` для диплинков и автозапуск.
class WindowsIntegration {
  static String get _exe => Platform.resolvedExecutable;

  /// Ссылки `sru://…` из браузера открываются в приложении.
  static void registerUrlProtocol() {
    final key = CURRENT_USER.create(r'Software\Classes\sru');
    try {
      key.setValue('', const StringValue('URL:SruNaZapret'));
      key.setValue('URL Protocol', const StringValue(''));
      final cmd = key.create(r'shell\open\command');
      cmd.setValue('', StringValue('"$_exe" "%1"'));
      cmd.close();
    } finally {
      key.close();
    }
  }

  static const _runPath = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _runName = 'SruNaZapret';

  /// Запуск вместе с Windows: свёрнутым в трей (флаг --autostart).
  static bool get autostart {
    final key = CURRENT_USER.create(_runPath);
    try {
      return key.getString(_runName) != null;
    } finally {
      key.close();
    }
  }

  static set autostart(bool on) {
    final key = CURRENT_USER.create(_runPath);
    try {
      if (on) {
        key.setValue(_runName, StringValue('"$_exe" --autostart'));
      } else if (key.getString(_runName) != null) {
        key.removeValue(_runName);
      }
    } finally {
      key.close();
    }
  }
}
