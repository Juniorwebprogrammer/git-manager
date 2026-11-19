import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/core/error/app_exception.dart';
import 'package:git_manager/features/accounts/data/datasources/github_remote_data_source.dart';
import 'package:git_manager/features/repos/data/parsers/git_parsers.dart';
import 'package:git_manager/features/repos/domain/conflicts/conflict_parser.dart';
import 'package:git_manager/features/repos/domain/entities/pull_request.dart';
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
}
