/// Протоколы, которые умеет ядро Xray (тот же набор, что у Happ:
/// VLESS, VMess, Trojan, Shadowsocks, SOCKS, WireGuard, Hysteria2).
enum ProxyProtocol {
  vless('VLESS'),
  vmess('VMess'),
  trojan('Trojan'),
  shadowsocks('Shadowsocks'),
  hysteria2('Hysteria2'),
  wireguard('WireGuard'),

  /// Не через Xray: отдельный движок amneziawg-go в ядре (Android, Windows).
  amneziawg('AmneziaWG'),
  socks('SOCKS');

  const ProxyProtocol(this.title);
  final String title;
}

/// Один сервер (одна ссылка). Транспорт и безопасность хранятся в [params]
/// в том же виде, что в query-строке share-ссылки (type, security, sni, pbk…),
/// чтобы ссылку можно было восстановить без потерь.
class ProxyProfile {
  ProxyProfile({
    required this.protocol,
    required this.host,
    required this.port,
    required this.name,
    this.credential = '',
    this.secondaryCredential = '',
    Map<String, String>? params,
    this.raw = '',
  }) : params = params ?? {};

  final ProxyProtocol protocol;
  final String host;
  final int port;
  final String name;

  /// UUID (VLESS/VMess), пароль (Trojan/SS/Hysteria2), private key (WireGuard),
  /// логин (SOCKS).
  final String credential;

  /// Метод шифрования (SS) или пароль (SOCKS).
  final String secondaryCredential;

  final Map<String, String> params;
  final String raw;

  String get network => params['type'] ?? 'tcp';
  String get security => params['security'] ?? 'none';

  /// Короткое описание для списка серверов в продвинутом режиме.
  String get transportLabel {
    if (protocol == ProxyProtocol.hysteria2) return 'QUIC';
    if (protocol == ProxyProtocol.wireguard || protocol == ProxyProtocol.amneziawg) return 'UDP';
    final sec = security == 'none' ? '' : ' + ${security.toUpperCase()}';
    return '${network.toUpperCase()}$sec';
  }

  Map<String, dynamic> toJson() => {
    'protocol': protocol.name,
    'host': host,
    'port': port,
    'name': name,
    'credential': credential,
    'secondaryCredential': secondaryCredential,
    'params': params,
    'raw': raw,
  };

  factory ProxyProfile.fromJson(Map<String, dynamic> json) => ProxyProfile(
    protocol: ProxyProtocol.values.byName(json['protocol'] as String),
    host: json['host'] as String,
    port: json['port'] as int,
    name: json['name'] as String,
    credential: json['credential'] as String? ?? '',
    secondaryCredential: json['secondaryCredential'] as String? ?? '',
    params: Map<String, String>.from(json['params'] as Map? ?? {}),
    raw: json['raw'] as String? ?? '',
  );
}
