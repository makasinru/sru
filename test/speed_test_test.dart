import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sru/core/vpn/connectivity_check.dart';

void main() {
  test('замер скорости считает Мбит/с по скачанному через прокси', () async {
    // Локальный сервер играет роль HTTP-прокси: для http:// клиент шлёт ему GET.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      for (var i = 0; i < 40; i++) {
        r.response.add(Uint8List(64 * 1024));
        await r.response.flush();
      }
      await r.response.close();
    });
    final checker = ConnectivityChecker(proxyPort: server.port, speedUrl: 'http://speed.test/__down');
    final mbps = await checker.speedTest(duration: const Duration(seconds: 2));
    await server.close(force: true);
    expect(mbps, isNotNull);
    expect(mbps!, greaterThan(1));
  });

  test('замер скорости: ничего не скачалось — null', () async {
    final checker = ConnectivityChecker(proxyPort: 1, speedUrl: 'http://speed.test/');
    expect(await checker.speedTest(), isNull);
  });
}
