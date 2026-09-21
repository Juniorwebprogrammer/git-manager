import '../../../../core/error/result.dart';
import '../entities/git_account.dart';
import '../repositories/account_repository.dart';

/// El "ping pong" con GitHub: confirma que el token guardado sigue
/// siendo válido y refresca los datos de perfil de la cuenta.
class TestConnectionUseCase {
  final AccountRepository _repository;

  const TestConnectionUseCase(this._repository);

  Future<Result<GitAccount>> call(String accountId) =>
      _repository.testConnection(accountId);
}
