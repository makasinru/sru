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

  test('разгон не занижает замер: медленное начало не считается', () async {
    // Первую секунду сервер отдаёт по капле (как разгон TCP), потом секунду — быстро.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < 1000) {
        r.response.add(Uint8List(1024));
        await r.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      while (sw.elapsedMilliseconds < 2000) {
        r.response.add(Uint8List(64 * 1024));
        await r.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 4));
      }
      await r.response.close();
    });
    final checker = ConnectivityChecker(proxyPort: server.port, speedUrl: 'http://speed.test/__down');
    Future<double> measure(Duration warmup) async =>
        (await checker.speedTest(streams: 1, warmup: warmup, duration: const Duration(seconds: 5)))!;
    final withWarmup = await measure(const Duration(milliseconds: 1100));
    final wholeTime = await measure(Duration.zero);
    await server.close(force: true);
    // Первая секунда почти пустая: по всему времени скорость выходит вдвое меньше.
    expect(withWarmup, greaterThan(wholeTime * 1.5));
  });
}
