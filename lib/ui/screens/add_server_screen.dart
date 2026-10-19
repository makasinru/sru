import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../theme.dart';
import 'own_server_screen.dart';

/// Аналог PageSetupWizardStart / PageSetupWizardConfigSource в Amnezia:
/// «у меня есть ключ» или «настроить свой сервер».
class AddServerScreen extends StatelessWidget {
  const AddServerScreen({super.key, this.isOnboarding = false});
  final bool isOnboarding;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: isOnboarding ? null : AppBar(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (isOnboarding) const SizedBox(height: 48),
            Text(
              isOnboarding ? 'SRU VPN' : 'Новое подключение',
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Подключитесь по ключу, который вам дали, или настройте собственный сервер — '
              'приложение само всё установит.',
              style: TextStyle(color: SruColors.textTertiary, fontSize: 16),
            ),
            const SizedBox(height: 32),
            _Option(
              icon: Icons.key,
              title: 'У меня есть ключ',
              subtitle: 'vless://, vmess://, trojan://, ss://, hy2://, wireguard:// или ссылка на подписку',
              onTap: () => _enterKey(context),
            ),
            const SizedBox(height: 12),
            _Option(
              icon: Icons.content_paste,
              title: 'Вставить из буфера',
              subtitle: 'Если вы уже скопировали ключ',
              onTap: () => _fromClipboard(context),
            ),
            const SizedBox(height: 12),
            _Option(
              icon: Icons.dns,
              title: 'Настроить свой сервер',
              subtitle: 'Нужен VPS с Linux: IP-адрес, логин и пароль. Установим 3x-ui и протоколы автоматически',
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const OwnServerScreen())),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _fromClipboard(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!context.mounted) return;
    final text = data?.text ?? '';
    if (!AppState.isKeyText(text)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('В буфере нет ключа')));
      return;
    }
    await _import(context, text);
  }

  Future<void> _enterKey(BuildContext context) async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SruColors.bgSurface,
        title: const Text('Ключ подключения'),
        content: TextField(
          controller: ctrl,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(hintText: 'Вставьте ключ или ссылку'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Добавить')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty || !context.mounted) return;
    await _import(context, text);
  }

  Future<void> _import(BuildContext context, String text) async {
    final state = context.read<AppState>();
    try {
      final entry = await state.addFromText(text);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Добавлено: ${entry.name} (${entry.profiles.length})')));
      if (!isOnboarding) Navigator.pop(context);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        leading: Icon(icon, color: SruColors.accent),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        subtitle: Padding(padding: const EdgeInsets.only(top: 4), child: Text(subtitle)),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
