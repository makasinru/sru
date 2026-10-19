import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

/// Протоколы, которые приложение умеет развернуть на сервере через 3x-ui.
enum ServerProtocol {
  vlessRealityVision(
    'VLESS + Reality (Vision)',
    'Основной протокол: маскируется под обычный HTTPS к популярному сайту. Быстрый и устойчивый к блокировкам.',
    443,
  ),
  vlessRealityXhttp(
    'VLESS + Reality (XHTTP)',
    'Запасной вариант на другом порту: трафик похож на обычные HTTP-запросы, помогает при агрессивном DPI.',
    8443,
  ),
  hysteria2(
    'Hysteria2',
    'Работает поверх QUIC/UDP, очень быстрый на плохих и дальних каналах. Может не работать там, где режут UDP.',
    443,
  ),
  trojanReality('Trojan + Reality', 'Совместимость со старыми клиентами, тоже маскируется через Reality.', 2053),
  shadowsocks2022(
    'Shadowsocks 2022',
    'Простой и лёгкий протокол без маскировки. Подходит для обхода геоблоков, но не DPI.',
    8388,
  ),
  vmessWs('VMess + WebSocket', 'Для работы через CDN (Cloudflare) или старых клиентов. Без CDN менее устойчив.', 8080),
  amneziawg(
    'AmneziaWG',
    'WireGuard с маскировкой от DPI, как в AmneziaVPN. Быстрый, работает поверх UDP. На Windows нужны права администратора.',
    47521,
  );

  const ServerProtocol(this.title, this.description, this.defaultPort);
  final String title;
  final String description;
  final int defaultPort;

  /// Протоколы на UDP не конфликтуют по порту с TCP.
  bool get isUdp => this == ServerProtocol.hysteria2 || this == ServerProtocol.amneziawg;

  /// Клиент добавляется отдельно, через clients/add: панель сама выдаёт ключи
  /// и адрес в туннеле (в настройках inbound ей нужен готовый allowedIPs).
  bool get clientViaApi => this == ServerProtocol.amneziawg;
}

/// Что ставит простой режим («Автоматически»): основной протокол, запасной на
/// другом порту, быстрый UDP-протокол и AmneziaWG — клиент сам выберет работающий.
const casualProtocols = [
  ServerProtocol.vlessRealityVision,
  ServerProtocol.vlessRealityXhttp,
  ServerProtocol.hysteria2,
  ServerProtocol.amneziawg,
];

class PresetContext {
  PresetContext({
    required this.subId,
    required this.email,
    this.realityTarget = 'www.microsoft.com',
    this.realityKeys,
    this.hysteriaCertFile,
    this.hysteriaKeyFile,
    this.hysteriaCertSha256,
    Random? random,
  }) : random = random ?? Random.secure();

  /// Общий subId: все inbound'ы одного пользователя попадают в одну подписку.
  final String subId;
  final String email;
  final String realityTarget;
  final ({String privateKey, String publicKey})? realityKeys;
  final String? hysteriaCertFile;
  final String? hysteriaKeyFile;

  /// SHA-256 самоподписанного сертификата (hex) для пиннинга на клиенте.
  final String? hysteriaCertSha256;
  final Random random;

  String hex(int bytes) => List.generate(bytes, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  String b64Key(int bytes) => base64.encode(List.generate(bytes, (_) => random.nextInt(256)));

  String password([int len = 24]) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    return List.generate(len, (_) => chars[random.nextInt(chars.length)]).join();
  }
}

