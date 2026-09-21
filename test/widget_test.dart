import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:git_manager/core/di/providers.dart';
import 'package:git_manager/core/error/result.dart';
import 'package:git_manager/features/accounts/domain/entities/git_account.dart';
import 'package:git_manager/features/accounts/domain/repositories/account_repository.dart';
import 'package:git_manager/main.dart';

class _FakeAccountRepository implements AccountRepository {
  @override
  Future<Result<List<GitAccount>>> getAccounts() async => const Success([]);

  @override
  Future<Result<GitAccount>> addAccount(String token) =>
      throw UnimplementedError();

  @override
  Future<Result<GitAccount>> testConnection(String accountId) =>
      throw UnimplementedError();

  @override
  Future<Result<List<GitAccount>>> connectAccount(String accountId) =>
      throw UnimplementedError();

  @override
  Future<Result<List<GitAccount>>> removeAccount(String accountId) =>
      throw UnimplementedError();
}

void main() {
  testWidgets('Muestra el estado vacío cuando no hay cuentas añadidas', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(_FakeAccountRepository()),
        ],
        child: const GitManagerApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Aún no has añadido ninguna cuenta'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Añadir cuenta'), findsOneWidget);
  });
}
