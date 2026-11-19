import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../../core/error/app_exception.dart';
import '../../../../core/git/git_runner.dart';
import '../../domain/entities/file_change.dart';
import '../../domain/entities/file_diff.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/entities/git_commit.dart';
import '../../domain/entities/repo_snapshot.dart';
import '../parsers/git_parsers.dart';

/// Traduce las operaciones de la app a comandos del binario `git`.
class GitCliDataSource {
  final GitRunner _git;

  const GitCliDataSource(this._git);

  static const _maxFileBytes = 2 * 1024 * 1024;

  Future<String> resolveRoot(String path) async {
    if (!await Directory(path).exists()) {
      throw GitCommandException('The folder "$path" does not exist.');
    }
    final out = await _git.tryRun(['rev-parse', '--show-toplevel'], workingDirectory: path);
    if (!out.ok) throw GitCommandException('"$path" is not a git repository.');
    return p.normalize(out.stdout.trim());
  }

  // ---------------------------------------------------------------- lectura

  Future<RepoSnapshot> snapshot(String path) async {
    final results = await Future.wait([
      _git.run(['status', '--porcelain=v1', '-z', '--untracked-files=all'], workingDirectory: path),
      _git.run(['for-each-ref', '--format=$refFormat', 'refs/heads', 'refs/remotes', 'refs/tags'],
          workingDirectory: path),
      _git.tryRun(['symbolic-ref', '-q', '--short', 'HEAD'], workingDirectory: path)
          .then((o) => o.ok ? o.stdout.trim() : ''),
      _git.tryRun(['rev-parse', '-q', '--verify', 'HEAD'], workingDirectory: path)
          .then((o) => o.ok ? o.stdout.trim() : ''),
      _git.run(['stash', 'list', '--format=%gd%x1f%s'], workingDirectory: path),
      _git.run(['remote'], workingDirectory: path),
      _git.run(['rev-parse', '--absolute-git-dir'], workingDirectory: path),
    ]);

    final status = parseStatus(results[0]);
    final branch = results[2];
    final head = results[3];
    final gitDir = results[6].trim();
    final pending = await _pendingOperation(gitDir);

    return RepoSnapshot(
      path: path,
      currentBranch: branch.isEmpty ? null : branch,
      headSha: head.isEmpty ? null : head,
      refs: parseRefs(results[1]),
      stashes: parseStashes(results[4]),
      remotes: results[5].split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      staged: status.staged,
      unstaged: status.unstaged,
      pendingOperation: pending.operation,
      rebase: pending.rebase,
    );
  }

  Future<({PendingOperation operation, RebaseProgress? rebase})> _pendingOperation(String gitDir) async {
    for (final dir in ['rebase-merge', 'rebase-apply']) {
      final base = p.join(gitDir, dir);
      if (!await Directory(base).exists()) continue;
      Future<String?> read(String name) async {
        final f = File(p.join(base, name));
        return await f.exists() ? (await f.readAsString()).trim() : null;
      }

      final head = await read('head-name');
      final merge = dir == 'rebase-merge';
      return (
        operation: PendingOperation.rebase,
        rebase: RebaseProgress(
          branch: head?.replaceFirst('refs/heads/', ''),
          onto: (await read('onto'))?.substring(0, 7),
          step: int.tryParse(await read(merge ? 'msgnum' : 'next') ?? '') ?? 0,
          total: int.tryParse(await read(merge ? 'end' : 'last') ?? '') ?? 0,
        ),
      );
    }
    if (await File(p.join(gitDir, 'MERGE_HEAD')).exists()) return (operation: PendingOperation.merge, rebase: null);
    if (await File(p.join(gitDir, 'CHERRY_PICK_HEAD')).exists()) {
      return (operation: PendingOperation.cherryPick, rebase: null);
    }
    if (await File(p.join(gitDir, 'REVERT_HEAD')).exists()) return (operation: PendingOperation.revert, rebase: null);
    return (operation: PendingOperation.none, rebase: null);
  }

