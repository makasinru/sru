// Запускается, если собрано ядро: SRU_CORE_BIN=/path/to/sru-core flutter test test/desktop_engine_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sru/core/vpn/vpn_engine.dart';

void main() {
  final core = Platform.environment['SRU_CORE_BIN'];

  test('десктоп: ядро запускается, проксирует и останавливается', () async {
    final engine = DesktopXrayEngine(corePath: core)..useSystemProxy = false;
    final config = jsonEncode({
      'inbounds': [
        {'tag': 'http', 'listen': '127.0.0.1', 'port': 47809, 'protocol': 'http'},
      ],
      'outbounds': [
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    });
    await engine.start(config, sessionName: 'test');
    expect(engine.current, VpnStatus.connected, reason: engine.lastError);

    // Через HTTP-прокси ядра до локального сервера.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(
      (r) => r.response
        ..write('pong')
        ..close(),
    );
    final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:47809';
    final resp = await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/'))).close();
    expect(await resp.transform(utf8.decoder).join(), 'pong');
    client.close(force: true);
    await server.close(force: true);

    await engine.stop();
    expect(engine.current, VpnStatus.disconnected);
    expect(await engine.coreVersion(), startsWith('Xray '));
  }, skip: core == null ? 'нет SRU_CORE_BIN' : null);

  test('десктоп: понятная ошибка при битом конфиге', () async {
    final engine = DesktopXrayEngine(corePath: core)..useSystemProxy = false;
    await engine.start('{"inbounds": [{"protocol": "nope"}]}', sessionName: 'test');
    expect(engine.current, VpnStatus.error);
    expect(engine.lastError, isNotEmpty);
  }, skip: core == null ? 'нет SRU_CORE_BIN' : null);
}
