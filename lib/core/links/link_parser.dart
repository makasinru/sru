import 'dart:convert';

import '../models/proxy_profile.dart';
import 'amnezia_wg.dart';

class LinkParseException implements Exception {
  LinkParseException(this.message);
  final String message;
  @override
  String toString() => 'LinkParseException: $message';
}

/// Разбор share-ссылок в формате, который понимают Happ, v2rayNG, Hiddify
/// и который выдаёт подписка 3x-ui.
class LinkParser {
  static const supportedSchemes = [
    'vless',
    'vmess',
    'trojan',
    'ss',
    'hysteria2',
    'hy2',
    'wireguard',
    'wg',
    'socks',
    'socks5',
    'vpn',
  ];

  static bool looksLikeLink(String s) {
    final i = s.indexOf('://');
    return i > 0 && supportedSchemes.contains(s.substring(0, i).toLowerCase());
  }

  /// Разбирает текст с несколькими ссылками (по одной на строку), пропуская
  /// пустые строки, комментарии и неподдерживаемые схемы.
  static List<ProxyProfile> parseMany(String text) {
    // Целиком .conf AmneziaWG/WireGuard.
    if (AmneziaWg.isConf(text)) return [AmneziaWg.profile(text)];
    final result = <ProxyProfile>[];
    for (final line in const LineSplitter().convert(text)) {
      final s = line.trim();
      if (!looksLikeLink(s)) continue;
      try {
        result.add(parse(s));
      } on FormatException {
        continue;
      } on LinkParseException {
        continue;
      }
    }
    return result;
  }

  static ProxyProfile parse(String link) {
    final s = link.trim();
    final scheme = s.substring(0, s.indexOf('://')).toLowerCase();
    switch (scheme) {
      case 'vmess':
        return _parseVmess(s);
      case 'ss':
        return _parseShadowsocks(s);
      case 'vless':
        return _parseStandard(s, ProxyProtocol.vless);
      case 'trojan':
        return _parseStandard(s, ProxyProtocol.trojan);
      case 'hysteria2':
      case 'hy2':
        return _parseStandard(s, ProxyProtocol.hysteria2);
      case 'wireguard':
      case 'wg':
        return _parseStandard(s, ProxyProtocol.wireguard);
      case 'socks':
      case 'socks5':
        return _parseSocks(s);
      case 'vpn':
        final conf = AmneziaWg.confFromVpnLink(s);
        if (conf == null) throw LinkParseException('В ключе vpn:// нет конфигурации AmneziaWG');
        return AmneziaWg.profile(conf, raw: s);
    }
    throw LinkParseException('Неподдерживаемая схема: $scheme');
  }

  /// scheme://credential@host:port?query#name
  static ProxyProfile _parseStandard(String link, ProxyProtocol protocol) {
    final uri = Uri.parse(link);
    if (uri.host.isEmpty) throw LinkParseException('Нет адреса сервера');
    final params = Map<String, String>.from(uri.queryParameters);
    if (protocol == ProxyProtocol.hysteria2) {
      params['security'] = 'tls';
    }
    return ProxyProfile(
      protocol: protocol,
      host: uri.host,
      port: uri.hasPort ? uri.port : 443,
      name: _fragment(uri, uri.host),
      credential: Uri.decodeComponent(uri.userInfo),
      params: params,
      raw: link,
    );
  }

