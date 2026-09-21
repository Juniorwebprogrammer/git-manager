import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:git_manager/core/di/providers.dart';
import 'package:git_manager/core/error/app_failure.dart';
import 'package:git_manager/core/error/result.dart';
import 'package:git_manager/features/accounts/domain/entities/git_account.dart';
import 'package:git_manager/features/accounts/domain/repositories/account_repository.dart';
import 'package:git_manager/features/accounts/presentation/widgets/add_account_dialog.dart';

class _MockAccountRepository extends Mock implements AccountRepository {}

const _newAccount = GitAccount(
  id: '1',
  login: 'octocat',
  displayName: 'The Octocat',
  email: 'octocat@example.com',
  avatarUrl: '',
  profileUrl: '',
);

Future<void> _pumpDialog(WidgetTester tester, AccountRepository repository) async {
  when(() => repository.getAccounts()).thenAnswer((_) async => const Success([]));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [accountRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog(
                context: context,
                builder: (_) => const AddAccountDialog(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  late _MockAccountRepository repository;

  setUp(() {
    repository = _MockAccountRepository();
  });

  testWidgets('con token válido añade la cuenta y cierra el diálogo', (tester) async {
    when(() => repository.addAccount('tok_123'))
        .thenAnswer((_) async => const Success(_newAccount));

    await _pumpDialog(tester, repository);

    await tester.enterText(find.byType(TextField), 'tok_123');
    await tester.tap(find.widgetWithText(FilledButton, 'Test & add'));
    await tester.pumpAndSettle();

    expect(find.byType(AddAccountDialog), findsNothing);
    expect(find.textContaining('Account added: octocat'), findsOneWidget);
  });

  testWidgets('con token inválido muestra el error y deja el diálogo abierto', (tester) async {
    when(() => repository.addAccount(any()))
        .thenAnswer((_) async => const Failure(InvalidTokenFailure()));

    await _pumpDialog(tester, repository);

    await tester.enterText(find.byType(TextField), 'tok_malo');
    await tester.tap(find.widgetWithText(FilledButton, 'Test & add'));
    await tester.pumpAndSettle();

    expect(find.byType(AddAccountDialog), findsOneWidget);
    expect(find.text('The token is invalid or does not have enough permissions.'), findsOneWidget);
  });

  testWidgets('no permite enviar el formulario vacío', (tester) async {
    await _pumpDialog(tester, repository);

    await tester.tap(find.widgetWithText(FilledButton, 'Test & add'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a personal access token.'), findsOneWidget);
    verifyNever(() => repository.addAccount(any()));
  });
}
