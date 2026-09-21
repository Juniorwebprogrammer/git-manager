import '../../../../core/error/result.dart';
import '../entities/git_account.dart';
import '../repositories/account_repository.dart';

class AddAccountUseCase {
  final AccountRepository _repository;

  const AddAccountUseCase(this._repository);

  Future<Result<GitAccount>> call(String token) =>
      _repository.addAccount(token.trim());
}
