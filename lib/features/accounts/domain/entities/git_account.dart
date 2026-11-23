import '../../../../core/hosting/git_provider.dart';

/// Cuenta (de GitHub o Azure DevOps) gestionada por la app. No contiene el
/// token: eso pertenece exclusivamente a la capa de datos.
class GitAccount {
  final String id;
  final String login;
  final String displayName;
  final String email;
  final String avatarUrl;
  final String profileUrl;
  final bool isActive;
  final GitProvider provider;

  /// Organizaciones de Azure DevOps (vacío en GitHub).
  final List<String> organizations;

  const GitAccount({
    required this.id,
    required this.login,
    required this.displayName,
    required this.email,
    required this.avatarUrl,
    required this.profileUrl,
    this.isActive = false,
    this.provider = GitProvider.github,
    this.organizations = const [],
  });

  String get nameOrLogin => displayName.isNotEmpty ? displayName : login;

  /// Cómo se muestra la cuenta bajo su nombre: `@login` en GitHub; en
  /// Azure DevOps, el email y las organizaciones.
  String get handle => switch (provider) {
        GitProvider.github => '@$login',
        GitProvider.azure => organizations.isEmpty ? login : '$login · ${organizations.join(', ')}',
      };

  GitAccount copyWith({
    String? displayName,
    String? email,
    String? avatarUrl,
    bool? isActive,
  }) {
    return GitAccount(
      id: id,
      login: login,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      profileUrl: profileUrl,
      isActive: isActive ?? this.isActive,
      provider: provider,
      organizations: organizations,
    );
  }

  @override
  bool operator ==(Object other) => other is GitAccount && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
