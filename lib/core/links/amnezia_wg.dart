import 'dart:convert';
import 'dart:io';

import '../models/proxy_profile.dart';
import 'link_parser.dart';

/// Ключи AmneziaWG:
/// * текст .conf (`[Interface]` … `[Peer]`) — его же понимает WireGuard;
/// * `vpn://<base64url .conf>` — так их отдаёт 3x-ui;
/// * `vpn://<base64url qCompress(JSON)>` — родной формат приложения AmneziaVPN.
class AmneziaWg {
  static bool isConf(String s) => s.contains('[Interface]') && s.contains('[Peer]');

  /// Текст .conf из ключа vpn://, или null.
  static String? confFromVpnLink(String link) {
    final body = link.trim().substring('vpn://'.length);
    final List<int> bytes;
    try {
      bytes = decodeBase64Loose(body);
    } on FormatException {
      return null;
    }
    final asText = utf8.decode(bytes, allowMalformed: true);
    if (isConf(asText)) return asText;
    // qCompress: 4 байта длины (big-endian) + zlib.
    if (bytes.length > 4) {
      try {
        final json = utf8.decode(zlib.decode(bytes.sublist(4)));
        return _findConf(jsonDecode(json));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// В JSON AmneziaVPN конфиг лежит строкой (иногда внутри ещё одной JSON-строки).
  static String? _findConf(Object? node) {
    if (node is String) {
      final t = node.trimLeft();
      // Сначала вложенный JSON (он тоже может содержать «[Interface]» как
      // подстроку), потом сам конфиг — он начинается с «[», но это не JSON.
      if (t.startsWith('{') || (t.startsWith('[') && !t.startsWith('[Interface]'))) {
        try {
          return _findConf(jsonDecode(node));
        } catch (_) {
          return null;
        }
      }
      return isConf(node) ? node : null;
    }
    if (node is Map) {
      for (final v in node.values) {
        final r = _findConf(v);
        if (r != null) return r;
      }
    }
    if (node is List) {
      for (final v in node) {
        final r = _findConf(v);
        if (r != null) return r;
      }
    }
    return null;
  }

  static ProxyProfile profile(String conf, {String raw = ''}) {
    String? value(String key) {
      final m = RegExp('^\\s*$key\\s*=\\s*(.+?)\\s*\$', multiLine: true, caseSensitive: false).firstMatch(conf);
      return m?.group(1);
    }

    final endpoint = value('Endpoint') ?? '';
    final i = endpoint.lastIndexOf(':');
    var host = i > 0 ? endpoint.substring(0, i) : endpoint;
    if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
    final port = i > 0 ? int.tryParse(endpoint.substring(i + 1)) ?? 51820 : 51820;
    // Имя — из комментария перед [Peer] (3x-ui пишет туда название).
    final name = RegExp(r'^#\s*(.+)$', multiLine: true).firstMatch(conf)?.group(1)?.trim();
    return ProxyProfile(
      protocol: ProxyProtocol.amneziawg,
      host: host,
      port: port,
      name: (name == null || name.isEmpty) ? 'AmneziaWG $host' : name,
      params: {'conf': conf.trim()},
      raw: raw.isEmpty ? conf.trim() : raw,
    );
  }

  /// Параметры интерфейса для VpnService (адреса, DNS, MTU, маршруты).
  static Map<String, Object> tunParams(String conf) {
    List<String> list(String key) => [
      for (final m in RegExp('^\\s*$key\\s*=\\s*(.+)\$', multiLine: true, caseSensitive: false).allMatches(conf))
        ...m.group(1)!.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty),
    ];
    final mtu = int.tryParse(list('MTU').firstOrNull ?? '') ?? 1420;
    return {'addresses': list('Address'), 'dns': list('DNS'), 'routes': list('AllowedIPs'), 'mtu': mtu};
  }
}
