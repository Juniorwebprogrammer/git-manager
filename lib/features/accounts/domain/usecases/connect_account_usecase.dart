import '../../../../core/error/result.dart';
import '../entities/git_account.dart';
import '../repositories/account_repository.dart';

/// Cambia la identidad global de git a la cuenta indicada.
class ConnectAccountUseCase {
  final AccountRepository _repository;

  const ConnectAccountUseCase(this._repository);

  Future<Result<List<GitAccount>>> call(String accountId) =>
      _repository.connectAccount(accountId);
}
