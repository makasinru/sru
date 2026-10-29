import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/state/app_state.dart';
import 'package:sru/state/server_entry.dart';
import 'package:sru/state/settings_file.dart';

import 'dart:io';

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

  test('Android: серверы сохраняются в свой файл и читаются из него без SharedPreferences', () async {
    final dir = await Directory.systemTemp.createTemp('sru_settings');
    final file = SettingsFile('${dir.path}/settings.json');
    SharedPreferences.setMockInitialValues({});
    final a = AppState(engine: FakeEngine(), settingsFile: Future.value(file));
    await a.load();
    await a.addFromText('vless://u@h:443?security=none#мой');
    expect(await File(file.path).exists(), isTrue);

    // Новый запуск: SharedPreferences пусты (плагин потерял данные), файл на месте.
    SharedPreferences.setMockInitialValues({});
    final b = AppState(engine: FakeEngine(), settingsFile: Future.value(file));
    await b.load();
    expect(b.servers.single.profiles.single.name, 'мой');
    expect(b.storageError, isNull);
    await dir.delete(recursive: true);
  });

  test('переход со старой версии: серверы берутся из SharedPreferences', () async {
    final dir = await Directory.systemTemp.createTemp('sru_settings');
    SharedPreferences.setMockInitialValues({
      'servers': jsonEncode([good]),
      'mode': 'advanced',
    });
    final state = AppState(engine: FakeEngine(), settingsFile: Future.value(SettingsFile('${dir.path}/s.json')));
    await state.load();
    expect(state.servers.single.id, 'ok');
    expect(state.mode, UiMode.advanced);
    await dir.delete(recursive: true);
  });
}
