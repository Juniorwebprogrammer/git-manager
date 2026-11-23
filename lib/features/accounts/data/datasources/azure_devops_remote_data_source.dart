import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../../core/error/app_exception.dart';
import '../../../../core/hosting/git_provider.dart';
import '../../../repos/domain/entities/file_change.dart';
import '../../../repos/domain/entities/pull_request.dart';
import '../../../repos/domain/entities/pull_request_detail.dart';
import '../../../repos/domain/entities/remote_repository.dart';

/// Perfil de Azure DevOps del dueño de un PAT.
class AzureProfile {
  final String id;
  final String displayName;
  final String email;

  const AzureProfile({required this.id, required this.displayName, required this.email});
}

/// API REST de Azure DevOps (Services, dev.azure.com) con un PAT.
class AzureDevOpsRemoteDataSource {
  final http.Client _client;

  AzureDevOpsRemoteDataSource(this._client);

  static const _vssps = 'https://app.vssps.visualstudio.com';
  static const _api = 'api-version=7.1';

  /// Azure acepta cualquier usuario con el PAT como contraseña.
  Map<String, String> _headers(String token) => {
        'Authorization': 'Basic ${base64.encode(utf8.encode(':$token'))}',
        'Accept': 'application/json',
      };

  Future<AzureProfile> fetchProfile(String token) async {
    final json = await _getJson('$_vssps/_apis/profile/profiles/me?$_api', token);
    return AzureProfile(
      id: json['id'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      email: json['emailAddress'] as String? ?? json['publicAlias'] as String? ?? '',
    );
  }

  /// Organizaciones a las que tiene acceso el token. Si el PAT está
  /// limitado a una sola organización, Azure no deja listarlas: devuelve
  /// una lista vacía y la organización se pide a mano.
  Future<List<String>> fetchOrganizations(String token, String memberId) async {
    try {
      final json = await _getJson('$_vssps/_apis/accounts?memberId=$memberId&$_api', token);
      return [
        for (final a in (json['value'] as List<dynamic>? ?? const []))
          (a as Map<String, dynamic>)['accountName'] as String? ?? '',
      ].where((n) => n.isNotEmpty).toList()
        ..sort();
    } on InvalidTokenException {
      return const [];
    } on ServerException {
      return const [];
    }
  }

  /// Comprueba que el token puede entrar en [organization].
  Future<void> checkOrganization(String token, String organization) async {
    await _getJson('https://dev.azure.com/${Uri.encodeComponent(organization)}/_apis/projects?\$top=1&$_api', token,
        organization: organization);
  }

  /// Repos de [organization] (de todos sus proyectos).
  Future<List<RemoteRepository>> fetchRepositories(String token, String organization) async {
    final json = await _getJson(
      'https://dev.azure.com/${Uri.encodeComponent(organization)}/_apis/git/repositories?$_api',
      token,
      organization: organization,
    );
    return [
      for (final r in (json['value'] as List<dynamic>? ?? const []))
        if ((r as Map<String, dynamic>)['isDisabled'] != true)
          RemoteRepository(
            fullName: '$organization/${(r['project'] as Map<String, dynamic>?)?['name'] ?? ''}/${r['name']}',
            name: r['name'] as String? ?? '',
            description: 'Project: ${(r['project'] as Map<String, dynamic>?)?['name'] ?? ''}',
            cloneUrl: r['remoteUrl'] as String? ?? '',
            isPrivate: true,
          ),
    ]..sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
  }

  // ───────────────────────── Pull requests (Azure Repos) ─────────────────────────

  static String _seg(String s) => Uri.encodeComponent(s);

  String _repoApi(HostedRemote r) =>
      'https://dev.azure.com/${_seg(r.owner)}/${_seg(r.project ?? '')}/_apis/git/repositories/${_seg(r.name)}';

  /// Página web del repo: `https://dev.azure.com/org/proyecto/_git/repo`.
  static String webUrl(HostedRemote r) =>
      'https://dev.azure.com/${_seg(r.owner)}/${_seg(r.project ?? '')}/_git/${_seg(r.name)}';

  static String _repoNotFound(HostedRemote r) =>
      'Repository "${r.project}/${r.name}" not found in "${r.owner}", or this token cannot access it.';

  static String _branch(Object? ref) => (ref as String? ?? '').replaceFirst('refs/heads/', '');

  static String _name(Object? identity) {
    final m = identity as Map<String, dynamic>?;
    return m?['displayName'] as String? ?? m?['uniqueName'] as String? ?? '';
  }

  static DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

  static List<Map<String, dynamic>> _values(Object? json) =>
      [for (final v in ((json as Map<String, dynamic>?)?['value'] as List<dynamic>? ?? const [])) v as Map<String, dynamic>];

  Future<HostedRepoInfo> fetchRepoInfo(String token, HostedRemote r) async {
    final json = await _json('GET', '${_repoApi(r)}?$_api', token, notFound: _repoNotFound(r)) as Map<String, dynamic>;
    return HostedRepoInfo(
      owner: '${r.owner}/${r.project}',
      name: r.name,
      defaultBranch: json['defaultBranch'] == null ? 'main' : _branch(json['defaultBranch']),
      provider: GitProvider.azure,
    );
  }

  Future<List<PullRequest>> fetchOpenPullRequests(String token, HostedRemote r) async {
    final json = await _json(
      'GET',
      '${_repoApi(r)}/pullrequests?searchCriteria.status=active&\$top=50&$_api',
      token,
      notFound: _repoNotFound(r),
    );
    return Future.wait(_values(json).map((pr) async {
      // En la lista, solo builds y estados externos (no revisores).
      final checks = (await _policiesAndStatuses(token, r, pr)).where((c) => c.isCi).map((c) => c.check).toList();
      return _pullRequest(r, pr, _ci(checks));
    }));
  }

  Future<PullRequest> createPullRequest(
    String token,
    HostedRemote r, {
    required String title,
    required String head,
    required String base,
    String body = '',
    bool draft = false,
  }) async {
    final json = await _json('POST', '${_repoApi(r)}/pullrequests?$_api', token, notFound: _repoNotFound(r), body: {
      'sourceRefName': 'refs/heads/$head',
      'targetRefName': 'refs/heads/$base',
      'title': title,
      'description': body,
      'isDraft': draft,
    });
    return _pullRequest(r, json as Map<String, dynamic>, CiStatus.none);
  }

  /// Detalle de la PR. Azure no da el diff por API: [localFiles] lo calcula
  /// con git entre las puntas de destino y origen; si falla, se listan los
  /// ficheros de la última iteración sin diff.
  Future<PullRequestBundle> fetchPullRequestBundle(
    String token,
    HostedRemote r,
    int number, {
    Future<List<PullRequestFile>> Function(String base, String head)? localFiles,
  }) async {
    final url = '${_repoApi(r)}/pullrequests/$number';
    final pr = await _json('GET', '$url?$_api', token, notFound: 'Pull request #$number not found.') as Map<String, dynamic>;
    final threadsF = _json('GET', '$url/threads?$_api', token);
    final commitsF = _json('GET', '$url/commits?\$top=500&$_api', token);
    final policiesF = _policiesAndStatuses(token, r, pr);

    final base = (pr['lastMergeTargetCommit'] as Map<String, dynamic>?)?['commitId'] as String?;
    final head = (pr['lastMergeSourceCommit'] as Map<String, dynamic>?)?['commitId'] as String?;
    List<PullRequestFile>? files;
    if (localFiles != null && base != null && head != null) {
      try {
        files = await localFiles(base, head);
      } on AppException {
        files = null;
      }
    }
    files ??= await _iterationFiles(token, url);

    final commits = [
      for (final c in _values(await commitsF))
        PullRequestCommit(
          sha: c['commitId'] as String? ?? '',
          message: c['comment'] as String? ?? '',
          author: (c['author'] as Map<String, dynamic>?)?['name'] as String? ?? '',
          date: _date((c['author'] as Map<String, dynamic>?)?['date']),
        ),
    ]..sort((a, b) => (a.date ?? DateTime(0)).compareTo(b.date ?? DateTime(0)));

    final policies = await policiesF;
    final (timeline, reviewComments) = _threads(_values(await threadsF));

    final status = pr['status'] as String?;
    final draft = pr['isDraft'] == true;
    final mergeStatus = pr['mergeStatus'] as String?;
    final detail = PullRequestDetail(
      number: number,
      title: pr['title'] as String? ?? '',
      body: pr['description'] as String? ?? '',
      author: _name(pr['createdBy']),
      state: switch (status) {
        'completed' => PullRequestState.merged,
        'abandoned' => PullRequestState.closed,
        _ => draft ? PullRequestState.draft : PullRequestState.open,
      },
      headRef: _branch(pr['sourceRefName']),
      headSha: head ?? '',
      headRepoFullName: _headRepo(r, pr),
      baseRef: _branch(pr['targetRefName']),
      url: '${webUrl(r)}/pullrequest/$number',
      mergeable: switch (mergeStatus) {
        'succeeded' => true,
        'conflicts' || 'failure' || 'rejectedByPolicy' => false,
        _ => null,
      },
      mergeableState: _mergeState(draft, mergeStatus, policies),
      commitCount: commits.length,
      additions: files.fold(0, (n, f) => n + f.additions),
      deletions: files.fold(0, (n, f) => n + f.deletions),
      changedFiles: files.length,
      createdAt: _date(pr['creationDate']),
      mergedBy: status == 'completed' ? _name(pr['closedBy']) : null,
      provider: GitProvider.azure,
      fork: pr['forkSource'] != null,
    );

    return PullRequestBundle(
      detail: detail,
      timeline: timeline,
      commits: commits,
      files: files,
      checks: [for (final p in policies) p.check],
      reviewComments: reviewComments,
    );
  }

  Future<void> pullRequestAction(String token, HostedRemote r, int number, PullRequestOp op) async {
    final url = '${_repoApi(r)}/pullrequests/$number';
    Future<void> patch(Map<String, Object?> body) => _json('PATCH', '$url?$_api', token, body: body);
    Future<void> thread(String content, [Map<String, Object?>? context]) => _json('POST', '$url/threads?$_api', token, body: {
          'comments': [
            {'parentCommentId': 0, 'content': content, 'commentType': 1},
          ],
          'status': 1,
          'threadContext': ?context,
        });

    switch (op) {
      case CommentOnPullRequest(:final body):
        await thread(body);
      case ReviewPullRequest(:final event, :final body):
        if (body.trim().isNotEmpty) await thread(body.trim());
        // Votos de Azure: 10 aprobado, -5 esperando al autor.
        final vote = switch (event) {
          ReviewEvent.approve => 10,
          ReviewEvent.requestChanges => -5,
          ReviewEvent.comment => null,
        };
        if (vote != null) {
          final me = await _myId(token, r.owner);
          await _json('PUT', '$url/reviewers/${_seg(me)}?$_api', token, body: {'vote': vote});
        }
      case MergePullRequest(:final method, :final title, :final message, :final deleteBranch):
        final pr = await _json('GET', '$url?$_api', token) as Map<String, dynamic>;
        final text = [?title?.trim(), ?message?.trim()].where((s) => s.isNotEmpty).join('\n\n');
        await patch({
          'status': 'completed',
          'lastMergeSourceCommit': pr['lastMergeSourceCommit'],
          'completionOptions': {
            'mergeStrategy': switch (method) {
              MergeMethod.merge => 'noFastForward',
              MergeMethod.squash => 'squash',
              MergeMethod.rebase => 'rebase',
            },
            'deleteSourceBranch': deleteBranch,
            if (text.isNotEmpty) 'mergeCommitMessage': text,
          },
        });
      case SetPullRequestOpen(:final open):
        await patch({'status': open ? 'active' : 'abandoned'});
      case EditPullRequest(:final title, :final body):
        await patch({'title': title, 'description': body});
      case CommentOnLine(:final path, :final line, :final side, :final body):
        final position = {'line': line, 'offset': 1};
        await thread(body, {
          'filePath': '/$path',
          if (side == DiffSide.right) ...{'rightFileStart': position, 'rightFileEnd': position},
          if (side == DiffSide.left) ...{'leftFileStart': position, 'leftFileEnd': position},
        });
      case ReplyToReviewComment(:final commentId, :final body):
        // En Azure se responde a un hilo; el id del hilo es el del comentario raíz.
        await _json('POST', '$url/threads/$commentId/comments?$_api', token,
            body: {'content': body, 'parentCommentId': 1, 'commentType': 1});
    }
  }

  final _myIds = <String, String>{};

  /// Id del dueño del token en [organization] (para votar como revisor).
  Future<String> _myId(String token, String organization) async {
    final key = '$organization:${token.hashCode}';
    final cached = _myIds[key];
    if (cached != null) return cached;
    final json = await _json('GET', 'https://dev.azure.com/${_seg(organization)}/_apis/connectionData', token,
        organization: organization) as Map<String, dynamic>;
    final id = (json['authenticatedUser'] as Map<String, dynamic>?)?['id'] as String?;
    if (id == null || id.isEmpty) throw const ServerException('Could not identify your Azure DevOps user.');
    return _myIds[key] = id;
  }

  PullRequest _pullRequest(HostedRemote r, Map<String, dynamic> j, CiStatus ci) => PullRequest(
        number: j['pullRequestId'] as int? ?? 0,
        title: j['title'] as String? ?? '',
        author: _name(j['createdBy']),
        headRef: _branch(j['sourceRefName']),
        headSha: (j['lastMergeSourceCommit'] as Map<String, dynamic>?)?['commitId'] as String? ?? '',
        headRepoFullName: _headRepo(r, j),
        baseRef: _branch(j['targetRefName']),
        url: '${webUrl(r)}/pullrequest/${j['pullRequestId']}',
        draft: j['isDraft'] == true,
        updatedAt: _date(j['creationDate']),
        ci: ci,
        provider: GitProvider.azure,
        fork: j['forkSource'] != null,
      );

  static String _headRepo(HostedRemote r, Map<String, dynamic> pr) {
    final fork = (pr['forkSource'] as Map<String, dynamic>?)?['repository'] as Map<String, dynamic>?;
    if (fork == null) return '${r.project}/${r.name}';
    final project = (fork['project'] as Map<String, dynamic>?)?['name'];
    return [?project, fork['name'] ?? 'fork'].join('/');
  }

  static CiStatus _ci(List<PullRequestCheck> checks) {
    if (checks.isEmpty) return CiStatus.none;
    if (checks.any((c) => c.status == CiStatus.failure)) return CiStatus.failure;
    if (checks.any((c) => c.status == CiStatus.pending)) return CiStatus.pending;
    return CiStatus.success;
  }

  /// Políticas de rama (revisores, builds…) y estados que publican otros
  /// servicios. Si el token no puede leerlos, la PR se muestra sin checks.
  Future<List<_AzureCheck>> _policiesAndStatuses(String token, HostedRemote r, Map<String, dynamic> pr) async {
    final id = pr['pullRequestId'];
    final projectId = ((pr['repository'] as Map<String, dynamic>?)?['project'] as Map<String, dynamic>?)?['id'];
    final project = 'https://dev.azure.com/${_seg(r.owner)}/${_seg(r.project ?? '')}';
    final checks = <_AzureCheck>[];

    if (projectId != null) {
      try {
        final artifact = Uri.encodeQueryComponent('vstfs:///CodeReview/CodeReviewId/$projectId/$id');
        final json = await _json(
            'GET', '$project/_apis/policy/evaluations?artifactId=$artifact&api-version=7.1-preview.1', token);
        for (final e in _values(json)) {
          final config = e['configuration'] as Map<String, dynamic>? ?? const {};
          if (config['isEnabled'] == false || e['status'] == 'notApplicable') continue;
          final type = (config['type'] as Map<String, dynamic>?)?['displayName'] as String? ?? 'Policy';
          final settings = config['settings'] as Map<String, dynamic>? ?? const {};
          final isBuild = type == 'Build';
          final blocking = config['isBlocking'] != false;
          final raw = e['status'] as String? ?? 'queued';
          final buildId = (e['context'] as Map<String, dynamic>?)?['buildId'];
          checks.add(_AzureCheck(
            PullRequestCheck(
              name: settings['displayName'] as String? ?? type,
              // Revisores u otras políticas sin cumplir: pendiente, no fallo.
              status: switch (raw) {
                'approved' => CiStatus.success,
                'rejected' || 'broken' => isBuild ? CiStatus.failure : CiStatus.pending,
                _ => CiStatus.pending,
              },
              detail: '$raw · ${blocking ? 'required' : 'optional'}',
              url: buildId == null ? null : '$project/_build/results?buildId=$buildId',
            ),
            isCi: isBuild,
            blocking: blocking,
            approved: raw == 'approved',
            rejected: raw == 'rejected' || raw == 'broken',
          ));
        }
      } on AppException {
        // Sin permiso para leer políticas: se ignoran.
      }
    }

    try {
      final json = await _json('GET', '${_repoApi(r)}/pullrequests/$id/statuses?$_api', token);
      // Un estado por contexto: el último publicado.
      final latest = <String, Map<String, dynamic>>{};
      for (final s in _values(json)) {
        final c = s['context'] as Map<String, dynamic>? ?? const {};
        latest[[c['genre'], c['name']].whereType<String>().join('/')] = s;
      }
      for (final MapEntry(key: name, value: s) in latest.entries) {
        final state = s['state'] as String? ?? 'notSet';
        if (state == 'notApplicable' || state == 'notSet') continue;
        checks.add(_AzureCheck(
          PullRequestCheck(
            name: name.isEmpty ? 'Status' : name,
            status: switch (state) {
              'succeeded' => CiStatus.success,
              'failed' || 'error' => CiStatus.failure,
              _ => CiStatus.pending,
            },
            detail: (s['description'] as String?)?.trim().isNotEmpty == true ? s['description'] as String : state,
            url: s['targetUrl'] as String?,
          ),
          isCi: true,
          blocking: false,
          approved: state == 'succeeded',
          rejected: state == 'failed' || state == 'error',
        ));
      }
    } on AppException {
      // Ídem.
    }
    return checks;
  }

  static String _mergeState(bool draft, String? mergeStatus, List<_AzureCheck> policies) {
    if (draft) return 'draft';
    switch (mergeStatus) {
      case 'conflicts':
        return 'dirty';
      case 'rejectedByPolicy':
        return 'blocked';
      case 'failure':
        return 'failed';
      case 'succeeded':
        break;
      default:
        return 'unknown';
    }
    if (policies.any((p) => p.blocking && !p.approved)) return 'blocked';
    if (policies.any((p) => p.rejected)) return 'unstable';
    return 'clean';
  }

  /// Hilos de Azure → conversación + comentarios en líneas.
  static (List<PullRequestEvent>, List<ReviewComment>) _threads(List<Map<String, dynamic>> threads) {
    final timeline = <PullRequestEvent>[];
    final review = <ReviewComment>[];
    for (final t in threads) {
      if (t['isDeleted'] == true) continue;
      final threadId = t['id'] as int? ?? 0;
      final props = t['properties'] as Map<String, dynamic>? ?? const {};
      String? prop(String k) => (props[k] as Map<String, dynamic>?)?[r'$value']?.toString();
      final comments = [
        for (final c in (t['comments'] as List<dynamic>? ?? const []))
          if ((c as Map<String, dynamic>)['isDeleted'] != true) c,
      ];
      if (comments.isEmpty) continue;

      // Cambios de voto: se muestran como reviews.
      if (prop('CodeReviewThreadType') == 'VoteUpdate') {
        final vote = int.tryParse(prop('CodeReviewVoteResult') ?? '');
        final state = switch (vote) {
          10 || 5 => ReviewState.approved,
          -5 || -10 => ReviewState.changesRequested,
          0 => ReviewState.dismissed,
          _ => null,
        };
        if (state != null) {
          timeline.add(PullRequestEvent(
            author: _name(comments.first['author']),
            body: switch (vote) {
              5 => 'Approved with suggestions',
              -5 => 'Waiting for author',
              -10 => 'Rejected',
              0 => 'Reset their vote',
              _ => '',
            },
            date: _date(comments.first['publishedDate']),
            review: state,
          ));
        }
        continue;
      }

      final texts = comments.where((c) => c['commentType'] == 'text').toList();
      if (texts.isEmpty) continue;
      final ctx = t['threadContext'] as Map<String, dynamic>?;
      final file = (ctx?['filePath'] as String?)?.replaceFirst(RegExp('^/'), '');
      if (ctx == null || file == null) {
        for (final c in texts) {
          timeline.add(PullRequestEvent(
            author: _name(c['author']),
            body: c['content'] as String? ?? '',
            date: _date(c['publishedDate']),
          ));
        }
        continue;
      }

      final right = (ctx['rightFileStart'] as Map<String, dynamic>?)?['line'] as int?;
      final left = (ctx['leftFileStart'] as Map<String, dynamic>?)?['line'] as int?;
      final side = right != null ? DiffSide.right : DiffSide.left;
      final line = right ?? left;
      for (var i = 0; i < texts.length; i++) {
        final c = texts[i];
        final date = _date(c['publishedDate']);
        review.add(ReviewComment(
          id: i == 0 ? threadId : threadId * 10000 + (c['id'] as int? ?? i),
          author: _name(c['author']),
          body: c['content'] as String? ?? '',
          path: file,
          line: line,
          side: side,
          date: date,
          inReplyTo: i == 0 ? null : threadId,
        ));
        timeline.add(PullRequestEvent(
          author: _name(c['author']),
          body: c['content'] as String? ?? '',
          date: date,
          location: line == null ? file : '$file:$line',
        ));
      }
    }
    timeline.sort((a, b) => (a.date ?? DateTime(0)).compareTo(b.date ?? DateTime(0)));
    return (timeline, review);
  }

  /// Ficheros de la última iteración (sin diff: Azure no lo da por API).
  Future<List<PullRequestFile>> _iterationFiles(String token, String prUrl) async {
    final iterations = _values(await _json('GET', '$prUrl/iterations?$_api', token));
    if (iterations.isEmpty) return const [];
    final last = iterations.map((i) => i['id'] as int? ?? 0).reduce((a, b) => a > b ? a : b);
    final json = await _json('GET', '$prUrl/iterations/$last/changes?\$top=2000&$_api', token) as Map<String, dynamic>;
    return [
      for (final c in (json['changeEntries'] as List<dynamic>? ?? const []))
        if (((c as Map<String, dynamic>)['item'] as Map<String, dynamic>?)?['isFolder'] != true)
          PullRequestFile(
            path: ((c['item'] as Map<String, dynamic>?)?['path'] as String? ?? '').replaceFirst(RegExp('^/'), ''),
            oldPath: (c['originalPath'] as String?)?.replaceFirst(RegExp('^/'), ''),
            type: switch (c['changeType'] as String? ?? '') {
              final t when t.contains('rename') => ChangeType.renamed,
              final t when t.contains('add') => ChangeType.added,
              final t when t.contains('delete') => ChangeType.deleted,
              _ => ChangeType.modified,
            },
          ),
    ];
  }

  Future<Map<String, dynamic>> _getJson(String url, String token, {String? organization}) async =>
      await _json('GET', url, token, organization: organization) as Map<String, dynamic>;

  Future<Object?> _json(
    String method,
    String url,
    String token, {
    Object? body,
    String? organization,
    String? notFound,
  }) async {
    final http.Response response;
    try {
      final request = http.Request(method, Uri.parse(url))..headers.addAll(_headers(token));
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      response = await http.Response.fromStream(await _client.send(request)).timeout(const Duration(seconds: 30));
    } on SocketException catch (_) {
      throw const ServerException('No internet connection.');
    } on HttpException catch (_) {
      throw const ServerException('Could not reach Azure DevOps.');
    }

    // Con un PAT inválido, Azure suele responder 203 con la página HTML de
    // inicio de sesión en lugar de un 401.
    final isHtml = (response.headers['content-type'] ?? '').contains('text/html') ||
        response.body.trimLeft().startsWith('<');
    if (response.statusCode == 401 || response.statusCode == 203 || (response.statusCode == 200 && isHtml)) {
      throw const InvalidTokenException();
    }
    if (response.statusCode == 403) {
      throw ServerException(
        'Azure DevOps refused the request: the token is missing permissions'
        '${organization == null ? '' : ' in "$organization"'}.\n\n'
        'Edit the token at dev.azure.com → User settings → Personal access tokens and give it:\n'
        '  • Code: Read & write\n'
        '  • User Profile: Read\n'
        '  • Organization: "All accessible organizations" (or the one you use).',
      );
    }
    if (response.statusCode == 404 && (notFound != null || organization != null)) {
      throw ServerException(notFound ?? 'Organization "$organization" not found, or this token cannot access it.');
    }
    if (response.statusCode == 204) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Azure explica el motivo en "message" (políticas, PR ya existente…).
      String? message;
      try {
        message = (jsonDecode(response.body) as Map<String, dynamic>)['message'] as String?;
      } on FormatException {
        message = null;
      } on TypeError {
        message = null;
      }
      throw ServerException(message == null
          ? 'Azure DevOps responded with status code ${response.statusCode}.'
          : 'Azure DevOps: $message');
    }
    return response.body.trim().isEmpty ? null : jsonDecode(response.body);
  }
}

/// Un check de la PR y lo que importa para decidir si se puede completar.
class _AzureCheck {
  final PullRequestCheck check;
  final bool isCi;
  final bool blocking;
  final bool approved;
  final bool rejected;

  const _AzureCheck(this.check, {required this.isCi, required this.blocking, required this.approved, required this.rejected});
}
