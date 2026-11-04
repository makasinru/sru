import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sru/app_version.dart';

void main() {
  test('версия в приложении совпадает с pubspec.yaml', () {
    final m = RegExp(r'^version:\s*([0-9.]+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync());
    expect(appVersion, m!.group(1));
  });
}
