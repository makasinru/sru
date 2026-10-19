import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/server/protocol_presets.dart';
import '../../core/server/remote_shell.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'installing_screen.dart';

/// Аналог PageSetupWizardCredentials + PageSetupWizardEasy/Protocols в Amnezia.
class OwnServerScreen extends StatefulWidget {
  const OwnServerScreen({super.key});

  @override
  State<OwnServerScreen> createState() => _OwnServerScreenState();
}

class _OwnServerScreenState extends State<OwnServerScreen> {
  final _form = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'root');
  final _secret = TextEditingController();
  final _realityTarget = TextEditingController(text: 'www.microsoft.com');
  final _panelVersion = TextEditingController();
  bool _useKey = false;
  bool _auto = true;
  final Set<ServerProtocol> _selected = {...casualProtocols};
  final Map<ServerProtocol, TextEditingController> _ports = {
    for (final p in ServerProtocol.values) p: TextEditingController(text: '${p.defaultPort}'),
  };

  @override
  Widget build(BuildContext context) {
    final advanced = context.watch<AppState>().advanced;
    return Scaffold(
      appBar: AppBar(title: const Text('Свой сервер')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Данные для входа на сервер обычно приходят от хостинга в письме после покупки VPS.',
                style: TextStyle(color: SruColors.textTertiary),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _host,
                decoration: const InputDecoration(labelText: 'IP-адрес сервера'),
                keyboardType: TextInputType.url,
                validator: (v) => (v ?? '').trim().isEmpty ? 'Укажите адрес' : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _user,
                      decoration: const InputDecoration(labelText: 'Логин'),
                    ),
                  ),
                  if (advanced) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _port,
                        decoration: const InputDecoration(labelText: 'SSH порт'),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              if (advanced)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _useKey,
                  onChanged: (v) => setState(() => _useKey = v),
                  title: const Text('Вход по SSH-ключу'),
                ),
              TextFormField(
                controller: _secret,
                obscureText: !_useKey,
                minLines: _useKey ? 4 : 1,
                maxLines: _useKey ? 10 : 1,
                decoration: InputDecoration(labelText: _useKey ? 'Приватный ключ (PEM)' : 'Пароль'),
                validator: (v) => (v ?? '').isEmpty ? 'Обязательное поле' : null,
              ),
              const SizedBox(height: 24),
              const Text('Что установить', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              RadioGroup<bool>(
                groupValue: _auto,
                onChanged: (v) => setState(() => _auto = v!),
                child: Column(
                  children: [
                    const RadioListTile<bool>(
                      contentPadding: EdgeInsets.zero,
                      value: true,
                      title: Text('Автоматически'),
                      subtitle: Text(
                        'VLESS Reality + запасной XHTTP + Hysteria2. Приложение само выберет то, что работает в вашей сети.',
                      ),
                    ),
                    if (advanced)
                      const RadioListTile<bool>(
                        contentPadding: EdgeInsets.zero,
                        value: false,
                        title: Text('Выбрать протоколы вручную'),
                      ),
                  ],
                ),
              ),
              if (advanced && !_auto) ..._manualOptions(),
              const SizedBox(height: 24),
              FilledButton(onPressed: _start, child: const Text('Установить')),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _manualOptions() => [
    for (final p in ServerProtocol.values)
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: _selected.contains(p),
        onChanged: (v) => setState(() => v! ? _selected.add(p) : _selected.remove(p)),
        title: Text(p.title),
        subtitle: Text(p.description),
        secondary: SizedBox(
          width: 72,
          child: TextField(
            controller: _ports[p],
            keyboardType: TextInputType.number,
            decoration: InputDecoration(isDense: true, labelText: p.isUdp ? 'UDP' : 'TCP'),
          ),
        ),
      ),
    const SizedBox(height: 12),
    TextField(
      controller: _realityTarget,
      decoration: const InputDecoration(
        labelText: 'Сайт для маскировки Reality',
        helperText: 'Должен поддерживать TLS 1.3 и HTTP/2, лучше — с серверами рядом с вашим VPS',
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _panelVersion,
      decoration: const InputDecoration(labelText: 'Версия 3x-ui (пусто — последняя)'),
    ),
  ];

  void _start() {
    if (!_form.currentState!.validate()) return;
    final protocols = _auto ? casualProtocols : ServerProtocol.values.where(_selected.contains).toList();
    if (protocols.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Выберите хотя бы один протокол')));
      return;
    }
    final creds = SshCredentials(
      host: _host.text.trim(),
      port: int.tryParse(_port.text) ?? 22,
      username: _user.text.trim(),
      password: _useKey ? null : _secret.text,
      privateKeyPem: _useKey ? _secret.text : null,
    );
    Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(
        builder: (_) => InstallingScreen(
          credentials: creds,
          protocols: protocols,
          ports: {for (final p in protocols) p: int.tryParse(_ports[p]!.text) ?? p.defaultPort},
          realityTarget: _realityTarget.text.trim().isEmpty ? 'www.microsoft.com' : _realityTarget.text.trim(),
          panelVersion: _panelVersion.text.trim().isEmpty ? null : _panelVersion.text.trim(),
        ),
      ),
    );
  }
}
