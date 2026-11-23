import '../../../../core/error/result.dart';
import '../entities/git_account.dart';
import '../repositories/account_repository.dart';

class AddAccountUseCase {
  final AccountRepository _repository;

  const AddAccountUseCase(this._repository);

  Future<Result<GitAccount>> call(String token) =>
      _repository.addAccount(token.trim());

  Future<Result<GitAccount>> azure(String token, {String? organization}) => _repository.addAzureAccount(
        token.trim(),
        organization: organization?.trim().isEmpty ?? true ? null : organization!.trim(),
      );
}
