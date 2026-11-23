import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'core/settings/app_settings.dart';
import 'core/theme/app_theme.dart';
import 'features/accounts/presentation/pages/accounts_page.dart';
import 'features/updates/domain/app_release.dart';
import 'features/updates/presentation/update_banner.dart';
import 'features/updates/presentation/update_notifier.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppVersion? version;
  try {
    version = AppVersion.parse((await PackageInfo.fromPlatform()).version);
  } catch (_) {
    version = null; // sin versión no se buscan actualizaciones
  }
  runApp(ProviderScope(
    overrides: [currentAppVersionProvider.overrideWithValue(version)],
    child: const GitManagerApp(),
  ));
}

final _navigatorKey = GlobalKey<NavigatorState>();

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
      navigatorKey: _navigatorKey,
      // Aviso de versión nueva por encima de todas las pantallas.
      builder: (context, child) => UpdateBanner(navigatorKey: _navigatorKey, child: child ?? const SizedBox()),
      home: const AccountsPage(),
    );
  }
}
