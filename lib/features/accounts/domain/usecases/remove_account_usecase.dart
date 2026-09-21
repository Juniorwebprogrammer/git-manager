import '../../../../core/error/result.dart';
import '../entities/git_account.dart';
import '../repositories/account_repository.dart';

class RemoveAccountUseCase {
  final AccountRepository _repository;

  const RemoveAccountUseCase(this._repository);

  Future<Result<List<GitAccount>>> call(String accountId) =>
      _repository.removeAccount(accountId);
}
