import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/settings/app_settings.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/entities/repo_snapshot.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'interactive_rebase_dialog.dart';
import 'pull_request_dialog.dart';
import 'settings_dialog.dart';
import 'ui_helpers.dart';

class PaletteCommand {
  final String title;
  final String group;
  final IconData icon;
  final String? shortcut;
  final Future<void> Function() run;

  const PaletteCommand(this.title, this.group, this.icon, this.run, {this.shortcut});
}

/// Puntuación de [query] contra [text] (menor = mejor; null = no coincide).
/// Cada palabra de la búsqueda debe aparecer, entera o como subsecuencia.
int? paletteScore(String query, String text) {
  final t = text.toLowerCase();
  var score = 0;
  for (final word in query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty)) {
    final at = t.indexOf(word);
    if (at != -1) {
      score += at == 0 || t[at - 1] == ' ' || t[at - 1] == '/' ? 0 : 1;
      continue;
    }
    var i = 0;
    for (final ch in word.split('')) {
      i = t.indexOf(ch, i);
      if (i == -1) return null;
      i++;
    }
    score += 3;
  }
  return score;
}

/// Comandos disponibles ahora: generales y, si hay un repo activo, los suyos.
List<PaletteCommand> buildPaletteCommands(
  BuildContext context,
  WidgetRef ref, {
  RepoHandle? repo,
  required List<String> tabs,
  required void Function(int index) switchTab,
  required Future<void> Function() openRepository,
}) {
  final settings = ref.read(appSettingsProvider.notifier);
  void set(AppSettings Function(AppSettings s) change) => settings.update(change);
  final current = ref.read(appSettingsProvider);

  final commands = <PaletteCommand>[
    PaletteCommand('Open or clone a repository…', 'Workspace', Icons.add, openRepository, shortcut: 'Ctrl+T'),
    for (var i = 0; i < tabs.length; i++)
      PaletteCommand('Switch to ${p.basename(tabs[i])}', 'Tabs', Icons.tab, () async => switchTab(i)),
    PaletteCommand('Settings…', 'App', Icons.settings_outlined, () => showSettingsDialog(context)),
    for (final (mode, label, icon) in [
      (ThemeMode.system, 'System', Icons.brightness_auto),
      (ThemeMode.light, 'Light', Icons.light_mode_outlined),
      (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
    ])
      PaletteCommand('Theme: $label', 'App', icon, () async => set((s) => s.copyWith(themeMode: mode))),
    PaletteCommand(current.wrapLines ? 'Diff: stop wrapping long lines' : 'Diff: wrap long lines', 'App',
        Icons.wrap_text, () async => set((s) => s.copyWith(wrapLines: !s.wrapLines))),
    PaletteCommand(current.ignoreWhitespace ? 'Diff: show whitespace changes' : 'Diff: ignore whitespace changes',
        'App', Icons.space_bar, () async => set((s) => s.copyWith(ignoreWhitespace: !s.ignoreWhitespace))),
    PaletteCommand('Diff: larger font', 'App', Icons.text_increase,
        () async => set((s) => s.copyWith(diffFontSize: s.diffFontSize + 1))),
    PaletteCommand('Diff: smaller font', 'App', Icons.text_decrease,
        () async => set((s) => s.copyWith(diffFontSize: s.diffFontSize - 1))),
  ];
  if (repo == null) return commands;

  final state = ref.read(repoNotifierProvider(repo));
  final notifier = ref.read(repoNotifierProvider(repo).notifier);
  final snapshot = state.snapshot;
  final branch = snapshot?.currentBranch;
  final name = p.basename(repo.path);
  Future<void> run(GitAction action, [String? ok]) => runGitAction(context, ref, repo, action, successMessage: ok);

  commands.addAll([
    PaletteCommand('Fetch all remotes', name, Icons.sync, () => run(const FetchAction(), 'Fetched')),
    PaletteCommand('Pull', name, Icons.cloud_download_outlined, () => run(const PullAction(), 'Pulled')),
    PaletteCommand('Pull (rebase)', name, Icons.low_priority, () => run(const PullAction(rebase: true), 'Pulled')),
    if (branch != null) ...[
      PaletteCommand('Push $branch', name, Icons.cloud_upload_outlined, () => run(const PushAction(), 'Pushed')),
      PaletteCommand('Force push $branch (with lease)', name, Icons.cloud_upload, () async {
        if (await confirmDialog(context,
                title: 'Force push',
                message: 'Overwrite the remote "$branch" with your local branch?',
                confirmLabel: 'Force push',
                destructive: true) &&
            context.mounted) {
          await run(PushAction(force: true), 'Force pushed');
        }
      }),
    ],
    if (state.undoPlan != null)
      PaletteCommand(state.undoPlan!.label, name, Icons.undo, () async {
        final failure = await notifier.undo();
        if (failure != null && context.mounted) await showGitError(context, failure);
      }),
    if (state.redoStack.isNotEmpty)
      PaletteCommand(state.redoStack.last.label, name, Icons.redo, () async {
        final failure = await notifier.redo();
        if (failure != null && context.mounted) await showGitError(context, failure);
      }),
    PaletteCommand('Refresh', name, Icons.refresh, () => notifier.refresh(forceHistory: true), shortcut: 'F5'),
    if (snapshot?.hasChanges ?? false)
      PaletteCommand('Stash changes', name, Icons.archive_outlined, () => run(const StashAction(message: 'WIP'), 'Stashed')),
    if (snapshot?.stashes.isNotEmpty ?? false)
      PaletteCommand('Pop latest stash', name, Icons.unarchive_outlined, () => run(const StashPopAction())),
    PaletteCommand('Create branch…', name, Icons.call_split, () async {
      final branchName = await promptDialog(context, title: 'Create branch', label: 'Branch name', confirmLabel: 'Create');
      if (branchName != null && context.mounted) await run(CreateBranchAction(branchName));
    }),
    if (snapshot?.remotes.isNotEmpty ?? false)
      PaletteCommand('Create pull request…', name, Icons.merge_type, () => showCreatePullRequestDialog(context, ref, repo)),
    PaletteCommand('Open terminal here', name, Icons.terminal,
        () async => ref.read(systemLauncherProvider).openTerminal(repo.path)),
    PaletteCommand('Open repository in VS Code', name, Icons.code,
        () async => ref.read(systemLauncherProvider).openFolderInEditor(repo.path)),
    PaletteCommand('Open folder', name, Icons.folder_open_outlined, () async => launchUrl(Uri.file(repo.path))),
  ]);

  // Ramas: checkout / merge / rebase / comparar.
  for (final r in snapshot?.refs ?? const <GitRef>[]) {
    if (r.kind == RefKind.tag) continue;
    final isCurrent = r.kind == RefKind.local && r.name == branch;
    if (isCurrent) continue;
    final hasLocal = r.kind == RefKind.remote && snapshot!.localBranches.any((l) => l.name == r.nameWithoutRemote);
    if (!hasLocal && !(snapshot?.worktreeBranches.containsKey(r.name) ?? false)) {
      commands.add(PaletteCommand(
        'Checkout ${r.name}',
        'Branches',
        r.kind == RefKind.remote ? Icons.cloud_outlined : Icons.call_split,
        () => run(r.kind == RefKind.remote ? CheckoutRemoteAction(r.name, r.nameWithoutRemote) : CheckoutAction(r.name)),
      ));
    }
    if (branch != null) {
      commands.addAll([
        PaletteCommand('Merge ${r.name} into $branch', 'Branches', Icons.merge, () => run(MergeAction(r.name), 'Merged')),
        PaletteCommand('Rebase $branch onto ${r.name}', 'Branches', Icons.low_priority,
            () => confirmAndRebase(context, ref, repo, onto: r.name, branchLabel: branch)),
        PaletteCommand('Interactive rebase $branch onto ${r.name}…', 'Branches', Icons.reorder,
            () => showInteractiveRebaseDialog(context, ref, repo, base: r.name, baseLabel: r.name, branchLabel: branch)),
        PaletteCommand('Compare ${r.name} with $branch', 'Branches', Icons.compare_arrows,
            () => notifier.compareRevisions(branch, r.name)),
      ]);
    }
  }

  // Pull Requests ya cargadas.
  for (final pr in ref.read(pullRequestsProvider(repo)).value ?? const []) {
    commands.add(PaletteCommand('View PR #${pr.number}: ${pr.title}', 'Pull requests', Icons.merge_type,
        () async => notifier.openPullRequest(pr.number)));
  }

  // Ficheros cambiados: historial, blame, editor.
  final files = {...?snapshot?.unstaged.map((c) => c.path), ...?snapshot?.staged.map((c) => c.path)};
  for (final f in files) {
    commands.addAll([
      PaletteCommand('File history: $f', 'Files', Icons.history, () async => notifier.openHistory(f)),
      PaletteCommand('Blame: $f', 'Files', Icons.person_search_outlined, () async => notifier.openBlame(f)),
      PaletteCommand('Open in editor: $f', 'Files', Icons.code, () => openFileInEditor(context, ref, repo, f)),
    ]);
  }
  return commands;
}

Future<void> showCommandPalette(BuildContext context, List<PaletteCommand> commands) async {
  final chosen = await showDialog<PaletteCommand>(
    context: context,
    barrierColor: Colors.black26,
    builder: (_) => _CommandPalette(commands: commands),
  );
  if (chosen != null) await chosen.run();
}

class _CommandPalette extends StatefulWidget {
  final List<PaletteCommand> commands;

  const _CommandPalette({required this.commands});

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  static const _rowHeight = 44.0;
  final _query = TextEditingController();
  final _scroll = ScrollController();
  int _selected = 0;

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<PaletteCommand> get _results {
    final q = _query.text.trim();
    if (q.isEmpty) return widget.commands;
    final scored = <(int, int, PaletteCommand)>[];
    for (var i = 0; i < widget.commands.length; i++) {
      final c = widget.commands[i];
      final s = paletteScore(q, '${c.title} ${c.group}');
      if (s != null) scored.add((s, i, c));
    }
    scored.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    return [for (final s in scored) s.$3];
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() => _selected = (_selected + delta) % count);
    if (_selected < 0) _selected += count;
    final top = _selected * _rowHeight;
    if (_scroll.hasClients) {
      final view = _scroll.position.viewportDimension;
      if (top < _scroll.offset) {
        _scroll.jumpTo(top);
      } else if (top + _rowHeight > _scroll.offset + view) {
        _scroll.jumpTo(top + _rowHeight - view);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = _results;
    if (_selected >= results.length) _selected = results.isEmpty ? 0 : results.length - 1;

    return Align(
      alignment: const Alignment(0, -0.7),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        elevation: 12,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 640,
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: Focus(
            // Por encima del campo de texto: las flechas mueven la selección.
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
              if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                _move(1, results.length);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                _move(-1, results.length);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.enter && results.isNotEmpty) {
                Navigator.pop(context, results[_selected]);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: TextField(
                    controller: _query,
                    autofocus: true,
                    onChanged: (_) => setState(() => _selected = 0),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Type a command — e.g. "rebase", "checkout feat", "push"',
                    ),
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: results.isEmpty
                      ? const Padding(padding: EdgeInsets.all(20), child: Text('No matching commands'))
                      : ListView.builder(
                          controller: _scroll,
                          shrinkWrap: true,
                          itemExtent: _rowHeight,
                          itemCount: results.length,
                          itemBuilder: (context, i) {
                            final c = results[i];
                            final selected = i == _selected;
                            return Material(
                              color: selected ? theme.colorScheme.primary.withValues(alpha: 0.18) : Colors.transparent,
                              child: InkWell(
                                onTap: () => Navigator.pop(context, c),
                                onHover: (h) {
                                  if (h) setState(() => _selected = i);
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 14),
                                  child: Row(
                                    children: [
                                      Icon(c.icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                      ),
                                      if (c.shortcut != null)
                                        Padding(
                                          padding: const EdgeInsets.only(left: 8),
                                          child: Text(c.shortcut!,
                                              style: monoStyle(context, size: 11, color: theme.colorScheme.onSurfaceVariant)),
                                        ),
                                      const SizedBox(width: 10),
                                      Flexible(
                                        flex: 0,
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(maxWidth: 140),
                                          child: Text(c.group,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.labelSmall
                                                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
