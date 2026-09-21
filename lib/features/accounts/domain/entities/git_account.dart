/// Cuenta de GitHub gestionada por la app. No contiene el token: eso
/// pertenece exclusivamente a la capa de datos.
class GitAccount {
  final String id;
  final String login;
  final String displayName;
  final String email;
  final String avatarUrl;
  final String profileUrl;
  final bool isActive;

  const GitAccount({
    required this.id,
    required this.login,
    required this.displayName,
    required this.email,
    required this.avatarUrl,
    required this.profileUrl,
    this.isActive = false,
  });

  String get nameOrLogin => displayName.isNotEmpty ? displayName : login;

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
    );
  }

  @override
  bool operator ==(Object other) => other is GitAccount && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
