import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/state/app_state.dart';
import 'package:sru/state/server_entry.dart';

import 'auto_select_test.dart' show FakeEngine;

void main() {
  final good = ServerEntry(
    id: 'ok',
    name: 'мой сервер',
    kind: ServerKind.key,
    profiles: LinkParser.parseMany('vless://u@h:443?security=none#a'),
  ).toJson();

  test('битая запись не стирает остальные серверы', () async {
    SharedPreferences.setMockInitialValues({
      'servers': jsonEncode([
        {'id': 'bad', 'kind': 'нет-такого'},
        good,
      ]),
    });
    final state = AppState(engine: FakeEngine());
    expect(state.loaded, isFalse);
    await state.load();
    expect(state.loaded, isTrue);
    expect(state.servers.map((s) => s.id), ['ok']);
  });

  test('до загрузки ничего не сохраняется — пустой список не затирает серверы', () async {
    SharedPreferences.setMockInitialValues({
      'servers': jsonEncode([good]),
    });
    final state = AppState(engine: FakeEngine());
    state.setMode(UiMode.advanced); // вызывает сохранение до load()
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('servers')!) as List, hasLength(1));
    await state.load();
    expect(state.servers, hasLength(1));
  });
}
