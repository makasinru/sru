import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/core/links/subscription.dart';

void main() {
  const awgConf =
      '[Interface]\nPrivateKey = x\nAddress = 10.8.1.2/32\n[Peer]\nPublicKey = y\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51821';
  final body = [
    'vless://u@h:443?security=none#vless',
    'tuic://u:p@h:8444#tuic',
    'vpn://${base64Url.encode(utf8.encode(awgConf)).replaceAll('=', '')}',
    'tg://proxy?server=h&port=10445&secret=ee00',
  ].join('\n');

  test('подписка 3x-ui: AmneziaWG берётся, TUIC и MTProto помечаются как неподдерживаемые', () async {
    final client = MockClient((_) async => http.Response(base64.encode(utf8.encode(body)), 200));
    final res = await SubscriptionParser.fetch(Uri.parse('https://h/sub/x'), client: client);
    expect(res.profiles.map((p) => p.protocol.name), ['vless', 'amneziawg']);
    expect(res.unsupported, ['TUIC', 'MTProto (прокси Telegram)']);
  });

  test('неподдерживаемые схемы из обычного текста', () {
    expect(LinkParser.unsupported('vless://a@b:1#x\nfoo bar'), isEmpty);
  });
}
