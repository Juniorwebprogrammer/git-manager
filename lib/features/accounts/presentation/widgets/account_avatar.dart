import 'package:flutter/material.dart';

import '../../../../core/utils/avatar_palette.dart';
import '../../domain/entities/git_account.dart';

class AccountAvatar extends StatelessWidget {
  final GitAccount account;
  final double radius;

  const AccountAvatar({super.key, required this.account, this.radius = 28});

  @override
  Widget build(BuildContext context) {
    final color = AvatarPalette.colorFor(account.login);
    final initials = AvatarPalette.initialsFor(account.nameOrLogin);

    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      foregroundColor: Colors.white,
      child: ClipOval(
        child: account.avatarUrl.isEmpty
            ? _InitialsLabel(initials: initials, radius: radius)
            : Image.network(
                account.avatarUrl,
                width: radius * 2,
                height: radius * 2,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) =>
                    progress == null
                        ? child
                        : _InitialsLabel(initials: initials, radius: radius),
                errorBuilder: (_, _, _) =>
                    _InitialsLabel(initials: initials, radius: radius),
              ),
      ),
    );
  }
}

class _InitialsLabel extends StatelessWidget {
  final String initials;
  final double radius;

  const _InitialsLabel({required this.initials, required this.radius});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        initials,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: radius * 0.7,
        ),
      ),
    );
  }
}
