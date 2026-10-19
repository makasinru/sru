import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../xray/split_tunnel.dart';
import 'windows_proxy.dart';

enum VpnStatus { disconnected, connecting, connected, disconnecting, error }

class InstalledApp {
  InstalledApp(this.packageName, this.label, [this.icon]);
  final String packageName;
  final String label;

  /// PNG 96×96.
  final Uint8List? icon;
}

/// Абстракция над ядром. На Android/iOS это нативный VpnService/NetworkExtension
/// с libXray (так устроен Happ: libgojni.so = Xray-core через gomobile,
/// TUN — встроенный tun-inbound Xray). На десктопе — процесс sru-core в режиме прокси.
abstract class VpnEngine {
  Stream<VpnStatus> get status;
  VpnStatus get current;
  String? get lastError;

  /// [appSplit]/[apps] — раздельное туннелирование приложений (только Android).
  Future<void> start(
    String xrayConfigJson, {
    required String sessionName,
    SplitMode appSplit = SplitMode.off,
    List<String> apps = const [],
    Map<String, Object>? tun,
  });
  Future<void> stop();

  /// Установленные приложения для экрана раздельного туннелирования (Android).
  Future<List<InstalledApp>> installedApps() async => const [];

  /// Версия ядра (для экрана «О приложении» в продвинутом режиме).
  Future<String?> coreVersion();

  static VpnEngine platformDefault() {
    if (Platform.isAndroid || Platform.isIOS) return MethodChannelVpnEngine();
    return DesktopXrayEngine();
  }
}

abstract class _BaseEngine implements VpnEngine {
  final _controller = StreamController<VpnStatus>.broadcast();
  VpnStatus _current = VpnStatus.disconnected;
  String? _lastError;

  @override
  Stream<VpnStatus> get status => _controller.stream;
  @override
  VpnStatus get current => _current;
  @override
  String? get lastError => _lastError;

  @override
  Future<List<InstalledApp>> installedApps() async => const [];

  void emit(VpnStatus s, [String? error]) {
    _current = s;
    _lastError = error;
    _controller.add(s);
  }
}

/// Контракт с нативной частью (android/…/VpnPlugin.kt, ios/PacketTunnel):
///   start({config: String, name: String}) — поднять TUN и запустить Xray;
///   stop(); coreVersion() -> String;
///   события через EventChannel 'ru.sru/vpn/status': "connecting" | "connected" |
///   "disconnected" | "error:<текст>".
class MethodChannelVpnEngine extends _BaseEngine {
  MethodChannelVpnEngine() {
    _events.receiveBroadcastStream().listen((e) {
      final s = e.toString();
      if (s.startsWith('error:')) {
        emit(VpnStatus.error, s.substring(6));
      } else {
        emit(VpnStatus.values.firstWhere((v) => v.name == s, orElse: () => VpnStatus.error));
      }
    }, onError: (Object e) => emit(VpnStatus.error, e.toString()));
  }

  static const _method = MethodChannel('ru.sru/vpn');
  static const _events = EventChannel('ru.sru/vpn/status');

  @override
  Future<void> start(
    String xrayConfigJson, {
    required String sessionName,
    SplitMode appSplit = SplitMode.off,
    List<String> apps = const [],
    Map<String, Object>? tun,
  }) async {
    emit(VpnStatus.connecting);
    try {
      // Нативная сторона отвечает, только когда ядро подключилось или упало.
      await _method.invokeMethod('start', {
        'config': xrayConfigJson,
        'name': sessionName,
        'appMode': appSplit.name,
        'apps': apps,
        // AmneziaWG: адреса, DNS, MTU и маршруты интерфейса из .conf.
        'tun': ?tun,
      });
      emit(VpnStatus.connected);
    } on PlatformException catch (e) {
      emit(VpnStatus.error, e.message);
    } on MissingPluginException {
      emit(VpnStatus.error, 'Нативный модуль VPN не собран для этой платформы');
    }
  }

  @override
  Future<void> stop() async {
    emit(VpnStatus.disconnecting);
    try {
      await _method.invokeMethod('stop');
    } on MissingPluginException {
      // нечего останавливать
    }
    emit(VpnStatus.disconnected);
  }

