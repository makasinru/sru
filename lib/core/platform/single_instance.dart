import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Один экземпляр приложения на компьютере. Второй запуск (ярлык, ссылка
/// sru://… из браузера) передаёт свои аргументы первому и закрывается.
class SingleInstance {
  SingleInstance._(this._server);

  static const port = 47391;
  final ServerSocket _server;
  final _messages = StreamController<List<String>>.broadcast();

  /// Аргументы, пришедшие от повторных запусков.
  Stream<List<String>> get messages => _messages.stream;

  /// null — приложение уже запущено, аргументы переданы ему.
  /// [wait] — сколько ждать, пока старый экземпляр закроется (перезапуск
  /// с правами администратора).
  static Future<SingleInstance?> claim(List<String> args, {Duration wait = Duration.zero}) async {
    final deadline = DateTime.now().add(wait);
    while (true) {
      try {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        final inst = SingleInstance._(server);
        server.listen(inst._accept);
        return inst;
      } on SocketException {
        if (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        if (await _send(args)) return null;
        // Порт занят чем-то посторонним — работаем без защиты от второго запуска.
        return SingleInstance._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
      }
    }
  }

  static Future<bool> _send(List<String> args) async {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 2));
      s.write('${jsonEncode({'sru': 1, 'args': args})}\n');
      await s.flush();
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _accept(Socket s) {
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .then((line) {
          final m = jsonDecode(line) as Map<String, dynamic>;
          if (m['sru'] == 1) _messages.add((m['args'] as List).cast<String>());
        })
        .catchError((Object _) {})
        .whenComplete(s.destroy);
  }

  Future<void> close() => _server.close();
}