  Future<List<GitCommit>> history(String path, {required int limit}) async {
    final head = await _git.tryRun(['rev-parse', '-q', '--verify', 'HEAD'], workingDirectory: path);
    final out = await _git.run([
      'log',
      '--decorate=full',
      '--date-order',
      '-n',
      '$limit',
      '--format=$logFormat',
      '--branches',
      '--remotes',
      '--tags',
      if (head.ok) 'HEAD',
    ], workingDirectory: path);
    return parseLog(out);
  }

  Future<GitCommitDetail> commitDetail(String path, String sha) async {
    final header = await _git.run(['show', '-s', '--format=$commitDetailFormat', sha], workingDirectory: path);
    final parentsField = header.split('\x1f')[1];
    final firstParent = parentsField.isEmpty ? null : parentsField.split(' ').first;
    final nameStatus = await _git.run([
      if (firstParent == null) ...['diff-tree', '--root'] else 'diff-tree',
      '-r', '-z', '-M', '--name-status', '--no-commit-id',
      ?firstParent,
      sha,
    ], workingDirectory: path);
    return parseCommitHeader(header, parseNameStatus(nameStatus));
  }

  Future<FileDiff> diff(String path, DiffTarget t) async {
    final paths = ['--', if (t.oldPath != null) t.oldPath!, t.path];

    switch (t.source) {
      case DiffSource.unstaged:
        if (t.untracked) {
          final content = await _readWorkingFile(path, t.path);
          if (content.isBinary) return FileDiff(path: t.path, isBinary: true);
          return allAddedDiff(t.path, content.text);
        }
        final out = await _git.run(['diff', '--no-ext-diff', '-M', ...paths], workingDirectory: path);
        if (out.startsWith('diff --cc')) {
          // Fichero en conflicto: mostramos el fichero con los marcadores.
          final content = await _readWorkingFile(path, t.path);
          return _contextOnlyDiff(t.path, content.text);
        }
        return parseUnifiedDiff(t.path, out);
      case DiffSource.staged:
        final out = await _git.run(['diff', '--cached', '--no-ext-diff', '-M', ...paths], workingDirectory: path);
        return parseUnifiedDiff(t.path, out);
      case DiffSource.commit:
        final out = t.parentSha == null
            ? await _git.run(['diff-tree', '-p', '--no-ext-diff', '-M', '--root', '--no-commit-id', t.commitSha!, ...paths],
                workingDirectory: path)
            : await _git.run(['diff', '--no-ext-diff', '-M', t.parentSha!, t.commitSha!, ...paths],
                workingDirectory: path);
        return parseUnifiedDiff(t.path, out);
    }
  }

  FileDiff _contextOnlyDiff(String path, String text) {
    final lines = text.split('\n');
    return FileDiff(path: path, hunks: [
      DiffHunk('Conflicted file — resolve the markers, then stage it', [
        for (var i = 0; i < lines.length; i++)
          DiffLine(
            lines[i].startsWith('<<<<<<<') || lines[i].startsWith('>>>>>>>') || lines[i].startsWith('=======')
                ? DiffLineType.removed
                : DiffLineType.context,
            lines[i],
            oldNumber: i + 1,
            newNumber: i + 1,
          ),
      ]),
    ]);
  }

  Future<FileContent> fileContent(String path, DiffTarget t) async {
    switch (t.source) {
      case DiffSource.unstaged:
        if (t.deleted) return _showBlob(path, t.path, ':${t.path}');
        return _readWorkingFile(path, t.path);
      case DiffSource.staged:
        if (t.deleted) return _showBlob(path, t.path, 'HEAD:${t.oldPath ?? t.path}');
        return _showBlob(path, t.path, ':${t.path}');
      case DiffSource.commit:
        if (t.deleted && t.parentSha != null) {
          return _showBlob(path, t.path, '${t.parentSha}:${t.oldPath ?? t.path}');
        }
        return _showBlob(path, t.path, '${t.commitSha}:${t.path}');
    }
  }

  Future<FileContent> _showBlob(String repo, String path, String spec) async {
    final out = await _git.run(['show', spec], workingDirectory: repo);
    return _toContent(path, out);
  }

