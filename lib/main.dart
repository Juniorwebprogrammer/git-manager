import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/settings/app_settings.dart';
import 'core/theme/app_theme.dart';
import 'features/accounts/presentation/pages/accounts_page.dart';

void main() {
  runApp(const ProviderScope(child: GitManagerApp()));
}

class GitManagerApp extends ConsumerWidget {
  const GitManagerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(appSettingsProvider.select((s) => s.themeMode));
    return MaterialApp(
      title: 'Git Manager',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: const AccountsPage(),
    );
  }
}
