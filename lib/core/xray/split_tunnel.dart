/// Раздельное туннелирование, как в AmneziaVPN: «только эти через VPN»
/// или «все, кроме этих».
enum SplitMode {
  off('Выключено'),
  onlyListed('Только эти через VPN'),
  exceptListed('Все, кроме этих');

  const SplitMode(this.title);
  final String title;
}

/// Готовые наборы сайтов для быстрого добавления (категории geosite/geoip
/// из баз Loyalsoldier, которые лежат в приложении).
const sitePresets = <String, List<String>>{
  'YouTube': ['geosite:youtube'],
  'Telegram': ['geosite:telegram', 'geoip:telegram'],
  'Discord': ['geosite:discord'],
  'Instagram': ['geosite:instagram'],
  'ChatGPT': ['geosite:openai'],
  'Microsoft': ['geosite:microsoft'],
};

/// Разбор того, что ввёл пользователь, в правила Xray: домены и IP/подсети.
class SiteRules {
  SiteRules(this.domains, this.ips);
  final List<String> domains;
  final List<String> ips;

  bool get isEmpty => domains.isEmpty && ips.isEmpty;

  static final _ipLike = RegExp(r'^[0-9a-fA-F:.]+(/\d{1,3})?$');
  static const _domainPrefixes = ['domain:', 'full:', 'regexp:', 'keyword:', 'geosite:', 'ext:'];

  static SiteRules parse(Iterable<String> entries) {
    final domains = <String>[];
    final ips = <String>[];
    for (final raw in entries) {
      final e = normalize(raw);
      if (e.isEmpty) continue;
      if (e.startsWith('geoip:')) {
        ips.add(e);
      } else if (_domainPrefixes.any(e.startsWith)) {
        domains.add(e);
      } else if (_ipLike.hasMatch(e) && (e.contains('.') || e.contains(':'))) {
        ips.add(e);
      } else {
        domains.add('domain:$e'); // сам домен и все поддомены
      }
    }
    return SiteRules(domains, ips);
  }

  /// "https://www.YouTube.com/watch?v=1" → "youtube.com".
  static String normalize(String raw) {
    var e = raw.trim();
    if (e.isEmpty) return '';
    if (e.contains('://')) {
      final uri = Uri.tryParse(e);
      e = uri?.host ?? e;
    }
    // Путь отрезаем только у доменов: у подсети "1.2.3.0/24" после / идёт маска.
    if (!e.contains(':') && !_ipLike.hasMatch(e)) {
      e = e.split('/').first;
    }
    final lower = e.toLowerCase();
    if (lower.startsWith('www.')) return lower.substring(4);
    return lower;
  }
}
