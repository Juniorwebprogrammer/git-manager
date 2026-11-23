import '../../../../core/error/result.dart';
import '../entities/git_account.dart';

/// Contrato que la capa de datos implementa para gestionar cuentas de
/// GitHub y su identidad activa en el sistema.
abstract interface class AccountRepository {
  Future<Result<List<GitAccount>>> getAccounts();

  /// Valida el [token] contra la API de GitHub y, si es correcto,
  /// persiste la nueva cuenta.
  Future<Result<GitAccount>> addAccount(String token);

  /// Valida un PAT de Azure DevOps, obtiene el perfil y las organizaciones
  /// (o comprueba [organization] si se indica) y guarda la cuenta.
  Future<Result<GitAccount>> addAzureAccount(String token, {String? organization});

  /// Vuelve a comprobar contra GitHub que el token de la cuenta sigue
  /// siendo válido, refrescando sus datos de perfil.
  Future<Result<GitAccount>> testConnection(String accountId);

  /// Marca [accountId] como activa y actualiza el `user.name` /
  /// `user.email` globales de git en el sistema.
  Future<Result<List<GitAccount>>> connectAccount(String accountId);

  Future<Result<List<GitAccount>>> removeAccount(String accountId);
}
