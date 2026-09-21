import 'package:flutter/material.dart';

import '../../domain/entities/git_account.dart';
import 'account_avatar.dart';

class AccountCard extends StatelessWidget {
  final GitAccount account;
  final VoidCallback onTap;

  const AccountCard({super.key, required this.account, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  height: 24,
                  child: account.isActive
                      ? Chip(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                          backgroundColor: theme.colorScheme.primaryContainer,
                          avatar: Icon(
                            Icons.check_circle,
                            size: 14,
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                          label: Text(
                            'Conectada',
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              AccountAvatar(account: account, radius: 32),
              const SizedBox(height: 12),
              Text(
                account.nameOrLogin,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                '@${account.login}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
