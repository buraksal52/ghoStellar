import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/features/settings/settings_page.dart';
import 'package:ghostellar_app/state/auth_providers.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

const _testnet = 'Test SDF Network ; September 2015';
const _public = 'Public Global Stellar Network ; September 2015';

class _NoOpAuth extends AuthNotifier {
  @override
  Future<bool> build() async => true;
}

Widget _app(FakeAuthApi authApi, {String networkPassphrase = _testnet}) {
  return ProviderScope(
    overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(KeyPair.random())),
      authApiProvider.overrideWithValue(authApi),
      authProvider.overrideWith(_NoOpAuth.new),
      networkPassphraseProvider.overrideWithValue(networkPassphrase),
    ],
    child: MaterialApp(
      theme: ThemeData(extensions: [AppColors.light]),
      home: const Scaffold(body: SettingsPage()),
    ),
  );
}

void main() {
  testWidgets('the fund button is shown on testnet and calls the API', (tester) async {
    final authApi = FakeAuthApi();
    await tester.pumpWidget(_app(authApi));

    expect(find.text('Fund with testnet XLM'), findsOneWidget);

    await tester.tap(find.text('Fund with testnet XLM'));
    await tester.pump();
    await tester.pump();

    expect(authApi.fundCalls, 1);
    expect(find.text('Funded — you can set up USDC or send a payment now.'), findsOneWidget);
  });

  testWidgets('the fund button is hidden on a non-testnet network', (tester) async {
    final authApi = FakeAuthApi();
    await tester.pumpWidget(_app(authApi, networkPassphrase: _public));

    expect(find.text('Fund with testnet XLM'), findsNothing);
    expect(authApi.fundCalls, 0);
  });

  testWidgets('a failed fund attempt shows a friendly retry message', (tester) async {
    final authApi = FakeAuthApi()..fundResult = false;
    await tester.pumpWidget(_app(authApi));

    await tester.tap(find.text('Fund with testnet XLM'));
    await tester.pump();
    await tester.pump();

    expect(find.text("Couldn't fund the account right now. Try again in a moment."), findsOneWidget);
  });

  testWidgets('a thrown exception is treated the same as "not funded"', (tester) async {
    final authApi = FakeAuthApi()..fundError = Exception('network down');
    await tester.pumpWidget(_app(authApi));

    await tester.tap(find.text('Fund with testnet XLM'));
    await tester.pump();
    await tester.pump();

    expect(find.text("Couldn't fund the account right now. Try again in a moment."), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second tap while funding is in flight is ignored', (tester) async {
    final authApi = FakeAuthApi()..fundDelay = const Duration(milliseconds: 200);
    await tester.pumpWidget(_app(authApi));

    await tester.tap(find.text('Fund with testnet XLM'));
    await tester.pump(); // rebuild with the button disabled, still in flight
    await tester.tap(find.text('Fund with testnet XLM'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    expect(authApi.fundCalls, 1);
  });
}
