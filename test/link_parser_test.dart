import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/core/models/proxy_profile.dart';

void main() {
  test('VLESS Reality Vision', () {
    final p = LinkParser.parse(
      'vless://8a1b2c3d-1111-2222-3333-444455556666@1.2.3.4:443'
      '?type=tcp&security=reality&pbk=PUBKEY&fp=chrome&sni=www.microsoft.com&sid=abcd&spx=%2F&flow=xtls-rprx-vision'
      '#%D0%93%D0%B5%D1%80%D0%BC%D0%B0%D0%BD%D0%B8%D1%8F',
    );
    expect(p.protocol, ProxyProtocol.vless);
    expect(p.host, '1.2.3.4');
    expect(p.port, 443);
    expect(p.credential, '8a1b2c3d-1111-2222-3333-444455556666');
    expect(p.name, 'Германия');
    expect(p.security, 'reality');
    expect(p.params['flow'], 'xtls-rprx-vision');
    expect(p.params['spx'], '/');
  });

  test('VMess base64 JSON', () {
    final json = {
      'v': '2',
      'ps': 'vm',
      'add': 'example.com',
      'port': '8080',
      'id': 'uuid-1',
      'net': 'ws',
      'path': '/ws',
      'host': 'cdn.example.com',
      'tls': '',
    };
    final p = LinkParser.parse('vmess://${base64.encode(utf8.encode(jsonEncode(json)))}');
    expect(p.protocol, ProxyProtocol.vmess);
    expect(p.port, 8080);
    expect(p.network, 'ws');
    expect(p.security, 'none');
    expect(p.params['path'], '/ws');
    expect(p.params['host'], 'cdn.example.com');
  });

  test('Shadowsocks SIP002 и SS-2022 с plain userinfo', () {
    final userinfo = base64Url.encode(utf8.encode('chacha20-ietf-poly1305:secret')).replaceAll('=', '');
    final a = LinkParser.parse('ss://$userinfo@5.6.7.8:8388#ss1');
    expect(a.secondaryCredential, 'chacha20-ietf-poly1305');
    expect(a.credential, 'secret');
    expect(a.port, 8388);

    final b = LinkParser.parse('ss://2022-blake3-aes-256-gcm:c2VydmVy%3D%3AY2xpZW50%3D@5.6.7.8:8388#ss2022');
    expect(b.secondaryCredential, '2022-blake3-aes-256-gcm');
    expect(b.credential, 'c2VydmVy=:Y2xpZW50=');
  });

  test('Shadowsocks старый формат целиком в base64', () {
    final body = base64.encode(utf8.encode('aes-256-gcm:pass@9.9.9.9:1234'));
    final p = LinkParser.parse('ss://$body#old');
    expect(p.host, '9.9.9.9');
    expect(p.port, 1234);
    expect(p.credential, 'pass');
    expect(p.name, 'old');
  });

  test('Hysteria2 / hy2', () {
    final p = LinkParser.parse(
      'hy2://pa%24%24@[2001:db8::1]:443?sni=a.com&obfs=salamander&obfs-password=x&pinSHA256=ab#hy',
    );
    expect(p.protocol, ProxyProtocol.hysteria2);
    expect(p.host, '2001:db8::1');
    expect(p.credential, r'pa$$');
    expect(p.security, 'tls');
    expect(p.params['obfs'], 'salamander');
  });

  test('Trojan, WireGuard, SOCKS', () {
    final t = LinkParser.parse('trojan://pwd@t.example:443?type=grpc&serviceName=svc&security=tls&sni=t.example#tr');
    expect(t.protocol, ProxyProtocol.trojan);
    expect(t.params['serviceName'], 'svc');

    final w = LinkParser.parse(
      'wireguard://PRIVKEY%3D@wg.example:51820?publickey=PUB%3D&address=10.0.0.2%2F32&mtu=1280#wg',
    );
    expect(w.protocol, ProxyProtocol.wireguard);
    expect(w.credential, 'PRIVKEY=');
    expect(w.params['publickey'], 'PUB=');

    final s = LinkParser.parse('socks://${base64.encode(utf8.encode('u:p'))}@127.0.0.1:1080#s');
    expect(s.credential, 'u');
    expect(s.secondaryCredential, 'p');
  });

  test('parseMany пропускает мусор и неизвестные схемы', () {
    final list = LinkParser.parseMany('''
# comment
vless://id@h:1?security=none#a
tuic://x@h:2#unsupported
not a link
trojan://p@h:3#b
''');
    expect(list.map((e) => e.name), ['a', 'b']);
  });

  test('decodeBase64Loose: url-safe без паддинга', () {
    expect(utf8.decode(decodeBase64Loose('aGk_Pw')), 'hi??');
  });
}
