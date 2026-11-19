import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/error/result.dart';
import '../../domain/entities/file_change.dart';
import '../../domain/entities/file_diff.dart';
import '../../domain/entities/repo_extras.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'diff_viewer.dart';
import 'ui_helpers.dart';

/// Historial de un fichero: los commits que lo tocaron (siguiendo
/// renombrados) y, al elegir uno, su diff.
class FileHistoryView extends ConsumerStatefulWidget {
  final RepoHandle repo;
  final String path;

  const FileHistoryView({super.key, required this.repo, required this.path});

  @override
  ConsumerState<FileHistoryView> createState() => _FileHistoryViewState();
}

class _FileHistoryViewState extends ConsumerState<FileHistoryView> {
  late Future<Result<List<FileHistoryEntry>>> _future = _load();

  Future<Result<List<FileHistoryEntry>>> _load() =>
      ref.read(gitRepositoryProvider).loadFileHistory(widget.repo, widget.path);

  @override
  void didUpdateWidget(FileHistoryView old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _future = _load();
  }

  void _open(List<FileHistoryEntry> entries, int i) {
    final e = entries[i];
    final previous = i + 1 < entries.length ? entries[i + 1].path : null;
    ref.read(repoNotifierProvider(widget.repo).notifier).openFile(DiffTarget(
          source: DiffSource.commit,
          path: e.path,
          oldPath: e.change == ChangeType.renamed && previous != e.path ? previous : null,
          commitSha: e.commit.sha,
          parentSha: e.commit.parents.isEmpty ? null : e.commit.parents.first,
          deleted: e.change == ChangeType.deleted,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notifier = ref.read(repoNotifierProvider(widget.repo).notifier);
    final open = ref.watch(repoNotifierProvider(widget.repo).select((s) => s.openFile));

    final header = Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Icon(Icons.history, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('File history', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                Text(widget.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Blame',
            onPressed: () => notifier.openBlame(widget.path),
            icon: const Icon(Icons.person_search_outlined, size: 20),
          ),
          IconButton(
            tooltip: 'Open in editor',
            onPressed: () => openFileInEditor(context, ref, widget.repo, widget.path),
            icon: const Icon(Icons.code, size: 20),
          ),
          IconButton(tooltip: 'Close history', onPressed: notifier.closeHistoryAndBlame, icon: const Icon(Icons.close)),
        ],
      ),
    );

    return FutureBuilder(
      future: _future,
      builder: (context, snap) {
        final result = snap.data;
        Widget body;
        if (result == null) {
          body = const Center(child: CircularProgressIndicator());
        } else if (result case Failure(:final failure)) {
          body = Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(failure.message)));
        } else {
          final entries = (result as Success<List<FileHistoryEntry>>).value;
          final list = entries.isEmpty
              ? const Center(child: Text('This file has no committed history yet.'))
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    final selected = open?.commitSha == e.commit.sha;
                    return Material(
                      color: selected ? theme.colorScheme.primary.withValues(alpha: 0.16) : Colors.transparent,
                      child: InkWell(
                        onTap: () => _open(entries, i),
                        onSecondaryTapDown: (d) =>
                            showFileMenu(context, ref, widget.repo, e.path, d.globalPosition, revision: e.commit.sha),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
                          child: Row(
                            children: [
                              InitialsAvatar(e.commit.authorName, size: 22),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(e.commit.subject,
                                        maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                                    Text(
                                      '${e.commit.authorName} · ${formatDate(e.commit.date)} · ${e.commit.shortSha}'
                                      '${i + 1 < entries.length && entries[i + 1].path != e.path ? ' · renamed from ${entries[i + 1].path}' : ''}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              ChangeBadge(e.change),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
          final diff = open == null
              ? Center(
                  child: Text('Select a commit to see what it changed in this file.',
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                )
              : DiffViewer(repo: widget.repo);
          body = LayoutBuilder(builder: (context, c) {
            // Estrecho: lista arriba y diff debajo.
            if (c.maxWidth < 760) {
              return Column(children: [
                SizedBox(height: c.maxHeight * 0.38, child: list),
                const Divider(height: 1),
                Expanded(child: diff),
              ]);
            }
            return Row(children: [
              SizedBox(width: (c.maxWidth * 0.38).clamp(260.0, 420.0), child: list),
              const VerticalDivider(width: 1),
              Expanded(child: diff),
            ]);
          });
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header, const Divider(height: 1), Expanded(child: body)],
        );
      },
    );
  }
}
