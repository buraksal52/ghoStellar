import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/payments/payment_uri.dart';
import 'package:ghostellar_app/core/theme/app_colors.dart';
import 'package:ghostellar_app/features/send/send_page.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/tap_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

const _receiver = 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5';
const _chequeId = '01J8F2K9ABCDEFGHJKMNPQRSTV';

class _Rig {
  final nfc = FakeNfc();
  final chequeApi = FakeChequeApi();
  DateTime now = DateTime.utc(2026, 9, 20, 12);

  List<Override> get overrides => [
        walletProvider.overrideWith(() => UnlockedWallet(KeyPair.random())),
        nfcServiceProvider.overrideWithValue(nfc),
        chequeApiProvider.overrideWithValue(chequeApi),
        txApiProvider.overrideWithValue(FakeTxApi()),
        stellarSigningServiceProvider.overrideWithValue(FakeSigning()),
        syncProvider.overrideWith(() => FakeSyncNotifier(const [])),
        clockProvider.overrideWithValue(() => now),
      ];

  Widget app() => ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: ThemeData(extensions: [AppColors.light]),
          home: const Scaffold(body: Padding(padding: EdgeInsets.all(20), child: SendPage())),
        ),
      );
}

Finder get _pasteField => find.byWidgetPredicate(
      (w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Or paste'),
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
    'asset_code': 'XLM',
    'x_req': ?nonce,
    if (exp != null) 'x_exp': '$exp',
  };
  return Uri(scheme: 'web+stellar', path: 'pay', queryParameters: q).toString();
}

/// Taps the send arrow and lets the four fake API calls (all microtasks) run.
Future<void> _send(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.north_rounded).last);
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

void main() {
  group('choosing a recipient', () {
    testWidgets('a bare address still works and leaves the amount editable', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());

      await _pasteRecipient(tester, _receiver);

      expect(find.text('to GBBD...FLA5'), findsOneWidget);
      expect(tester.widget<TextField>(_amountField).readOnly, isFalse);
      expect(find.text('They asked for this amount.'), findsNothing);
    });

    testWidgets('a request with an amount fixes it until "Change"', (tester) async {
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

    testWidgets('an expired request is refused with its own message', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());
      final past = rig.now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000;

      await _pasteRecipient(tester, _link(amount: '5', nonce: 'n1', exp: past));

      expect(find.textContaining('has expired'), findsOneWidget);
    });

    testWidgets('a request that was already paid is refused', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());
      _container(tester).read(usedNoncesProvider.notifier).add('n1');

      await _pasteRecipient(tester, _link(nonce: 'n1'));

      expect(find.text('You already paid this request.'), findsOneWidget);
    });

    testWidgets('garbage gets the address hint', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());

      await _pasteRecipient(tester, 'https://example.com');

      expect(find.textContaining('Enter a valid Stellar address'), findsOneWidget);
    });

    testWidgets('a secret seed is never accepted as a recipient', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());

      await _pasteRecipient(tester, 'S${_receiver.substring(1)}');

      expect(find.textContaining('Enter a valid Stellar address'), findsOneWidget);
    });
  });

  group('NFC entry', () {
    testWidgets('the circle opens the sheet already listening; a tap picks the recipient', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());

      await tester.tap(find.byIcon(Icons.nfc));
      // Not pumpAndSettle: the scanning spinner animates for as long as it listens.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(rig.nfc.scanCount, 1);
      expect(find.text('Hold near their phone…'), findsOneWidget);

      rig.nfc.deliver(_link(amount: '7.25', nonce: 'nfc-1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('to GBBD...FLA5'), findsOneWidget);
      expect(tester.widget<TextField>(_amountField).controller!.text, '7.25');
    });

    testWidgets('without NFC the circle opens the sheet and offers no tap button', (tester) async {
      final rig = _Rig();
      rig.nfc.isScanSupported = false;
      rig.nfc.isEmulateSupported = false;
      await tester.pumpWidget(rig.app());

      await tester.tap(find.byIcon(Icons.nfc));
      await tester.pumpAndSettle();

      expect(rig.nfc.scanCount, 0);
      expect(find.text('Tap their phone'), findsNothing);
      expect(find.text('Scan QR Code'), findsOneWidget);
    });

    testWidgets('closing the sheet ends the reader session', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());

      await tester.tap(find.byIcon(Icons.nfc));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(const Offset(5, 5)); // the scrim
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(rig.nfc.cancels, greaterThan(0));
    });
  });

  group('sending', () {
    testWidgets('locks the cheque, then offers the handoff over NFC and QR', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _link(amount: '25.50', nonce: 'req-1'));

      await _send(tester);

      // The four-step choreography ran with the request's data.
      expect(rig.chequeApi.created, [(receiver: _receiver, amount: '25.50')]);
      expect(rig.chequeApi.confirmedLocks, [_chequeId]);
      expect(rig.chequeApi.preauths, [_chequeId]);

      // The request can't be paid twice.
      expect(_container(tester).read(usedNoncesProvider), contains('req-1'));

      // The receiver's phone gets the cheque id, bound to their nonce.
      expect(find.text('Payment sent'), findsOneWidget);
      final handoff = ChequeHandoff.tryParse(rig.nfc.broadcasts.single)!;
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

      rig.nfc.peerReads();
      await tester.pump(); // delivers the event (a microtask)…
      await tester.pump(); // …and rebuilds for the setState it triggers

      expect(find.text('Delivered'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pump();
    });

    testWidgets('"Done" stops offering the payload and returns to the form', (tester) async {
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

    testWidgets('without NFC the handoff is a QR the receiver can scan', (tester) async {
      final rig = _Rig();
      rig.nfc.isEmulateSupported = false;
      rig.nfc.isScanSupported = false;
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _link(amount: '1', nonce: 'req-4'));
      await _send(tester);

      expect(find.text('Payment sent'), findsOneWidget);
      expect(rig.nfc.broadcasts, isEmpty);
      expect(find.textContaining('scan this code'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pump();
    });

    testWidgets('a failed send offers no handoff and keeps the recipient', (tester) async {
      final rig = _Rig();
      rig.chequeApi.createError = StateError('insufficient');
      await tester.pumpWidget(rig.app());
      await _pasteRecipient(tester, _link(amount: '25.50', nonce: 'req-5'));

      await _send(tester);

      expect(find.text('Payment sent'), findsNothing);
      expect(rig.nfc.broadcasts, isEmpty);
      expect(find.text('to GBBD...FLA5'), findsOneWidget);
      expect(
        _container(tester).read(usedNoncesProvider),
        isEmpty,
        reason: 'no cheque was written, so the request stays payable',
      );
    });
  });
}