/// Собирает тело запроса /panel/api/inbounds/add для протокола.
/// Поля соответствуют схемам фронтенда 3x-ui (frontend/src/schemas/protocols).
class ProtocolPresets {
  static Map<String, dynamic> inbound(ServerProtocol proto, PresetContext c, {int? port}) {
    final p = port ?? proto.defaultPort;
    final email = '${c.email}-${proto.name}';
    Map<String, dynamic> client(Map<String, dynamic> creds) => {
      ...creds,
      'email': email,
      'limitIp': 0,
      'totalGB': 0,
      'expiryTime': 0,
      'enable': true,
      'tgId': 0,
      'subId': c.subId,
      'comment': '',
      'reset': 0,
    };

    final base = <String, dynamic>{
      'enable': true,
      'remark': 'SRU ${proto.title}',
      'listen': '',
      'port': p,
      'expiryTime': 0,
      'total': 0,
      'sniffing': {
        'enabled': true,
        'destOverride': ['http', 'tls', 'quic'],
        'routeOnly': false,
      },
    };

    switch (proto) {
      case ServerProtocol.vlessRealityVision:
        return {
          ...base,
          'protocol': 'vless',
          'settings': {
            'clients': [
              client({'id': const Uuid().v4(), 'flow': 'xtls-rprx-vision'}),
            ],
            'decryption': 'none',
            'fallbacks': [],
          },
          'streamSettings': {
            'network': 'tcp',
            'tcpSettings': {
              'acceptProxyProtocol': false,
              'header': {'type': 'none'},
            },
            ..._reality(c),
          },
        };
      case ServerProtocol.vlessRealityXhttp:
        return {
          ...base,
          'protocol': 'vless',
          'settings': {
            'clients': [
              client({'id': const Uuid().v4(), 'flow': ''}),
            ],
            'decryption': 'none',
            'fallbacks': [],
          },
          'streamSettings': {
            'network': 'xhttp',
            'xhttpSettings': {'path': '/${c.hex(4)}', 'host': '', 'mode': 'auto'},
            ..._reality(c),
          },
        };
      case ServerProtocol.trojanReality:
        return {
          ...base,
          'protocol': 'trojan',
          'settings': {
            'clients': [
              client({'password': c.password()}),
            ],
            'fallbacks': [],
          },
          'streamSettings': {
            'network': 'tcp',
            'tcpSettings': {
              'acceptProxyProtocol': false,
              'header': {'type': 'none'},
            },
            ..._reality(c),
          },
        };
      case ServerProtocol.hysteria2:
        if (c.hysteriaCertFile == null || c.hysteriaKeyFile == null) {
          throw ArgumentError('Для Hysteria2 нужен сертификат');
        }
        return {
          ...base,
          'protocol': 'hysteria',
          'settings': {
            'version': 2,
            'clients': [
              client({'auth': c.password(32)}),
            ],
          },
          'streamSettings': {
            'network': 'hysteria',
            'hysteriaSettings': {'version': 2, 'auth': '', 'udpIdleTimeout': 60},
            'security': 'tls',
            'tlsSettings': {
              'serverName': c.realityTarget,
              'minVersion': '1.3',
              'maxVersion': '1.3',
              'alpn': ['h3'],
              'certificates': [
                {'certificateFile': c.hysteriaCertFile, 'keyFile': c.hysteriaKeyFile, 'usage': 'encipherment'},
              ],
              'settings': {
                'fingerprint': '',
                'pinnedPeerCertSha256': [if (c.hysteriaCertSha256 != null) c.hysteriaCertSha256],
              },
            },
          },
        };
      case ServerProtocol.shadowsocks2022:
        const method = '2022-blake3-aes-256-gcm';
        return {
          ...base,
          'protocol': 'shadowsocks',
          'settings': {
            'method': method,
            'password': c.b64Key(32),
            'network': 'tcp,udp',
            'clients': [
              client({'method': '', 'password': c.b64Key(32)}),
            ],
          },
          'streamSettings': {'network': 'tcp', 'security': 'none'},
        };
      case ServerProtocol.amneziawg:
        // Пустые clients: ключи сервера и параметры обфускации (AWG 3.1)
        // панель генерирует сама.
        return {
          ...base,
          'protocol': 'amneziawg',
          'settings': {'clients': []},
          'streamSettings': {},
          'sniffing': {'enabled': false},
        };
      case ServerProtocol.vmessWs:
        return {
          ...base,
          'protocol': 'vmess',
          'settings': {
            'clients': [
              client({'id': const Uuid().v4(), 'security': 'auto'}),
            ],
          },
          'streamSettings': {
            'network': 'ws',
            'wsSettings': {'path': '/${c.hex(4)}', 'host': ''},
            'security': 'none',
          },
        };
    }
  }

  static Map<String, dynamic> _reality(PresetContext c) {
    final keys = c.realityKeys;
    if (keys == null) throw ArgumentError('Для Reality нужны ключи X25519');
    return {
      'security': 'reality',
      'realitySettings': {
        'show': false,
        'xver': 0,
        'target': '${c.realityTarget}:443',
        'serverNames': [c.realityTarget],
        'privateKey': keys.privateKey,
        'shortIds': [c.hex(8)],
        'settings': {'publicKey': keys.publicKey, 'fingerprint': 'chrome', 'serverName': '', 'spiderX': '/'},
      },
    };
  }
}
