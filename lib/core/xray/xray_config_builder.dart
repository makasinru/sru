import 'dart:convert';

import '../models/proxy_profile.dart';
import 'split_tunnel.dart';

/// Пресеты маршрутизации. Простой режим показывает только их,
/// продвинутый — ещё и собственные правила.
enum RoutingPreset {
  /// Весь трафик через VPN.
  global,

  /// Российские сайты и IP напрямую, остальное через VPN.
  bypassRu,
}

class RoutingRule {
  RoutingRule({required this.outbound, this.domains = const [], this.ips = const []});
  final String outbound; // proxy | direct | block
  final List<String> domains;
  final List<String> ips;

  Map<String, dynamic> toJson() => {
    'type': 'field',
    'outboundTag': outbound,
    if (domains.isNotEmpty) 'domain': domains,
    if (ips.isNotEmpty) 'ip': ips,
  };
}

class XrayOptions {
  const XrayOptions({
    this.tun = true,
    this.socksPort = 10808,
    this.httpPort = 10809,
    this.routing = RoutingPreset.bypassRu,
    this.customRules = const [],
    this.dns = const ['https://1.1.1.1/dns-query', '8.8.8.8'],
    this.blockAds = false,
    this.mtu = 1500,
    this.windowsTun = false,
    this.siteSplit = SplitMode.off,
    this.splitSites = const [],
    this.proxyUser,
    this.proxyPassword,
  });

  /// true — TUN-интерфейс (весь трафик устройства, как VPN в Amnezia/Happ),
  /// false — только локальный SOCKS/HTTP прокси.
  final bool tun;
  final int socksPort;
  final int httpPort;
  final RoutingPreset routing;
  final List<RoutingRule> customRules;
  final List<String> dns;
  final bool blockAds;
  final int mtu;

  /// TUN на Windows (wintun, права администратора): Xray сам назначает адрес,
  /// маршруты и выводит свои соединения мимо туннеля. Требует [tun].
  final bool windowsTun;

  /// Раздельное туннелирование по сайтам (продвинутый режим).
  final SplitMode siteSplit;
  final List<String> splitSites;

  /// Пароль на локальные SOCKS/HTTP-входы. На Android они нужны только самому
  /// приложению (проверка подключения), и без пароля другие приложения могли бы
  /// найти прокси на 127.0.0.1 и ходить через него или вычислить VPN.
  final String? proxyUser;
  final String? proxyPassword;

  bool get _auth => proxyUser != null && proxyPassword != null;
}

