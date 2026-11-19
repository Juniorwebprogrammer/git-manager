import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/settings/app_settings.dart';
import 'ui_helpers.dart';

Future<void> showSettingsDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _SettingsDialog());

class _SettingsDialog extends ConsumerWidget {
  const _SettingsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    void set(AppSettings Function(AppSettings s) change) => notifier.update(change);

    Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 6),
          child: Text(title.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 0.8, fontWeight: FontWeight.w700, color: theme.colorScheme.onSurfaceVariant)),
        );

    return AlertDialog(
      title: const Row(children: [Icon(Icons.settings_outlined), SizedBox(width: 10), Text('Settings')]),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              section('Appearance'),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (v) => set((s) => s.copyWith(themeMode: v.first)),
              ),
              section('Code & diffs'),
              Row(
                children: [
                  const Text('Font size'),
                  Expanded(
                    child: Slider(
                      value: settings.diffFontSize,
                      min: AppSettings.minFontSize,
                      max: AppSettings.maxFontSize,
                      divisions: ((AppSettings.maxFontSize - AppSettings.minFontSize) * 2).round(),
                      label: settings.diffFontSize.toStringAsFixed(1),
                      onChanged: (v) => set((s) => s.copyWith(diffFontSize: v)),
                    ),
                  ),
                  SizedBox(width: 36, child: Text(settings.diffFontSize.toStringAsFixed(1))),
                ],
              ),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Text('final greeting = "hello world"; // preview',
                    style: monoStyle(context, size: settings.diffFontSize)),
              ),
              SwitchListTile(
                value: settings.wrapLines,
                onChanged: (v) => set((s) => s.copyWith(wrapLines: v)),
                title: const Text('Wrap long lines'),
                subtitle: const Text('Off: scroll horizontally instead'),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
              SwitchListTile(
                value: settings.ignoreWhitespace,
                onChanged: (v) => set((s) => s.copyWith(ignoreWhitespace: v)),
                title: const Text('Ignore whitespace changes in diffs'),
                subtitle: const Text('Like "git diff -w". Staging by hunk or line is disabled while on.'),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
              section('Notifications'),
              SwitchListTile(
                value: settings.notifications,
                onChanged: (v) => set((s) => s.copyWith(notifications: v)),
                title: const Text('Notify when push, pull, fetch or clone finish'),
                subtitle: const Text('Only for slow operations, or when the window is in the background'),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final ok = await ref.read(systemLauncherProvider).notify('Git Manager', 'Notifications are working');
                    if (!ok && context.mounted) {
                      showToast(context, 'No notification service found (on Linux, install libnotify-bin)');
                    }
                  },
                  icon: const Icon(Icons.notifications_active_outlined, size: 18),
                  label: const Text('Send a test notification'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }
}
