import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Guarda qué repos (pestañas) tiene abiertos cada cuenta.
class WorkspaceLocalDataSource {
  final FlutterSecureStorage _storage;

  const WorkspaceLocalDataSource(this._storage);

  String _key(String accountId) => 'workspace_$accountId';

  Future<({List<String> tabs, int activeIndex})> read(String accountId) async {
    try {
      final raw = await _storage.read(key: _key(accountId));
      if (raw == null || raw.isEmpty) return (tabs: <String>[], activeIndex: 0);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final tabs = (json['tabs'] as List<dynamic>? ?? const []).cast<String>();
      final active = json['active'] as int? ?? 0;
      return (tabs: tabs, activeIndex: active.clamp(0, tabs.isEmpty ? 0 : tabs.length - 1));
    } catch (_) {
      return (tabs: <String>[], activeIndex: 0);
    }
  }

  Future<void> write(String accountId, List<String> tabs, int activeIndex) async {
    try {
      await _storage.write(
        key: _key(accountId),
        value: jsonEncode({'tabs': tabs, 'active': activeIndex}),
      );
    } catch (_) {
      // No es crítico: en el peor caso no se recuerdan las pestañas.
    }
  }
}
