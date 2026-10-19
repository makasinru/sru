import 'dart:convert';

import 'package:http/http.dart' as http;

class XuiApiException implements Exception {
  XuiApiException(this.message);
  final String message;
  @override
  String toString() => '3x-ui: $message';
}

/// Клиент REST API панели 3x-ui (/panel/api/*), авторизация Bearer-токеном,
/// который установщик пишет в /etc/x-ui/install-result.env.
class XuiApi {
  XuiApi({required this.baseUrl, required this.token, http.Client? client}) : _client = client ?? http.Client();

  /// Например http://127.0.0.1:54321/AbCdEf (порт — локальный конец SSH-туннеля).
  final Uri baseUrl;
  final String token;
  final http.Client _client;

  Uri _u(String path) {
    final base = baseUrl.path.endsWith('/') ? baseUrl.path : '${baseUrl.path}/';
    return baseUrl.replace(path: '${base}panel/api/$path');
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };

  Future<dynamic> _unwrap(Future<http.Response> req) async {
    final resp = await req.timeout(const Duration(seconds: 30));
    Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw XuiApiException('HTTP ${resp.statusCode}: неожиданный ответ');
    }
    if (body['success'] != true) {
      throw XuiApiException((body['msg'] as String?) ?? 'HTTP ${resp.statusCode}');
    }
    return body['obj'];
  }

  Future<dynamic> get(String path) => _unwrap(_client.get(_u(path), headers: _headers));

  Future<dynamic> post(String path, [Object? body]) =>
      _unwrap(_client.post(_u(path), headers: _headers, body: body == null ? null : jsonEncode(body)));

  Future<String> xrayVersion() async => (await get('server/getXrayVersion')).toString();

  Future<({String privateKey, String publicKey})> newX25519() async {
    final obj = await get('server/getNewX25519Cert') as Map<String, dynamic>;
    return (privateKey: obj['privateKey'] as String, publicKey: obj['publicKey'] as String);
  }

  Future<List<Map<String, dynamic>>> listInbounds() async {
    final obj = await get('inbounds/list');
    return (obj as List? ?? []).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> addInbound(Map<String, dynamic> inbound) async {
    final obj = await post('inbounds/add', inbound);
    return (obj as Map<String, dynamic>?) ?? {};
  }

  Future<void> deleteInbound(int id) async => post('inbounds/del/$id');

  /// Все ссылки клиента — тот же набор, что отдаёт подписка 3x-ui.
  Future<List<String>> subLinks(String subId) async {
    final obj = await get('clients/subLinks/$subId');
    return (obj as List? ?? []).cast<String>();
  }

  Future<Map<String, dynamic>> settings() async => (await post('setting/all') as Map<String, dynamic>?) ?? {};

  void close() => _client.close();
}
