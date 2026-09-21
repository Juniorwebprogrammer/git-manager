import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:git_manager/features/accounts/domain/entities/git_account.dart';
import 'package:git_manager/features/accounts/presentation/widgets/account_card.dart';

const _account = GitAccount(
  id: '1',
  login: 'octocat',
  displayName: 'The Octocat',
  email: 'octocat@example.com',
  avatarUrl: '',
  profileUrl: '',
);

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SizedBox(width: 220, height: 220, child: child)),
    );

void main() {
  testWidgets('una cuenta inactiva no tiene tinte verde ni check', (tester) async {
    await tester.pumpWidget(
      _wrap(AccountCard(account: _account, onTap: () {})),
    );

    final card = tester.widget<Card>(find.byType(Card));
    expect(card.color, isNull);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('una cuenta activa se muestra con tarjeta verde y check', (tester) async {
    await tester.pumpWidget(
      _wrap(AccountCard(account: _account.copyWith(isActive: true), onTap: () {})),
    );

    final card = tester.widget<Card>(find.byType(Card));
    expect(card.color, isNotNull);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    // Ya no se usa el chip "Conectada" en banner.
    expect(find.text('Conectada'), findsNothing);
  });

  testWidgets('el tap invoca el callback', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _wrap(AccountCard(account: _account, onTap: () => tapped = true)),
    );

    await tester.tap(find.byType(InkWell));
    expect(tapped, isTrue);
  });
}
