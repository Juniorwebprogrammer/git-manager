import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferencias de la app (no por cuenta ni por repo).
class AppSettings {
  final ThemeMode themeMode;

  /// Tamaño de letra del código en diffs, ficheros y blame.
  final double diffFontSize;

  /// Ajustar líneas largas en lugar de desplazarse en horizontal.
  final bool wrapLines;

  /// Diffs ignorando cambios de espacios (`git diff -w`).
  final bool ignoreWhitespace;

  /// Notificación del sistema al terminar push/pull/fetch/clone largos.
  final bool notifications;

  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.diffFontSize = 12.5,
    this.wrapLines = true,
    this.ignoreWhitespace = false,
    this.notifications = true,
  });

  static const minFontSize = 10.0;
  static const maxFontSize = 20.0;

  AppSettings copyWith({
    ThemeMode? themeMode,
    double? diffFontSize,
    bool? wrapLines,
    bool? ignoreWhitespace,
    bool? notifications,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        diffFontSize: (diffFontSize ?? this.diffFontSize).clamp(minFontSize, maxFontSize),
        wrapLines: wrapLines ?? this.wrapLines,
        ignoreWhitespace: ignoreWhitespace ?? this.ignoreWhitespace,
        notifications: notifications ?? this.notifications,
      );

  Map<String, Object> toMap() => {
        'themeMode': themeMode.name,
        'diffFontSize': diffFontSize,
        'wrapLines': wrapLines,
        'ignoreWhitespace': ignoreWhitespace,
        'notifications': notifications,
      };

  factory AppSettings.fromMap(Map<String, Object?> map) {
    const d = AppSettings();
    return d.copyWith(
      themeMode: ThemeMode.values.where((m) => m.name == map['themeMode']).firstOrNull,
      diffFontSize: (map['diffFontSize'] as num?)?.toDouble(),
      wrapLines: map['wrapLines'] as bool?,
      ignoreWhitespace: map['ignoreWhitespace'] as bool?,
      notifications: map['notifications'] as bool?,
    );
  }
}

/// Dónde se guardan los ajustes (en tests, en memoria).
abstract interface class SettingsStore {
  Future<Map<String, Object?>> load();
  Future<void> save(Map<String, Object> values);
}

class PrefsSettingsStore implements SettingsStore {
  static const _prefix = 'settings.';

  @override
  Future<Map<String, Object?>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return {
        for (final key in prefs.getKeys().where((k) => k.startsWith(_prefix)))
          key.substring(_prefix.length): prefs.get(key),
      };
    } catch (_) {
      return const {}; // sin almacenamiento disponible: valores por defecto
    }
  }

  @override
  Future<void> save(Map<String, Object> values) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final e in values.entries) {
        final key = '$_prefix${e.key}';
        switch (e.value) {
          case final bool v:
            await prefs.setBool(key, v);
          case final double v:
            await prefs.setDouble(key, v);
          case final String v:
            await prefs.setString(key, v);
        }
      }
    } catch (_) {
      // No es crítico: en el peor caso no se recuerdan.
    }
  }
}

final settingsStoreProvider = Provider<SettingsStore>((ref) => PrefsSettingsStore());

final appSettingsProvider = NotifierProvider<AppSettingsNotifier, AppSettings>(AppSettingsNotifier.new);

class AppSettingsNotifier extends Notifier<AppSettings> {
  bool _touched = false;

  @override
  AppSettings build() {
    Future.microtask(() async {
      final stored = await ref.read(settingsStoreProvider).load();
      // Si el usuario ya cambió algo mientras cargaba, no se pisa.
      if (ref.mounted && !_touched && stored.isNotEmpty) state = AppSettings.fromMap(stored);
    });
    return const AppSettings();
  }

  void update(AppSettings Function(AppSettings current) change) {
    _touched = true;
    state = change(state);
    ref.read(settingsStoreProvider).save(state.toMap());
  }
}
