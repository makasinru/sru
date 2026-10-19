import '../core/links/subscription.dart';
import '../core/models/proxy_profile.dart';
import '../core/server/remote_shell.dart';
import '../core/server/xui_installer.dart';

enum ServerKind {
  /// Сервер, который приложение само настроило по SSH (3x-ui).
  own,

  /// Добавлен по ключу/ссылке.
  key,

  /// Добавлен по ссылке подписки — обновляется автоматически.
  subscription,
}

class ServerEntry {
  ServerEntry({
    required this.id,
    required this.name,
    required this.kind,
    required this.profiles,
    this.selectedProfile,
    this.subscriptionUrl,
    this.subscriptionInfo,
    this.ssh,
    this.hostKey,
    this.panel,
    this.subId,
  });

  final String id;
  String name;
  final ServerKind kind;
  List<ProxyProfile> profiles;

  /// Профиль, который в прошлый раз оказался самым быстрым из рабочих:
  /// в режиме «Автоматически» пробуется первым.
  int? lastGoodProfile;

  /// null — «Автоматически»: перебор профилей по порядку (простой режим).
  int? selectedProfile;

  String? subscriptionUrl;
  SubscriptionInfo? subscriptionInfo;

  /// Секреты (SSH, панель) хранятся в защищённом хранилище, здесь — только в памяти.
  SshCredentials? ssh;
  String? hostKey;
  PanelInfo? panel;
  String? subId;

  String get subtitle {
    if (profiles.isEmpty) return 'Нет протоколов';
    if (selectedProfile == null) {
      return profiles.length == 1 ? profiles.first.protocol.title : 'Автоматически · ${profiles.length} протокола';
    }
    final p = profiles[selectedProfile!.clamp(0, profiles.length - 1)];
    return '${p.protocol.title} · ${p.transportLabel}';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'profiles': profiles.map((p) => p.toJson()).toList(),
    'selectedProfile': selectedProfile,
    'lastGoodProfile': lastGoodProfile,
    'subscriptionUrl': subscriptionUrl,
    'hostKey': hostKey,
    'subId': subId,
  };

  factory ServerEntry.fromJson(Map<String, dynamic> j) => ServerEntry(
    id: j['id'] as String,
    name: j['name'] as String,
    kind: ServerKind.values.byName(j['kind'] as String),
    profiles: (j['profiles'] as List).map((e) => ProxyProfile.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
    selectedProfile: j['selectedProfile'] as int?,
    subscriptionUrl: j['subscriptionUrl'] as String?,
    hostKey: j['hostKey'] as String?,
    subId: j['subId'] as String?,
  )..lastGoodProfile = j['lastGoodProfile'] as int?;
}
