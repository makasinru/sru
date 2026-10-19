import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/links/deep_link.dart';
import 'app_state.dart';

/// Принимает диплинки (sru://…, vless:// и т. п.) и добавляет сервер.
/// Android присылает их через канал ru.sru/links, Windows — аргументами запуска
/// (и через [handle] из второго экземпляра приложения).
class LinkHandler {
  LinkHandler(this.state, this.messenger);

  final AppState state;
  final GlobalKey<ScaffoldMessengerState> messenger;
  static const _channel = MethodChannel('ru.sru/links');

  Future<void> init(List<String> args) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link') await handle(call.arguments as String);
    });
    for (final a in args) {
      if (DeepLink.payload(a) != null) await handle(a);
    }
    try {
      final initial = await _channel.invokeMethod<String>('initial');
      if (initial != null) await handle(initial);
    } on MissingPluginException {
      // десктоп: ссылки приходят аргументами
    }
  }

  Future<void> handle(String link) async {
    final payload = DeepLink.payload(link);
    if (payload == null) return;
    try {
      final entry = await state.addFromText(payload);
      _show('Добавлено: ${entry.name}');
    } catch (e) {
      _show('Не удалось добавить: $e');
    }
  }

  void _show(String text) {
    // Первый кадр мог ещё не отрисоваться — ждём его.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => messenger.currentState?.showSnackBar(SnackBar(content: Text(text))),
    );
    WidgetsBinding.instance.scheduleFrame();
  }
}