  Future<FileContent> _readWorkingFile(String repo, String relative) async {
    final file = File(p.join(repo, relative));
    if (!await file.exists()) return FileContent(path: relative, text: '');
    final length = await file.length();
    final raf = await file.open();
    try {
      final bytes = await raf.read(length > _maxFileBytes ? _maxFileBytes : length);
      final text = utf8.decode(bytes, allowMalformed: true);
      return _toContent(relative, text, truncated: length > _maxFileBytes);
    } finally {
      await raf.close();
    }
  }

  FileContent _toContent(String path, String text, {bool truncated = false}) {
    final probe = text.length > 8000 ? text.substring(0, 8000) : text;
    if (probe.contains('\x00')) return FileContent(path: path, text: '', isBinary: true);
    if (text.length > _maxFileBytes) {
      return FileContent(path: path, text: text.substring(0, _maxFileBytes), truncated: true);
    }
    return FileContent(path: path, text: text, truncated: truncated);
  }

  // ------------------------------------------------------------- escritura

  Future<void> run(String path, GitAction action, GitIdentity identity) async {
    Future<String> git(List<String> args) => _git.run(args, workingDirectory: path, identity: identity);

    switch (action) {
      case FetchAction():
        await git(['fetch', '--all', '--prune']);
      case PullAction(rebase: true):
        await git(['pull', '--rebase', '--autostash']);
      case PullAction():
        final rebaseConfigured =
            (await _git.tryRun(['config', '--get', 'pull.rebase'], workingDirectory: path)).ok;
        await git(['pull', '--no-edit', if (!rebaseConfigured) '--no-rebase']);
      case RebaseAction(:final onto, :final branch):
        await git(['rebase', '--autostash', onto, ?branch]);
      case ContinueOperationAction():
        final args = switch ((await snapshot(path)).pendingOperation) {
          PendingOperation.merge => ['commit', '--no-edit'],
          PendingOperation.cherryPick => ['cherry-pick', '--continue'],
          PendingOperation.revert => ['revert', '--continue'],
          PendingOperation.rebase => ['rebase', '--continue'],
          PendingOperation.none => null,
        };
        if (args != null) await git(args);
      case SkipOperationAction():
        final args = switch ((await snapshot(path)).pendingOperation) {
          PendingOperation.cherryPick => ['cherry-pick', '--skip'],
          PendingOperation.revert => ['revert', '--skip'],
          PendingOperation.rebase => ['rebase', '--skip'],
          PendingOperation.merge || PendingOperation.none => null,
        };
        if (args != null) await git(args);
      case PushAction(:final branch, :final force):
        await _push(path, identity, branch: branch, force: force);
      case CheckoutAction(:final ref):
        await git(['switch', ref]);
      case CheckoutRemoteAction(:final remoteRef, :final localName):
        final exists = await _git.tryRun(['rev-parse', '-q', '--verify', 'refs/heads/$localName'],
            workingDirectory: path);
        await git(exists.ok ? ['switch', localName] : ['switch', '-c', localName, '--track', remoteRef]);
      case CheckoutDetachedAction(:final sha):
        await git(['switch', '--detach', sha]);
      case CreateBranchAction(:final name, :final startPoint, :final checkout):
        await git([
          if (checkout) ...['switch', '-c'] else 'branch',
          name,
          ?startPoint,
        ]);
      case DeleteBranchAction(:final name, :final force):
        await git(['branch', force ? '-D' : '-d', name]);
      case DeleteRemoteBranchAction(:final remote, :final branch):
        await git(['push', remote, '--delete', branch]);
      case MergeAction(:final ref):
        await git(['merge', '--no-edit', ref]);
      case StashAction(:final message):
        await git(['stash', 'push', '--include-untracked', if (message != null && message.isNotEmpty) ...['-m', message]]);
      case StashPopAction(:final ref):
        await git(['stash', 'pop', ref]);
      case StashApplyAction(:final ref):
        await git(['stash', 'apply', ref]);
      case StashDropAction(:final ref):
        await git(['stash', 'drop', ref]);
      case StageAction(:final paths):
        await git(['add', '-A', '--', ...paths]);
      case StageAllAction():
        await git(['add', '-A']);
      case UnstageAction(:final paths):
        await git(await _hasHead(path)
            ? ['restore', '--staged', '--', ...paths]
            : ['rm', '--cached', '-r', '-q', '--', ...paths]);
      case UnstageAllAction():
        await git(await _hasHead(path) ? ['reset', '-q'] : ['rm', '--cached', '-r', '-q', '.']);
      case DiscardAction(:final changes):
        final untracked = changes.where((c) => c.type == ChangeType.untracked).map((c) => c.path).toList();
        final tracked = changes.where((c) => c.type != ChangeType.untracked).map((c) => c.path).toList();
        if (untracked.isNotEmpty) await git(['clean', '-f', '-q', '--', ...untracked]);
        if (tracked.isNotEmpty) await git(['restore', '--worktree', '--', ...tracked]);
      case CommitAction(:final message, :final amend):
        // Mensaje vacío: se reutiliza el de MERGE_MSG / el commit enmendado.
        await git([
          'commit',
          if (message.trim().isEmpty) '--no-edit' else ...['-m', message],
          if (amend) '--amend',
        ]);
      case CherryPickAction(:final sha):
        await git(['cherry-pick', sha]);
      case RevertAction(:final sha):
        await git(['revert', '--no-edit', sha]);
      case ResetAction(:final sha, :final mode):
        await git(['reset', '--${mode.name}', sha]);
      case CreateTagAction(:final name, :final sha):
        await git(['tag', name, sha]);
      case DeleteTagAction(:final name):
        await git(['tag', '-d', name]);
      case PushTagAction(:final name):
        await git(['push', await _defaultRemote(path), 'refs/tags/$name']);
      case AbortOperationAction():
        final snap = await snapshot(path);
        final sub = switch (snap.pendingOperation) {
          PendingOperation.merge => 'merge',
          PendingOperation.cherryPick => 'cherry-pick',
          PendingOperation.revert => 'revert',
          PendingOperation.rebase => 'rebase',
          PendingOperation.none => null,
        };
        if (sub != null) await git([sub, '--abort']);
    }
  }

