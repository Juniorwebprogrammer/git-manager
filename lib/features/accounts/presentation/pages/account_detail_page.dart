import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../repos/presentation/pages/workspace_page.dart';
import '../../domain/entities/git_account.dart';
import '../state/accounts_notifier.dart';
import '../widgets/account_avatar.dart';

class AccountDetailPage extends ConsumerWidget {
  final String accountId;

  const AccountDetailPage({super.key, required this.accountId});

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref, GitAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove account'),
        content: Text('"${account.nameOrLogin}" and its saved token will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final error = await ref.read(accountsNotifierProvider.notifier).remove(account.id);
    if (!context.mounted) return;

    if (error == null) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _connect(BuildContext context, WidgetRef ref, GitAccount account) async {
    final error = await ref.read(accountsNotifierProvider.notifier).connect(account.id);
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    if (error == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Connected as ${account.login}. Git identity and HTTPS '
            'credentials updated.',
          ),
        ),
      );
    } else {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(accountsNotifierProvider);
    final account = state.accounts.where((a) => a.id == accountId).firstOrNull;

    if (account == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This account no longer exists.')),
      );
    }

    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(account.nameOrLogin)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                AccountAvatar(account: account, radius: 56),
                const SizedBox(height: 16),
                Text(account.nameOrLogin, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(
                  '@${account.login}',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.mail_outline),
                        title: const Text('Email'),
                        subtitle: Text(account.email.isEmpty ? '—' : account.email),
                      ),
                      ListTile(
                        leading: const Icon(Icons.open_in_new),
                        title: const Text('GitHub profile'),
                        subtitle: Text(account.profileUrl),
                        onTap: account.profileUrl.isEmpty
                            ? null
                            : () => launchUrl(Uri.parse(account.profileUrl)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => WorkspacePage(accountId: account.id),
                      ),
                    ),
                    icon: const Icon(Icons.account_tree_outlined),
                    label: const Text('Open projects'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: account.isActive
                      ? FilledButton.icon(
                          onPressed: null,
                          icon: const Icon(Icons.check_circle),
                          label: const Text('Connected'),
                        )
                      : FilledButton.icon(
                          onPressed: state.isLoading ? null : () => _connect(context, ref, account),
                          icon: const Icon(Icons.swap_horiz),
                          label: const Text('Connect'),
                        ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () => _confirmRemove(context, ref, account),
                    style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove account'),
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
