import 'dart:io';

/// Локальные порты SOCKS/HTTP ядра. Стандартные 10808/10809 часто уже заняты
/// другим клиентом (v2rayN, Happ, NekoBox) — тогда берём свободные.
class LocalPorts {
  const LocalPorts(this.socks, this.http);
  final int socks;
  final int http;

  static const preferred = LocalPorts(10808, 10809);

  static Future<LocalPorts> pick() async {
    final socks = await _free(preferred.socks);
    var http = await _free(preferred.http);
    if (http == socks) http = await _free(0);
    return LocalPorts(socks, http);
  }

  /// [port], если он свободен на 127.0.0.1, иначе любой свободный.
  static Future<int> _free(int port) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      final p = s.port;
      await s.close();
      return p;
    } on SocketException {
      if (port == 0) rethrow;
      return _free(0);
    }
  }

  /// [n] разных свободных портов (для одновременной проверки многих серверов).
  static Future<List<int>> pickMany(int n) async {
    final sockets = [for (var i = 0; i < n; i++) await ServerSocket.bind(InternetAddress.loopbackIPv4, 0)];
    final ports = [for (final s in sockets) s.port];
    for (final s in sockets) {
      await s.close();
    }
    return ports;
  }
}
