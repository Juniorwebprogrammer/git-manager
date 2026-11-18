import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/error/result.dart';
import '../../domain/entities/remote_repository.dart';
import 'ui_helpers.dart';

/// Abre un repo local o clona uno de GitHub. Devuelve la ruta a abrir.
Future<String?> showOpenRepoDialog(BuildContext context, String accountId) {
  return showDialog<String>(
    context: context,
    builder: (_) => _OpenRepoDialog(accountId: accountId),
  );
}

class _OpenRepoDialog extends StatelessWidget {
  final String accountId;

  const _OpenRepoDialog({required this.accountId});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 640,
        height: 560,
        child: DefaultTabController(
          length: 2,
          child: Column(
            children: [
              const TabBar(tabs: [
                Tab(icon: Icon(Icons.folder_open), text: 'Open local repository'),
                Tab(icon: Icon(Icons.cloud_download_outlined), text: 'Clone from GitHub'),
              ]),
              Expanded(
                child: TabBarView(children: [
                  const _LocalTab(),
                  _CloneTab(accountId: accountId),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalTab extends StatefulWidget {
  const _LocalTab();

  @override
  State<_LocalTab> createState() => _LocalTabState();
}

class _LocalTabState extends State<_LocalTab> {
  final _path = TextEditingController();

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Open repository');
    if (dir != null && mounted) Navigator.pop(context, dir);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.folder_special_outlined, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('Open a repository that is already on this computer.', style: theme.textTheme.bodyLarge),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _browse,
            icon: const Icon(Icons.folder_open),
            label: const Text('Choose folder…'),
          ),
          const SizedBox(height: 24),
          Row(children: [
            const Expanded(child: Divider()),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('or paste a path', style: theme.textTheme.bodySmall)),
            const Expanded(child: Divider()),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _path,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: Platform.isWindows ? r'C:\Users\me\projects\my-repo' : '/home/me/projects/my-repo',
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: () {
                  if (_path.text.trim().isNotEmpty) Navigator.pop(context, _path.text.trim());
                },
              ),
            ),
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
            },
          ),
        ],
      ),
    );
  }
}

class _CloneTab extends ConsumerStatefulWidget {
  final String accountId;

  const _CloneTab({required this.accountId});

  @override
  ConsumerState<_CloneTab> createState() => _CloneTabState();
}

class _CloneTabState extends ConsumerState<_CloneTab> {
  List<RemoteRepository>? _repos;
  String? _error;
  String _filter = '';
  RemoteRepository? _selected;
  final _url = TextEditingController();
  String? _destination;
  bool _cloning = false;

  @override
  void initState() {
    super.initState();
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    _destination = home;
    _load();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final result = await ref.read(gitRepositoryProvider).listRemoteRepositories(widget.accountId);
    if (!mounted) return;
    setState(() {
      switch (result) {
        case Success(:final value):
          _repos = value;
        case Failure(:final failure):
          _error = failure.message;
      }
    });
  }

  Future<void> _pickDestination() async {
    final dir = await getDirectoryPath(initialDirectory: _destination, confirmButtonText: 'Clone here');
    if (dir != null) setState(() => _destination = dir);
  }

  Future<void> _clone() async {
    final url = _url.text.trim();
    if (url.isEmpty || _destination == null) return;
    setState(() => _cloning = true);
    final result = await ref.read(gitRepositoryProvider).clone(widget.accountId, url, _destination!);
    if (!mounted) return;
    setState(() => _cloning = false);
    switch (result) {
      case Success(:final value):
        Navigator.pop(context, value);
      case Failure(:final failure):
        await showGitError(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repos = _repos
        ?.where((r) => _filter.isEmpty || r.fullName.toLowerCase().contains(_filter.toLowerCase()))
        .toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: 'Search your repositories',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _filter = v),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _error != null
                  ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, textAlign: TextAlign.center)))
                  : repos == null
                      ? const Center(child: CircularProgressIndicator())
                      : repos.isEmpty
                          ? const Center(child: Text('No repositories found.'))
                          : ListView.builder(
                              itemCount: repos.length,
                              itemBuilder: (context, i) {
                                final r = repos[i];
                                return ListTile(
                                  dense: true,
                                  selected: _selected == r,
                                  leading: Icon(r.isPrivate ? Icons.lock_outline : Icons.public, size: 20),
                                  title: Text(r.fullName),
                                  subtitle: r.description.isEmpty
                                      ? null
                                      : Text(r.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  onTap: () => setState(() {
                                    _selected = r;
                                    _url.text = r.cloneUrl;
                                  }),
                                );
                              },
                            ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Repository URL',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.folder_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _destination == null ? 'Choose where to clone' : 'Clone into: $_destination',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              TextButton(onPressed: _cloning ? null : _pickDestination, child: const Text('Change…')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _cloning || _url.text.trim().isEmpty || _destination == null ? null : _clone,
                icon: _cloning
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download),
                label: Text(_cloning ? 'Cloning…' : 'Clone'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
