import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../../core/error/app_exception.dart';
import '../../../repos/domain/entities/pull_request.dart';
import '../../../repos/domain/entities/remote_repository.dart';
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

  /// Repos a los que tiene acceso el token (propios, de colaborador y de
  /// organizaciones), los más recientes primero. Máximo [maxPages] × 100.
  Future<List<RemoteRepository>> fetchRepositories(String token, {int maxPages = 5}) async {
    final repos = <RemoteRepository>[];
    for (var page = 1; page <= maxPages; page++) {
      final response = await _get(
        '/user/repos?per_page=100&page=$page&sort=updated'
        '&affiliation=owner,collaborator,organization_member',
        token,
      );
      final list = jsonDecode(response.body) as List<dynamic>;
      for (final item in list) {
        final map = item as Map<String, dynamic>;
        repos.add(RemoteRepository(
          fullName: map['full_name'] as String? ?? '',
          name: map['name'] as String? ?? '',
          description: map['description'] as String? ?? '',
          cloneUrl: map['clone_url'] as String? ?? '',
          isPrivate: map['private'] as bool? ?? false,
          updatedAt: DateTime.tryParse(map['pushed_at'] as String? ?? map['updated_at'] as String? ?? ''),
        ));
      }
      if (list.length < 100) break;
    }
    return repos;
  }

  Future<GitHubRepoInfo> fetchRepoInfo(String token, String owner, String name) async {
    final response = await _get('/repos/$owner/$name', token);
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return GitHubRepoInfo(
      owner: owner,
      name: name,
      defaultBranch: json['default_branch'] as String? ?? 'main',
    );
  }

  Future<List<PullRequest>> fetchOpenPullRequests(String token, String owner, String name) async {
    final response = await _get('/repos/$owner/$name/pulls?state=open&per_page=50&sort=updated&direction=desc', token);
    final list = jsonDecode(response.body) as List<dynamic>;
    return [for (final item in list) _pullFromJson(item as Map<String, dynamic>)];
  }

  /// Estado de CI de un commit: combina los "statuses" clásicos y los
  /// "check runs" de GitHub Actions. Si el token no puede leerlos → none.
  Future<CiStatus> fetchCiStatus(String token, String owner, String name, String sha) async {
    final states = <String>[];
    try {
      final status = jsonDecode((await _get('/repos/$owner/$name/commits/$sha/status', token)).body)
          as Map<String, dynamic>;
      if (((status['total_count'] as int?) ?? 0) > 0) states.add(status['state'] as String? ?? '');
    } catch (_) {}
    try {
      final checks = jsonDecode((await _get('/repos/$owner/$name/commits/$sha/check-runs?per_page=100', token)).body)
          as Map<String, dynamic>;
      for (final run in (checks['check_runs'] as List<dynamic>? ?? const [])) {
        final map = run as Map<String, dynamic>;
        states.add(map['status'] == 'completed' ? (map['conclusion'] as String? ?? '') : 'pending');
      }
    } catch (_) {}
    return combineCiStates(states);
  }

  Future<PullRequest> createPullRequest(
    String token,
    String owner,
    String name, {
    required String title,
    required String head,
    required String base,
    String body = '',
    bool draft = false,
  }) async {
    final response = await _send(
      'POST',
      '/repos/$owner/$name/pulls',
      token,
      body: {'title': title, 'head': head, 'base': base, 'body': body, 'draft': draft},
    );
    return _pullFromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  PullRequest _pullFromJson(Map<String, dynamic> json) {
    final head = json['head'] as Map<String, dynamic>? ?? const {};
    final base = json['base'] as Map<String, dynamic>? ?? const {};
    final headRepo = head['repo'] as Map<String, dynamic>?;
    final user = json['user'] as Map<String, dynamic>? ?? const {};
    return PullRequest(
      number: json['number'] as int,
      title: json['title'] as String? ?? '',
      author: user['login'] as String? ?? '',
      headRef: head['ref'] as String? ?? '',
      headSha: head['sha'] as String? ?? '',
      headRepoFullName: headRepo?['full_name'] as String? ?? '',
      baseRef: base['ref'] as String? ?? '',
      url: json['html_url'] as String? ?? '',
      draft: json['draft'] as bool? ?? false,
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }

  Future<http.Response> _send(String method, String path, String token, {Object? body}) async {
    final http.Response response;
    try {
      final request = http.Request(method, Uri.parse('$_baseUrl$path'))
        ..headers.addAll({..._headers(token), 'Content-Type': 'application/json'})
        ..body = body == null ? '' : jsonEncode(body);
      response = await http.Response.fromStream(await _client.send(request).timeout(const Duration(seconds: 20)));
    } on SocketException catch (_) {
      throw const ServerException('No internet connection.');
    } on HttpException catch (_) {
      throw const ServerException('Could not reach GitHub.');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return response;
    if (response.statusCode == 401) throw const InvalidTokenException();
    if (response.statusCode == 403 || response.statusCode == 404) {
      final permission = permissionProblem(response, token: token, path: path);
      if (permission != null) throw ServerException(permission);
    }
    throw ServerException(_githubError(response));
  }

  /// Mensaje legible de un error de la API ("A pull request already exists…").
  String _githubError(http.Response response) {
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final details = (json['errors'] as List<dynamic>? ?? const [])
          .map((e) => e is Map ? (e['message'] ?? e['code'] ?? '').toString() : e.toString())
          .where((m) => m.isNotEmpty)
          .join('\n');
      final message = json['message'] as String? ?? 'GitHub error';
      return details.isEmpty
          ? '$message (HTTP ${response.statusCode})'
          : '$message (HTTP ${response.statusCode}):\n$details';
    } catch (_) {
      return 'GitHub responded with status code ${response.statusCode}.';
    }
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
      throw const ServerException('No internet connection.');
    } on HttpException catch (_) {
      throw const ServerException('Could not reach GitHub.');
    }

    if (response.statusCode == 200) return response;
    if (response.statusCode == 403 || response.statusCode == 404) {
      final permission = permissionProblem(response, token: token, path: path);
      if (permission != null) throw ServerException(permission);
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const InvalidTokenException();
    }
    throw ServerException('GitHub responded with status code ${response.statusCode}.');
  }
}

