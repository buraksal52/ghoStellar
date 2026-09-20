import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/payments/payment_uri.dart';
import 'package:ghostellar_app/core/config/pay_asset.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/data/api/models/cheque_models.dart';
import 'package:ghostellar_app/data/nfc/nfc_service.dart';
import 'package:ghostellar_app/data/storage/offline_payment_store.dart';
import 'package:ghostellar_app/data/stellar/offline_account_cache.dart';
import 'package:ghostellar_app/data/stellar/offline_payment_verifier.dart';
import 'package:ghostellar_app/features/send/send_page.dart';
import 'package:ghostellar_app/features/shared/widgets/qr_card.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/offline_providers.dart';
import 'package:ghostellar_app/state/signing_overlay_provider.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/tap_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

const _receiver = 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5';
const _chequeId = '01J8F2K9ABCDEFGHJKMNPQRSTV';

class _Rig {
  _Rig({this.alreadySent});

  /// Cheques the server already lists for this wallet, built from its address.
  final List<Cheque> Function(String me)? alreadySent;

  final keyPair = KeyPair.random();
  final nfc = FakeNfc();
  final chequeApi = FakeChequeApi();
  DateTime now = DateTime.utc(2026, 9, 20, 12);

  List<Override> get overrides => [
    walletProvider.overrideWith(() => UnlockedWallet(keyPair)),
    nfcServiceProvider.overrideWithValue(nfc),
    chequeApiProvider.overrideWithValue(chequeApi),
    txApiProvider.overrideWithValue(FakeTxApi()),
    stellarSigningServiceProvider.overrideWithValue(FakeSigning()),
    syncProvider.overrideWith(
      () => FakeSyncNotifier(alreadySent?.call(keyPair.accountId) ?? const []),
    ),
    clockProvider.overrideWithValue(() => now),
  ];

  Widget app() => ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: ThemeData(extensions: [AppColors.light]),
      home: const Scaffold(
        body: Padding(padding: EdgeInsets.all(20), child: SendPage()),
      ),
    ),
  );
}

Finder get _pasteField => find.byWidgetPredicate(
  (w) =>
      w is TextField && (w.decoration?.hintText ?? '').startsWith('Or paste'),
);

Finder get _amountField => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == '0.00',
);

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(SendPage)));

Future<void> _pasteRecipient(WidgetTester tester, String text) async {
  await tester.tap(find.text('Tap to choose recipient'));
  await tester.pumpAndSettle();
  await tester.enterText(_pasteField, text);
  await tester.tap(find.text('Use this address'));
  await tester.pumpAndSettle();
}

String _link({String? amount, String? nonce, int? exp}) {
  final q = <String, String>{
    'destination': _receiver,
    'amount': ?amount,
    'asset_code': PayAsset.configured.code,
    if (!PayAsset.configured.isNative)
      'asset_issuer': PayAsset.configured.issuer!,
    'x_req': ?nonce,
    if (exp != null) 'x_exp': '$exp',
  };
  return Uri(scheme: 'web+stellar', path: 'pay', queryParameters: q).toString();
}

