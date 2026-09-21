import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:git_manager/core/di/providers.dart';
import 'package:git_manager/core/error/result.dart';
import 'package:git_manager/features/accounts/domain/entities/git_account.dart';
import 'package:git_manager/features/accounts/domain/repositories/account_repository.dart';
import 'package:git_manager/features/accounts/presentation/pages/account_detail_page.dart';

class _MockAccountRepository extends Mock implements AccountRepository {}

const _account = GitAccount(
  id: '1',
  login: 'personal',
  displayName: 'Cuenta Personal',
  email: 'personal@example.com',
  avatarUrl: '',
  profileUrl: 'https://github.com/personal',
);

Future<void> _pumpDetail(WidgetTester tester, AccountRepository repository) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [accountRepositoryProvider.overrideWithValue(repository)],
      child: const MaterialApp(home: AccountDetailPage(accountId: '1')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late _MockAccountRepository repository;

  setUp(() {
    repository = _MockAccountRepository();
  });

  testWidgets('pulsar Connect llama al repositorio y muestra confirmación', (tester) async {
    when(() => repository.getAccounts()).thenAnswer((_) async => const Success([_account]));
    when(() => repository.connectAccount('1'))
        .thenAnswer((_) async => const Success([GitAccount(
              id: '1',
              login: 'personal',
              displayName: 'Cuenta Personal',
              email: 'personal@example.com',
              avatarUrl: '',
              profileUrl: '',
              isActive: true,
            )]));

    await _pumpDetail(tester, repository);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();

    verify(() => repository.connectAccount('1')).called(1);
    expect(find.textContaining('Conectado como personal'), findsOneWidget);
  });

  testWidgets('cuando la cuenta está activa el botón muestra "Conectada" y está deshabilitado',
      (tester) async {
    when(() => repository.getAccounts()).thenAnswer(
      (_) async => const Success([
        GitAccount(
          id: '1',
          login: 'personal',
          displayName: 'Cuenta Personal',
          email: 'personal@example.com',
          avatarUrl: '',
          profileUrl: '',
          isActive: true,
        ),
      ]),
    );

    await _pumpDetail(tester, repository);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Conectada'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('eliminar cuenta pide confirmación y, al aceptar, llama al repositorio', (
    tester,
  ) async {
    when(() => repository.getAccounts()).thenAnswer((_) async => const Success([_account]));
    when(() => repository.removeAccount('1')).thenAnswer((_) async => const Success([]));

    await _pumpDetail(tester, repository);
    await tester.tap(find.widgetWithText(TextButton, 'Eliminar cuenta'));
    await tester.pumpAndSettle();

    expect(find.text('Se eliminará "Cuenta Personal" y su token guardado.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Eliminar'));
    await tester.pumpAndSettle();

    verify(() => repository.removeAccount('1')).called(1);
  });
}
