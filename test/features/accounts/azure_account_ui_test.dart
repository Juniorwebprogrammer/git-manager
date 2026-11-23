import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_manager/core/di/providers.dart';
import 'package:git_manager/core/error/app_failure.dart';
import 'package:git_manager/core/error/result.dart';
import 'package:git_manager/core/hosting/git_provider.dart';
import 'package:git_manager/features/accounts/domain/entities/git_account.dart';
import 'package:git_manager/features/accounts/domain/repositories/account_repository.dart';
import 'package:git_manager/main.dart';

/// Simula un PAT de Azure limitado a una organización: sin escribirla, falla.
class _FakeAccounts implements AccountRepository {
  final accounts = <GitAccount>[];
  final azureCalls = <(String, String?)>[];

  @override
  Future<Result<List<GitAccount>>> getAccounts() async => Success(List.of(accounts));

  @override
  Future<Result<GitAccount>> addAccount(String token) => throw UnimplementedError();

  @override
  Future<Result<GitAccount>> addAzureAccount(String token, {String? organization}) async {
    azureCalls.add((token, organization));
    if (organization == null || organization.trim().isEmpty) {
      return const Failure(AccountSetupFailure(
          'This token cannot list your organizations. Type the organization (dev.azure.com/<organization>).'));
    }
    final account = GitAccount(
      id: 'az',
      login: 'ana@contoso.com',
      displayName: 'Ana Pérez',
      email: 'ana@contoso.com',
      avatarUrl: '',
      profileUrl: 'https://dev.azure.com/${organization.trim()}',
      provider: GitProvider.azure,
      organizations: [organization.trim()],
    );
    accounts.add(account);
    return Success(account);
  }

  @override
  Future<Result<GitAccount>> testConnection(String accountId) => throw UnimplementedError();

  @override
  Future<Result<List<GitAccount>>> connectAccount(String accountId) => throw UnimplementedError();

  @override
  Future<Result<List<GitAccount>>> removeAccount(String accountId) => throw UnimplementedError();
}

void main() {
  testWidgets('adds an Azure DevOps account, asking for the organization when needed', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final repo = _FakeAccounts();
    await tester.pumpWidget(ProviderScope(
      overrides: [accountRepositoryProvider.overrideWithValue(repo)],
      child: const GitManagerApp(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Add account'));
    await tester.pumpAndSettle();
    // En GitHub solo hay un campo: el token.
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.text('Azure DevOps'));
    await tester.pumpAndSettle();
    expect(find.text('Organization (optional)'), findsOneWidget);
    expect(find.text('Open Azure DevOps to create a token'), findsOneWidget);

    final tokenField = find.widgetWithText(TextField, 'Personal Access Token');
    await tester.enterText(tokenField, '  pat123  ');
    await tester.tap(find.text('Test & add'));
    await tester.pumpAndSettle();

    // El error aparece bajo el campo de organización y el diálogo sigue abierto.
    final orgField = find.widgetWithText(TextField, 'Organization (optional)');
    expect(
      find.descendant(of: orgField, matching: find.textContaining('cannot list your organizations')),
      findsOneWidget,
    );

    await tester.enterText(orgField, 'contoso');
    await tester.tap(find.text('Test & add'));
    await tester.pumpAndSettle();

    expect(repo.azureCalls, [('pat123', null), ('pat123', 'contoso')]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Account added: ana@contoso.com'), findsOneWidget);
    expect(find.text('Ana Pérez'), findsOneWidget);
    expect(find.text('ana@contoso.com · contoso'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
