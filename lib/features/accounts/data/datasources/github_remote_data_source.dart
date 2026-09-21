import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../../core/error/app_exception.dart';
import '../models/github_user_dto.dart';

/// Habla directamente con la API REST de GitHub para validar tokens y
/// obtener el perfil autenticado.
class GitHubRemoteDataSource {
  final http.Client _client;

  const GitHubRemoteDataSource(this._client);

  static const _baseUrl = 'https://api.github.com';

  Map<String, String> _headers(String token) => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  /// El "ping": confirma que el token es válido y trae el perfil.
  Future<GitHubUserDto> fetchAuthenticatedUser(String token) async {
    final response = await _get('/user', token);
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final dto = GitHubUserDto.fromJson(json);
    if (dto.email != null && dto.email!.isNotEmpty) return dto;

    final primaryEmail = await _fetchPrimaryEmail(token);
    final resolvedEmail = primaryEmail ?? _noreplyEmailFor(dto);
    return GitHubUserDto(
      id: dto.id,
      login: dto.login,
      name: dto.name,
      email: resolvedEmail,
      avatarUrl: dto.avatarUrl,
      profileUrl: dto.profileUrl,
    );
  }

  /// El correo puede ser privado; si el token tiene el scope
  /// `user:email` lo recuperamos, si no caemos a la dirección
  /// `@users.noreply.github.com` que GitHub asigna por defecto.
  Future<String?> _fetchPrimaryEmail(String token) async {
    try {
      final response = await _get('/user/emails', token);
      final emails = jsonDecode(response.body) as List<dynamic>;
      for (final entry in emails) {
        final map = entry as Map<String, dynamic>;
        if (map['primary'] == true) return map['email'] as String?;
      }
    } catch (_) {
      // Sin scope user:email o error de red: se resuelve con el fallback.
    }
    return null;
  }

  String _noreplyEmailFor(GitHubUserDto dto) =>
      '${dto.id}+${dto.login}@users.noreply.github.com';

  Future<http.Response> _get(String path, String token) async {
    final http.Response response;
    try {
      response = await _client
          .get(Uri.parse('$_baseUrl$path'), headers: _headers(token))
          .timeout(const Duration(seconds: 15));
    } on SocketException catch (_) {
      throw const ServerException('No hay conexión a internet.');
    } on HttpException catch (_) {
      throw const ServerException('No se pudo contactar con GitHub.');
    }

    if (response.statusCode == 200) return response;
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const InvalidTokenException();
    }
    throw ServerException('GitHub respondió con el código ${response.statusCode}.');
  }
}
