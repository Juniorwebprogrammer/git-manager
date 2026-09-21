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
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
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
    await tester.tap(find.widgetWithText(FilledButton, 'Probar y añadir'));
    await tester.pumpAndSettle();

    expect(find.byType(AddAccountDialog), findsNothing);
    expect(find.textContaining('Cuenta añadida: octocat'), findsOneWidget);
  });

  testWidgets('con token inválido muestra el error y deja el diálogo abierto', (tester) async {
    when(() => repository.addAccount(any()))
        .thenAnswer((_) async => const Failure(InvalidTokenFailure()));

    await _pumpDialog(tester, repository);

    await tester.enterText(find.byType(TextField), 'tok_malo');
    await tester.tap(find.widgetWithText(FilledButton, 'Probar y añadir'));
    await tester.pumpAndSettle();

    expect(find.byType(AddAccountDialog), findsOneWidget);
    expect(find.text('El token no es válido o no tiene permisos suficientes.'), findsOneWidget);
  });

  testWidgets('no permite enviar el formulario vacío', (tester) async {
    await _pumpDialog(tester, repository);

    await tester.tap(find.widgetWithText(FilledButton, 'Probar y añadir'));
    await tester.pumpAndSettle();

    expect(find.text('Introduce un token de acceso personal.'), findsOneWidget);
    verifyNever(() => repository.addAccount(any()));
  });
}
