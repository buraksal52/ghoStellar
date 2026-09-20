import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/config/pay_asset.dart';
import 'package:ghostellar_app/core/payments/payment_uri.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/data/nfc/nfc_service.dart';
import 'package:ghostellar_app/features/receive/receive_page.dart';
import 'package:ghostellar_app/features/shared/widgets/qr_card.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/tap_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

const _chequeId = '01J8F2K9ABCDEFGHJKMNPQRSTV';

class _Rig {
  _Rig({this.pending = false}) {
    keyPair = KeyPair.random();
  }

  final bool pending;
  late final KeyPair keyPair;
  final nfc = FakeNfc();
  final chequeApi = FakeChequeApi();
  final syncApi = FakeSyncApi();

  late final List<Override> overrides = [
    walletProvider.overrideWith(() => UnlockedWallet(keyPair)),
    nfcServiceProvider.overrideWithValue(nfc),
    chequeApiProvider.overrideWithValue(chequeApi),
    syncApiProvider.overrideWithValue(syncApi),
    txApiProvider.overrideWithValue(FakeTxApi()),
    stellarSigningServiceProvider.overrideWithValue(FakeSigning()),
    syncProvider.overrideWith(
      () => FakeSyncNotifier([
        if (pending) testCheque(_chequeId, keyPair.accountId),
      ]),
    ),
  ];

  Widget _scope(Widget home) => ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: ThemeData(extensions: [AppColors.light]),
      home: home,
    ),
  );

  Widget app() => _scope(
    const Scaffold(
      body: Padding(padding: EdgeInsets.all(20), child: ReceivePage()),
    ),
  );

  /// Same scope (so the container survives), page gone.
  Widget appWithoutPage() => _scope(const Scaffold(body: SizedBox()));
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(ReceivePage)));

Future<void> _open(WidgetTester tester, _Rig rig) async {
  // Tall enough that the whole list is on screen and tappable.
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(rig.app());
  await tester.pump(); // post-frame: session.start()
  await tester.pump();
  await tester.pump(); // baseline resolved
}

