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
  ConnectivityChecker({required this.proxyPort, this.proxyUser, this.proxyPassword});

  final int proxyPort;
  final String? proxyUser;
  final String? proxyPassword;

  /// Приоритетные сайты простого режима.
  static const targets = [
    CheckTarget('Telegram', 'https://api.telegram.org/'),
    CheckTarget('YouTube', 'https://www.youtube.com/generate_204'),
    CheckTarget('Microsoft', 'https://www.microsoft.com/robots.txt'),
  ];

  Future<List<CheckResult>> checkAll({
    List<CheckTarget> sites = targets,
    Duration timeout = const Duration(seconds: 8),
  }) => Future.wait(sites.map((t) => check(t, timeout: timeout)));

  Future<CheckResult> check(CheckTarget t, {Duration timeout = const Duration(seconds: 8)}) async {
    final auth = proxyUser == null ? '' : '$proxyUser:$proxyPassword@';
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY ${auth}127.0.0.1:$proxyPort')
      ..connectionTimeout = timeout
      ..userAgent = 'Mozilla/5.0 SruNaZapret';
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
