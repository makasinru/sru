import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Настройки и серверы в собственном JSON-файле приложения.
///
/// На Android раньше всё лежало только в SharedPreferences через плагин; если
/// его канал не отвечает (бывает на части прошивок в релизной сборке), запись
/// молча не происходила, и после выгрузки из памяти серверы пропадали.
/// Файл пишется обычным dart:io — без плагинов, атомарно (через .tmp).
class SettingsFile {
  SettingsFile(this.path);

  final String path;

  static const _channel = MethodChannel('ru.sru/vpn');

  /// Файл в каталоге приложения на Android; на других платформах — null
  /// (там SharedPreferences работают надёжно).
  static Future<SettingsFile?> forPlatform() async {
    if (!Platform.isAndroid) return null;
    String? dir;
    try {
      dir = await _channel.invokeMethod<String>('filesDir');
    } catch (_) {
      // Старая нативная часть без filesDir: каталог cache лежит рядом с files.
    }
    dir ??= '${Directory.systemTemp.parent.path}/files';
    return SettingsFile('$dir/settings.json');
  }

  Future<Map<String, dynamic>?> read() async {
    final f = File(path);
    if (!await f.exists()) return null;
    return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
  }

  Future<void> write(Map<String, dynamic> data) async {
    final tmp = File('$path.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(jsonEncode(data), flush: true);
    await tmp.rename(path);
  }
}
