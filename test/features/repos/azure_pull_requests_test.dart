import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/core/error/app_exception.dart';
import 'package:git_manager/core/error/result.dart';
import 'package:git_manager/core/git/git_runner.dart';
import 'package:git_manager/core/hosting/git_provider.dart';
import 'package:git_manager/features/accounts/data/datasources/account_local_data_source.dart';
import 'package:git_manager/features/accounts/data/datasources/azure_devops_remote_data_source.dart';
import 'package:git_manager/features/accounts/data/datasources/github_remote_data_source.dart';
import 'package:git_manager/features/accounts/data/models/git_account_model.dart';
import 'package:git_manager/features/repos/data/datasources/git_cli_data_source.dart';
import 'package:git_manager/features/repos/data/repositories/git_repository_impl.dart';
import 'package:git_manager/features/repos/domain/entities/file_change.dart';
import 'package:git_manager/features/repos/domain/entities/git_action.dart';
import 'package:git_manager/features/repos/domain/entities/pull_request.dart';
import 'package:git_manager/features/repos/domain/entities/pull_request_detail.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';

class _MockLocal extends Mock implements AccountLocalDataSource {}

class _MockGitHub extends Mock implements GitHubRemoteDataSource {}

const remote = HostedRemote(provider: GitProvider.azure, owner: 'contoso', project: 'Store', name: 'demo');
const repoApi = '/contoso/Store/_apis/git/repositories/demo';

Map<String, dynamic> prJson({
  int id = 5,
  String status = 'active',
  String mergeStatus = 'succeeded',
  bool draft = false,
  String source = 'aaa',
  String target = 'bbb',
  bool fork = false,
}) =>
    {
      'pullRequestId': id,
      'title': 'Add login',
      'description': 'Adds the **login** screen',
      'status': status,
      'isDraft': draft,
      'mergeStatus': mergeStatus,
      'createdBy': {'displayName': 'Ana Pérez', 'uniqueName': 'ana@contoso.com'},
      'creationDate': '2026-11-20T10:00:00Z',
      'sourceRefName': 'refs/heads/feature/login',
      'targetRefName': 'refs/heads/main',
      'lastMergeSourceCommit': {'commitId': source},
      'lastMergeTargetCommit': {'commitId': target},
      'repository': {
        'name': 'demo',
        'project': {'id': 'proj-1', 'name': 'Store'},
      },
      if (fork)
        'forkSource': {
          'name': 'refs/heads/feature/login',
          'repository': {
            'name': 'demo-fork',
            'project': {'name': 'Ana'},
          },
        },
      if (status == 'completed') 'closedBy': {'displayName': 'Bob'},
    };

Map<String, dynamic> threadsJson() => {
      'value': [
        {
          'id': 1,
          'publishedDate': '2026-11-20T11:00:00Z',
          'comments': [
            {
              'id': 1,
              'author': {'displayName': 'Bob'},
              'content': 'Looks good',
              'publishedDate': '2026-11-20T11:00:00Z',
              'commentType': 'text',
            },
          ],
        },
        {
          // Voto: aparece como review.
          'id': 2,
          'properties': {
            'CodeReviewThreadType': {r'$type': 'System.String', r'$value': 'VoteUpdate'},
            'CodeReviewVoteResult': {r'$type': 'System.String', r'$value': '10'},
          },
          'comments': [
            {
              'id': 1,
              'author': {'displayName': 'Bob'},
              'content': 'Bob voted 10',
              'publishedDate': '2026-11-20T12:00:00Z',
              'commentType': 'system',
            },
          ],
        },
        {
          // Hilo en una línea, con respuesta.
          'id': 3,
          'threadContext': {
            'filePath': '/a.txt',
            'rightFileStart': {'line': 2, 'offset': 1},
            'rightFileEnd': {'line': 2, 'offset': 1},
          },
          'comments': [
            {
              'id': 1,
              'author': {'displayName': 'Eve'},
              'content': 'Why two?',
              'publishedDate': '2026-11-20T09:00:00Z',
              'commentType': 'text',
            },
            {
              'id': 2,
              'parentCommentId': 1,
              'author': {'displayName': 'Ana Pérez'},
              'content': 'Backend limit',
              'publishedDate': '2026-11-20T09:30:00Z',
              'commentType': 'text',
            },
          ],
        },
        {
          // Mensajes del sistema (push, cambios de política…): no se muestran.
          'id': 4,
          'comments': [
            {
              'id': 1,
              'author': {'displayName': 'Azure DevOps'},
              'content': 'Ana updated the pull request',
              'commentType': 'system',
            },
          ],
        },
        {'id': 6, 'isDeleted': true, 'comments': []},
      ],
    };

