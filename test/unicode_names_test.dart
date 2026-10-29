import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sru/core/links/link_parser.dart';
import 'package:sru/core/xray/xray_config_builder.dart';
import 'package:sru/state/app_state.dart';

import 'auto_select_test.dart' show FakeEngine;

void main() {
  const names = ["O'Brien 🇩🇪 сервер", 'שרת בגרמניה', '🚀🔥', "d'Artagnan \"quoted\" \\ back"];

  for (final name in names) {
    test('название «$name» переживает ссылку, конфиг и сохранение', () async {
      final link = 'vless://u@h:443?security=none#${Uri.encodeComponent(name)}';
      final p = LinkParser.parse(link);
      expect(p.name, name);
      expect(() => XrayConfigBuilder.buildJson(p), returnsNormally);

      SharedPreferences.setMockInitialValues({});
      final state = AppState(engine: FakeEngine());
      await state.load();
      final s = await state.addFromText(link);
      state.renameServer(s, name);
      final again = AppState(engine: FakeEngine());
      await again.load();
      expect(again.servers.single.name, name);
      expect(again.servers.single.profiles.single.name, name);
    });
  }
}
