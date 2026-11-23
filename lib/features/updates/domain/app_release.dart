/// Versión `mayor.menor.parche` (se ignoran `v`, `+build` y `-pre`).
class AppVersion implements Comparable<AppVersion> {
  final int major;
  final int minor;
  final int patch;

  const AppVersion(this.major, this.minor, this.patch);

  static AppVersion? parse(String text) {
    final m = RegExp(r'^v?(\d+)\.(\d+)(?:\.(\d+))?').firstMatch(text.trim());
    if (m == null) return null;
    return AppVersion(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3) ?? '0'));
  }

  @override
  int compareTo(AppVersion other) => major != other.major
      ? major.compareTo(other.major)
      : minor != other.minor
          ? minor.compareTo(other.minor)
          : patch.compareTo(other.patch);

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// Fichero adjunto a una release.
class ReleaseAsset {
  final String name;
  final String url;
  final int size;

  const ReleaseAsset({required this.name, required this.url, this.size = 0});
}

/// Una release publicada en GitHub.
class AppRelease {
  final AppVersion version;
  final String tag;
  final String name;

  /// Notas de la release (Markdown).
  final String notes;
  final String pageUrl;
  final DateTime? publishedAt;

  /// Paquete .deb para Linux y su suma SHA-256 (si se publicaron).
  final ReleaseAsset? deb;
  final ReleaseAsset? debChecksum;

  const AppRelease({
    required this.version,
    required this.tag,
    required this.name,
    required this.notes,
    required this.pageUrl,
    this.publishedAt,
    this.deb,
    this.debChecksum,
  });
}
