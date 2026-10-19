import 'dart:convert';

import 'link_parser.dart';

/// Диплинки, которые открывают приложение и добавляют сервер:
///
/// * `sru://add/<ключ или ссылка на подписку, URL-encoded>`;
/// * `sru://add?url=<…>` — то же самое в параметре;
/// * `sru://import/<base64url>` — несколько ключей одним QR-кодом
///   (так приложение делится сервером, см. [DeepLink.importLink]);
/// * сами ключи `vless://`, `vmess://`, `trojan://`, `ss://`, `hysteria2://`,
///   `hy2://`, `vpn://` — Android предлагает открыть их в приложении.
///
/// Возвращает текст, который понимает AppState.addFromText, или null.
class DeepLink {
  static String? payload(String link) {
    final s = link.trim();
    if (LinkParser.looksLikeLink(s)) return s;
    final uri = Uri.tryParse(s);
    if (uri == null || uri.scheme.toLowerCase() != 'sru') return null;
    final param = uri.queryParameters['url'] ?? uri.queryParameters['key'];
    final path = _afterHost(s, uri.host);
    switch (uri.host.toLowerCase()) {
      case 'add':
        final v = param ?? (path.isEmpty ? null : _decode(path));
        return (v == null || v.trim().isEmpty) ? null : v.trim();
      case 'import':
        final v = param ?? path;
        if (v.isEmpty) return null;
        try {
          return utf8.decode(decodeBase64Loose(v));
        } on FormatException {
          return null;
        }
    }
    return null;
  }

  /// Ссылку могли вставить без кодирования (с кириллицей в имени сервера).
  static String _decode(String v) {
    try {
      return Uri.decodeComponent(v);
    } on ArgumentError {
      return v;
    }
  }

  /// Вся строка после `sru://<host>/` — без разбора, чтобы не потерять `?`
  /// и `#` внутри вложенной ссылки (у share-ссылок там имя сервера).
  static String _afterHost(String s, String host) {
    final i = s.toLowerCase().indexOf('://${host.toLowerCase()}');
    if (i < 0) return '';
    var rest = s.substring(i + 3 + host.length);
    if (rest.startsWith('/')) rest = rest.substring(1);
    if (rest.startsWith('?')) return '';
    return rest;
  }

  /// Ссылка `sru://import/…` для QR-кода с несколькими ключами сервера.
  static String importLink(Iterable<String> keys) =>
      'sru://import/${base64Url.encode(utf8.encode(keys.join('\n'))).replaceAll('=', '')}';
}
