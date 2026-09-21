import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'features/accounts/presentation/pages/accounts_page.dart';

void main() {
  runApp(const ProviderScope(child: GitManagerApp()));
}

class GitManagerApp extends StatelessWidget {
  const GitManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Git Manager',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const AccountsPage(),
    );
  }
}
