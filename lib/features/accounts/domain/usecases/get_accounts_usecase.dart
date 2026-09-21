import '../../../../core/error/result.dart';
import '../entities/git_account.dart';
import '../repositories/account_repository.dart';

class GetAccountsUseCase {
  final AccountRepository _repository;

  const GetAccountsUseCase(this._repository);

  Future<Result<List<GitAccount>>> call() => _repository.getAccounts();
}
