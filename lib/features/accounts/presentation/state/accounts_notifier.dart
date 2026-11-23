import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/error/result.dart';
import '../../domain/entities/git_account.dart';
import 'accounts_state.dart';

final accountsNotifierProvider =
    NotifierProvider<AccountsNotifier, AccountsState>(AccountsNotifier.new);

class AccountsNotifier extends Notifier<AccountsState> {
  @override
  AccountsState build() {
    Future.microtask(load);
    return const AccountsState(isLoading: true);
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    final result = await ref.read(getAccountsUseCaseProvider).call();
    state = result.when(
      success: (accounts) => state.copyWith(accounts: accounts, isLoading: false),
      failure: (failure) => state.copyWith(isLoading: false, errorFailure: failure),
    );
  }

  Future<AppFailure?> connect(String accountId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    final result = await ref.read(connectAccountUseCaseProvider).call(accountId);
    AppFailure? error;
    state = result.when(
      success: (accounts) => state.copyWith(accounts: accounts, isLoading: false),
      failure: (failure) {
        error = failure;
        return state.copyWith(isLoading: false, errorFailure: failure);
      },
    );
    return error;
  }

  Future<AppFailure?> remove(String accountId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    final result = await ref.read(removeAccountUseCaseProvider).call(accountId);
    AppFailure? error;
    state = result.when(
      success: (accounts) => state.copyWith(accounts: accounts, isLoading: false),
      failure: (failure) {
        error = failure;
        return state.copyWith(isLoading: false, errorFailure: failure);
      },
    );
    return error;
  }

  Future<Result<GitAccount>> addAzure(String token, {String? organization}) async {
    final result = await ref.read(addAccountUseCaseProvider).azure(token, organization: organization);
    if (result case Success(:final value)) {
      state = state.copyWith(accounts: [...state.accounts, value]);
    }
    return result;
  }

  Future<Result<GitAccount>> add(String token) async {
    final result = await ref.read(addAccountUseCaseProvider).call(token);
    if (result case Success(:final value)) {
      state = state.copyWith(accounts: [...state.accounts, value]);
    }
    return result;
  }
}
