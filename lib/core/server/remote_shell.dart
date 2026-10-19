import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

class CommandResult {
  CommandResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
  bool get ok => exitCode == 0;
}

/// Минимальный интерфейс удалённой машины — позволяет тестировать
/// установщик без настоящего SSH.
abstract class RemoteShell {
  /// Выполнить команду. [onLine] получает вывод построчно (для экрана
  /// «Установка…» в стиле Amnezia).
  Future<CommandResult> exec(String command, {void Function(String line)? onLine});

  /// Пробросить порт сервера на локальный 127.0.0.1:<случайный порт>.
  /// Возвращает локальный порт.
  Future<int> forwardToLocal(String remoteHost, int remotePort);

  Future<void> close();
}

class SshCredentials {
  SshCredentials({
    required this.host,
    this.port = 22,
    required this.username,
    this.password,
    this.privateKeyPem,
    this.passphrase,
  });

  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKeyPem;
  final String? passphrase;

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'username': username,
    if (password != null) 'password': password,
    if (privateKeyPem != null) 'privateKeyPem': privateKeyPem,
    if (passphrase != null) 'passphrase': passphrase,
  };

  factory SshCredentials.fromJson(Map<String, dynamic> j) => SshCredentials(
    host: j['host'] as String,
    port: j['port'] as int? ?? 22,
    username: j['username'] as String,
    password: j['password'] as String?,
    privateKeyPem: j['privateKeyPem'] as String?,
    passphrase: j['passphrase'] as String?,
  );
}

class DartSshShell implements RemoteShell {
  DartSshShell._(this._client);

  final SSHClient _client;
  final _servers = <ServerSocket>[];

  /// Отпечаток ключа сервера, полученный при подключении (TOFU): сохраняется
  /// вместе с сервером, при следующих подключениях сравнивается.
  static Future<(DartSshShell, String)> connect(SshCredentials c, {String? expectedHostKey}) async {
    final socket = await SSHSocket.connect(c.host, c.port, timeout: const Duration(seconds: 15));
    var seenKey = '';
    final client = SSHClient(
      socket,
      username: c.username,
      onPasswordRequest: c.password == null ? null : () => c.password,
      identities: c.privateKeyPem == null ? null : SSHKeyPair.fromPem(c.privateKeyPem!, c.passphrase),
      onVerifyHostKey: (type, fingerprint) {
        seenKey = '$type:${base64.encode(fingerprint)}';
        return expectedHostKey == null || expectedHostKey == seenKey;
      },
    );
    await client.authenticated;
    return (DartSshShell._(client), seenKey);
  }

  @override
  Future<CommandResult> exec(String command, {void Function(String line)? onLine}) async {
    final session = await _client.execute(command);
    final out = StringBuffer();
    final err = StringBuffer();
    Future<void> pump(Stream<Uint8List> s, StringBuffer sink) => s
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((line) {
          sink.writeln(line);
          onLine?.call(line);
        });
    await Future.wait([pump(session.stdout, out), pump(session.stderr, err)]);
    await session.done;
    return CommandResult(session.exitCode ?? -1, out.toString(), err.toString());
  }

  @override
  Future<int> forwardToLocal(String remoteHost, int remotePort) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _servers.add(server);
    server.listen((local) async {
      try {
        final ch = await _client.forwardLocal(remoteHost, remotePort);
        unawaited(ch.stream.cast<List<int>>().pipe(local).catchError((_) {}));
        unawaited(local.cast<List<int>>().pipe(ch.sink).catchError((_) {}));
      } catch (_) {
        local.destroy();
      }
    });
    return server.port;
  }

  @override
  Future<void> close() async {
    for (final s in _servers) {
      await s.close();
    }
    _client.close();
  }
}
