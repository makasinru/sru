import 'dart:async';
import 'dart:io';

/// Сайт для проверки «работает ли VPN на самом деле».
class CheckTarget {
  const CheckTarget(this.name, this.url);
  final String name;
  final String url;
}

class CheckResult {
  CheckResult(this.target, this.ms, [this.error]);
  final CheckTarget target;

  /// Время до ответа сервера, мс; null — не открылся.
  final int? ms;
  final String? error;
  bool get ok => ms != null;
}

/// Проверяет, открываются ли сайты через туннель. Запросы идут через локальный
/// HTTP-вход ядра, то есть тем же путём, что и трафик устройства: ядро → протокол
/// → сервер → сайт. Любой HTTP-ответ (даже 404) значит, что сайт доступен.
class ConnectivityChecker {
  ConnectivityChecker({required this.proxyPort, this.proxyUser, this.proxyPassword, this.speedUrl = defaultSpeedUrl});

  final int proxyPort;
  final String? proxyUser;
  final String? proxyPassword;
  final String speedUrl;

  /// Приоритетные сайты простого режима.
  static const targets = [
    CheckTarget('Telegram', 'https://api.telegram.org/'),
    CheckTarget('YouTube', 'https://www.youtube.com/generate_204'),
  ];

  /// Сколько максимум скачивает один замер скорости: 10 МБ.
  static const speedBytes = 10 * 1000 * 1000;

  /// Файл для замера скорости (Cloudflare отдаёт столько байт, сколько попросили).
  static const defaultSpeedUrl = 'https://speed.cloudflare.com/__down?bytes=$speedBytes';

  Future<List<CheckResult>> checkAll({
    List<CheckTarget> sites = targets,
    Duration timeout = const Duration(seconds: 8),
  }) => Future.wait(sites.map((t) => check(t, timeout: timeout)));

  HttpClient _client(Duration timeout) {
    final auth = proxyUser == null ? '' : '$proxyUser:$proxyPassword@';
    return HttpClient()
      ..findProxy = ((_) => 'PROXY ${auth}127.0.0.1:$proxyPort')
      ..connectionTimeout = timeout
      ..userAgent = 'Mozilla/5.0 SruNaZapret';
  }

  /// Скорость загрузки через туннель, Мбит/с; null — не удалось скачать.
  /// Качает не больше [speedBytes] и не дольше [duration], чтобы не тратить трафик.
  Future<double?> speedTest({Duration duration = const Duration(seconds: 4)}) async {
    final client = _client(const Duration(seconds: 8));
    var bytes = 0;
    final sw = Stopwatch();
    try {
      final req = await client.getUrl(Uri.parse(speedUrl)).timeout(const Duration(seconds: 8));
      final resp = await req.close().timeout(const Duration(seconds: 8));
      if (resp.statusCode != HttpStatus.ok) return null;
      sw.start();
      await for (final chunk in resp.timeout(const Duration(seconds: 5))) {
        bytes += chunk.length;
        if (sw.elapsed >= duration) break;
      }
    } catch (_) {
      // Обрыв или таймаут посередине — считаем по тому, что успело скачаться.
    } finally {
      client.close(force: true);
    }
    final secs = sw.elapsedMicroseconds / 1e6;
    if (bytes < 100000 || secs <= 0) return null;
    return bytes * 8 / secs / 1e6;
  }

  Future<CheckResult> check(CheckTarget t, {Duration timeout = const Duration(seconds: 8)}) async {
    final client = _client(timeout);
    final sw = Stopwatch()..start();
    try {
      final req = await client.getUrl(Uri.parse(t.url)).timeout(timeout);
      req.followRedirects = false;
      final resp = await req.close().timeout(timeout);
      final ms = sw.elapsedMilliseconds;
      await resp.drain<void>().timeout(const Duration(seconds: 3), onTimeout: () {});
      // 407 отдаёт сам локальный прокси, до сайта запрос не дошёл.
      if (resp.statusCode == HttpStatus.proxyAuthenticationRequired) {
        return CheckResult(t, null, 'прокси отклонил пароль');
      }
      // 502/503/504 отдаёт ядро, когда не достучалось до сервера VPN.
      if (resp.statusCode >= 502 && resp.statusCode <= 504) {
        return CheckResult(t, null, 'сервер VPN не отвечает');
      }
      return CheckResult(t, ms);
    } catch (e) {
      return CheckResult(t, null, e is TimeoutException ? 'нет ответа' : e.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// Лучшее время среди открывшихся сайтов (меньше — быстрее).
  static int? bestMs(List<CheckResult> results) {
    final ok = results.where((r) => r.ok).map((r) => r.ms!).toList()..sort();
    return ok.isEmpty ? null : ok.first;
  }
}
