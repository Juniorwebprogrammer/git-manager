import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../domain/entities/git_action.dart';
import '../../domain/entities/repo_extras.dart';
import '../../domain/repositories/git_repository.dart';
import '../state/repo_notifier.dart';
import 'ui_helpers.dart';

/// Configura la firma de commits (GPG o SSH) para este repositorio.
Future<void> showSigningDialog(BuildContext context, WidgetRef ref, RepoHandle repo) async {
  final current = await ref.read(signingConfigProvider(repo).future);
  if (!context.mounted) return;
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _SigningDialog(repo: repo, initial: current),
  );
  if (saved == true) ref.invalidate(signingConfigProvider(repo));
}

class _SigningDialog extends ConsumerStatefulWidget {
  final RepoHandle repo;
  final SigningConfig initial;

  const _SigningDialog({required this.repo, required this.initial});

  @override
  ConsumerState<_SigningDialog> createState() => _SigningDialogState();
}

class _SigningDialogState extends ConsumerState<_SigningDialog> {
  late SigningFormat _format = widget.initial.format;
  late final _key = TextEditingController(text: widget.initial.key);
  late bool _byDefault = widget.initial.signByDefault || !widget.initial.hasKey;
  List<({String key, String label})> _keys = const [];
  bool _globalBroken = false;

  @override
  void initState() {
    super.initState();
    _loadKeys();
    ref.read(signingKeysProvider).globalConfigBroken().then((broken) {
      if (mounted) setState(() => _globalBroken = broken);
    });
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _loadKeys() async {
    final keys = await ref.read(signingKeysProvider).available(_format);
    if (mounted) setState(() => _keys = keys);
  }

  Future<void> _save() async {
    final ok = await runGitAction(
      context,
      ref,
      widget.repo,
      ConfigureSigningAction(format: _format, key: _key.text, signByDefault: _byDefault),
      successMessage: 'Signing settings saved for this repository',
    );
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ssh = _format == SigningFormat.ssh;
    return AlertDialog(
      title: const Row(children: [Icon(Icons.verified_user_outlined), SizedBox(width: 10), Text('Commit signing')]),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_globalBroken) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your global git configuration (~/.gitconfig) has an empty "gpg.format". '
                        'Git refuses to sign any commit until that line is fixed.',
                        style: TextStyle(color: theme.colorScheme.onErrorContainer),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () async {
                            await ref.read(signingKeysProvider).fixGlobalConfig();
                            final still = await ref.read(signingKeysProvider).globalConfigBroken();
                            if (mounted) setState(() => _globalBroken = still);
                          },
                          child: const Text('Remove the empty entries'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                'Signed commits show as "Verified" on GitHub. The settings are saved in this repository only.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              SegmentedButton<SigningFormat>(
                segments: const [
                  ButtonSegment(value: SigningFormat.ssh, label: Text('SSH key'), icon: Icon(Icons.key)),
                  ButtonSegment(value: SigningFormat.gpg, label: Text('GPG key'), icon: Icon(Icons.lock_outline)),
                ],
                selected: {_format},
                onSelectionChanged: (s) {
                  setState(() {
                    _format = s.first;
                    _keys = const [];
                    _key.clear();
                  });
                  _loadKeys();
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _key,
                decoration: InputDecoration(
                  labelText: ssh ? 'Public key file' : 'GPG key ID',
                  hintText: ssh ? '~/.ssh/id_ed25519.pub' : '3AA5C34371567BD2',
                  helperText: ssh
                      ? 'Add the same key on GitHub as a "Signing key" (Settings → SSH and GPG keys).'
                      : 'Upload the public key to GitHub (Settings → SSH and GPG keys).',
                  helperMaxLines: 2,
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (_keys.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final k in _keys)
                      ActionChip(
                        avatar: Icon(ssh ? Icons.key : Icons.lock_outline, size: 16),
                        label: Text(k.label, overflow: TextOverflow.ellipsis),
                        onPressed: () => setState(() => _key.text = k.key),
                      ),
                  ],
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    ssh ? 'No public keys found in ~/.ssh.' : 'No GPG secret keys found (gpg --list-secret-keys).',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _byDefault,
                onChanged: (v) => setState(() => _byDefault = v ?? false),
                title: const Text('Sign every commit in this repository by default'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _key.text.trim().isEmpty ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
