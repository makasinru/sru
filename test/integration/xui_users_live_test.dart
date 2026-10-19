// Живой тест управления пользователями на настоящей панели 3x-ui:
//   XUI_TEST_URL=http://127.0.0.1:<порт>/<путь> XUI_TEST_TOKEN=... flutter test test/integration/xui_users_live_test.dart
// На панели должен быть хотя бы один inbound (например, после xui_live_test).
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/core/server/server_users.dart';
import 'package:sru/core/server/xui_api.dart';

void main() {
  final url = Platform.environment['XUI_TEST_URL'];
  final token = Platform.environment['XUI_TEST_TOKEN'];

  test('пользователи: создать, лимиты, отключить, сбросить, удалить', () async {
    final api = XuiApi(baseUrl: Uri.parse(url!), token: token!);
    final users = ServerUsers(api);
    final inbounds = await api.listInbounds();
    expect(inbounds, isNotEmpty, reason: 'на панели нет inbound-ов');

    final (user, links) = await users.create('Мама', limitGb: 50, days: 30);
    try {
      expect(user.name, 'Мама');
      expect(user.limitBytes, 50 << 30);
      expect(user.expiry!.difference(DateTime.now()).inDays, inInclusiveRange(29, 30));
      final profiles = LinkParser.parseMany(links.join('\n'));
      expect(profiles, isNotEmpty);
      // flow Vision панель оставила только там, где он возможен (TCP + Reality).
      for (final p in profiles) {
        if (p.params['flow'] == 'xtls-rprx-vision') expect(p.network, anyOf('tcp', 'raw'));
      }

      await users.setLimits(user, limitGb: 0, days: 0);
      var fresh = (await users.list()).firstWhere((u) => u.subId == user.subId);
      expect(fresh.limitBytes, 0);
      expect(fresh.expiry, isNull);
      expect(fresh.name, 'Мама', reason: 'обновление не должно терять поля');

      await users.setEnabled(fresh, false);
      fresh = (await users.list()).firstWhere((u) => u.subId == user.subId);
      expect(fresh.enabled, isFalse);

      await users.resetTraffic(fresh);
      expect(await api.onlineClients(), isA<Set<String>>());
    } finally {
      final current = (await users.list()).where((u) => u.subId == user.subId);
      for (final u in current) {
        await users.delete(u);
      }
      expect((await users.list()).any((u) => u.subId == user.subId), isFalse);
      api.close();
    }
  }, skip: url == null || token == null ? 'нет XUI_TEST_URL/XUI_TEST_TOKEN' : null);
}
