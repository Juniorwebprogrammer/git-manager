import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../../core/error/app_exception.dart';
import '../models/git_account_model.dart';

/// Persiste las cuentas (incluido el token) en el almacén seguro nativo
/// del sistema operativo (libsecret en Linux, Keychain en macOS,
/// Credential Manager en Windows).
class AccountLocalDataSource {
  final FlutterSecureStorage _storage;

  const AccountLocalDataSource(this._storage);

  static const _accountsKey = 'github_accounts';

  Future<List<GitAccountModel>> readAccounts() async {
    try {
      final raw = await _storage.read(key: _accountsKey);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => GitAccountModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw StorageException('No se pudieron leer las cuentas guardadas: $e');
    }
  }

  Future<void> writeAccounts(List<GitAccountModel> accounts) async {
    try {
      final raw = jsonEncode(accounts.map((a) => a.toJson()).toList());
      await _storage.write(key: _accountsKey, value: raw);
    } catch (e) {
      throw StorageException('No se pudieron guardar las cuentas: $e');
    }
  }
}
