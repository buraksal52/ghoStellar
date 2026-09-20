import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/data/storage/handoff_inbox.dart';
import 'package:ghostellar_app/features/shared/widgets/app_shell.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

const _chequeId = '01J8F2K9ABCDEFGHJKMNPQRSTV';

Widget _app(FakeChequeApi chequeApi) {
  final router = GoRouter(routes: [
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: [
        GoRoute(path: '/', builder: (context, state) => const SizedBox()),
      ],
    ),
  ]);
  return ProviderScope(
    overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(KeyPair.random())),
      chequeApiProvider.overrideWithValue(chequeApi),
      txApiProvider.overrideWithValue(FakeTxApi()),
      stellarSigningServiceProvider.overrideWithValue(FakeSigning()),
      syncProvider.overrideWith(() => FakeSyncNotifier(const [])),
    ],
    child: MaterialApp.router(
      theme: ThemeData(extensions: [AppColors.light]),
      routerConfig: router,
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('retries a pending offline handoff on first build', (tester) async {
    await HandoffInboxStore().writeAll([
      PendingHandoff(chequeId: _chequeId, from: 'GSENDER', receivedAt: DateTime.utc(2026, 9, 20)),
    ]);
    final chequeApi = FakeChequeApi();

    await tester.pumpWidget(_app(chequeApi));
    await tester.pump();
    await tester.pump();

    expect(chequeApi.claimed, [_chequeId]);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('retries again when the app comes back to the foreground', (tester) async {
    await HandoffInboxStore().writeAll([
      PendingHandoff(chequeId: _chequeId, from: 'GSENDER', receivedAt: DateTime.utc(2026, 9, 20)),
    ]);
    final chequeApi = FakeChequeApi()..claimError = StateError('offline');

    await tester.pumpWidget(_app(chequeApi));
    await tester.pump();
    await tester.pump();
    final attemptsWhileOffline = chequeApi.claimAttempts;
    expect(attemptsWhileOffline, greaterThan(0));

    chequeApi.claimError = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(chequeApi.claimed, [_chequeId]);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('nothing pending: no crash, no stray claim attempt', (tester) async {
    final chequeApi = FakeChequeApi();

    await tester.pumpWidget(_app(chequeApi));
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(chequeApi.claimAttempts, 0);

    await tester.pumpWidget(const SizedBox());
  });
}