  Future<bool> _hasHead(String path) async =>
      (await _git.tryRun(['rev-parse', '-q', '--verify', 'HEAD'], workingDirectory: path)).ok;

  Future<String> _defaultRemote(String path) async {
    final remotes = (await _git.run(['remote'], workingDirectory: path))
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (remotes.isEmpty) throw const GitCommandException('This repository has no remotes.');
    return remotes.contains('origin') ? 'origin' : remotes.first;
  }

  Future<void> _push(String path, GitIdentity identity, {String? branch, bool force = false}) async {
    var name = branch;
    if (name == null) {
      final current = await _git.tryRun(['symbolic-ref', '-q', '--short', 'HEAD'], workingDirectory: path);
      if (!current.ok) throw const GitCommandException('HEAD is detached: check out a branch to push.');
      name = current.stdout.trim();
    }

    final remote = await _git.tryRun(['config', '--get', 'branch.$name.remote'], workingDirectory: path);
    final merge = await _git.tryRun(['config', '--get', 'branch.$name.merge'], workingDirectory: path);
    final forceArgs = force ? ['--force-with-lease'] : <String>[];

    if (remote.ok && merge.ok && remote.stdout.trim() != '.') {
      await _git.run(['push', ...forceArgs, remote.stdout.trim(), '$name:${merge.stdout.trim()}'],
          workingDirectory: path, identity: identity);
    } else {
      await _git.run(['push', ...forceArgs, '-u', await _defaultRemote(path), name],
          workingDirectory: path, identity: identity);
    }
  }

  Future<String> clone(String url, String parentDirectory, GitIdentity identity) async {
    var name = url.split('/').last;
    if (name.endsWith('.git')) name = name.substring(0, name.length - 4);
    final destination = p.join(parentDirectory, name);
    if (await Directory(destination).exists()) {
      throw GitCommandException('"$destination" already exists.');
    }
    await _git.run(['clone', url, destination], workingDirectory: parentDirectory, identity: identity);
    return destination;
  }
}
