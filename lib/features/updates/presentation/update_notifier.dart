import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/settings/app_settings.dart';
import '../data/update_service.dart';
import '../domain/app_release.dart';

enum UpdatePhase { idle, checking, upToDate, available, downloading, installing, installed, failed }

class UpdateState {
  final UpdatePhase phase;
  final AppVersion? current;
  final AppRelease? release;

  /// Descarga: de 0 a 1.
  final double progress;
  final String? error;

  /// Se puede instalar desde la app (si no, se abre la página de la release).
  final bool canInstall;

  /// "Más tarde": no mostrar la barra hasta la próxima comprobación.
  final bool hidden;

  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.current,
    this.release,
    this.progress = 0,
    this.error,
    this.canInstall = false,
    this.hidden = false,
  });

  bool get isBusy => phase == UpdatePhase.downloading || phase == UpdatePhase.installing;

  /// La barra de aviso se ve si hay algo que hacer con una versión nueva.
  bool get showBanner =>
      release != null &&
      !hidden &&
      const {UpdatePhase.available, UpdatePhase.downloading, UpdatePhase.installing, UpdatePhase.installed, UpdatePhase.failed}
          .contains(phase);

  UpdateState copyWith({
    UpdatePhase? phase,
    double? progress,
    String? error,
    bool? hidden,
  }) =>
      UpdateState(
        phase: phase ?? this.phase,
        current: current,
        release: release,
        progress: progress ?? this.progress,
        error: error,
        canInstall: canInstall,
        hidden: hidden ?? this.hidden,
      );
}

/// Versión de la app en marcha (la de pubspec.yaml al compilar). `main()`
/// la lee al arrancar; null = desconocida (no se busca nada).
final currentAppVersionProvider = Provider<AppVersion?>((ref) => null);

final updateServiceProvider = Provider<UpdateService>((ref) => UpdateService(client: ref.watch(httpClientProvider)));

/// Cuándo se comprueba: poco después de arrancar y luego cada pocas horas.
final updateScheduleProvider = Provider<({Duration first, Duration every})>(
  (ref) => (first: const Duration(seconds: 8), every: const Duration(hours: 6)),
);

/// Cierra la app (tras abrir la versión nueva).
final appExitProvider = Provider<void Function()>((ref) => () => exit(0));

final updateNotifierProvider = NotifierProvider<UpdateNotifier, UpdateState>(UpdateNotifier.new);

class UpdateNotifier extends Notifier<UpdateState> {
  Timer? _first;
  Timer? _periodic;
  String? _notified;

  @override
  UpdateState build() {
    final schedule = ref.read(updateScheduleProvider);
    void auto() {
      if (ref.read(appSettingsProvider).checkForUpdates) check();
    }

    _first = Timer(schedule.first, auto);
    _periodic = Timer.periodic(schedule.every, (_) => auto());
    ref.onDispose(() {
      _first?.cancel();
      _periodic?.cancel();
    });
    return const UpdateState();
  }

  /// Busca una versión nueva. [manual] (botón "Check now"): muestra los
  /// errores e ignora "omitir esta versión". Devuelve el estado final.
  Future<UpdateState> check({bool manual = false}) async {
    if (state.isBusy || state.phase == UpdatePhase.installed || state.phase == UpdatePhase.checking) return state;
    final before = state;
    state = state.copyWith(phase: UpdatePhase.checking);
    try {
      final service = ref.read(updateServiceProvider);
      final current = ref.read(currentAppVersionProvider);
      final release = await service.latestRelease();
      if (!ref.mounted) return state;
      final settings = ref.read(appSettingsProvider);
      final skipped = AppVersion.parse(settings.skippedVersion);
      if (current == null || release == null || !(release.version > current) || (!manual && skipped == release.version)) {
        state = UpdateState(phase: UpdatePhase.upToDate, current: current);
        return state;
      }
      final canInstall = await service.canInstall();
      if (!ref.mounted) return state;
      state = UpdateState(phase: UpdatePhase.available, current: current, release: release, canInstall: canInstall);

      // Aviso del sistema una vez por versión (si la ventana no está a la vista).
      if (!manual && settings.notifications && _notified != '${release.version}') {
        _notified = '${release.version}';
        await ref.read(systemLauncherProvider).notify(
              'Git Manager ${release.version} is available',
              canInstall ? 'Open Git Manager and click Update to install it.' : 'Open Git Manager to download it.',
            );
      }
    } on UpdateException catch (e) {
      if (!ref.mounted) return state;
      // En segundo plano, sin red o con GitHub limitando: en silencio.
      state = manual
          ? UpdateState(phase: UpdatePhase.failed, current: before.current, error: e.message)
          : before.copyWith(phase: before.phase == UpdatePhase.checking ? UpdatePhase.idle : before.phase);
    }
    return state;
  }

  /// Descarga e instala la versión nueva.
  Future<void> install() async {
    final release = state.release;
    if (release == null || state.isBusy || !state.canInstall) return;
    final service = ref.read(updateServiceProvider);
    state = state.copyWith(phase: UpdatePhase.downloading, progress: 0);
    try {
      final file = await service.download(release, onProgress: (p) {
        if (ref.mounted && state.phase == UpdatePhase.downloading) state = state.copyWith(progress: p);
      });
      if (!ref.mounted) return;
      state = state.copyWith(phase: UpdatePhase.installing);
      await service.install(file);
      if (!ref.mounted) return;
      state = state.copyWith(phase: UpdatePhase.installed);
    } on UpdateException catch (e) {
      if (ref.mounted) state = state.copyWith(phase: UpdatePhase.failed, error: e.message);
    }
  }

  /// Abre la versión instalada y cierra esta.
  Future<void> restart() async {
    await ref.read(updateServiceProvider).launchInstalled();
    ref.read(appExitProvider)();
  }

  void later() => state = state.copyWith(hidden: true);

  void skip() {
    final release = state.release;
    if (release == null) return;
    ref.read(appSettingsProvider.notifier).update((s) => s.copyWith(skippedVersion: '${release.version}'));
    state = state.copyWith(hidden: true);
  }
}
