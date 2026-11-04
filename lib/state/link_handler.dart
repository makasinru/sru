import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/links/deep_link.dart';
import '../core/links/subscription.dart';
import 'app_state.dart';

/// Принимает диплинки (sru://…, vless:// и т. п.) и добавляет сервер.
/// Android присылает их через канал ru.sru/links, Windows — аргументами запуска
/// (и через [handle] из второго экземпляра приложения).
///
/// Сервер добавляется только после подтверждения: иначе любая ссылка на сайте,
/// QR-код или другая программа могли бы незаметно подменить сервер VPN на
/// чужой и пустить через него весь трафик.
class LinkHandler {
  LinkHandler(this.state, this.messenger, this.navigator);

  final AppState state;
  final GlobalKey<ScaffoldMessengerState> messenger;
  final GlobalKey<NavigatorState> navigator;

  /// Для тестов: ответ на вопрос «добавить сервер?» без диалога.
  Future<bool> Function(String what)? confirm;
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
    if (!await _confirm(_describe(payload))) return;
    try {
      final entry = await state.addFromText(payload);
      _show('Добавлено: ${entry.name}');
    } catch (e) {
      _show('Не удалось добавить: $e');
    }
  }

  /// Что именно добавится — чтобы пользователь видел адрес, а не только «сервер».
  static String _describe(String payload) {
    final t = payload.trim();
    if (t.startsWith('http://') || t.startsWith('https://')) {
      return 'Подписка с ${Uri.tryParse(t)?.host ?? t}';
    }
    final profiles = SubscriptionParser.parseBody(t);
    if (profiles.isEmpty) return 'Ключ не распознан';
    final hosts = profiles.map((p) => p.host).toSet().join(', ');
    final names = profiles.map((p) => p.name).where((n) => n.isNotEmpty).take(3).join(', ');
    return '${profiles.length == 1 ? '1 протокол' : '${profiles.length} протоколов'} · $hosts'
        '${names.isEmpty ? '' : '\n$names'}';
  }

  Future<bool> _confirm(String what) async {
    if (confirm != null) return confirm!(what);
    // Окно могло ещё не открыться (ссылка пришла при запуске) — ждём первый кадр.
    for (var i = 0; i < 50 && navigator.currentContext == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final context = navigator.currentContext;
    if (context == null || !context.mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить сервер по ссылке?'),
        content: Text(
          '$what\n\nДобавляйте только ссылки от тех, кому доверяете: через этот сервер пойдёт весь ваш трафик.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Добавить')),
        ],
      ),
    );
    return ok ?? false;
  }

  void _show(String text) {
    // Первый кадр мог ещё не отрисоваться — ждём его.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => messenger.currentState?.showSnackBar(SnackBar(content: Text(text))),
    );
    WidgetsBinding.instance.scheduleFrame();
  }
}
