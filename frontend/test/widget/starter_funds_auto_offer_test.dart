import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/error_copy.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/data/stellar/horizon_read_service.dart';
import 'package:ghostellar_app/data/storage/starter_funds_flag.dart';
import 'package:ghostellar_app/features/shared/widgets/app_shell.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/starter_funds.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

const _testnet = 'Test SDF Network ; September 2015';
const _public = 'Public Global Stellar Network ; September 2015';

/// Horizon being unreachable.
class _DownHorizon extends FakeHorizonReadService {
  @override
  Future<AccountBalances> fetchBalances(String accountId) async => throw Exception('horizon down');
}

Widget _app(
  KeyPair wallet,
  FakeStarterFunds funds, {
  FakeHorizonReadService? horizon,
  String passphrase = _testnet,
}) {
  final router = GoRouter(routes: [
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: [GoRoute(path: '/', builder: (context, state) => const SizedBox())],
    ),
  ]);
  return ProviderScope(
    overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(wallet)),
      chequeApiProvider.overrideWithValue(FakeChequeApi()),
      txApiProvider.overrideWithValue(FakeTxApi()),
      stellarSigningServiceProvider.overrideWithValue(FakeSigning()),
      syncProvider.overrideWith(() => FakeSyncNotifier(const [])),
      networkPassphraseProvider.overrideWithValue(passphrase),
      horizonReadServiceProvider.overrideWithValue(horizon ?? FakeHorizonReadService()),
      starterFundsProvider.overrideWithValue(funds),
    ],
    child: MaterialApp.router(
      theme: ThemeData(extensions: [AppColors.light]),
      routerConfig: router,
    ),
  );
}

Future<void> _open(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

void main() {
  late KeyPair wallet;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    wallet = KeyPair.random();
  });

  testWidgets('a brand-new testnet wallet gets its starter funds automatically, once', (tester) async {
    final funds = FakeStarterFunds();

    await _open(tester, _app(wallet, funds));

    expect(funds.runs, 1);
    expect(await StarterFundsFlag().wasOffered(wallet.accountId), isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the next app start does not offer it again', (tester) async {
    await StarterFundsFlag().markOffered(wallet.accountId);
    final funds = FakeStarterFunds();

    await _open(tester, _app(wallet, funds));

    expect(funds.runs, 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed run is explained and is NOT retried by itself on the next start', (tester) async {
    final funds = FakeStarterFunds()..error = apiError('anchor.deposit_failed');

    await _open(tester, _app(wallet, funds));

    expect(funds.runs, 1);
    expect(find.text(ErrorCopy.forCode('anchor.deposit_failed')), findsOneWidget);

    // Next start: same wallet, flag already written before the failed run.
    await tester.pumpWidget(const SizedBox());
    final again = FakeStarterFunds();
    await _open(tester, _app(wallet, again));
    expect(again.runs, 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a wallet that already holds USDC is left alone', (tester) async {
    final funds = FakeStarterFunds();
    final horizon = FakeHorizonReadService([
      FakeHorizonReadService.fundedBalances(other: {'USDC': '12.0000000'}),
    ]);

    await _open(tester, _app(wallet, funds, horizon: horizon));

    expect(funds.runs, 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('outside testnet nothing is offered and nothing is remembered', (tester) async {
    final funds = FakeStarterFunds();

    await _open(tester, _app(wallet, funds, passphrase: _public));

    expect(funds.runs, 0);
    expect(await StarterFundsFlag().wasOffered(wallet.accountId), isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('if Horizon cannot be reached it is not offered — and not used up, so it can happen next time',
      (tester) async {
    final funds = FakeStarterFunds();

    await _open(tester, _app(wallet, funds, horizon: _DownHorizon()));

    expect(funds.runs, 0);
    expect(await StarterFundsFlag().wasOffered(wallet.accountId), isFalse);

    await tester.pumpWidget(const SizedBox());
  });
}
