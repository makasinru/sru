import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/proxy_profile.dart';
import 'link_parser.dart';

/// Данные из заголовков подписки (стандарт, который используют 3x-ui,
/// Marzban, Remnawave и понимает Happ).
class SubscriptionInfo {
  SubscriptionInfo({
    this.title,
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire,
    this.updateIntervalHours,
    this.supportUrl,
    this.announce,
  });

  final String? title;
  final int upload;
  final int download;

  /// 0 — без ограничения.
  final int total;
  final DateTime? expire;
  final int? updateIntervalHours;
  final String? supportUrl;
  final String? announce;

  int get used => upload + download;

  static SubscriptionInfo fromHeaders(Map<String, String> headers) {
    String? h(String name) => headers[name] ?? headers[name.toLowerCase()];
    final userinfo = <String, int>{};
    for (final part in (h('subscription-userinfo') ?? '').split(';')) {
      final kv = part.split('=');
      if (kv.length == 2) {
        userinfo[kv[0].trim()] = int.tryParse(kv[1].trim()) ?? 0;
      }
    }
    final expire = userinfo['expire'] ?? 0;
    return SubscriptionInfo(
      title: _maybeBase64(h('profile-title')),
      upload: userinfo['upload'] ?? 0,
      download: userinfo['download'] ?? 0,
      total: userinfo['total'] ?? 0,
      expire: expire > 0 ? DateTime.fromMillisecondsSinceEpoch(expire * 1000, isUtc: true) : null,
      updateIntervalHours: int.tryParse(h('profile-update-interval') ?? ''),
      supportUrl: h('support-url'),
      announce: _maybeBase64(h('announce')),
    );
  }

  /// Значения вида "base64:...." — так 3x-ui и Happ передают кириллицу.
  static String? _maybeBase64(String? v) {
    if (v == null || v.isEmpty) return null;
    if (v.startsWith('base64:')) {
      try {
        return utf8.decode(decodeBase64Loose(v.substring(7)));
      } catch (_) {
        return v;
      }
    }
    return v;
  }
}

class SubscriptionResult {
  SubscriptionResult(this.profiles, this.info);
  final List<ProxyProfile> profiles;
  final SubscriptionInfo info;
}

class SubscriptionParser {
  /// Тело подписки — либо base64 от списка ссылок, либо список ссылок как есть.
  static List<ProxyProfile> parseBody(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return [];
    if (LinkParser.looksLikeLink(trimmed.split('\n').first.trim())) {
      return LinkParser.parseMany(trimmed);
    }
    try {
      return LinkParser.parseMany(utf8.decode(decodeBase64Loose(trimmed)));
    } on FormatException {
      return [];
    }
  }

  static Future<SubscriptionResult> fetch(Uri url, {http.Client? client, String? hwid}) async {
    final c = client ?? http.Client();
    try {
      final resp = await c
          .get(url, headers: {'User-Agent': 'SRU/1.0', if (hwid != null) 'x-hwid': hwid})
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw http.ClientException('HTTP ${resp.statusCode}', url);
      }
      return SubscriptionResult(parseBody(utf8.decode(resp.bodyBytes)), SubscriptionInfo.fromHeaders(resp.headers));
    } finally {
      if (client == null) c.close();
    }
  }
}
