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

  const GitAccountModel({
    required this.id,
    required this.login,
    required this.displayName,
    required this.email,
    required this.avatarUrl,
    required this.profileUrl,
    required this.token,
    this.isActive = false,
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
      };

  GitAccountModel copyWith({
    String? displayName,
    String? email,
    String? avatarUrl,
    String? token,
    bool? isActive,
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
      );
}
