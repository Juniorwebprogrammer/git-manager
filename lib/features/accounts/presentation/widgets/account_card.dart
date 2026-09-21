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
    final isDark = theme.brightness == Brightness.dark;
    final connectedColor = isDark ? Colors.green.shade900 : Colors.green.shade50;
    final connectedBorder = isDark ? Colors.green.shade400 : Colors.green.shade400;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: account.isActive ? connectedColor : null,
      shape: account.isActive
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: connectedBorder, width: 1.5),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AccountAvatar(account: account, radius: 32),
                  if (account.isActive)
                    Positioned(
                      bottom: -2,
                      right: -2,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check_circle,
                          size: 18,
                          color: Colors.green.shade600,
                        ),
                      ),
                    ),
                ],
              ),
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
