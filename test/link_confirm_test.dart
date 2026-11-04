import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sru/state/app_state.dart';
import 'package:sru/state/link_handler.dart';

import 'auto_select_test.dart' show FakeEngine;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(AppState, LinkHandler, List<String>)> setup(bool answer) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(engine: FakeEngine());
    await state.load();
    final asked = <String>[];
    final links = LinkHandler(state, GlobalKey(), GlobalKey())
      ..confirm = (what) async {
        asked.add(what);
        return answer;
      };
    return (state, links, asked);
  }

  test('ссылка с сайта не подменяет сервер без подтверждения', () async {
    final (state, links, asked) = await setup(false);
    await links.handle('sru://add/${Uri.encodeComponent('vless://u@evil.example:443?security=none#free')}');
    expect(state.servers, isEmpty);
    expect(asked.single, contains('evil.example'));
  });

  test('после подтверждения сервер добавляется', () async {
    final (state, links, _) = await setup(true);
    await links.handle('vless://u@h:443?security=none#мой');
    expect(state.servers.single.profiles.single.name, 'мой');
  });
}
