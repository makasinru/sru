import 'remote_shell.dart';
import 'xui_api.dart';
import 'xui_installer.dart';

/// Подключение к своему серверу для управления: SSH (с проверкой ключа хоста,
/// сохранённого при установке) → туннель к панели на 127.0.0.1 → API.
class ServerSession {
  ServerSession._(this._shell, this.api);

  final RemoteShell _shell;
  final XuiApi api;

  static Future<ServerSession> open(SshCredentials ssh, PanelInfo panel, {String? hostKey}) async {
    final (shell, _) = await DartSshShell.connect(ssh, expectedHostKey: hostKey);
    try {
      final port = await shell.forwardToLocal('127.0.0.1', panel.port);
      final api = XuiApi(baseUrl: Uri.parse('http://127.0.0.1:$port/${panel.webBasePath}'), token: panel.apiToken);
      return ServerSession._(shell, api);
    } catch (_) {
      await shell.close();
      rethrow;
    }
  }

  Future<void> close() async {
    api.close();
    await _shell.close();
  }
}