  @override
  Future<List<InstalledApp>> installedApps() async {
    try {
      final list = await _method.invokeListMethod<Map<Object?, Object?>>('installedApps') ?? [];
      return [
        for (final m in list) InstalledApp(m['package'] as String, m['label'] as String, m['icon'] as Uint8List?),
      ];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<String?> coreVersion() async {
    try {
      return await _method.invokeMethod<String>('coreVersion');
    } on MissingPluginException {
      return null;
    }
  }
}

/// Десктоп (Windows 10/11, Linux): запускает ядро sru-core (Xray-core, см.
/// core/main.go) в режиме локального прокси — SOCKS 10808 / HTTP 10809 — и
/// на Windows включает системный прокси, чтобы браузеры и программы шли через VPN.
/// Ядро завершается само, когда закрывается его stdin, то есть вместе с приложением.
class DesktopXrayEngine extends _BaseEngine {
  DesktopXrayEngine({this.corePath, WindowsSystemProxy? proxy})
    : _proxy = proxy ?? (Platform.isWindows ? WindowsSystemProxy() : null) {
    // Прошлый запуск завершился аварийно — вернуть пользователю интернет.
    try {
      _proxy?.restoreIfStale();
    } catch (_) {}
  }

  String? corePath;

  /// Включать ли системный прокси Windows при подключении.
  bool useSystemProxy = true;

  final WindowsSystemProxy? _proxy;
  Process? _process;
  bool _proxyEnabled = false;

  static String get _appDir => File(Platform.resolvedExecutable).parent.path;

  String _resolveCore() {
    if (corePath != null) return corePath!;
    final exe = Platform.isWindows ? 'sru-core.exe' : 'sru-core';
    final besideApp = File('$_appDir${Platform.pathSeparator}$exe');
    return besideApp.existsSync() ? besideApp.path : exe;
  }

  @override
  Future<void> start(
    String xrayConfigJson, {
    required String sessionName,
    SplitMode appSplit = SplitMode.off, // на десктопе не поддерживается
    List<String> apps = const [],
    Map<String, Object>? tun, // на Windows адреса AmneziaWG настраивает ядро
  }) async {
    emit(VpnStatus.connecting);
    final dir = await Directory.systemTemp.createTemp('sru');
    final cfg = File('${dir.path}${Platform.pathSeparator}config.json')..writeAsStringSync(xrayConfigJson);
    final geo = '$_appDir${Platform.pathSeparator}geo';
    try {
      final p = await Process.start(_resolveCore(), ['desktop', cfg.path, geo]);
      _process = p;
      final started = Completer<bool>();
      final errors = <String>[];
      p.stdout.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((l) {
        if (!started.isCompleted && l.trim() == 'started') started.complete(true);
      });
      p.stderr.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((l) {
        errors.add(l);
        if (errors.length > 5) errors.removeAt(0);
      });
      unawaited(
        p.exitCode.then((code) async {
          if (!started.isCompleted) started.complete(false);
          if (_process == p) {
            _process = null;
            _disableProxy();
            emit(VpnStatus.error, 'Ядро остановилось: ${errors.isEmpty ? 'код $code' : errors.last}');
          }
        }),
      );
      final ok = await started.future.timeout(const Duration(seconds: 15), onTimeout: () => false);
      if (!ok) {
        await stop();
        emit(VpnStatus.error, errors.isEmpty ? 'Ядро не запустилось' : errors.last);
        return;
      }
      if (useSystemProxy && _proxy != null) {
        final port = _httpPort(xrayConfigJson);
        if (port != null) {
          _proxy.enable('127.0.0.1:$port');
          _proxyEnabled = true;
        }
      }
      emit(VpnStatus.connected);
    } on ProcessException catch (e) {
      emit(VpnStatus.error, 'Не найдено ядро sru-core: ${e.message}');
    }
  }

  static int? _httpPort(String configJson) {
    if (!configJson.trimLeft().startsWith('{')) return null; // .conf AmneziaWG
    final inbounds = (jsonDecode(configJson) as Map<String, dynamic>)['inbounds'] as List? ?? [];
    for (final i in inbounds.cast<Map<String, dynamic>>()) {
      if (i['protocol'] == 'http') return i['port'] as int?;
    }
    return null;
  }

  void _disableProxy() {
    if (!_proxyEnabled) return;
    _proxyEnabled = false;
    try {
      _proxy?.disable();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    emit(VpnStatus.disconnecting);
    _disableProxy();
    final p = _process;
    _process = null;
    if (p != null) {
      await p.stdin.close(); // ядро видит закрытый stdin и выходит
      await p.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          p.kill();
          return -1;
        },
      );
    }
    emit(VpnStatus.disconnected);
  }

  @override
  Future<String?> coreVersion() async {
    try {
      final r = await Process.run(_resolveCore(), ['version']);
      return (r.stdout as String).split('\n').first.trim();
    } on ProcessException {
      return null;
    }
  }
}