Map<String, dynamic> policiesJson({bool reviewersOk = false}) => {
      'value': [
        {
          'status': reviewersOk ? 'approved' : 'rejected',
          'configuration': {
            'isEnabled': true,
            'isBlocking': true,
            'type': {'displayName': 'Minimum number of reviewers'},
            'settings': {'minimumApproverCount': 2},
          },
        },
        {
          'status': 'rejected',
          'context': {'buildId': 77},
          'configuration': {
            'isEnabled': true,
            'isBlocking': false,
            'type': {'displayName': 'Build'},
            'settings': {'displayName': 'CI build'},
          },
        },
        {
          'status': 'notApplicable',
          'configuration': {
            'isEnabled': true,
            'isBlocking': true,
            'type': {'displayName': 'Comment requirements'},
          },
        },
      ],
    };

/// Azure DevOps simulado. Guarda cada petición (método, ruta, cuerpo).
class FakeAzure {
  final requests = <(String, String, Object?)>[];
  Map<String, dynamic> pr = prJson();
  bool reviewersOk = false;
  int? failWith;

  late final client = MockClient((req) async {
    final path = req.url.path;
    requests.add((req.method, path, req.body.isEmpty ? null : jsonDecode(req.body)));
    expect(req.headers['authorization'], 'Basic ${base64.encode(utf8.encode(':pat'))}');
    if (failWith != null && req.method != 'GET') {
      return http.Response(jsonEncode({'message': 'TF401179: An active pull request already exists.'}), failWith!);
    }
    http.Response ok(Object? json) => http.Response.bytes(utf8.encode(jsonEncode(json)), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

    if (path == repoApi) return ok({'name': 'demo', 'defaultBranch': 'refs/heads/develop'});
    if (path == '$repoApi/pullrequests' && req.method == 'GET') {
      expect(req.url.queryParameters['searchCriteria.status'], 'active');
      return ok({
        'value': [pr, prJson(id: 6, draft: true, fork: true)],
      });
    }
    if (path == '$repoApi/pullrequests' && req.method == 'POST') {
      return ok(prJson(id: 9));
    }
    if (RegExp(r'/pullrequests/\d+$').hasMatch(path)) return ok(req.method == 'GET' ? pr : pr);
    if (path.endsWith('/threads')) return ok(req.method == 'GET' ? threadsJson() : {'id': 10});
    if (path.endsWith('/comments')) return ok({'id': 3});
    if (path.endsWith('/commits')) {
      return ok({
        'value': [
          {
            'commitId': 'c2',
            'comment': 'Second',
            'author': {'name': 'Ana', 'date': '2026-11-20T09:00:00Z'},
          },
          {
            'commitId': 'c1',
            'comment': 'First',
            'author': {'name': 'Ana', 'date': '2026-11-19T09:00:00Z'},
          },
        ],
      });
    }
    if (path.endsWith('/statuses')) {
      return ok({
        'value': [
          {
            'state': 'pending',
            'context': {'genre': 'sonar', 'name': 'quality'},
          },
          {
            'state': 'succeeded',
            'description': 'Quality gate passed',
            'context': {'genre': 'sonar', 'name': 'quality'},
            'targetUrl': 'https://sonar/1',
          },
        ],
      });
    }
    if (path == '/contoso/Store/_apis/policy/evaluations') {
      expect(req.url.queryParameters['artifactId'], startsWith('vstfs:///CodeReview/CodeReviewId/proj-1/'));
      return ok(policiesJson(reviewersOk: reviewersOk));
    }
    if (path.endsWith('/iterations')) {
      return ok({
        'value': [
          {'id': 1},
          {'id': 2},
        ],
      });
    }
    if (path.endsWith('/iterations/2/changes')) {
      return ok({
        'changeEntries': [
          {
            'changeType': 'edit',
            'item': {'path': '/a.txt'},
          },
          {
            'changeType': 'edit, rename',
            'item': {'path': '/e.txt'},
            'originalPath': '/d.txt',
          },
          {
            'changeType': 'add',
            'item': {'path': '/src', 'isFolder': true},
          },
        ],
      });
    }
    if (path == '/contoso/_apis/connectionData') {
      return ok({
        'authenticatedUser': {'id': 'me-123'},
      });
    }
    if (path.contains('/reviewers/')) return ok({'vote': 10});
    return http.Response('not found', 404);
  });

  AzureDevOpsRemoteDataSource get api => AzureDevOpsRemoteDataSource(client);
}

void main() {
  group('Azure Repos pull requests API', () {
    test('lists active PRs with CI from builds and statuses (not reviewers)', () async {
      final azure = FakeAzure();
      final prs = await azure.api.fetchOpenPullRequests('pat', remote);
      expect(prs.map((p) => p.number), [5, 6]);
      final pr = prs.first;
      expect((pr.title, pr.author, pr.headRef, pr.baseRef, pr.headSha), ('Add login', 'Ana Pérez', 'feature/login', 'main', 'aaa'));
      expect(pr.url, 'https://dev.azure.com/contoso/Store/_git/demo/pullrequest/5');
      expect((pr.provider, pr.isFromFork), (GitProvider.azure, false));
      // Build fallido → rojo, aunque falten revisores (eso no es CI).
      expect(pr.ci, CiStatus.failure);
      expect((prs.last.draft, prs.last.isFromFork, prs.last.headRepoFullName), (true, true, 'Ana/demo-fork'));
    });

    test('bundle: conversation, votes, line threads, commits, checks and mergeability', () async {
      final azure = FakeAzure();
      final bundle = await azure.api.fetchPullRequestBundle('pat', remote, 5, localFiles: (base, head) async {
        expect((base, head), ('bbb', 'aaa'));
        return const [
          PullRequestFile(path: 'a.txt', type: ChangeType.modified, additions: 2, deletions: 1, patch: '@@ -1 +1,2 @@'),
        ];
      });
      final d = bundle.detail;
      expect((d.number, d.body, d.state, d.provider), (5, 'Adds the **login** screen', PullRequestState.open, GitProvider.azure));
      expect((d.commitCount, d.additions, d.deletions, d.changedFiles), (2, 2, 1, 1));
      // Faltan revisores obligatorios: no se puede completar.
      expect(d.mergeableState, 'blocked');
      expect(d.mergeability.canMerge, isFalse);
      expect(d.mergeability.text, contains('branch policies'));

      expect(bundle.commits.map((c) => c.message), ['First', 'Second']);
      expect(
        bundle.timeline.map((e) => (e.author, e.body, e.review, e.location)),
        [
          ('Eve', 'Why two?', null, 'a.txt:2'),
          ('Ana Pérez', 'Backend limit', null, 'a.txt:2'),
          ('Bob', 'Looks good', null, null),
          ('Bob', '', ReviewState.approved, null),
        ],
      );
      final threads = bundle.threadsFor('a.txt');
      expect(threads.single.map((c) => (c.id, c.body, c.line, c.side, c.inReplyTo)), [
        (3, 'Why two?', 2, DiffSide.right, null),
        (30002, 'Backend limit', 2, DiffSide.right, 3),
      ]);
      expect(
        bundle.checks.map((c) => (c.name, c.status, c.url)),
        [
          ('Minimum number of reviewers', CiStatus.pending, null),
          ('CI build', CiStatus.failure, 'https://dev.azure.com/contoso/Store/_build/results?buildId=77'),
          ('sonar/quality', CiStatus.success, 'https://sonar/1'),
        ],
      );
    });

    test('mergeability follows Azure merge status and policies', () async {
      Future<String> state(Map<String, dynamic> pr, {bool reviewersOk = true}) async {
        final azure = FakeAzure()
          ..pr = pr
          ..reviewersOk = reviewersOk;
        return (await azure.api.fetchPullRequestBundle('pat', remote, pr['pullRequestId'] as int)).detail.mergeableState;
      }

      // Solo falla un build opcional: se puede completar, avisando.
      expect(await state(prJson()), 'unstable');
      expect(await state(prJson(mergeStatus: 'conflicts')), 'dirty');
      expect(await state(prJson(mergeStatus: 'queued')), 'unknown');
      expect(await state(prJson(draft: true)), 'draft');
      final merged = FakeAzure()..pr = prJson(status: 'completed');
      final bundle = await merged.api.fetchPullRequestBundle('pat', remote, 5);
      expect((bundle.detail.state, bundle.detail.mergedBy), (PullRequestState.merged, 'Bob'));
    });

    test('without a local diff, files come from the last iteration', () async {
      final azure = FakeAzure();
      final bundle = await azure.api.fetchPullRequestBundle('pat', remote, 5,
          localFiles: (_, _) async => throw const GitCommandException('no commits'));
      expect(bundle.files.map((f) => (f.path, f.oldPath, f.type, f.patch)), [
        ('a.txt', null, ChangeType.modified, null),
        ('e.txt', 'd.txt', ChangeType.renamed, null),
      ]);
    });

    test('actions send the right requests', () async {
      final azure = FakeAzure();
      final api = azure.api;
      // Listas (no records) para comparar los cuerpos JSON en profundidad.
      Future<List<List<Object?>>> run(PullRequestOp op) async {
        azure.requests.clear();
        await api.pullRequestAction('pat', remote, 5, op);
        return [for (final r in azure.requests.where((r) => r.$1 != 'GET')) [r.$1, r.$2, r.$3]];
      }

      final pr = '$repoApi/pullrequests/5';
      expect(await run(const CommentOnPullRequest('Thanks!')), [
        ['POST', '$pr/threads', {
          'comments': [
            {'parentCommentId': 0, 'content': 'Thanks!', 'commentType': 1},
          ],
          'status': 1,
        }],
      ]);
      expect(await run(const ReviewPullRequest(ReviewEvent.approve)), [
        ['PUT', '$pr/reviewers/me-123', {'vote': 10}],
      ]);
      final changes = await run(const ReviewPullRequest(ReviewEvent.requestChanges, 'Add tests'));
      expect(changes.map((r) => r[0]), ['POST', 'PUT']);
      expect(changes.last[2], {'vote': -5});
      // El id del usuario se pide una sola vez.
      expect(azure.requests.where((r) => r.$2.endsWith('connectionData')), isEmpty);

      expect(await run(const MergePullRequest(MergeMethod.squash, title: 'Add login (#5)', deleteBranch: true)), [
        ['PATCH', pr, {
          'status': 'completed',
          'lastMergeSourceCommit': {'commitId': 'aaa'},
          'completionOptions': {'mergeStrategy': 'squash', 'deleteSourceBranch': true, 'mergeCommitMessage': 'Add login (#5)'},
        }],
      ]);
      expect((await run(const MergePullRequest(MergeMethod.merge))).single[2],
          containsPair('completionOptions', {'mergeStrategy': 'noFastForward', 'deleteSourceBranch': false}));
      expect((await run(const SetPullRequestOpen(false))).single[2], {'status': 'abandoned'});
      expect((await run(const SetPullRequestOpen(true))).single[2], {'status': 'active'});
      expect((await run(const EditPullRequest('New', 'Body'))).single[2], {'title': 'New', 'description': 'Body'});

      final line = await run(const CommentOnLine(path: 'lib/a.dart', line: 7, side: DiffSide.left, body: 'Hm', commitSha: 'aaa'));
      expect((line.single[2] as Map)['threadContext'], {
        'filePath': '/lib/a.dart',
        'leftFileStart': {'line': 7, 'offset': 1},
        'leftFileEnd': {'line': 7, 'offset': 1},
      });
      expect(await run(const ReplyToReviewComment(3, 'Fixed')), [
        ['POST', '$pr/threads/3/comments', {'content': 'Fixed', 'parentCommentId': 1, 'commentType': 1}],
      ]);
    });

    test('create, repo info and readable errors', () async {
      final azure = FakeAzure();
      final info = await azure.api.fetchRepoInfo('pat', remote);
      expect((info.defaultBranch, info.provider), ('develop', GitProvider.azure));

      final created = await azure.api.createPullRequest('pat', remote, title: 'T', head: 'feature/x', base: 'main', draft: true);
      expect(created.number, 9);
      expect(azure.requests.last.$3, {
        'sourceRefName': 'refs/heads/feature/x',
        'targetRefName': 'refs/heads/main',
        'title': 'T',
        'description': '',
        'isDraft': true,
      });

      azure.failWith = 409;
      await expectLater(
        azure.api.createPullRequest('pat', remote, title: 'T', head: 'feature/x', base: 'main'),
        throwsA(isA<ServerException>().having((e) => e.message, 'message', 'Azure DevOps: TF401179: An active pull request already exists.')),
      );
      final missing = AzureDevOpsRemoteDataSource(MockClient((_) async => http.Response('', 404)));
      await expectLater(
        missing.fetchOpenPullRequests('pat', remote),
        throwsA(isA<ServerException>().having((e) => e.message, 'message', contains('Repository "Store/demo" not found'))),
      );
    });
  });

  group('with real git', () {
    late Directory tmp;
    late String mine;
    late String featureSha;
    late String mainSha;
    const runner = GitRunner();
    Future<String> git(String dir, List<String> args) async => (await runner.run(args, workingDirectory: dir)).trim();

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('gm_azpr_');
      final bare = '${tmp.path}/origin.git';
      final dev = '${tmp.path}/dev';
      await git(tmp.path, ['init', '-q', '--bare', '-b', 'main', bare]);
      await git(tmp.path, ['clone', '-q', bare, dev]);
      for (final kv in {'user.name': 'Dev', 'user.email': 'dev@x.com', 'commit.gpgsign': 'false'}.entries) {
        await git(dev, ['config', kv.key, kv.value]);
      }
      await File('$dev/a.txt').writeAsString('one\n');
      await File('$dev/c.txt').writeAsString('gone\n');
      await File('$dev/d.txt').writeAsString('${List.filled(20, 'same line').join('\n')}\n');
      await git(dev, ['add', '-A']);
      await git(dev, ['commit', '-q', '-m', 'base']);
      await git(dev, ['push', '-q', 'origin', 'main']);

      await git(dev, ['switch', '-q', '-c', 'feature/login']);
      await File('$dev/a.txt').writeAsString('one\ntwo\n');
      await File('$dev/b.txt').writeAsString('new\n');
      await File('$dev/c.txt').delete();
      await git(dev, ['mv', 'd.txt', 'e.txt']);
      await File('$dev/bin.dat').writeAsBytes([0, 1, 2, 0, 255]);
      await git(dev, ['add', '-A']);
      await git(dev, ['commit', '-q', '-m', 'feature']);
      featureSha = await git(dev, ['rev-parse', 'HEAD']);
      // Azure publica refs/pull/N/merge (destino + PR), no la rama de un fork.
      await git(dev, ['switch', '-q', '--detach', 'main']);
      await git(dev, ['merge', '-q', '--no-ff', '-m', 'Merge PR 5', 'feature/login']);
      await git(dev, ['push', '-q', 'origin', 'HEAD:refs/pull/5/merge']);
      mainSha = await git(dev, ['rev-parse', 'main']);

      // Nuestro clon solo tiene main: los commits de la PR hay que traerlos.
      mine = '${tmp.path}/mine';
      await git(tmp.path, ['clone', '-q', '--single-branch', '-b', 'main', bare, mine]);
      const url = 'https://dev.azure.com/contoso/Store/_git/demo';
      await git(mine, ['remote', 'set-url', 'origin', url]);
      await git(mine, ['config', 'url.$bare.insteadOf', url]);
    });

    tearDown(() => tmp.delete(recursive: true));

    GitRepositoryImpl repository(FakeAzure azure) {
      final local = _MockLocal();
      when(() => local.readAccounts()).thenAnswer((_) async => const [
            GitAccountModel(
              id: 'az',
              login: 'ana@contoso.com',
              displayName: 'Ana',
              email: 'ana@contoso.com',
              avatarUrl: '',
              profileUrl: '',
              token: 'pat',
              provider: GitProvider.azure,
              organizations: ['contoso'],
            ),
          ]);
      return GitRepositoryImpl(
        cli: const GitCliDataSource(runner),
        accounts: local,
        github: _MockGitHub(),
        azure: azure.api,
      );
    }

    test('the PR diff is computed locally after fetching its commits', () async {
      final azure = FakeAzure()..pr = prJson(source: featureSha, target: mainSha);
      final result = await repository(azure).loadPullRequest((accountId: 'az', path: mine), 5);
      final bundle = (result as Success<PullRequestBundle>).value;
      final files = {for (final f in bundle.files) f.path: f};
      expect(files.keys, unorderedEquals(['a.txt', 'b.txt', 'bin.dat', 'c.txt', 'e.txt']));
      expect((files['a.txt']!.type, files['a.txt']!.additions, files['a.txt']!.deletions), (ChangeType.modified, 1, 0));
      expect(files['a.txt']!.patch, startsWith('@@ -1 +1,2 @@'));
      expect(files['a.txt']!.patch, endsWith('+two'));
      expect((files['b.txt']!.type, files['c.txt']!.type), (ChangeType.added, ChangeType.deleted));
      expect((files['e.txt']!.type, files['e.txt']!.oldPath), (ChangeType.renamed, 'd.txt'));
      expect(files['bin.dat']!.patch, isNull);
      expect(bundle.detail.changedFiles, 5);
      // No se ha creado ninguna rama local.
      expect(await git(mine, ['branch', '--format=%(refname:short)']), 'main');
    });

    test('a fork PR is checked out from refs/pull/N/merge', () async {
      final repo = repository(FakeAzure());
      final result = await repo.run(
        (accountId: 'az', path: mine),
        const CheckoutPullRequestAction(number: 5, headRef: 'feature/login', sameRepo: false),
      );
      expect(result, isA<Success<void>>());
      expect(await git(mine, ['rev-parse', '--abbrev-ref', 'HEAD']), 'pr/5');
      expect(await git(mine, ['rev-parse', 'HEAD']), featureSha);
    });

    test('a GitHub tab gets a clear message for Azure pull requests', () async {
      final local = _MockLocal();
      when(() => local.readAccounts()).thenAnswer((_) async => const [
            GitAccountModel(
                id: 'gh', login: 'octo', displayName: 'Octo', email: '', avatarUrl: '', profileUrl: '', token: 't'),
          ]);
      final repo = GitRepositoryImpl(
          cli: const GitCliDataSource(runner), accounts: local, github: _MockGitHub(), azure: FakeAzure().api);
      final result = await repo.listPullRequests((accountId: 'gh', path: mine));
      expect((result as Failure).failure.message, contains('This repository is on Azure DevOps'));
    });
  });
}
