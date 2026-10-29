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

  /// Сколько максимум скачивает один замер скорости по умолчанию: 10 МБ.
  static const speedBytes = 10 * 1000 * 1000;

  /// Cloudflare отдаёт столько байт, сколько попросили в ?bytes=.
  static const defaultSpeedUrl = 'https://speed.cloudflare.com/__down';

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
  ///
  /// Как speedtest: несколько потоков сразу, а первые доли секунды (разгон TCP
  /// и задержка до первого байта) не считаются. Одним потоком на 10 МБ быстрый
  /// канал не успевал разогнаться, и замер упирался примерно в 100 Мбит/с.
  /// Всего скачивается не больше [maxBytes] и не дольше [duration].
  Future<double?> speedTest({
    int maxBytes = speedBytes,
    int streams = 4,
    Duration duration = const Duration(seconds: 5),
    Duration warmup = const Duration(milliseconds: 400),
  }) async {
    final client = _client(const Duration(seconds: 8))..maxConnectionsPerHost = streams;
    final sw = Stopwatch();
    var bytes = 0;
    int? warmBytes;
    Duration? warmAt;
    var done = false;

    Future<void> stream() async {
      try {
        final uri = Uri.parse('$speedUrl${speedUrl.contains('?') ? '&' : '?'}bytes=${maxBytes ~/ streams}');
        final req = await client.getUrl(uri).timeout(const Duration(seconds: 8));
        final resp = await req.close().timeout(const Duration(seconds: 8));
        if (resp.statusCode != HttpStatus.ok) return;
        await for (final chunk in resp.timeout(const Duration(seconds: 5))) {
          if (!sw.isRunning) sw.start();
          bytes += chunk.length;
          if (warmBytes == null && sw.elapsed >= warmup) {
            warmBytes = bytes;
            warmAt = sw.elapsed;
          }
          if (done || sw.elapsed >= duration) break;
        }
      } catch (_) {
        // Обрыв или таймаут посередине — считаем по тому, что успело скачаться.
      }
    }

    try {
      await Future.wait([for (var i = 0; i < streams; i++) stream()]);
    } finally {
      done = true;
      sw.stop();
      client.close(force: true);
    }
    if (bytes < 100000 || sw.elapsedMicroseconds <= 0) return null;
    // Если после разгона прошло хотя бы 0,3 с — считаем только этот отрезок.
    final from = warmAt;
    if (from != null && sw.elapsed - from >= const Duration(milliseconds: 300)) {
      return (bytes - warmBytes!) * 8 / ((sw.elapsed - from).inMicroseconds / 1e6) / 1e6;
    }
    return bytes * 8 / (sw.elapsedMicroseconds / 1e6) / 1e6;
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
