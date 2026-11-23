/// Servicio donde viven los repositorios de una cuenta.
enum GitProvider {
  github,
  azure;

  String get label => switch (this) {
        GitProvider.github => 'GitHub',
        GitProvider.azure => 'Azure DevOps',
      };

  /// Hosts HTTPS a los que se envía el token de una cuenta de este
  /// proveedor. Azure tiene además las URL antiguas `{org}.visualstudio.com`.
  List<String> httpsHosts(List<String> organizations) => switch (this) {
        GitProvider.github => const ['github.com'],
        GitProvider.azure => ['dev.azure.com', for (final o in organizations) '$o.visualstudio.com'],
      };

  /// Las cuentas guardadas antes de existir Azure no tienen proveedor: son de GitHub.
  static GitProvider fromName(String? name) => values.where((v) => v.name == name).firstOrNull ?? github;
}

/// Un remoto git reconocido: a qué servicio pertenece y qué repo es.
class HostedRemote {
  final GitProvider provider;

  /// Usuario/organización en GitHub; organización en Azure DevOps.
  final String owner;

  /// Proyecto de Azure DevOps (null en GitHub).
  final String? project;
  final String name;

  const HostedRemote({required this.provider, required this.owner, required this.name, this.project});

  @override
  bool operator ==(Object other) =>
      other is HostedRemote &&
      other.provider == provider &&
      other.owner == owner &&
      other.project == project &&
      other.name == name;

  @override
  int get hashCode => Object.hash(provider, owner, project, name);

  @override
  String toString() => '${provider.name}:$owner/${project == null ? '' : '$project/'}$name';
}

final _github = RegExp(
  r'^(?:https?://(?:[^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+)/([^/]+?)(?:\.git)?/?$',
);

final _azureHttps = RegExp(r'^https?://(?:[^@/]+@)?dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/?#]+?)/?$');
final _azureLegacy =
    RegExp(r'^https?://(?:[^@/]+@)?([^./]+)\.visualstudio\.com/(?:DefaultCollection/)?([^/]+)/_git/([^/?#]+?)/?$');
final _azureSsh = RegExp(r'^(?:ssh://)?(?:git@ssh\.dev\.azure\.com|[^@]+@vs-ssh\.visualstudio\.com):v3/([^/]+)/([^/]+)/([^/]+?)/?$');

String _decode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

/// Reconoce URLs de remoto de GitHub y de Azure DevOps (HTTPS, SSH y las
/// antiguas `*.visualstudio.com`). null si es de otro servicio.
HostedRemote? parseHostedRemote(String url) {
  final u = url.trim();
  final gh = _github.firstMatch(u);
  if (gh != null) return HostedRemote(provider: GitProvider.github, owner: gh.group(1)!, name: gh.group(2)!);
  for (final re in [_azureHttps, _azureLegacy, _azureSsh]) {
    final m = re.firstMatch(u);
    if (m != null) {
      return HostedRemote(
        provider: GitProvider.azure,
        owner: _decode(m.group(1)!),
        project: _decode(m.group(2)!),
        name: _decode(m.group(3)!),
      );
    }
  }
  return null;
}
