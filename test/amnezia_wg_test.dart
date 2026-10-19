import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sru/core/links/amnezia_wg.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/core/links/subscription.dart';
import 'package:sru/core/models/proxy_profile.dart';

// Так выглядит .conf из подписки 3x-ui (internal/sub/service.go).
const conf = '''[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.8.1.2/32
DNS = 8.8.8.8, 8.8.4.4
MTU = 1404
Jc = 6
Jmin = 82
Jmax = 252
S1 = 131
S2 = 84
I1 = <r 251>
HeaderProtectionKey = Gi1HbW0gDaW9i9vo3xpflK6+O/Ie7LATKpJwOsKpQqc=
RandomTrailers = on

# Нидерланды-мама
[Peer]
PublicKey = 5Q0Y18nLlcjNkN288ff8tNGs/yBSnAtF7Mz80hv3xlM=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.9:47521''';

void main() {
  test('vpn:// из 3x-ui (base64url .conf)', () {
    final link = 'vpn://${base64Url.encode(utf8.encode(conf)).replaceAll('=', '')}';
    final p = LinkParser.parse(link);
    expect(p.protocol, ProxyProtocol.amneziawg);
    expect(p.host, '203.0.113.9');
    expect(p.port, 47521);
    expect(p.name, 'Нидерланды-мама');
    expect(p.params['conf'], conf);
    expect(p.raw, link);
  });

  test('vpn:// родного формата AmneziaVPN (qCompress JSON)', () {
    final json = jsonEncode({
      'containers': [
        {
          'container': 'amnezia-awg',
          'awg': {
            'last_config': jsonEncode({'config': conf, 'hostName': '203.0.113.9'}),
          },
        },
      ],
      'description': 'Мой сервер',
    });
    final data = utf8.encode(json);
    final packed = BytesBuilder()
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(zlib.encode(data));
    final link = 'vpn://${base64Url.encode(packed.toBytes()).replaceAll('=', '')}';
    final p = LinkParser.parse(link);
    expect(p.protocol, ProxyProtocol.amneziawg);
    expect(p.params['conf'], conf);
  });

  test('.conf целиком: вставка и подписка', () {
    expect(LinkParser.parseMany(conf).single.protocol, ProxyProtocol.amneziawg);
    expect(SubscriptionParser.parseBody(conf).single.port, 47521);
  });

  test('параметры интерфейса для VpnService', () {
    expect(AmneziaWg.tunParams(conf), {
      'addresses': ['10.8.1.2/32'],
      'dns': ['8.8.8.8', '8.8.4.4'],
      'routes': ['0.0.0.0/0', '::/0'],
      'mtu': 1404,
    });
  });
}
