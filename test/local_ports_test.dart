import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sru/core/vpn/local_ports.dart';

void main() {
  test('порт 10808 занят другой программой — берётся свободный', () async {
    ServerSocket? busy;
    try {
      busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 10808);
    } on SocketException {
      // уже занят — тем лучше для теста
    }
    final p = await LocalPorts.pick();
    expect(p.socks, isNot(10808));
    expect(p.http, isNot(p.socks));
    // выбранные порты действительно свободны
    final a = await ServerSocket.bind(InternetAddress.loopbackIPv4, p.socks);
    final b = await ServerSocket.bind(InternetAddress.loopbackIPv4, p.http);
    await a.close();
    await b.close();
    await busy?.close();
  });
}
