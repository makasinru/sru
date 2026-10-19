import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

/// Системный прокси Windows (Параметры → Сеть и Интернет → Прокси).
///
/// Работает без прав администратора: настройки пользователя лежат в HKCU.
/// Его используют браузеры, магазин приложений, Telegram, Discord и большинство
/// программ. Прежние настройки пользователя сохраняются и возвращаются при
/// отключении — в том числе после аварийного закрытия приложения
/// ([restoreIfStale] при следующем запуске).
class WindowsSystemProxy {
  WindowsSystemProxy({File? backupFile}) : _backup = backupFile ?? _defaultBackup();

  static const _path = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  /// Локальные адреса и частные сети — напрямую, мимо прокси.
  static const bypass =
      '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;'
      '172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*';

  final File _backup;

  static File _defaultBackup() {
    final base = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    return File('$base\\SruNaZapret\\proxy-backup.json');
  }

  void enable(String server) {
    final key = CURRENT_USER.create(_path);
    try {
      if (!_backup.existsSync()) {
        _backup.parent.createSync(recursive: true);
        _backup.writeAsStringSync(
          jsonEncode({
            'server': server,
            'ProxyEnable': key.getInt('ProxyEnable') ?? 0,
            'ProxyServer': key.getString('ProxyServer'),
            'ProxyOverride': key.getString('ProxyOverride'),
          }),
        );
      }
      key.setValue('ProxyServer', StringValue(server));
      key.setValue('ProxyOverride', const StringValue(bypass));
      key.setValue('ProxyEnable', const DwordValue(1));
    } finally {
      key.close();
    }
    _notify();
  }

  /// Возвращает настройки, которые были до подключения.
  void disable() {
    final key = CURRENT_USER.create(_path);
    try {
      final saved = _readBackup();
      if (saved == null) {
        key.setValue('ProxyEnable', const DwordValue(0));
      } else {
        key.setValue('ProxyEnable', DwordValue(saved['ProxyEnable'] as int? ?? 0));
        for (final name in ['ProxyServer', 'ProxyOverride']) {
          final v = saved[name] as String?;
          if (v == null) {
            if (key.getString(name) != null) key.removeValue(name);
          } else {
            key.setValue(name, StringValue(v));
          }
        }
      }
    } finally {
      key.close();
    }
    if (_backup.existsSync()) _backup.deleteSync();
    _notify();
  }

  /// Если приложение закрылось аварийно, прокси остался включён на наш порт,
  /// и интернет у пользователя «пропадает». Вызывается при запуске.
  void restoreIfStale() {
    if (_readBackup() != null) disable();
  }

  Map<String, dynamic>? _readBackup() {
    try {
      return _backup.existsSync() ? jsonDecode(_backup.readAsStringSync()) as Map<String, dynamic> : null;
    } catch (_) {
      return null;
    }
  }

  /// Сообщает WinINET об изменении, чтобы браузеры применили его без перезапуска.
  static void _notify() {
    const settingsChanged = 39; // INTERNET_OPTION_SETTINGS_CHANGED
    const refresh = 37; // INTERNET_OPTION_REFRESH
    final setOption = DynamicLibrary.open('wininet.dll')
        .lookupFunction<
          Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int, Pointer<Void>, int)
        >('InternetSetOptionW');
    setOption(nullptr, settingsChanged, nullptr, 0);
    setOption(nullptr, refresh, nullptr, 0);
  }
}
