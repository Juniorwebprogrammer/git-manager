import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/file_change.dart';
import '../../domain/entities/file_diff.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'staging_panel.dart';
import 'ui_helpers.dart';

/// Panel derecho con el detalle de un commit y sus ficheros cambiados.
class CommitDetailPanel extends ConsumerWidget {
  final RepoHandle repo;

  const CommitDetailPanel({super.key, required this.repo});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(repoNotifierProvider(repo));
    final detail = state.detail;
    final theme = Theme.of(context);

    if (detail == null) {
      return state.detailLoading
          ? const Center(child: CircularProgressIndicator())
          : const Center(child: Text('Could not load the commit.'));
    }

    final notifier = ref.read(repoNotifierProvider(repo).notifier);
    final faded = theme.colorScheme.onSurfaceVariant;
    final open = state.openFile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('commit ', style: theme.textTheme.bodySmall?.copyWith(color: faded)),
                  Text(detail.sha.substring(0, 10), style: monoStyle(context, size: 12)),
                  IconButton(
                    tooltip: 'Copy SHA',
                    visualDensity: VisualDensity.compact,
                    iconSize: 15,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: detail.sha));
                      showToast(context, 'Copied ${detail.sha.substring(0, 7)}');
                    },
                    icon: const Icon(Icons.copy),
                  ),
                ],
              ),
              SelectableText(detail.subject, style: theme.textTheme.titleMedium),
              if (detail.body.isNotEmpty) ...[
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: SelectableText(detail.body, style: theme.textTheme.bodySmall),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  InitialsAvatar(detail.authorName, size: 30),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(detail.authorName, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                        Text('${detail.authorEmail} · ${formatDate(detail.authorDate)}',
                            style: theme.textTheme.bodySmall?.copyWith(color: faded), overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
              if (detail.committerName != detail.authorName)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 40),
                  child: Text('committed by ${detail.committerName}',
                      style: theme.textTheme.bodySmall?.copyWith(color: faded)),
                ),
              if (detail.parents.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(detail.parents.length > 1 ? 'parents' : 'parent',
                        style: theme.textTheme.bodySmall?.copyWith(color: faded)),
                    for (final p in detail.parents)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(p.substring(0, 7), style: monoStyle(context, size: 11.5)),
                        onPressed: () => notifier.selectCommit(p),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Text('${detail.changes.length} file${detail.changes.length == 1 ? '' : 's'} changed',
                  style: theme.textTheme.titleSmall),
              const Spacer(),
              for (final type in [ChangeType.added, ChangeType.modified, ChangeType.deleted])
                if (detail.changes.any((c) => c.type == type))
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Row(children: [
                      ChangeBadge(type),
                      const SizedBox(width: 3),
                      Text('${detail.changes.where((c) => c.type == type).length}', style: theme.textTheme.labelSmall),
                    ]),
                  ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: detail.changes.length,
            itemBuilder: (context, i) {
              final c = detail.changes[i];
              return FileChangeTile(
                change: c,
                selected: open?.source == DiffSource.commit && open?.commitSha == detail.sha && open?.path == c.path,
                onTap: () => notifier.openFile(DiffTarget(
                  source: DiffSource.commit,
                  path: c.path,
                  oldPath: c.oldPath,
                  commitSha: detail.sha,
                  parentSha: detail.parents.isEmpty ? null : detail.parents.first,
                  deleted: c.type == ChangeType.deleted,
                )),
              );
            },
          ),
        ),
      ],
    );
  }
}
