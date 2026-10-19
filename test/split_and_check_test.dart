import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/core/vpn/connectivity_check.dart';
import 'package:sru/core/vpn/vpn_engine.dart';
import 'package:sru/core/xray/split_tunnel.dart';
import 'package:sru/core/xray/xray_config_builder.dart';

void main() {
  group('Список сайтов', () {
    test('домены, адреса, подсети и категории', () {
      final r = SiteRules.parse([
        'https://www.YouTube.com/watch?v=1',
        'discord.gg',
        '1.2.3.4',
        '10.0.0.0/8',
        '2001:db8::/32',
        'geosite:openai',
        'geoip:telegram',
        'full:api.example.com',
        '  ',
      ]);
      expect(r.domains, ['domain:youtube.com', 'domain:discord.gg', 'geosite:openai', 'full:api.example.com']);
      expect(r.ips, ['1.2.3.4', '10.0.0.0/8', '2001:db8::/32', 'geoip:telegram']);
    });
  });

  group('Маршрутизация', () {
    final p = LinkParser.parse('vless://u@h:443?security=reality&pbk=k#a');
    List rules(XrayOptions o) => (XrayConfigBuilder.build(p, o)['routing'] as Map)['rules'] as List;

    test('«все, кроме этих» — список напрямую, обход РФ остаётся', () {
      final r = rules(const XrayOptions(siteSplit: SplitMode.exceptListed, splitSites: ['youtube.com', '1.1.1.1']));
      expect(
        r,
        contains(
          predicate((Map m) => m['outboundTag'] == 'direct' && (m['domain'] as List?)?.first == 'domain:youtube.com'),
        ),
      );
      expect(r, contains(predicate((Map m) => m['outboundTag'] == 'direct' && (m['ip'] as List?)?.first == '1.1.1.1')));
      expect(jsonEncode(r), contains('geoip:ru'));
    });

    test('«только эти через VPN» — список в прокси, остальное напрямую', () {
      final r = rules(const XrayOptions(siteSplit: SplitMode.onlyListed, splitSites: ['geosite:youtube']));
      final i = r.indexWhere((m) => m['outboundTag'] == 'proxy');
      expect(i, greaterThan(0));
      expect(r.last, {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'direct'});
      expect(jsonEncode(r), isNot(contains('geoip:ru')));
    });

    test('пустой список «только эти» не отключает VPN целиком', () {
      final r = rules(const XrayOptions(siteSplit: SplitMode.onlyListed));
      expect(r.any((m) => m['network'] == 'tcp,udp'), isFalse);
    });

    test('пароль на локальных прокси', () {
      final cfg = XrayConfigBuilder.build(p, const XrayOptions(proxyUser: 'sru', proxyPassword: 'x'));
      final inb = (cfg['inbounds'] as List).cast<Map>();
      expect(inb[0]['settings']['auth'], 'password');
      expect(inb[1]['settings']['accounts'][0], {'user': 'sru', 'pass': 'x'});
    });
  });

  // С настоящим ядром: SRU_CORE_BIN=/path/to/sru-core
  final core = Platform.environment['SRU_CORE_BIN'];
  test('проверка подключения через ядро с паролем на прокси', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(
      (r) => r.response
        ..statusCode = 204
        ..close(),
    );
    final engine = DesktopXrayEngine(corePath: core)..useSystemProxy = false;
    await engine.start(
      jsonEncode({
        'inbounds': [
          {
            'tag': 'http',
            'listen': '127.0.0.1',
            'port': 47810,
            'protocol': 'http',
            'settings': {
              'accounts': [
                {'user': 'sru', 'pass': 'secret'},
              ],
            },
          },
        ],
        'outbounds': [
          {'protocol': 'freedom'},
        ],
      }),
      sessionName: 't',
    );
    expect(engine.current, VpnStatus.connected, reason: engine.lastError);
    final target = CheckTarget('local', 'http://127.0.0.1:${server.port}/');
    final ok = await ConnectivityChecker(proxyPort: 47810, proxyUser: 'sru', proxyPassword: 'secret').check(target);
    expect(ok.ok, isTrue, reason: ok.error);
    final denied = await ConnectivityChecker(proxyPort: 47810, proxyUser: 'sru', proxyPassword: 'bad').check(target);
    // Неверный пароль: прокси отвечает 407 — это не «сайт открылся».
    expect(denied.ok, isFalse);
    expect(denied.error, contains('пароль'));
    await engine.stop();
    await server.close(force: true);
  }, skip: core == null ? 'нет SRU_CORE_BIN' : null);
}