/// Taps the send arrow and lets the four fake API calls (all microtasks) run.
Future<void> _send(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.north_rounded).last);
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('send options show and hide the wallet QR', (tester) async {
    final rig = _Rig();
    rig.nfc.canRead = false;
    rig.nfc.canBeTag = false;
    await tester.pumpWidget(rig.app());
    final address = _container(tester).read(walletProvider).publicKey;
    await tester.tap(find.byIcon(Icons.nfc));
    await tester.pumpAndSettle();
    expect(find.text('Scan QR Code'), findsOneWidget);
    await tester.tap(find.text('Show QR code'));
    await tester.pumpAndSettle();
    expect(tester.widget<QrCard>(find.byType(QrCard)).data, address);
    expect(find.text('Your wallet address'), findsOneWidget);
    await tester.tap(find.text('Hide QR code'));
    await tester.pumpAndSettle();
    expect(find.byType(QrCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('choosing a recipient', () {
    testWidgets('a bare address still works and leaves the amount editable', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());

      await _pasteRecipient(tester, _receiver);

      expect(find.text('to GBBD...FLA5'), findsOneWidget);
      expect(tester.widget<TextField>(_amountField).readOnly, isFalse);
      expect(find.text('They asked for this amount.'), findsNothing);
    });

    testWidgets('a request with an amount fixes it until "Change"', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());

      await _pasteRecipient(tester, _link(amount: '25.50'));

      expect(tester.widget<TextField>(_amountField).controller!.text, '25.50');
      expect(tester.widget<TextField>(_amountField).readOnly, isTrue);
      expect(find.text('They asked for this amount.'), findsOneWidget);

      await tester.tap(find.text('Change'));
      await tester.pump();

      expect(tester.widget<TextField>(_amountField).readOnly, isFalse);
    });

    testWidgets('an expired request is refused with its own message', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());
      final past =
          rig.now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/
          1000;

      await _pasteRecipient(tester, _link(amount: '5', nonce: 'n1', exp: past));

      expect(find.textContaining('has expired'), findsOneWidget);
    });

    testWidgets(
      'a request the server already has my cheque for is refused (from /sync)',
      (tester) async {
        final rig = _Rig(
          alreadySent: (me) => [
            testCheque(
              '01AAAAAAAAAAAAAAAAAAAAAAAA',
              _receiver,
              sender: me,
              requestId: 'n1',
            ),
          ],
        );
        await tester.pumpWidget(rig.app());
        await tester.pump(); // let /sync resolve

        await _pasteRecipient(tester, _link(nonce: 'n1'));

        expect(find.text('You already paid this request.'), findsOneWidget);
      },
    );

    testWidgets('a different request from the same receiver is not refused', (
      tester,
    ) async {
      final rig = _Rig(
        alreadySent: (me) => [
          testCheque(
            '01AAAAAAAAAAAAAAAAAAAAAAAA',
            _receiver,
            sender: me,
            requestId: 'n1',
          ),
        ],
      );
      await tester.pumpWidget(rig.app());
      await tester.pump();

      await _pasteRecipient(tester, _link(nonce: 'n2'));

      expect(find.text('You already paid this request.'), findsNothing);
      expect(find.text('to GBBD...FLA5'), findsOneWidget);
    });

    testWidgets('garbage gets the address hint', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());

      await _pasteRecipient(tester, 'https://example.com');

      expect(
        find.textContaining('Enter a valid Stellar address'),
        findsOneWidget,
      );
    });

    testWidgets('a secret seed is never accepted as a recipient', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());

      await _pasteRecipient(tester, 'S${_receiver.substring(1)}');

      expect(
        find.textContaining('Enter a valid Stellar address'),
        findsOneWidget,
      );
    });
  });

  group('NFC entry', () {
    testWidgets(
      'the circle opens the sheet already listening; a tap picks the recipient',
      (tester) async {
        final rig = _Rig();
        await tester.pumpWidget(rig.app());

        await tester.tap(find.byIcon(Icons.nfc));
        // Not pumpAndSettle: the scanning spinner animates for as long as it listens.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        // Android sender reads the receiver's continuously presented HCE tag.
        expect(rig.nfc.started.single.role, NfcRole.reader);
        expect(rig.nfc.started.single.offer, isNull);
        expect(find.text('Hold near their phone…'), findsOneWidget);

        rig.nfc.receive(_link(amount: '7.25', nonce: 'nfc-1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('to GBBD...FLA5'), findsOneWidget);
        expect(tester.widget<TextField>(_amountField).controller!.text, '7.25');
      },
    );

    testWidgets(
      'without NFC the circle opens the sheet and offers no tap button',
      (tester) async {
        final rig = _Rig();
        rig.nfc.canRead = false;
        rig.nfc.canBeTag = false;
        await tester.pumpWidget(rig.app());

        await tester.tap(find.byIcon(Icons.nfc));
        await tester.pumpAndSettle();

        expect(rig.nfc.started, isEmpty);
        expect(find.text('Tap their phone'), findsNothing);
        expect(find.text('Scan QR Code'), findsOneWidget);
      },
    );

    testWidgets('closing the sheet ends the reader session', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());

      await tester.tap(find.byIcon(Icons.nfc));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(const Offset(5, 5)); // the scrim
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(rig.nfc.stops, greaterThan(0));
    });

    testWidgets(
      'an iPhone sender reads (it can only read) as soon as the sheet opens',
      (tester) async {
        final rig = _Rig();
        rig.nfc.canBeTag = false;
        await tester.pumpWidget(rig.app());

        await tester.tap(find.byIcon(Icons.nfc));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(rig.nfc.started.single.role, NfcRole.reader);
        expect(find.text('Hold near their phone…'), findsOneWidget);

        // The request comes back as what we read from the Android's tag.
        rig.nfc.receive(_link(amount: '3', nonce: 'ios-1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('to GBBD...FLA5'), findsOneWidget);
      },
    );

    testWidgets(
      'a payload that is not a payment request is reported and listening continues',
      (tester) async {
        final rig = _Rig();
        await tester.pumpWidget(rig.app());
        await tester.tap(find.byIcon(Icons.nfc));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        rig.nfc.receive('hello');
        await tester.pump();

        expect(find.textContaining("isn't a payment request"), findsOneWidget);
        // …and the right phone can still arrive afterwards.
        rig.nfc.receive(_link(amount: '1', nonce: 'late-1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('to GBBD...FLA5'), findsOneWidget);
      },
    );

    testWidgets(
      'nothing found after the wait: Android suggests holding closer or the QR',
      (tester) async {
        final rig = _Rig();
        await tester.pumpWidget(rig.app());
        await tester.tap(find.byIcon(Icons.nfc));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        await tester.pump(const Duration(seconds: 31));

        expect(
          find.textContaining('Hold the phones back to back'),
          findsOneWidget,
        );
        expect(
          rig.nfc.stops,
          greaterThan(0),
          reason: 'the session is ended, not left running',
        );
        expect(
          find.text('Tap their phone'),
          findsOneWidget,
          reason: 'and can be retried',
        );
      },
    );

    testWidgets(
      'nothing found after the wait: an iPhone is told NFC needs an Android',
      (tester) async {
        final rig = _Rig();
        rig.nfc.canBeTag = false;
        await tester.pumpWidget(rig.app());
        await tester.tap(find.byIcon(Icons.nfc));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        await tester.pump(const Duration(seconds: 31));

        expect(
          find.textContaining('can only tap an Android phone'),
          findsOneWidget,
        );
      },
    );

    testWidgets('NFC switched off: the sheet says so and points at the QR', (
      tester,
    ) async {
      final rig = _Rig();
      rig.nfc.startError = StateError('NFC is off');
      await tester.pumpWidget(rig.app());

      await tester.tap(find.byIcon(Icons.nfc));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.textContaining('NFC is turned off or unavailable'),
        findsOneWidget,
      );
    });
  });

  group('sending', () {
    testWidgets('locks the cheque, then offers the handoff over NFC and QR', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _link(amount: '25.50', nonce: 'req-1'));

      await _send(tester);

      // The four-step choreography ran with the request's data.
      expect(rig.chequeApi.created.single.receiver, _receiver);
      expect(rig.chequeApi.created.single.amount, '25.50');
      expect(rig.chequeApi.confirmedLocks, [_chequeId]);
      expect(rig.chequeApi.preauths, [_chequeId]);

      // The request id goes to the server, which is what makes it single-use.
      expect(rig.chequeApi.created.single.requestId, 'req-1');

      // The receiver's phone gets the cheque id, bound to their nonce.
      expect(find.text('Payment sent'), findsOneWidget);
      final handoff = ChequeHandoff.tryParse(rig.nfc.presented.single)!;
      // Android sender alternates windows to present the handoff to an iPhone
      // receiver, while retaining reader windows for Android receivers.
      expect(rig.nfc.started.last.role, NfcRole.auto);
      expect(rig.nfc.started.last.offer, rig.nfc.presented.single);
      expect(handoff.chequeId, _chequeId);
      expect(handoff.amount, '25.50');
      expect(handoff.nonce, 'req-1');

      // The recipient is cleared so a stray tap can't double-send.
      expect(find.text('to GBBD...FLA5'), findsNothing);

      await tester.tap(find.text('Done'));
      await tester.pump();
    });

    testWidgets('a read of the handoff shows "Delivered"', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _link(amount: '1', nonce: 'req-2'));
      await _send(tester);

      rig.nfc.delivered();
      await tester.pump(); // delivers the event (a microtask)…
      await tester.pump(); // …and rebuilds for the setState it triggers

      expect(find.text('Delivered'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pump();
    });

    testWidgets('"Done" stops offering the payload and returns to the form', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _link(amount: '1', nonce: 'req-3'));
      await _send(tester);
      final stopsBefore = rig.nfc.stops;

      await tester.tap(find.text('Done'));
      await tester.pump();

      expect(rig.nfc.stops, greaterThan(stopsBefore));
      expect(find.text('Payment sent'), findsNothing);
      expect(find.text('Find recipient'), findsOneWidget);
    });

    testWidgets(
      'an iPhone sender gets a button for the second tap and starts a read on demand',
      (tester) async {
        final rig = _Rig();
        rig.nfc.canBeTag = false;
        await tester.pumpWidget(rig.app());
        await _pasteRecipient(tester, _link(amount: '2', nonce: 'req-ios'));
        await _send(tester);

        expect(find.text('Payment sent'), findsOneWidget);
        expect(
          find.byType(QrCard),
          findsOneWidget,
          reason: 'the QR is the always-available path',
        );
        expect(
          rig.nfc.started,
          isEmpty,
          reason: 'no automatic NFC session on an iPhone',
        );

        await tester.tap(find.text("Tap receiver's phone"));
        await tester.pump();

        expect(rig.nfc.started.single.role, NfcRole.reader);
        final handoff = ChequeHandoff.tryParse(rig.nfc.started.single.offer)!;
        expect(handoff.chequeId, _chequeId);
        expect(handoff.nonce, 'req-ios');

        // The write completing is "Delivered".
        rig.nfc.delivered();
        await tester.pump();
        await tester.pump();
        expect(find.text('Delivered'), findsOneWidget);
        expect(find.text("Tap receiver's phone"), findsNothing);

        await tester.tap(find.text('Done'));
        await tester.pump();
      },
    );

    testWidgets('without NFC the handoff is a QR the receiver can scan', (
      tester,
    ) async {
      final rig = _Rig();
      rig.nfc.canBeTag = false;
      rig.nfc.canRead = false;
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _link(amount: '1', nonce: 'req-4'));
      await _send(tester);

      expect(find.text('Payment sent'), findsOneWidget);
      expect(rig.nfc.presented, isEmpty);
      expect(find.textContaining('scan this code'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pump();
    });

    testWidgets('a failed send offers no handoff and keeps the recipient', (
      tester,
    ) async {
      final rig = _Rig();
      rig.chequeApi.createError = StateError('insufficient');
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _link(amount: '25.50', nonce: 'req-5'));

      await _send(tester);

      expect(find.text('Payment sent'), findsNothing);
      expect(rig.nfc.presented, isEmpty);
      expect(find.text('to GBBD...FLA5'), findsOneWidget);
    });

    testWidgets(
      'the server refusing a request that was paid elsewhere ends without a handoff',
      (tester) async {
        final rig = _Rig();
        rig.chequeApi.createError = ApiException(
          code: 'cheque.request_used',
          message: 'used',
          httpStatus: 409,
        );
        await tester.pumpWidget(rig.app());
        await _pasteRecipient(tester, _link(amount: '25.50', nonce: 'req-6'));

        await _send(tester);

        expect(find.text('Payment sent'), findsNothing);
        expect(rig.nfc.presented, isEmpty);
        expect(
          _container(tester).read(signingOverlayProvider).errorMessage,
          'That payment request was already paid. Ask for a new one.',
        );
      },
    );
  });

  group('sending while offline', () {
    Future<void> seedSnapshot(String accountId, {String availableRaw = '1000000000'}) =>
        OfflineAccountCache().write(
          OfflineAccountSnapshot(
            accountId: accountId,
            sequence: BigInt.from(41),
            availableRaw: availableRaw,
            decimals: 7,
            fetchedAt: DateTime.utc(2026, 9, 20),
          ),
        );

    testWidgets('no connection, a cached balance: hands over a signed offline payment', (tester) async {
      final rig = _Rig();
      await seedSnapshot(rig.keyPair.accountId);
      rig.chequeApi.createError = ApiException(code: 'network.error', message: 'offline', httpStatus: null);
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _link(amount: '5', nonce: 'off-1'));

      await _send(tester);
      await tester.pump();

      expect(find.text('Payment sent'), findsOneWidget);
      expect(find.textContaining('Sent while offline'), findsOneWidget);
      expect(rig.chequeApi.created, isEmpty, reason: 'never reached the backend');

      final payment = OfflinePayment.tryParse(rig.nfc.presented.single)!;
      expect(payment.nonce, 'off-1');
      const verifier = OfflinePaymentVerifier();
      final result = verifier.verify(
        signedXdr: payment.signedXdr,
        expectedDestination: _receiver,
        requestNonce: 'off-1',
        asset: PayAsset.configured,
        decimals: 7,
        networkPassphrase: _container(tester).read(networkPassphraseProvider),
      );
      expect(result.isValid, isTrue);
      expect(result.from, rig.keyPair.accountId);
      expect(result.amount, '50000000');

      // Spent locally, so the same request can't be paid twice.
      expect(_container(tester).read(offlineSpentRequestIdsProvider), contains('off-1'));
      expect(await OfflinePaymentStore().spentRequestIds(), contains('off-1'));

      await tester.tap(find.text('Done'));
      await tester.pump();
    });

    testWidgets('no connection, no cached balance: a plain error, no handoff', (tester) async {
      final rig = _Rig(); // no snapshot seeded
      rig.chequeApi.createError = ApiException(code: 'network.error', message: 'offline', httpStatus: null);
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _link(amount: '5', nonce: 'off-2'));

      await _send(tester);

      expect(find.text('Payment sent'), findsNothing);
      expect(rig.nfc.presented, isEmpty);
      expect(_container(tester).read(signingOverlayProvider).errorMessage, contains('connect once'));
    });

    testWidgets('no connection, balance too low: refused rather than overspending', (tester) async {
      final rig = _Rig();
      await seedSnapshot(rig.keyPair.accountId, availableRaw: '10000000'); // 1.0
      rig.chequeApi.createError = ApiException(code: 'network.error', message: 'offline', httpStatus: null);
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _link(amount: '5', nonce: 'off-3'));

      await _send(tester);

      expect(find.text('Payment sent'), findsNothing);
      expect(_container(tester).read(signingOverlayProvider).errorMessage, contains('Not enough balance'));
    });

    testWidgets('a manually pasted address has no request nonce, so offline is never offered', (tester) async {
      final rig = _Rig();
      await seedSnapshot(rig.keyPair.accountId);
      rig.chequeApi.createError = ApiException(code: 'network.error', message: 'offline', httpStatus: null);
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _receiver);
      await tester.enterText(_amountField, '5');

      await _send(tester);

      expect(find.text('Payment sent'), findsNothing);
      expect(rig.nfc.presented, isEmpty);
    });

    testWidgets('a non-network failure is shown normally, no offline fallback', (tester) async {
      final rig = _Rig();
      await seedSnapshot(rig.keyPair.accountId);
      rig.chequeApi.createError =
          ApiException(code: 'cheque.insufficient_balance', message: 'nope', httpStatus: 422);
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _link(amount: '5', nonce: 'off-4'));

      await _send(tester);

      expect(find.text('Payment sent'), findsNothing);
      expect(rig.nfc.presented, isEmpty);
      expect(
        _container(tester).read(signingOverlayProvider).errorMessage,
        "You don't have enough balance for this transaction.",
      );
    });

    testWidgets('two offline payments in a row do not reuse the same sequence number', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final rig = _Rig();
      await seedSnapshot(rig.keyPair.accountId);
      rig.chequeApi.createError = ApiException(code: 'network.error', message: 'offline', httpStatus: null);
      await tester.pumpWidget(rig.app());

      await _pasteRecipient(tester, _link(amount: '5', nonce: 'off-5'));
      await _send(tester);
      await tester.pump();
      final first = OfflinePayment.tryParse(rig.nfc.presented.single)!;
      await tester.tap(find.text('Done'));
      await tester.pump();
      // The real app's full-screen "Completed" overlay (only mounted inside
      // AppShell, not this bare-SendPage harness) is what the user taps to
      // clear the signing step back to idle; simulate that tap directly.
      _container(tester).read(signingOverlayProvider.notifier).dismiss();
      await tester.pump();

      await _pasteRecipient(tester, _link(amount: '5', nonce: 'off-6'));
      await _send(tester);
      await tester.pump();
      final second = OfflinePayment.tryParse(rig.nfc.presented.last)!;

      final firstTx = AbstractTransaction.fromEnvelopeXdrString(first.signedXdr) as Transaction;
      final secondTx = AbstractTransaction.fromEnvelopeXdrString(second.signedXdr) as Transaction;
      expect(secondTx.sequenceNumber, firstTx.sequenceNumber + BigInt.one);
    });
  });
}