/// Превращает [ProxyProfile] в полный конфиг Xray-core.
class XrayConfigBuilder {
  static Map<String, dynamic> build(ProxyProfile p, [XrayOptions o = const XrayOptions()]) {
    return {
      'log': {'loglevel': 'warning'},
      'dns': {'servers': o.dns, 'queryStrategy': 'UseIPv4'},
      'inbounds': [
        {
          'tag': 'socks',
          'listen': '127.0.0.1',
          'port': o.socksPort,
          'protocol': 'socks',
          'settings': {
            'auth': o._auth ? 'password' : 'noauth',
            'udp': true,
            if (o._auth)
              'accounts': [
                {'user': o.proxyUser, 'pass': o.proxyPassword},
              ],
          },
          'sniffing': _sniffing,
        },
        {
          'tag': 'http',
          'listen': '127.0.0.1',
          'port': o.httpPort,
          'protocol': 'http',
          if (o._auth)
            'settings': {
              'accounts': [
                {'user': o.proxyUser, 'pass': o.proxyPassword},
              ],
            },
          'sniffing': _sniffing,
        },
        if (o.tun)
          {
            'tag': 'tun',
            'port': 0,
            'protocol': 'tun',
            'settings': o.windowsTun ? _windowsTun(o) : {'name': 'sru0', 'mtu': o.mtu},
            'sniffing': _sniffing,
          },
      ],
      'outbounds': [
        outbound(p),
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'block', 'protocol': 'blackhole'},
        {'tag': 'dns-out', 'protocol': 'dns'},
      ],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          {'type': 'field', 'port': '53', 'network': 'udp', 'outboundTag': 'dns-out'},
          {
            'type': 'field',
            'ip': ['geoip:private'],
            'outboundTag': 'direct',
          },
          if (o.blockAds)
            {
              'type': 'field',
              'domain': ['geosite:category-ads-all'],
              'outboundTag': 'block',
            },
          ...o.customRules.map((r) => r.toJson()),
          ..._splitRules(o),
          if (o.routing == RoutingPreset.bypassRu && !_onlyListed(o)) ...[
            {
              'type': 'field',
              'domain': ['geosite:category-ru', 'domain:ru', 'domain:xn--p1ai'],
              'outboundTag': 'direct',
            },
            {
              'type': 'field',
              'ip': ['geoip:ru'],
              'outboundTag': 'direct',
            },
          ],
          // «Только эти через VPN»: всё, что не попало в список, — напрямую.
          if (_onlyListed(o)) {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'direct'},
        ],
      },
    };
  }

  /// Адрес TUN на Windows и DNS внутри него (запросы на 172.19.0.2:53 уходят в
  /// туннель и обрабатываются правилом port 53 → dns-out).
  static Map<String, dynamic> _windowsTun(XrayOptions o) => {
    'name': 'SruNaZapret',
    'mtu': o.mtu,
    'gateway': ['172.19.0.1/30'],
    'dns': ['172.19.0.2'],
    'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
    // Windows шлёт DNS-запросы во все интерфейсы сразу — закрываем эту утечку.
    'autoSystemWfpBlockLeak': ['dns'],
  };

  static bool _onlyListed(XrayOptions o) =>
      o.siteSplit == SplitMode.onlyListed && !SiteRules.parse(o.splitSites).isEmpty;

  static List<Map<String, dynamic>> _splitRules(XrayOptions o) {
    if (o.siteSplit == SplitMode.off) return const [];
    final rules = SiteRules.parse(o.splitSites);
    final out = o.siteSplit == SplitMode.onlyListed ? 'proxy' : 'direct';
    return [
      if (rules.domains.isNotEmpty) {'type': 'field', 'domain': rules.domains, 'outboundTag': out},
      if (rules.ips.isNotEmpty) {'type': 'field', 'ip': rules.ips, 'outboundTag': out},
    ];
  }

  static String buildJson(ProxyProfile p, [XrayOptions o = const XrayOptions()]) =>
      const JsonEncoder.withIndent('  ').convert(build(p, o));

  static const _sniffing = {
    'enabled': true,
    'destOverride': ['http', 'tls', 'quic'],
  };

  static Map<String, dynamic> outbound(ProxyProfile p) {
    final q = p.params;
    switch (p.protocol) {
      case ProxyProtocol.vless:
        return {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {
                'address': p.host,
                'port': p.port,
                'users': [
                  {
                    'id': p.credential,
                    'encryption': q['encryption'] ?? 'none',
                    if ((q['flow'] ?? '').isNotEmpty) 'flow': q['flow'],
                  },
                ],
              },
            ],
          },
          'streamSettings': streamSettings(p),
        };
      case ProxyProtocol.vmess:
        return {
          'tag': 'proxy',
          'protocol': 'vmess',
          'settings': {
            'vnext': [
              {
                'address': p.host,
                'port': p.port,
                'users': [
                  {'id': p.credential, 'security': q['encryption'] ?? 'auto'},
                ],
              },
            ],
          },
          'streamSettings': streamSettings(p),
        };
      case ProxyProtocol.trojan:
        return {
          'tag': 'proxy',
          'protocol': 'trojan',
          'settings': {
            'servers': [
              {'address': p.host, 'port': p.port, 'password': p.credential},
            ],
          },
          'streamSettings': streamSettings(p),
        };
      case ProxyProtocol.shadowsocks:
        return {
          'tag': 'proxy',
          'protocol': 'shadowsocks',
          'settings': {
            'servers': [
              {
                'address': p.host,
                'port': p.port,
                'method': p.secondaryCredential,
                'password': p.credential,
                'uot': true,
              },
            ],
          },
          'streamSettings': streamSettings(p),
        };
      case ProxyProtocol.hysteria2:
        return {
          'tag': 'proxy',
          'protocol': 'hysteria',
          'settings': {'version': 2, 'address': p.host, 'port': p.port},
          'streamSettings': streamSettings(p),
        };
      case ProxyProtocol.wireguard:
        return {
          'tag': 'proxy',
          'protocol': 'wireguard',
          'settings': {
            'secretKey': p.credential,
            'address': _csv(q['address'] ?? q['ip'] ?? '10.0.0.2/32'),
            'mtu': int.tryParse(q['mtu'] ?? '') ?? 1420,
            if ((q['reserved'] ?? '').isNotEmpty) 'reserved': _csv(q['reserved']!).map(int.parse).toList(),
            'peers': [
              {
                'publicKey': q['publickey'] ?? q['publicKey'] ?? '',
                if ((q['presharedkey'] ?? '').isNotEmpty) 'preSharedKey': q['presharedkey'],
                'endpoint': '${_hostForEndpoint(p.host)}:${p.port}',
                'allowedIPs': ['0.0.0.0/0', '::/0'],
              },
            ],
          },
        };
      case ProxyProtocol.socks:
        return {
          'tag': 'proxy',
          'protocol': 'socks',
          'settings': {
            'servers': [
              {
                'address': p.host,
                'port': p.port,
                if (p.credential.isNotEmpty)
                  'users': [
                    {'user': p.credential, 'pass': p.secondaryCredential},
                  ],
              },
            ],
          },
        };
    }
  }

  static Map<String, dynamic> streamSettings(ProxyProfile p) {
    final q = p.params;
    if (p.protocol == ProxyProtocol.hysteria2) {
      return {
        'network': 'hysteria',
        'hysteriaSettings': {'version': 2, 'auth': p.credential},
        'security': 'tls',
        'tlsSettings': _tls(q, p.host, defaultAlpn: const ['h3']),
        if ((q['obfs'] ?? '') == 'salamander')
          'finalmask': {
            'udp': [
              {
                'type': 'salamander',
                'settings': {'password': q['obfs-password'] ?? ''},
              },
            ],
          },
      };
    }

    final network = switch (p.network) {
      'splithttp' => 'xhttp',
      'h2' || 'http' => 'xhttp',
      final n => n,
    };
    final s = <String, dynamic>{'network': network};
    final host = q['host'] ?? '';
    final path = q['path'] ?? '/';
    switch (network) {
      case 'ws':
        s['wsSettings'] = {'path': path, if (host.isNotEmpty) 'host': host};
      case 'grpc':
        s['grpcSettings'] = {
          'serviceName': q['serviceName'] ?? '',
          'multiMode': q['mode'] == 'multi',
          if ((q['authority'] ?? '').isNotEmpty) 'authority': q['authority'],
        };
      case 'httpupgrade':
        s['httpupgradeSettings'] = {'path': path, if (host.isNotEmpty) 'host': host};
      case 'xhttp':
        s['xhttpSettings'] = {
          'path': path,
          if (host.isNotEmpty) 'host': host,
          'mode': q['mode'] ?? 'auto',
          if ((q['extra'] ?? '').isNotEmpty) 'extra': _tryJson(q['extra']!),
        };
      case 'kcp':
        s['kcpSettings'] = {if ((q['seed'] ?? '').isNotEmpty) 'seed': q['seed']};
      case 'tcp':
      case 'raw':
        if (q['headerType'] == 'http') {
          s['tcpSettings'] = {
            'header': {
              'type': 'http',
              'request': {
                'path': [path],
                'headers': {
                  'Host': [if (host.isNotEmpty) host],
                },
              },
            },
          };
        }
    }

    switch (p.security) {
      case 'reality':
        s['security'] = 'reality';
        s['realitySettings'] = {
          'serverName': q['sni'] ?? '',
          'fingerprint': q['fp']?.isNotEmpty == true ? q['fp'] : 'chrome',
          'publicKey': q['pbk'] ?? '',
          'shortId': q['sid'] ?? '',
          'spiderX': q['spx'] ?? '/',
          if ((q['pqv'] ?? '').isNotEmpty) 'mldsa65Verify': q['pqv'],
        };
      case 'tls':
        s['security'] = 'tls';
        s['tlsSettings'] = _tls(q, p.host);
      default:
        s['security'] = 'none';
    }
    return s;
  }

  static Map<String, dynamic> _tls(Map<String, String> q, String host, {List<String>? defaultAlpn}) {
    final alpn = (q['alpn'] ?? '').isNotEmpty ? _csv(q['alpn']!) : defaultAlpn;
    // allowInsecure удалён из Xray-core после 2026-06-01; для самоподписанных
    // сертификатов используется пиннинг по SHA-256 (pinSHA256 в ссылке).
    final pins = q['pinSHA256'] ?? q['pcs'] ?? '';
    return {
      'serverName': (q['sni'] ?? '').isNotEmpty ? q['sni'] : host,
      if ((q['fp'] ?? '').isNotEmpty) 'fingerprint': q['fp'],
      if (alpn != null) 'alpn': alpn,
      if (pins.isNotEmpty) 'pinnedPeerCertSha256': pins,
      if ((q['vcn'] ?? '').isNotEmpty) 'verifyPeerCertByName': q['vcn'],
      if ((q['ech'] ?? '').isNotEmpty) 'echConfigList': q['ech'],
    };
  }

  static List<String> _csv(String v) => v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  static String _hostForEndpoint(String host) => host.contains(':') ? '[$host]' : host;

  static Object _tryJson(String v) {
    try {
      return jsonDecode(v) as Object;
    } catch (_) {
      return v;
    }
  }
}
