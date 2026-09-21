/// Respuesta cruda de `GET /user` de la API REST de GitHub.
class GitHubUserDto {
  final String id;
  final String login;
  final String? name;
  final String? email;
  final String avatarUrl;
  final String profileUrl;

  const GitHubUserDto({
    required this.id,
    required this.login,
    required this.name,
    required this.email,
    required this.avatarUrl,
    required this.profileUrl,
  });

  factory GitHubUserDto.fromJson(Map<String, dynamic> json) {
    return GitHubUserDto(
      id: json['id'].toString(),
      login: json['login'] as String,
      name: json['name'] as String?,
      email: json['email'] as String?,
      avatarUrl: json['avatar_url'] as String? ?? '',
      profileUrl: json['html_url'] as String? ?? '',
    );
  }
}
