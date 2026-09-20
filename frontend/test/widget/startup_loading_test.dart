import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/data/api/models/cheque_models.dart';
import 'package:ghostellar_app/features/shared/widgets/ghostellar_mascot.dart';
import 'package:ghostellar_app/router/auth_gate_page.dart';
import 'package:ghostellar_app/state/auth_providers.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:go_router/go_router.dart';

import '../support/fakes.dart';

class _DelayedAuth extends AuthNotifier {
  final completed = Completer<void>();

  @override
  Future<bool> build() async => false;

  @override
  Future<void> login() async {
    await completed.future;
    state = const AsyncData(true);
  }
}

class _DelayedSync extends SyncNotifier {
  final completed = Completer<void>();

  @override
  Future<SyncResponse> build() async => syncResponse([]);

  @override
  Future<void> refresh() async {
    await completed.future;
    state = AsyncData(syncResponse([]));
  }
}

void main() {
  testWidgets('keeps mascot and project name throughout slow login and sync', (
    tester,
  ) async {
    final auth = _DelayedAuth();
    final sync = _DelayedSync();
    final router = GoRouter(
      initialLocation: '/auth-gate',
      routes: [
        GoRoute(
          path: '/auth-gate',
          builder: (_, _) => const AuthGatePage(),
        ),
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('Home ready')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(() => auth),
          syncProvider.overrideWith(() => sync),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(GhostellarMascot), findsOneWidget);
    expect(find.text('ghoStellar'), findsOneWidget);
    expect(find.text('Home ready'), findsNothing);

    auth.completed.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(GhostellarMascot), findsOneWidget);
    expect(find.text('ghoStellar'), findsOneWidget);
    expect(find.text('Home ready'), findsNothing);

    sync.completed.complete();
    await tester.pumpAndSettle();
    expect(find.text('Home ready'), findsOneWidget);
    expect(find.byType(GhostellarMascot), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
