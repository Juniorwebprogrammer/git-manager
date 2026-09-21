import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/accounts_notifier.dart';
import '../widgets/account_card.dart';
import '../widgets/add_account_card.dart';
import '../widgets/add_account_dialog.dart';
import 'account_detail_page.dart';

class AccountsPage extends ConsumerWidget {
  const AccountsPage({super.key});

  void _openAddAccountDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const AddAccountDialog(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(accountsNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cuentas de GitHub'),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: () => ref.read(accountsNotifierProvider.notifier).load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (state.isLoading && !state.hasAccounts) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!state.hasAccounts) {
            return _EmptyState(onAdd: () => _openAddAccountDialog(context));
          }

          return RefreshIndicator(
            onRefresh: () => ref.read(accountsNotifierProvider.notifier).load(),
            child: GridView.builder(
              padding: const EdgeInsets.all(20),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 0.85,
              ),
              itemCount: state.accounts.length + 1,
              itemBuilder: (context, index) {
                if (index == state.accounts.length) {
                  return AddAccountCard(onTap: () => _openAddAccountDialog(context));
                }
                final account = state.accounts[index];
                return AccountCard(
                  account: account,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AccountDetailPage(accountId: account.id),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;

  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_outlined, size: 72, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('Aún no has añadido ninguna cuenta', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Añade tu cuenta personal y la de empresa para\ncambiar entre ellas en un clic.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Añadir cuenta'),
          ),
        ],
      ),
    );
  }
}
