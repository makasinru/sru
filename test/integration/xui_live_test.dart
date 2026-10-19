// Живой тест против настоящей панели 3x-ui и бинарника Xray.
// Запускается только при заданных переменных окружения:
//   XUI_TEST_URL=http://127.0.0.1:23456/sp XUI_TEST_TOKEN=... XRAY_BIN=/path/to/xray \
//   flutter test test/integration/xui_live_test.dart
// Создаёт inbound'ы всех протоколов, получает ссылки из подписки, для каждой
// собирает клиентский конфиг XrayConfigBuilder и делает запрос через него.
// LIVE_TARGET — адрес для проверки, LIVE_CA_FILE — доп. корневой сертификат
// (нужен в песочницах с TLS-перехватом).
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/core/models/proxy_profile.dart';
import 'package:sru/core/server/protocol_presets.dart';
import 'package:sru/core/server/xui_api.dart';
import 'package:sru/core/xray/xray_config_builder.dart';

void main() {
  final env = Platform.environment;
  final url = env['XUI_TEST_URL'];
  final token = env['XUI_TEST_TOKEN'];
  final xray = env['XRAY_BIN'];
  final target = Uri.parse(env['LIVE_TARGET'] ?? 'https://www.microsoft.com/robots.txt');
  final caFile = env['LIVE_CA_FILE'];
  final skip = (url == null || token == null || xray == null) ? 'нет XUI_TEST_URL/XUI_TEST_TOKEN/XRAY_BIN' : null;

  test(
    'все протоколы: панель → ссылки → клиентский конфиг → трафик',
    () async {
      final api = XuiApi(baseUrl: Uri.parse(url!), token: token!);
      final tmp = await Directory.systemTemp.createTemp('sru-live');
      final crt = '${tmp.path}/hy.crt', key = '${tmp.path}/hy.key';
      await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'ec',
        '-pkeyopt',
        'ec_paramgen_curve:prime256v1',
        '-nodes',
        '-days',
        '30',
        '-subj',
        '/CN=www.microsoft.com',
        '-keyout',
        key,
        '-out',
        crt,
      ]);
      final sha = (await Process.run('sh', [
        '-c',
        "openssl x509 -in $crt -outform der | sha256sum | cut -d' ' -f1",
      ])).stdout.toString().trim();

      final ctx = PresetContext(
        subId: 'live${DateTime.now().millisecondsSinceEpoch}',
        email: 'live${DateTime.now().millisecondsSinceEpoch}',
        realityKeys: await api.newX25519(),
        hysteriaCertFile: crt,
        hysteriaKeyFile: key,
        hysteriaCertSha256: sha,
      );
      final created = <int>[];
      var port = 41000 + DateTime.now().second * 10;
      try {
        for (final proto in ServerProtocol.values) {
          final res = await api.addInbound(ProtocolPresets.inbound(proto, ctx, port: port++));
          created.add(res['id'] as int);
        }
        final links = await api.subLinks(ctx.subId);
        final profiles = LinkParser.parseMany(links.join('\n'));
        expect(profiles.map((p) => p.protocol).toSet(), {
          ProxyProtocol.vless,
          ProxyProtocol.trojan,
          ProxyProtocol.shadowsocks,
          ProxyProtocol.vmess,
          ProxyProtocol.hysteria2,
        });

        await Future<void>.delayed(const Duration(seconds: 2)); // панель перезапускает Xray
        final results = <String, String>{};
        var local = 42000;
        for (final p in profiles) {
          // Сервер слушает на этой же машине, а 127.0.0.1 в ссылке нет — подставляем.
          final prof = ProxyProfile(
            protocol: p.protocol,
            host: '127.0.0.1',
            port: p.port,
            name: p.name,
            credential: p.credential,
            secondaryCredential: p.secondaryCredential,
            params: p.params,
          );
          final httpPort = local++;
          final cfg = XrayConfigBuilder.buildJson(
            prof,
            XrayOptions(tun: false, routing: RoutingPreset.global, socksPort: local++, httpPort: httpPort),
          );
          final f = File('${tmp.path}/c$httpPort.json')..writeAsStringSync(cfg);
          final proc = await Process.start(xray!, ['run', '-c', f.path]);
          final log = StringBuffer();
          proc.stdout.transform(const SystemEncoding().decoder).listen(log.write);
          proc.stderr.transform(const SystemEncoding().decoder).listen(log.write);
          await Future<void>.delayed(const Duration(milliseconds: 800));
          final sec = SecurityContext(withTrustedRoots: true);
          if (caFile != null) sec.setTrustedCertificates(caFile);
          final client = HttpClient(context: sec)
            ..findProxy = ((_) => 'PROXY 127.0.0.1:$httpPort')
            ..connectionTimeout = const Duration(seconds: 10);
          // ignore: avoid_print
          print('→ ${p.protocol.title} ${p.transportLabel} :${p.port}');
          try {
            final req = await client.getUrl(target).timeout(const Duration(seconds: 15));
            final resp = await req.close().timeout(const Duration(seconds: 15));
            results['${p.protocol.title} ${p.transportLabel}'] = 'HTTP ${resp.statusCode}';
            await resp.drain<void>().timeout(const Duration(seconds: 10));
          } catch (e) {
            results['${p.protocol.title} ${p.transportLabel}'] = 'FAIL $e\n$log';
          } finally {
            client.close(force: true);
            proc.kill();
            await proc.exitCode;
          }
        }
        // ignore: avoid_print
        results.forEach((k, v) => print('$k: $v'));
        expect(results.values.where((v) => !v.startsWith('HTTP 200')), isEmpty);
      } finally {
        for (final id in created) {
          await api.deleteInbound(id);
        }
        api.close();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
