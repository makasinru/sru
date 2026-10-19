import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

enum VpnStatus { disconnected, connecting, connected, disconnecting, error }

/// Абстракция над ядром. На Android/iOS это нативный VpnService/NetworkExtension
/// с libXray (так устроен Happ: libgojni.so = Xray-core через gomobile,
/// TUN — встроенный tun-inbound Xray). На десктопе — процесс xray в режиме прокси.
abstract class VpnEngine {
  Stream<VpnStatus> get status;
  VpnStatus get current;
  String? get lastError;

  Future<void> start(String xrayConfigJson, {required String sessionName});
  Future<void> stop();

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
  Future<void> start(String xrayConfigJson, {required String sessionName}) async {
    emit(VpnStatus.connecting);
    try {
      // Нативная сторона отвечает, только когда ядро подключилось или упало.
      await _method.invokeMethod('start', {'config': xrayConfigJson, 'name': sessionName});
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
  Future<String?> coreVersion() async {
    try {
      return await _method.invokeMethod<String>('coreVersion');
    } on MissingPluginException {
      return null;
    }
  }
}

/// Десктоп: запускает бинарник xray (кладётся рядом с приложением или
/// указывается в настройках) с конфигом в режиме локального прокси
/// (SOCKS 10808 / HTTP 10809). TUN на десктопе требует прав администратора.
class DesktopXrayEngine extends _BaseEngine {
  DesktopXrayEngine({this.xrayPath});

  String? xrayPath;
  Process? _process;

  String _resolveBinary() {
    if (xrayPath != null) return xrayPath!;
    final exe = Platform.isWindows ? 'xray.exe' : 'xray';
    final besideApp = File('${File(Platform.resolvedExecutable).parent.path}/$exe');
    return besideApp.existsSync() ? besideApp.path : exe;
  }

  @override
  Future<void> start(String xrayConfigJson, {required String sessionName}) async {
    emit(VpnStatus.connecting);
    final dir = await Directory.systemTemp.createTemp('sru');
    final cfg = File('${dir.path}/config.json')..writeAsStringSync(xrayConfigJson);
    try {
      final p = await Process.start(_resolveBinary(), ['run', '-c', cfg.path]);
      _process = p;
      final ready = Completer<bool>();
      p.stdout.transform(const SystemEncoding().decoder).listen((s) {
        if (!ready.isCompleted && s.contains('started')) ready.complete(true);
      });
      p.stderr.transform(const SystemEncoding().decoder).listen((_) {});
      unawaited(
        p.exitCode.then((code) {
          if (!ready.isCompleted) ready.complete(false);
          if (_process == p) {
            _process = null;
            emit(
              code == 0 ? VpnStatus.disconnected : VpnStatus.error,
              code == 0 ? null : 'xray завершился с кодом $code',
            );
          }
        }),
      );
      final ok = await ready.future.timeout(const Duration(seconds: 10), onTimeout: () => true);
      if (ok) emit(VpnStatus.connected);
    } on ProcessException catch (e) {
      emit(VpnStatus.error, 'Не найден xray: ${e.message}');
    }
  }

  @override
  Future<void> stop() async {
    emit(VpnStatus.disconnecting);
    final p = _process;
    _process = null;
    p?.kill();
    await p?.exitCode;
    emit(VpnStatus.disconnected);
  }

  @override
  Future<String?> coreVersion() async {
    try {
      final r = await Process.run(_resolveBinary(), ['version']);
      return (r.stdout as String).split('\n').first.trim();
    } on ProcessException {
      return null;
    }
  }
}
