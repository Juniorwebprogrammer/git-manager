import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/file_change.dart';
import '../../domain/entities/file_diff.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'staging_panel.dart';
import 'ui_helpers.dart';

/// Panel derecho al comparar dos commits/ramas: qué ficheros cambian de
/// la base al destino.
class ComparePanel extends ConsumerWidget {
  final RepoHandle repo;

  const ComparePanel({super.key, required this.repo});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(repoNotifierProvider(repo));
    final compare = state.compare;
    if (compare == null) return const SizedBox.shrink();
    final notifier = ref.read(repoNotifierProvider(repo).notifier);
    final open = state.openFile;

    Widget rev(String label, String value, Color color) => Row(
          children: [
            Container(
              width: 58,
              padding: const EdgeInsets.symmetric(vertical: 2),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12.5)),
            ),
          ],
        );

    final changes = compare.changes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: theme.colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.compare_arrows, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Compare', style: theme.textTheme.titleSmall)),
                  IconButton(
                    tooltip: 'Swap base and target',
                    onPressed: () => notifier.compareRevisions(compare.target, compare.base,
                        baseLabel: compare.targetLabel, targetLabel: compare.baseLabel),
                    icon: const Icon(Icons.swap_vert, size: 20),
                  ),
                  IconButton(tooltip: 'Close comparison', onPressed: notifier.closeCompare, icon: const Icon(Icons.close)),
                ],
              ),
              const SizedBox(height: 4),
              rev('BASE', compare.baseLabel, const Color(0xFFF85149)),
              const SizedBox(height: 4),
              rev('TARGET', compare.targetLabel, const Color(0xFF3FB950)),
              const SizedBox(height: 6),
              Text(
                'Changes needed to go from base to target. Ctrl+click two commits in the graph to compare them.',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Text(
            changes == null
                ? (compare.error == null ? 'Comparing…' : 'Could not compare')
                : changes.isEmpty
                    ? 'No differences'
                    : '${changes.length} file${changes.length == 1 ? '' : 's'} changed',
            style: theme.textTheme.titleSmall,
          ),
        ),
        Expanded(
          child: compare.error != null
              ? Padding(padding: const EdgeInsets.all(14), child: Text(compare.error!.message))
              : changes == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: changes.length,
                      itemBuilder: (context, i) {
                        final c = changes[i];
                        return FileChangeTile(
                          change: c,
                          selected: open?.source == DiffSource.commit && open?.path == c.path && open?.title != null,
                          onSecondaryTapDown: (d) =>
                              showFileMenu(context, ref, repo, c.path, d.globalPosition, revision: compare.target),
                          onTap: () => notifier.openFile(DiffTarget(
                            source: DiffSource.commit,
                            path: c.path,
                            oldPath: c.oldPath,
                            commitSha: compare.target,
                            parentSha: compare.base,
                            deleted: c.type == ChangeType.deleted,
                            title: '${compare.baseLabel} → ${compare.targetLabel}',
                          )),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
