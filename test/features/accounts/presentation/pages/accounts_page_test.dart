import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:git_manager/core/di/providers.dart';
import 'package:git_manager/core/error/result.dart';
import 'package:git_manager/features/accounts/domain/entities/git_account.dart';
import 'package:git_manager/features/accounts/domain/repositories/account_repository.dart';
import 'package:git_manager/features/accounts/presentation/pages/account_detail_page.dart';
import 'package:git_manager/features/accounts/presentation/pages/accounts_page.dart';
import 'package:git_manager/features/accounts/presentation/widgets/add_account_dialog.dart';
import 'package:git_manager/features/repos/domain/repositories/git_repository.dart';
import 'package:git_manager/features/repos/presentation/pages/workspace_page.dart';

class _MockAccountRepository extends Mock implements AccountRepository {}

class _InMemoryWorkspaceRepository implements WorkspaceRepository {
  @override
  Future<({List<String> tabs, int activeIndex})> load(String accountId) async =>
      (tabs: <String>[], activeIndex: 0);

  @override
  Future<void> save(String accountId, List<String> tabs, int activeIndex) async {}
}

const _activeAccount = GitAccount(
  id: '1',
  login: 'personal',
  displayName: 'Personal Account',
  email: 'personal@example.com',
  avatarUrl: '',
  profileUrl: '',
  isActive: true,
);

const _otherAccount = GitAccount(
  id: '2',
  login: 'empresa',
  displayName: 'Work Account',
  email: 'empresa@example.com',
  avatarUrl: '',
  profileUrl: '',
);

Future<void> _pumpAccountsPage(WidgetTester tester, AccountRepository repository) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(repository),
        workspaceRepositoryProvider.overrideWithValue(_InMemoryWorkspaceRepository()),
      ],
      child: const MaterialApp(home: AccountsPage()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late _MockAccountRepository repository;

  setUp(() {
    repository = _MockAccountRepository();
  });

  testWidgets('no muestra un FloatingActionButton (solo la tarjeta de añadir)', (tester) async {
    when(() => repository.getAccounts())
        .thenAnswer((_) async => const Success([_activeAccount, _otherAccount]));

    await _pumpAccountsPage(tester, repository);

    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('muestra una tarjeta por cuenta y la tarjeta de añadir al final', (tester) async {
    when(() => repository.getAccounts())
        .thenAnswer((_) async => const Success([_activeAccount, _otherAccount]));

    await _pumpAccountsPage(tester, repository);

    expect(find.text('Personal Account'), findsOneWidget);
    expect(find.text('Work Account'), findsOneWidget);
    expect(find.text('Add account'), findsOneWidget);
  });

  testWidgets('tocar la tarjeta de añadir abre el diálogo de nueva cuenta', (tester) async {
    when(() => repository.getAccounts())
        .thenAnswer((_) async => const Success([_activeAccount]));

    await _pumpAccountsPage(tester, repository);
    await tester.tap(find.text('Add account'));
    await tester.pumpAndSettle();

    expect(find.byType(AddAccountDialog), findsOneWidget);
  });

  testWidgets('tocar una tarjeta abre los proyectos (workspace) de esa cuenta', (tester) async {
    when(() => repository.getAccounts())
        .thenAnswer((_) async => const Success([_activeAccount]));

    await _pumpAccountsPage(tester, repository);
    await tester.tap(find.text('Personal Account'));
    await tester.pumpAndSettle();

    expect(find.byType(WorkspacePage), findsOneWidget);
    expect(find.text('No projects open'), findsOneWidget);
  });

  testWidgets('el botón de info de la tarjeta navega al detalle de la cuenta', (tester) async {
    when(() => repository.getAccounts())
        .thenAnswer((_) async => const Success([_activeAccount]));

    await _pumpAccountsPage(tester, repository);
    await tester.tap(find.byTooltip('Account details'));
    await tester.pumpAndSettle();

    expect(find.byType(AccountDetailPage), findsOneWidget);
  });
}