/// Resume varios estados de CI (statuses y check runs) en uno.
CiStatus combineCiStates(List<String> states) {
  if (states.isEmpty) return CiStatus.none;
  const failed = {'failure', 'error', 'cancelled', 'timed_out', 'action_required', 'startup_failure'};
  if (states.any(failed.contains)) return CiStatus.failure;
  if (states.any((s) => s == 'pending' || s == 'queued' || s == 'in_progress' || s.isEmpty)) {
    return CiStatus.pending;
  }
  return CiStatus.success;
}

/// Explica un 403/404 de GitHub por falta de permisos del token, usando las
/// cabeceras que GitHub devuelve (`X-Accepted-GitHub-Permissions` para
/// tokens fine-grained, `X-OAuth-Scopes` para los clásicos). null si el
/// error no es de permisos.
String? permissionProblem(http.Response response, {required String token, required String path}) {
  String message;
  try {
    message = (jsonDecode(response.body) as Map<String, dynamic>)['message'] as String? ?? '';
  } catch (_) {
    message = '';
  }
  final notAccessible = message.contains('Resource not accessible');
  // GitHub responde 404 (no 403) cuando el token no puede ver el repo.
  final hidden = response.statusCode == 404 && path.startsWith('/repos/');
  if (!notAccessible && !hidden) return null;

  final repo = RegExp(r'^/repos/([^/]+/[^/?]+)').firstMatch(path)?.group(1) ?? 'this repository';
  final accepted = response.headers['x-accepted-github-permissions'];
  final scopes = response.headers['x-oauth-scopes'];
  final fineGrained = token.startsWith('github_pat_');
  final classic = token.startsWith('ghp_');

  final lines = <String>[
    hidden
        ? 'GitHub says $repo does not exist for this token — usually the token simply cannot see it.'
        : 'GitHub refused: the token of this account is not allowed to do this in $repo.',
    '',
  ];
  if (fineGrained || (!classic && accepted != null)) {
    lines.addAll([
      'It is a fine-grained token. On github.com → Settings → Developer settings → '
          'Fine-grained tokens → (your token) → Edit:',
      '  • Repository access: include $repo (or "All repositories").',
      '  • Repository permissions: Pull requests → Read and write, Contents → Read and write'
          '${accepted != null && accepted.isNotEmpty ? '\n    (GitHub says this action needs: ${accepted.replaceAll(';', ', ')})' : ''}.',
      '  • If $repo belongs to an organization, it must allow fine-grained tokens, '
          'and the token\'s "Resource owner" must be that organization.',
      '  • A fine-grained token cannot access repositories of another user where you are only a collaborator — '
          'use a classic token for those.',
    ]);
  } else {
    lines.addAll([
      'It is a classic token. On github.com → Settings → Developer settings → Tokens (classic) → '
          '(your token) → enable the "repo" scope (or "public_repo" for public repositories).',
      if (scopes != null) '  • Scopes the token has now: ${scopes.isEmpty ? '(none)' : scopes}.',
      '  • If $repo belongs to an organization with SSO, click "Configure SSO" → Authorize next to the token.',
    ]);
  }
  lines.addAll([
    '',
    'Editing the permissions keeps the same token, so you do not need to add the account again.',
    'GitHub said: ${message.isEmpty ? 'HTTP ${response.statusCode}' : message}',
  ]);
  return lines.join('\n');
}
