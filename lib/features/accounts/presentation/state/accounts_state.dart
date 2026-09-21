import '../../../../core/error/app_failure.dart';
import '../../domain/entities/git_account.dart';

class AccountsState {
  final List<GitAccount> accounts;
  final bool isLoading;
  final AppFailure? errorFailure;

  const AccountsState({
    this.accounts = const [],
    this.isLoading = false,
    this.errorFailure,
  });

  bool get hasAccounts => accounts.isNotEmpty;

  AccountsState copyWith({
    List<GitAccount>? accounts,
    bool? isLoading,
    AppFailure? errorFailure,
    bool clearError = false,
  }) {
    return AccountsState(
      accounts: accounts ?? this.accounts,
      isLoading: isLoading ?? this.isLoading,
      errorFailure: clearError ? null : (errorFailure ?? this.errorFailure),
    );
  }
}