/// Leaving the page must stop the session (its poll timer would otherwise
/// outlive the test).
Future<void> _leave(WidgetTester tester, _Rig rig) async {
  await tester.pumpWidget(rig.appWithoutPage());
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('opens a session on entry: NFC ready, request broadcast', (
    tester,
  ) async {
    final rig = _Rig();
    await _open(tester, rig);

    expect(find.text('Ready to Receive'), findsOneWidget);
    expect(rig.nfc.presented, hasLength(1));
    final request = PaymentRequest.tryParse(rig.nfc.presented.single)!;
    expect(request.destination, rig.keyPair.accountId);
    expect(
      request.amount,
      isNull,
      reason: 'no amount typed yet — the sender chooses',
    );
    expect(find.text('Receive'), findsOneWidget);
    expect(find.text('Request an amount (optional)'), findsOneWidget);

    await _leave(tester, rig);
  });

  testWidgets('the QR is offered too, and it is the same request', (
    tester,
  ) async {
    final rig = _Rig();
    await _open(tester, rig);

    expect(find.byType(QrCard), findsNothing);
    expect(find.text('Scan QR Code'), findsNothing);
    // `.first`: the big ring's icon, not the inline "Tap sender's phone" button.
    await tester.tap(find.byIcon(Icons.nfc).first);
    await tester.pumpAndSettle();
    expect(find.text('Scan QR Code'), findsOneWidget);
    expect(find.text('Use this code'), findsOneWidget);
    await tester.tap(find.text('Show QR code'));
    await tester.pump();

    final qr = tester.widget<QrCard>(find.byType(QrCard));
    expect(qr.data, rig.nfc.presented.single);

    await _leave(tester, rig);
  });

  testWidgets('without NFC the receive circle opens the payment QR', (
    tester,
  ) async {
    final rig = _Rig();
    rig.nfc.canBeTag = false;
    rig.nfc.canRead = false;
    await _open(tester, rig);

    expect(find.text('Ready to Receive'), findsOneWidget);
    expect(find.byType(QrCard), findsNothing);
    // `.first`: the big ring's icon, not the inline "Tap sender's phone" button.
    await tester.tap(find.byIcon(Icons.nfc).first);
    await tester.pumpAndSettle();
    expect(find.text('Scan QR Code'), findsOneWidget);
    await tester.tap(find.text('Show QR code'));
    await tester.pump();
    expect(find.byType(QrCard), findsOneWidget);
    expect(rig.nfc.presented, isEmpty);

    await _leave(tester, rig);
  });

  testWidgets(
    'an iPhone gets receive options plus a button to start an NFC read (never automatic)',
    (tester) async {
      final rig = _Rig();
      rig.nfc.canBeTag = false; // reader only
      await _open(tester, rig);

      expect(find.text('Ready to Receive'), findsOneWidget);
      expect(find.byType(QrCard), findsNothing);
      expect(
        rig.nfc.started,
        isEmpty,
        reason: 'Apple wants NFC sessions user-initiated',
      );

      await tester.tap(find.text("Tap sender's phone"));
      await tester.pump();

      expect(rig.nfc.started.single.role, NfcRole.reader);
      expect(
        PaymentRequest.tryParse(rig.nfc.started.single.offer)!.destination,
        rig.keyPair.accountId,
        reason: 'the request we write to their tag',
      );

      await _leave(tester, rig);
    },
  );

  testWidgets(
    'an Android receiver has a read button too — it just shows the wait, '
    'since the tag is already presenting',
    (tester) async {
      final rig = _Rig();
      await _open(tester, rig);

      expect(find.text("Tap sender's phone"), findsOneWidget);
      expect(rig.nfc.started.single.role, NfcRole.tag);

      await tester.tap(find.text("Tap sender's phone"));
      await tester.pump();

      expect(
        find.text('Hold near their phone…'),
        findsOneWidget,
      );
      expect(
        rig.nfc.started,
        hasLength(1),
        reason: 'the tag broadcast is not restarted, only the wait is shown',
      );

      await _leave(tester, rig);
    },
  );

  testWidgets(
    'the NFC read wait times out with "no phone found" and resets the button',
    (tester) async {
      final rig = _Rig();
      rig.nfc.canBeTag = false; // reader only
      await _open(tester, rig);

      await tester.tap(find.text("Tap sender's phone"));
      await tester.pump();
      expect(find.text('Hold near their phone…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 30));

      expect(find.text("Tap sender's phone"), findsOneWidget);
      expect(
        find.text(
          "No phone found. An iPhone can only tap an Android phone — for another iPhone, scan their code.",
        ),
        findsOneWidget,
      );

      await _leave(tester, rig);
    },
  );

  testWidgets(
    'the NFC read shows an error when NFC is off',
    (tester) async {
      final rig = _Rig();
      rig.nfc.canBeTag = false; // reader only
      rig.nfc.startError = StateError('NFC is off');
      await _open(tester, rig);

      await tester.tap(find.text("Tap sender's phone"));
      await tester.pump();

      expect(find.text("Tap sender's phone"), findsOneWidget);
      expect(
        find.text('NFC is turned off or unavailable. Scan their code instead.'),
        findsOneWidget,
      );

      await _leave(tester, rig);
    },
  );

  testWidgets('an iPhone waiting for the cheque can start the second tap', (
    tester,
  ) async {
    final rig = _Rig();
    rig.nfc.canBeTag = false;
    await _open(tester, rig);

    rig.nfc.delivered();
    await tester.pump();
    await tester.pump();

    expect(find.text('Waiting for the payment'), findsOneWidget);
    await tester.tap(find.text("Tap sender's phone"));
    await tester.pump();
    expect(rig.nfc.started, hasLength(1));

    await _leave(tester, rig);
  });

  testWidgets('typing an amount re-issues the request with it (debounced)', (
    tester,
  ) async {
    final rig = _Rig();
    await _open(tester, rig);

    await tester.enterText(find.byType(TextField), '25.50');
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      rig.nfc.presented,
      hasLength(1),
      reason: 'still typing — no restart yet',
    );

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(rig.nfc.presented, hasLength(2));
    expect(PaymentRequest.tryParse(rig.nfc.presented.last)!.amount, '25.50');
    expect(
      find.text('Requesting 25.5 ${PayAsset.configured.label}'),
      findsOneWidget,
    );

    await _leave(tester, rig);
  });

  testWidgets(
    'an invalid amount shows an error and does not touch the request',
    (tester) async {
      final rig = _Rig();
      await _open(tester, rig);

      await tester.enterText(find.byType(TextField), '12abc');
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.text('Enter a valid amount, or leave it empty.'),
        findsOneWidget,
      );
      expect(rig.nfc.presented, hasLength(1));

      await _leave(tester, rig);
    },
  );

  testWidgets('once a sender picks the request up it waits for their cheque', (
    tester,
  ) async {
    final rig = _Rig();
    await _open(tester, rig);

    rig.nfc.delivered();
    await tester.pump();
    await tester.pump();

    expect(find.text('Waiting for the payment'), findsOneWidget);
    expect(find.text('Scan QR Code'), findsNothing);
    expect(
      _container(tester).read(receiveSessionProvider).phase,
      ReceivePhase.awaitingCheque,
    );

    await _leave(tester, rig);
  });

  testWidgets('claiming the handed-over cheque ends in "Payment received"', (
    tester,
  ) async {
    final rig = _Rig();
    await _open(tester, rig);
    final session = _container(tester).read(receiveSessionProvider.notifier);
    final nonce = _container(
      tester,
    ).read(receiveSessionProvider).request!.nonce!;

    await session.acceptHandoff(
      ChequeHandoff(chequeId: _chequeId, from: testSender, nonce: nonce),
    );
    await tester.pump();
    await tester.pump();

    expect(rig.chequeApi.claimed, [_chequeId]);
    expect(find.text('Payment received'), findsOneWidget);
    expect(find.text('New request'), findsOneWidget);

    await tester.tap(find.text('New request'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Ready to Receive'), findsOneWidget);

    await _leave(tester, rig);
  });

  testWidgets('a cheque already waiting is listed and claimable by hand', (
    tester,
  ) async {
    final rig = _Rig(pending: true);
    await _open(tester, rig);

    expect(find.text('25.5 ${PayAsset.configured.label}'), findsOneWidget);
    await tester.tap(find.text('Claim'));
    await tester.pump();
    await tester.pump();

    expect(rig.chequeApi.claimed, [_chequeId]);

    await _leave(tester, rig);
  });

  testWidgets(
    'a cheque that was already waiting is not auto-claimed by the session',
    (tester) async {
      final rig = _Rig(pending: true);
      rig.syncApi.cheques = [testCheque(_chequeId, rig.keyPair.accountId)];
      await _open(tester, rig);

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(rig.chequeApi.claimAttempts, 0);

      await _leave(tester, rig);
    },
  );

  testWidgets('receive options validate and accept a pasted handoff', (
    tester,
  ) async {
    final rig = _Rig();
    await _open(tester, rig);
    final nonce = _container(
      tester,
    ).read(receiveSessionProvider).request!.nonce!;
    // `.first`: the big ring's icon, not the inline "Tap sender's phone" button.
    await tester.tap(find.byIcon(Icons.nfc).first);
    await tester.pumpAndSettle();
    final manual = find.widgetWithText(
      TextField,
      'Or paste sender’s payment code',
    );
    await tester.enterText(manual, 'invalid');
    await tester.tap(find.text('Use this code'));
    await tester.pump();
    expect(
      find.text('Enter a valid payment code from the sender.'),
      findsOneWidget,
    );
    await tester.enterText(
      manual,
      ChequeHandoff(
        chequeId: _chequeId,
        from: testSender,
        nonce: nonce,
      ).toUri(),
    );
    await tester.tap(find.text('Use this code'));
    await tester.pumpAndSettle();
    expect(rig.chequeApi.claimed, [_chequeId]);
    expect(find.text('Payment received'), findsOneWidget);
    expect(find.text('Use this code'), findsNothing);
    await _leave(tester, rig);
  });

  testWidgets('leaving the page ends the session and the radios', (
    tester,
  ) async {
    final rig = _Rig();
    await _open(tester, rig);
    final container = _container(tester);

    await _leave(tester, rig);

    expect(container.read(receiveSessionProvider).phase, ReceivePhase.idle);
    expect(rig.nfc.stops, greaterThan(0));

    final callsAfterLeaving = rig.syncApi.calls;
    await tester.pump(const Duration(seconds: 30));
    expect(
      rig.syncApi.calls,
      callsAfterLeaving,
      reason: 'no polling after leaving',
    );
  });
}
