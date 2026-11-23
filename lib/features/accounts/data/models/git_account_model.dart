import '../../../../core/hosting/git_provider.dart';
import '../../domain/entities/git_account.dart';

/// Representación persistida de una cuenta, incluye el token (que nunca
/// cruza hacia el dominio/presentación) y se guarda cifrada en el
/// almacén seguro del sistema.
class GitAccountModel {
  final String id;
  final String login;
  final String displayName;
  final String email;
  final String avatarUrl;
  final String profileUrl;
  final String token;
  final bool isActive;
  final GitProvider provider;

  /// Organizaciones de Azure DevOps de la cuenta (vacío en GitHub).
  final List<String> organizations;

  const GitAccountModel({
    required this.id,
    required this.login,
    required this.displayName,
    required this.email,
    required this.avatarUrl,
    required this.profileUrl,
    required this.token,
    this.isActive = false,
    this.provider = GitProvider.github,
    this.organizations = const [],
  });

  factory GitAccountModel.fromJson(Map<String, dynamic> json) {
    return GitAccountModel(
      id: json['id'] as String,
      login: json['login'] as String,
      displayName: json['displayName'] as String? ?? '',
      email: json['email'] as String? ?? '',
      avatarUrl: json['avatarUrl'] as String? ?? '',
      profileUrl: json['profileUrl'] as String? ?? '',
      token: json['token'] as String,
      isActive: json['isActive'] as bool? ?? false,
      provider: GitProvider.fromName(json['provider'] as String?),
      organizations: (json['organizations'] as List<dynamic>? ?? const []).cast<String>(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'login': login,
        'displayName': displayName,
        'email': email,
        'avatarUrl': avatarUrl,
        'profileUrl': profileUrl,
        'token': token,
        'isActive': isActive,
        'provider': provider.name,
        'organizations': organizations,
      };

  GitAccountModel copyWith({
    String? displayName,
    String? email,
    String? avatarUrl,
    String? token,
    bool? isActive,
    List<String>? organizations,
  }) {
    return GitAccountModel(
      id: id,
      login: login,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      profileUrl: profileUrl,
      token: token ?? this.token,
      isActive: isActive ?? this.isActive,
      provider: provider,
      organizations: organizations ?? this.organizations,
    );
  }

  GitAccount toEntity() => GitAccount(
        id: id,
        login: login,
        displayName: displayName,
        email: email,
        avatarUrl: avatarUrl,
        profileUrl: profileUrl,
        isActive: isActive,
        provider: provider,
        organizations: organizations,
      );
}
