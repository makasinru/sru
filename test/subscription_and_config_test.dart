import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/core/links/subscription.dart';
import 'package:sru/core/xray/xray_config_builder.dart';

void main() {
  group('Подписка', () {
    test('base64-тело и заголовки 3x-ui', () async {
      final body = base64.encode(utf8.encode('vless://id@h:443?security=reality&pbk=k#a\ntrojan://p@h:2053#b'));
      final client = MockClient((req) async {
        expect(req.headers['User-Agent'], 'SRU/1.0');
        return http.Response(
          body,
          200,
          headers: {
            'subscription-userinfo': 'upload=100; download=200; total=1000; expire=1893456000',
            'profile-title': 'base64:${base64.encode(utf8.encode('Мой VPN'))}',
            'profile-update-interval': '12',
          },
        );
      });
      final r = await SubscriptionParser.fetch(Uri.parse('https://sub.example/abc'), client: client);
      expect(r.profiles.length, 2);
      expect(r.info.title, 'Мой VPN');
      expect(r.info.used, 300);
      expect(r.info.total, 1000);
      expect(r.info.expire!.year, 2030);
      expect(r.info.updateIntervalHours, 12);
    });

    test('plain-тело', () {
      expect(SubscriptionParser.parseBody('ss://YWVzLTI1Ni1nY206cA@h:1#x\n').length, 1);
    });
  });

  group('Конфиг Xray', () {
    test('VLESS Reality Vision', () {
      final p = LinkParser.parse(
        'vless://uuid@1.2.3.4:443?type=tcp&security=reality&pbk=PUB&sni=www.microsoft.com&sid=ab&flow=xtls-rprx-vision#a',
      );
      final cfg = XrayConfigBuilder.build(p);
      final out = (cfg['outbounds'] as List).first as Map<String, dynamic>;
      expect(out['protocol'], 'vless');
      final user = out['settings']['vnext'][0]['users'][0];
      expect(user['flow'], 'xtls-rprx-vision');
      expect(user['encryption'], 'none');
      final ss = out['streamSettings'];
      expect(ss['security'], 'reality');
      expect(ss['realitySettings']['publicKey'], 'PUB');
      expect(ss['realitySettings']['fingerprint'], 'chrome');
      // TUN по умолчанию и правила обхода РФ
      expect((cfg['inbounds'] as List).any((i) => i['protocol'] == 'tun'), isTrue);
      expect(jsonEncode(cfg['routing']), contains('geoip:ru'));
    });

    test('XHTTP с extra', () {
      final p = LinkParser.parse(
        'vless://u@h:8443?type=xhttp&path=%2Fab&mode=packet-up&security=reality&pbk=k&extra=%7B%22xPaddingBytes%22%3A%22100-1000%22%7D#x',
      );
      final ss = XrayConfigBuilder.streamSettings(p);
      expect(ss['network'], 'xhttp');
      expect(ss['xhttpSettings']['mode'], 'packet-up');
      expect(ss['xhttpSettings']['extra'], {'xPaddingBytes': '100-1000'});
    });

    test('Hysteria2 с пиннингом и salamander', () {
      final p = LinkParser.parse('hy2://pass@h:443?sni=s.com&pinSHA256=deadbeef&obfs=salamander&obfs-password=o#h');
      final out = XrayConfigBuilder.outbound(p);
      expect(out['protocol'], 'hysteria');
      expect(out['settings'], {'version': 2, 'address': 'h', 'port': 443});
      final ss = out['streamSettings'];
      expect(ss['network'], 'hysteria');
      expect(ss['hysteriaSettings']['auth'], 'pass');
      expect(ss['tlsSettings']['pinnedPeerCertSha256'], 'deadbeef');
      expect(ss['tlsSettings']['alpn'], ['h3']);
      expect(ss['finalmask']['udp'][0]['type'], 'salamander');
    });

    test('режим прокси без TUN и глобальная маршрутизация', () {
      final p = LinkParser.parse('trojan://p@h:443?security=tls&sni=h#t');
      final cfg = XrayConfigBuilder.build(p, const XrayOptions(tun: false, routing: RoutingPreset.global));
      expect((cfg['inbounds'] as List).map((i) => i['protocol']), ['socks', 'http']);
      expect(jsonEncode(cfg['routing']), isNot(contains('geoip:ru')));
    });
  });
}
