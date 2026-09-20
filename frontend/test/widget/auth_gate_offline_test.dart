import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/data/storage/secure_wallet_store.dart';
import 'package:ghostellar_app/data/stellar/offline_account_cache.dart';
import 'package:ghostellar_app/router/auth_gate_page.dart';
import 'package:ghostellar_app/state/auth_providers.dart';
import 'package:ghostellar_app/state/connectivity_providers.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// A store with no plugin channel behind it, so `AuthNotifier.build()`
/// (which reads it directly, not through a fake notifier) doesn't hit a
/// `MissingPluginException` in a widget test.
class _FakeSecureWalletStore extends Fake implements SecureWalletStore {
  _FakeSecureWalletStore({this.accessToken});
  String? accessToken;

  @override
  Future<String?> readAccessToken() async => accessToken;
}

/// A login that fails the way the real [AuthNotifier.login] would on a
/// network outage: caught internally and stored as an [AsyncError], not
/// thrown out of the method (mirrors `AsyncValue.guard` in the real code).
class _NetworkFailAuth extends AuthNotifier {
  @override
  Future<bool> build() async => false;

  @override
  Future<void> login() async {
    state = AsyncError(
      ApiException(code: 'network.error', message: 'offline'),
      StackTrace.empty,
    );
  }
}

/// Deterministic "already authenticated" — avoids racing the real
/// [AuthNotifier.build]'s own async read of the store to decide whether
/// [AuthGatePage] skips `login()`.
class _AlreadyAuthed extends AuthNotifier {
  @override
  Future<bool> build() async => true;
}

class _BadSignatureAuth extends AuthNotifier {
  @override
  Future<bool> build() async => false;

  @override
  Future<void> login() async {
    state = AsyncError(
      ApiException(code: 'auth.invalid_signature', message: 'nope'),
      StackTrace.empty,
    );
  }
}

class _NetworkFailSync extends FakeSyncNotifier {
  _NetworkFailSync() : super(const []);

  @override
  Future<void> refresh() async {
    refreshes++;
    state = AsyncError(
      ApiException(code: 'network.error', message: 'offline'),
      StackTrace.empty,
    );
  }
}

GoRouter _router() => GoRouter(
      initialLocation: '/auth-gate',
      routes: [
        GoRoute(path: '/auth-gate', builder: (_, _) => const AuthGatePage()),
        GoRoute(path: '/home', builder: (_, _) => const Scaffold(body: Text('Home ready'))),
      ],
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a device with a saved session goes straight to the shell in offline mode', (tester) async {
    final router = _router();
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        secureWalletStoreProvider.overrideWithValue(_FakeSecureWalletStore(accessToken: 'tok')),
        authProvider.overrideWith(_AlreadyAuthed.new),
        syncProvider.overrideWith(_NetworkFailSync.new),
      ],
    );
    addTearDown(container.dispose);
    // Resolve both notifiers' build() eagerly, before `_run` calls
    // `refresh()`: otherwise the still-pending initial `build()` can settle
    // right after `refresh()` sets its `AsyncError`, clobbering it back to
    // the successful initial state.
    await container.read(authProvider.future);
    await container.read(syncProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: MaterialApp.router(routerConfig: router, theme: ThemeData(extensions: [AppColors.light]))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Home ready'), findsOneWidget);
    expect(find.textContaining('Could not connect'), findsNothing);
    expect(container.read(offlineModeProvider), isTrue);
  });

  testWidgets('a device with a cached account snapshot (but no saved session) also goes offline', (tester) async {
    await OfflineAccountCache().write(
      OfflineAccountSnapshot(
        accountId: 'GTEST',
        sequence: BigInt.one,
        availableRaw: '1000000',
        decimals: 7,
        fetchedAt: DateTime.utc(2026, 9, 20),
      ),
    );
    final router = _router();
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        secureWalletStoreProvider.overrideWithValue(_FakeSecureWalletStore()),
        authProvider.overrideWith(_NetworkFailAuth.new),
      ],
    );
    addTearDown(container.dispose);
    // Resolve the notifier's build() eagerly: `AuthGatePage._run` reads
    // `authState.value` synchronously, which would otherwise race an
    // async `build()` that hasn't settled yet on the very first frame.
    await container.read(authProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: MaterialApp.router(routerConfig: router, theme: ThemeData(extensions: [AppColors.light]))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Home ready'), findsOneWidget);
    expect(container.read(offlineModeProvider), isTrue);
  });

  testWidgets('a wallet that has never been online still hits the wall, not the shell', (tester) async {
    final router = _router();
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        secureWalletStoreProvider.overrideWithValue(_FakeSecureWalletStore()),
        authProvider.overrideWith(_NetworkFailAuth.new),
      ],
    );
    addTearDown(container.dispose);
    // Resolve the notifier's build() eagerly: `AuthGatePage._run` reads
    // `authState.value` synchronously, which would otherwise race an
    // async `build()` that hasn't settled yet on the very first frame.
    await container.read(authProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: MaterialApp.router(routerConfig: router, theme: ThemeData(extensions: [AppColors.light]))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Home ready'), findsNothing);
    expect(find.textContaining('Could not connect'), findsOneWidget);
    expect(container.read(offlineModeProvider), isFalse);
  });

  testWidgets('a non-network failure hits the wall even with a saved session', (tester) async {
    final router = _router();
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        secureWalletStoreProvider.overrideWithValue(_FakeSecureWalletStore(accessToken: 'tok')),
        authProvider.overrideWith(_BadSignatureAuth.new),
      ],
    );
    addTearDown(container.dispose);
    // `_BadSignatureAuth.build()` returns false, so login() (which fails)
    // always runs before `syncProvider` would even be reached. Resolved
    // eagerly for the same reason as the other cases (see above).
    await container.read(authProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: MaterialApp.router(routerConfig: router, theme: ThemeData(extensions: [AppColors.light]))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Home ready'), findsNothing);
    expect(find.textContaining('Could not connect'), findsOneWidget);
    expect(container.read(offlineModeProvider), isFalse);
  });
}
