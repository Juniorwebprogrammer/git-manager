import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/core/error/app_exception.dart';
import 'package:git_manager/features/accounts/data/datasources/github_remote_data_source.dart';
import 'package:git_manager/features/repos/data/parsers/git_parsers.dart';
import 'package:git_manager/features/repos/domain/conflicts/conflict_parser.dart';
import 'package:git_manager/features/repos/domain/entities/pull_request.dart';
import 'package:git_manager/features/repos/domain/entities/pull_request_detail.dart';
import 'package:git_manager/features/repos/domain/patch/patch_builder.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('buildPartialPatch', () {
    // -4 -5 +a +b +c, rodeado de contexto.
    final hunk = parseUnifiedDiff(
      'f.txt',
      'diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n'
          '@@ -3,4 +3,5 @@\n 3\n-4\n-5\n+a\n+b\n+c\n 6\n',
    ).hunks.single;

    test('whole hunk keeps every change', () {
      final patch = buildPartialPatch(path: 'f.txt', hunk: hunk, reverse: false)!;
      expect(patch, contains('@@ -3,1 +3,1 @@'));
      expect(patch.split('\n').where((l) => l.startsWith('+') && !l.startsWith('+++')), hasLength(3));
    });

    test('forward: unselected + dropped, unselected - becomes context', () {
      // índices: 0 ' 3', 1 '-4', 2 '-5', 3 '+a', 4 '+b', 5 '+c', 6 ' 6'
      final patch = buildPartialPatch(path: 'f.txt', hunk: hunk, selected: {1, 4}, reverse: false)!;
      final body = patch.split('\n').skip(4).where((l) => l.isNotEmpty).toList();
      expect(body, [' 3', '-4', ' 5', '+b', ' 6']);
    });

    test('reverse: unselected + becomes context, unselected - dropped', () {
      final patch = buildPartialPatch(path: 'f.txt', hunk: hunk, selected: {1, 4}, reverse: true)!;
      final body = patch.split('\n').skip(4).where((l) => l.isNotEmpty).toList();
      expect(body, [' 3', '-4', ' a', '+b', ' c', ' 6']);
    });

    test('selection without changes → null', () {
      expect(buildPartialPatch(path: 'f.txt', hunk: hunk, selected: {0, 6}, reverse: false), isNull);
    });
  });

  group('parseConflicts', () {
    const text = 'top\n<<<<<<< HEAD\nmine\n=======\ntheirs 1\ntheirs 2\n>>>>>>> feature\nmiddle\n'
        '<<<<<<< HEAD\nA\n||||||| base\nB\n=======\nC\n>>>>>>> feature\nbottom\n';

    test('splits text and conflict blocks with labels (incl. diff3 base)', () {
      final parsed = parseConflicts(text);
      expect(parsed.conflicts, hasLength(2));
      expect(parsed.conflicts[0].ours, ['mine']);
      expect(parsed.conflicts[0].theirs, ['theirs 1', 'theirs 2']);
      expect(parsed.conflicts[0].oursLabel, 'HEAD');
      expect(parsed.conflicts[0].theirsLabel, 'feature');
      expect(parsed.conflicts[1].base, ['B']);
    });

    test('renders each choice; unresolved keeps markers', () {
      final parsed = parseConflicts(text);
      expect(parsed.render([ConflictChoice.theirs, ConflictChoice.ours]),
          'top\ntheirs 1\ntheirs 2\nmiddle\nA\nbottom\n');
      expect(parsed.render([ConflictChoice.oursThenTheirs, ConflictChoice.theirsThenOurs]),
          'top\nmine\ntheirs 1\ntheirs 2\nmiddle\nC\nA\nbottom\n');
      expect(parsed.render([ConflictChoice.ours, null]), contains('<<<<<<< HEAD\nA\n'));
    });

    test('keeps CRLF line endings and ignores unterminated markers', () {
      final parsed = parseConflicts('a\r\n<<<<<<< HEAD\r\nx\r\n=======\r\ny\r\n>>>>>>> b\r\nz\r\n');
      expect(parsed.render([ConflictChoice.theirs]), 'a\r\ny\r\nz\r\n');
      expect(parseConflicts('<<<<<<< HEAD\nno end\n').conflicts, isEmpty);
    });
  });

  group('GitHub', () {
    test('parseGitHubRemote understands https, ssh and rejects others', () {
      expect(parseGitHubRemote('https://github.com/octo/app.git'), (owner: 'octo', name: 'app'));
      expect(parseGitHubRemote('https://user@github.com/octo/app'), (owner: 'octo', name: 'app'));
      expect(parseGitHubRemote('git@github.com:octo/my.repo.git'), (owner: 'octo', name: 'my.repo'));
      expect(parseGitHubRemote('ssh://git@github.com/octo/app.git'), (owner: 'octo', name: 'app'));
      expect(parseGitHubRemote('https://gitlab.com/octo/app.git'), isNull);
    });

    test('combineCiStates', () {
      expect(combineCiStates([]), CiStatus.none);
      expect(combineCiStates(['success', 'success']), CiStatus.success);
      expect(combineCiStates(['success', 'pending']), CiStatus.pending);
      expect(combineCiStates(['success', 'failure', 'pending']), CiStatus.failure);
      expect(combineCiStates(['skipped', 'neutral']), CiStatus.success);
    });

    Map<String, dynamic> pr(int n) => {
          'number': n,
          'title': 'PR $n',
          'html_url': 'https://github.com/o/r/pull/$n',
          'draft': n == 2,
          'updated_at': '2026-11-19T10:00:00Z',
          'user': {'login': 'octo'},
          'head': {
            'ref': 'feature-$n',
            'sha': 'sha$n',
            'repo': {'full_name': n == 2 ? 'fork/r' : 'o/r'},
          },
          'base': {'ref': 'main'},
        };

    test('lists pull requests and reads CI from statuses + check runs', () async {
      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/repos/o/r/pulls') return http.Response(jsonEncode([pr(1), pr(2)]), 200);
        if (path.endsWith('/status')) {
          return http.Response(jsonEncode({'total_count': 1, 'state': 'success'}), 200);
        }
        if (path.endsWith('/check-runs')) {
          final failing = path.contains('sha2');
          return http.Response(
              jsonEncode({
                'check_runs': [
                  {'status': 'completed', 'conclusion': failing ? 'failure' : 'success'},
                ],
              }),
              200);
        }
        return http.Response('{}', 404);
      });
      final api = GitHubRemoteDataSource(client);

      final pulls = await api.fetchOpenPullRequests('t', 'o', 'r');
      expect(pulls.map((p) => p.number), [1, 2]);
      expect(pulls[1].draft, isTrue);
      expect(pulls[1].headRepoFullName, 'fork/r');
      expect(await api.fetchCiStatus('t', 'o', 'r', 'sha1'), CiStatus.success);
      expect(await api.fetchCiStatus('t', 'o', 'r', 'sha2'), CiStatus.failure);
    });

    test('creates a pull request and surfaces GitHub validation errors', () async {
      late Map<String, dynamic> sent;
      final client = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        if (sent['head'] == 'dup') {
          return http.Response(
              jsonEncode({
                'message': 'Validation Failed',
                'errors': [
                  {'message': 'A pull request already exists for o:dup.'},
                ],
              }),
              422);
        }
        return http.Response(jsonEncode(pr(9)), 201);
      });
      final api = GitHubRemoteDataSource(client);

      final created = await api.createPullRequest('t', 'o', 'r', title: 'T', head: 'feature', base: 'main', draft: true);
      expect(created.number, 9);
      expect(sent, {'title': 'T', 'head': 'feature', 'base': 'main', 'body': '', 'draft': true});

      await expectLater(
        api.createPullRequest('t', 'o', 'r', title: 'T', head: 'dup', base: 'main'),
        throwsA(isA<ServerException>().having((e) => e.message, 'message', contains('already exists'))),
      );
    });
  });

  group('GitHub permission errors', () {
    test('fine-grained token: says which permission is missing and how to add it', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({'message': 'Resource not accessible by personal access token'}),
            403,
            headers: {'x-accepted-github-permissions': 'pull_requests=write'},
          ));
      final api = GitHubRemoteDataSource(client);
      await expectLater(
        api.createPullRequest('github_pat_abc', 'octo', 'demo', title: 'T', head: 'f', base: 'main'),
        throwsA(isA<ServerException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('fine-grained token'),
            contains('Pull requests → Read and write'),
            contains('pull_requests=write'),
            contains('octo/demo'),
            contains('Resource not accessible by personal access token'),
          ),
        )),
      );
    });

    test('classic token: shows its scopes and asks for "repo"', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({'message': 'Resource not accessible by personal access token'}),
            403,
            headers: {'x-oauth-scopes': 'read:user, user:email'},
          ));
      final api = GitHubRemoteDataSource(client);
      await expectLater(
        api.fetchOpenPullRequests('ghp_abc', 'octo', 'demo'),
        throwsA(isA<ServerException>().having(
          (e) => e.message,
          'message',
          allOf(contains('classic token'), contains('"repo" scope'), contains('read:user, user:email')),
        )),
      );
    });

    test('a 404 on a repository is explained as missing access', () async {
      final api = GitHubRemoteDataSource(MockClient((req) async => http.Response('{"message":"Not Found"}', 404)));
      await expectLater(
        api.fetchRepoInfo('github_pat_abc', 'octo', 'private'),
        throwsA(isA<ServerException>().having((e) => e.message, 'message', contains('cannot see it'))),
      );
    });

    test('other 403s on /user still mean an invalid token', () async {
      final api = GitHubRemoteDataSource(MockClient((req) async => http.Response('{"message":"Bad credentials"}', 403)));
      await expectLater(api.fetchAuthenticatedUser('ghp_x'), throwsA(isA<InvalidTokenException>()));
    });
  });

  group('pull request view API', () {
    Map<String, dynamic> detailJson({String state = 'open', bool merged = false}) => {
          'number': 5,
          'title': 'Add login',
          'body': 'Adds the login screen.',
          'state': state,
          'merged': merged,
          'draft': false,
          'html_url': 'https://github.com/o/r/pull/5',
          'user': {'login': 'ana'},
          'head': {
            'ref': 'feature/login',
            'sha': 'abc123',
            'repo': {'full_name': 'o/r'},
          },
          'base': {'ref': 'main'},
          'mergeable': true,
          'mergeable_state': 'clean',
          'commits': 2,
          'additions': 10,
          'deletions': 3,
          'changed_files': 1,
          'created_at': '2026-11-19T10:00:00Z',
        };

    test('loads detail, timeline (comments + reviews in order), commits, files and checks', () async {
      final client = MockClient((req) async {
        final p = req.url.path;
        if (p == '/repos/o/r/pulls/5') return http.Response(jsonEncode(detailJson()), 200);
        if (p == '/repos/o/r/issues/5/comments') {
          return http.Response(
              jsonEncode([
                {'user': {'login': 'bob'}, 'body': 'Looks good', 'created_at': '2026-11-19T12:00:00Z'},
              ]),
              200);
        }
        if (p == '/repos/o/r/pulls/5/reviews') {
          return http.Response(
              jsonEncode([
                {'user': {'login': 'eve'}, 'state': 'CHANGES_REQUESTED', 'body': 'Fix X', 'submitted_at': '2026-11-19T11:00:00Z'},
                {'user': {'login': 'eve'}, 'state': 'PENDING', 'body': '', 'submitted_at': null},
              ]),
              200);
        }
        if (p == '/repos/o/r/pulls/5/commits') {
          return http.Response(
              jsonEncode([
                {'sha': 'c1', 'commit': {'message': 'First\n\nbody', 'author': {'name': 'Ana', 'date': '2026-11-19T09:00:00Z'}}},
              ]),
              200);
        }
        if (p == '/repos/o/r/pulls/5/files') {
          return http.Response(
              jsonEncode([
                {'filename': 'lib/a.dart', 'status': 'modified', 'additions': 1, 'deletions': 1, 'patch': '@@ -1 +1 @@\n-a\n+b'},
              ]),
              200);
        }
        if (p.endsWith('/check-runs')) {
          return http.Response(
              jsonEncode({
                'check_runs': [
                  {'name': 'build', 'status': 'completed', 'conclusion': 'success', 'html_url': 'https://ci/1'},
                  {'name': 'tests', 'status': 'in_progress', 'conclusion': null},
                ],
              }),
              200);
        }
        if (p.endsWith('/status')) return http.Response(jsonEncode({'statuses': []}), 200);
        if (p == '/repos/o/r/pulls/5/comments') return http.Response('[]', 200);
        return http.Response('{}', 404);
      });

      final bundle = await GitHubRemoteDataSource(client).fetchPullRequestBundle('t', 'o', 'r', 5);
      expect(bundle.detail.title, 'Add login');
      expect(bundle.detail.state, PullRequestState.open);
      expect(bundle.detail.mergeability.canMerge, isTrue);
      expect(bundle.timeline.map((e) => e.author), ['eve', 'bob']); // la review pendiente no sale
      expect(bundle.timeline.first.review, ReviewState.changesRequested);
      expect(bundle.commits.single.subject, 'First');
      expect(bundle.files.single.patch, contains('+b'));
      expect(bundle.checks.map((c) => c.status), [CiStatus.success, CiStatus.pending]);
      expect(bundle.ci, CiStatus.pending);
    });

    test('merged and closed states, and mergeability texts', () {
      expect(PullRequestDetail(
        number: 1, title: '', body: '', author: '', state: PullRequestState.open, headRef: 'f', headSha: '',
        headRepoFullName: 'o/r', baseRef: 'main', url: 'https://github.com/o/r/pull/1', mergeableState: 'dirty',
      ).mergeability, (canMerge: false, text: 'Conflicts with main. Check it out, merge or rebase main into it, resolve and push.'));
    });

    test('operations send the right requests', () async {
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add('${req.method} ${req.url.path} ${req.body}');
        if (req.method == 'GET') return http.Response(jsonEncode(detailJson()), 200);
        return http.Response('{}', 200);
      });
      final api = GitHubRemoteDataSource(client);

      await api.pullRequestAction('t', 'o', 'r', 5, const CommentOnPullRequest('Nice'));
      await api.pullRequestAction('t', 'o', 'r', 5, const ReviewPullRequest(ReviewEvent.approve, 'LGTM'));
      await api.pullRequestAction('t', 'o', 'r', 5, const ReviewPullRequest(ReviewEvent.requestChanges, ''));
      await api.pullRequestAction('t', 'o', 'r', 5, const SetPullRequestOpen(false));
      await api.pullRequestAction('t', 'o', 'r', 5, const EditPullRequest('New title', 'New body'));
      await api.pullRequestAction(
          't', 'o', 'r', 5, const MergePullRequest(MergeMethod.squash, title: 'Add login (#5)', deleteBranch: true));

      expect(calls, [
        'POST /repos/o/r/issues/5/comments {"body":"Nice"}',
        'POST /repos/o/r/pulls/5/reviews {"event":"APPROVE","body":"LGTM"}',
        'POST /repos/o/r/pulls/5/reviews {"event":"REQUEST_CHANGES"}',
        'PATCH /repos/o/r/pulls/5 {"state":"closed"}',
        'PATCH /repos/o/r/pulls/5 {"title":"New title","body":"New body"}',
        'GET /repos/o/r/pulls/5 ',
        'PUT /repos/o/r/pulls/5/merge {"merge_method":"squash","commit_title":"Add login (#5)"}',
        'DELETE /repos/o/r/git/refs/heads/feature/login ',
      ]);
    });

    test('GitHub refusing to approve your own PR is shown with its reason', () async {
      final api = GitHubRemoteDataSource(MockClient((req) async => http.Response(
          jsonEncode({
            'message': 'Unprocessable Entity',
            'errors': ['Review Can not approve your own pull request'],
          }),
          422)));
      await expectLater(
        api.pullRequestAction('t', 'o', 'r', 5, const ReviewPullRequest(ReviewEvent.approve)),
        throwsA(isA<ServerException>().having((e) => e.message, 'm', contains('Can not approve your own pull request'))),
      );
    });
  });

  group('review comments on diff lines', () {
    test('are loaded as threads and shown in the conversation with their location', () async {
      final client = MockClient((req) async {
        final p = req.url.path;
        if (p == '/repos/o/r/pulls/5') {
          return http.Response(
              jsonEncode({
                'number': 5,
                'title': 'T',
                'state': 'open',
                'html_url': 'https://github.com/o/r/pull/5',
                'user': {'login': 'ana'},
                'head': {'ref': 'f', 'sha': 'abc', 'repo': {'full_name': 'o/r'}},
                'base': {'ref': 'main'},
              }),
              200);
        }
        if (p == '/repos/o/r/pulls/5/comments') {
          return http.Response(
              jsonEncode([
                {'id': 1, 'user': {'login': 'eve'}, 'body': 'Why 3?', 'path': 'a.dart', 'line': 3, 'side': 'RIGHT',
                  'created_at': '2026-11-19T10:00:00Z'},
                {'id': 2, 'user': {'login': 'ana'}, 'body': 'Retries', 'path': 'a.dart', 'line': 3, 'side': 'RIGHT',
                  'created_at': '2026-11-19T11:00:00Z', 'in_reply_to_id': 1},
                {'id': 3, 'user': {'login': 'bob'}, 'body': 'Old', 'path': 'a.dart', 'line': null, 'side': 'LEFT',
                  'created_at': '2026-11-18T10:00:00Z'},
              ]),
              200);
        }
        if (p.endsWith('/status')) return http.Response('{"statuses":[]}', 200);
        if (p.endsWith('/check-runs')) return http.Response('{"check_runs":[]}', 200);
        return http.Response('[]', 200);
      });
      final bundle = await GitHubRemoteDataSource(client).fetchPullRequestBundle('t', 'o', 'r', 5);
      final threads = bundle.threadsFor('a.dart');
      expect(threads, hasLength(2));
      final live = threads.firstWhere((t) => !t.first.isOutdated);
      expect(live.map((c) => c.body), ['Why 3?', 'Retries']);
      expect(live.first.side, DiffSide.right);
      expect(threads.firstWhere((t) => t.first.isOutdated).first.side, DiffSide.left);
      expect(bundle.timeline.map((e) => e.location), ['a.dart (outdated)', 'a.dart:3']);
    });

    test('new comments and replies send the right payloads', () async {
      final calls = <String>[];
      final api = GitHubRemoteDataSource(MockClient((req) async {
        calls.add('${req.method} ${req.url.path} ${req.body}');
        return http.Response('{}', 201);
      }));
      await api.pullRequestAction('t', 'o', 'r', 5,
          const CommentOnLine(path: 'a.dart', line: 7, side: DiffSide.left, body: 'Hm', commitSha: 'abc'));
      await api.pullRequestAction('t', 'o', 'r', 5, const ReplyToReviewComment(1, 'Done'));
      expect(calls, [
        'POST /repos/o/r/pulls/5/comments {"body":"Hm","commit_id":"abc","path":"a.dart","line":7,"side":"LEFT"}',
        'POST /repos/o/r/pulls/5/comments/1/replies {"body":"Done"}',
      ]);
    });
  });
}