  static ProxyProfile _parseVmess(String link) {
    final body = link.substring('vmess://'.length);
    final hash = body.indexOf('#');
    final payload = hash >= 0 ? body.substring(0, hash) : body;
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(decodeBase64Loose(payload))) as Map<String, dynamic>;
    } catch (_) {
      throw LinkParseException('Некорректный vmess');
    }
    String str(String k) => (j[k] ?? '').toString();
    final params = <String, String>{
      'type': str('net').isEmpty ? 'tcp' : str('net'),
      'security': str('tls').isEmpty ? 'none' : str('tls'),
      if (str('type').isNotEmpty && str('type') != 'none') 'headerType': str('type'),
      if (str('host').isNotEmpty) 'host': str('host'),
      if (str('path').isNotEmpty) 'path': str('path'),
      if (str('sni').isNotEmpty) 'sni': str('sni'),
      if (str('alpn').isNotEmpty) 'alpn': str('alpn'),
      if (str('fp').isNotEmpty) 'fp': str('fp'),
      if (str('scy').isNotEmpty) 'encryption': str('scy'),
    };
    if (params['type'] == 'grpc' && params.containsKey('path')) {
      params['serviceName'] = params.remove('path')!;
    }
    final host = str('add');
    return ProxyProfile(
      protocol: ProxyProtocol.vmess,
      host: host,
      port: int.tryParse(str('port')) ?? 443,
      name: str('ps').isEmpty ? host : str('ps'),
      credential: str('id'),
      params: params,
      raw: link,
    );
  }

  /// SIP002 (ss://base64(method:pass)@host:port#name), plain userinfo
  /// (для SS-2022 ключи передаются percent-encoded) и старый формат
  /// ss://base64(method:pass@host:port)#name.
  static ProxyProfile _parseShadowsocks(String link) {
    var uri = Uri.parse(link);
    String userInfo;
    if (uri.host.isEmpty || uri.userInfo.isEmpty) {
      final body = link.substring('ss://'.length);
      final hash = body.indexOf('#');
      final payload = hash >= 0 ? body.substring(0, hash) : body;
      final decoded = utf8.decode(decodeBase64Loose(payload));
      uri = Uri.parse('ss://$decoded${hash >= 0 ? body.substring(hash) : ''}');
      userInfo = Uri.decodeComponent(uri.userInfo);
    } else {
      userInfo = Uri.decodeComponent(uri.userInfo);
      if (!userInfo.contains(':')) {
        userInfo = utf8.decode(decodeBase64Loose(userInfo));
      }
    }
    final sep = userInfo.indexOf(':');
    if (sep < 0) throw LinkParseException('Некорректный ss');
    return ProxyProfile(
      protocol: ProxyProtocol.shadowsocks,
      host: uri.host,
      port: uri.port,
      name: _fragment(uri, uri.host),
      credential: userInfo.substring(sep + 1),
      secondaryCredential: userInfo.substring(0, sep),
      params: Map<String, String>.from(uri.queryParameters),
      raw: link,
    );
  }

  static ProxyProfile _parseSocks(String link) {
    final uri = Uri.parse(link);
    var user = '';
    var pass = '';
    if (uri.userInfo.isNotEmpty) {
      var info = Uri.decodeComponent(uri.userInfo);
      if (!info.contains(':')) {
        try {
          info = utf8.decode(decodeBase64Loose(info));
        } catch (_) {}
      }
      final sep = info.indexOf(':');
      user = sep >= 0 ? info.substring(0, sep) : info;
      pass = sep >= 0 ? info.substring(sep + 1) : '';
    }
    return ProxyProfile(
      protocol: ProxyProtocol.socks,
      host: uri.host,
      port: uri.hasPort ? uri.port : 1080,
      name: _fragment(uri, uri.host),
      credential: user,
      secondaryCredential: pass,
      raw: link,
    );
  }

  static String _fragment(Uri uri, String fallback) {
    if (uri.fragment.isEmpty) return fallback;
    try {
      return Uri.decodeComponent(uri.fragment);
    } catch (_) {
      return uri.fragment;
    }
  }
}

/// base64 в любом варианте: стандартный/URL-safe, с паддингом и без,
/// с переносами строк.
List<int> decodeBase64Loose(String input) {
  var s = input.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
  final pad = s.length % 4;
  if (pad == 1) throw const FormatException('bad base64 length');
  if (pad > 0) s += '=' * (4 - pad);
  return base64.decode(s);
}
