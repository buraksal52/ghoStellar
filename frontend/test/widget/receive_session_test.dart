import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/payments/payment_uri.dart';
import 'package:ghostellar_app/data/api/models/cheque_models.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/signing_overlay_provider.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/tap_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

const _chequeId = '01J8F2K9ABCDEFGHJKMNPQRSTV';

class _Rig {
  _Rig({List<Cheque> Function(String me)? preexisting}) {
    keyPair = KeyPair.random();
    me = keyPair.accountId;
    container = ProviderContainer(overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(keyPair)),
      nfcServiceProvider.overrideWithValue(nfc),
      syncApiProvider.overrideWithValue(syncApi),
      chequeApiProvider.overrideWithValue(chequeApi),
      txApiProvider.overrideWithValue(FakeTxApi()),
      stellarSigningServiceProvider.overrideWithValue(FakeSigning()),
      syncProvider.overrideWith(() => FakeSyncNotifier(preexisting?.call(me) ?? const [])),
      clockProvider.overrideWithValue(() => now),
    ]);
  }

  late final KeyPair keyPair;
  late final String me;
  late final ProviderContainer container;
  final nfc = FakeNfc();
  final syncApi = FakeSyncApi();
  final chequeApi = FakeChequeApi();
  DateTime now = DateTime.utc(2026, 9, 20, 12);

  ReceiveSessionNotifier get session => container.read(receiveSessionProvider.notifier);
  ReceiveSessionState get state => container.read(receiveSessionProvider);

  /// Lets `syncProvider` resolve so the session's baseline sees it.
  Future<void> ready(WidgetTester tester) async {
    container.listen(syncProvider, (prev, next) {});
    await container.read(syncProvider.future);
    await tester.pump();
  }
}

void main() {
  testWidgets('offers a SEP-7 request with the amount, over NFC and for the QR', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);

    await rig.session.start(amount: '25.50');

    expect(rig.state.phase, ReceivePhase.offering);
    final request = rig.state.request!;
    expect(request.destination, rig.me);
    expect(request.amount, '25.50');
    expect(request.nonce, isNotEmpty);
    expect(request.expiresAt, rig.now.add(const Duration(minutes: 5)));
    // The tag and the QR carry the very same URI.
    expect(rig.nfc.broadcasts, [request.toUri()]);
    expect(PaymentRequest.tryParse(rig.nfc.broadcasts.single)!.amount, '25.50');

    rig.session.stop();
  });

  testWidgets('an invalid amount becomes an open request (sender chooses)', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);

    await rig.session.start(amount: 'abc');

    expect(rig.state.request!.amount, isNull);
    rig.session.stop();
  });

  testWidgets('no NFC: still offers the request (for the QR) and never broadcasts', (tester) async {
    final rig = _Rig();
    rig.nfc.isEmulateSupported = false;
    rig.nfc.isScanSupported = false;
    addTearDown(rig.container.dispose);
    await rig.ready(tester);

    await rig.session.start();

    expect(rig.state.phase, ReceivePhase.offering);
    expect(rig.nfc.broadcasts, isEmpty);
    rig.session.stop();
  });

  testWidgets('NFC path: peer reads → roles flip → handoff over a second tap → claimed', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start(amount: '25.50');
    final nonce = rig.state.request!.nonce!;

    rig.nfc.peerReads();
    await tester.pump();

    expect(rig.state.phase, ReceivePhase.awaitingCheque);
    expect(rig.nfc.stops, greaterThan(0), reason: 'stops being the tag');
    expect(rig.nfc.scanCount, 1, reason: 'becomes the reader');

    rig.nfc.deliver(ChequeHandoff(chequeId: _chequeId, from: testSender, amount: '25.50', nonce: nonce).toUri());
    await tester.pump();
    await tester.pump();

    expect(rig.chequeApi.claimed, [_chequeId]);
    expect(rig.chequeApi.acked, [_chequeId]);
    expect(rig.state.phase, ReceivePhase.done);
    expect(rig.state.claimedChequeId, _chequeId);
  });

  testWidgets('a repeated read of the tag does not restart the handoff wait', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();

    rig.nfc.peerReads();
    rig.nfc.peerReads();
    rig.nfc.peerReads();
    await tester.pump();

    expect(rig.nfc.scanCount, 1);
    rig.session.stop();
  });

  testWidgets("a handoff for someone else's request is ignored", (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();
    rig.nfc.peerReads();
    await tester.pump();

    rig.nfc.deliver(ChequeHandoff(chequeId: _chequeId, from: testSender, nonce: 'not-ours').toUri());
    await tester.pump();

    expect(rig.chequeApi.claimAttempts, 0);
    expect(rig.state.phase, ReceivePhase.awaitingCheque);

    // It keeps listening (after a short pause) rather than giving up.
    await tester.pump(const Duration(seconds: 1));
    expect(rig.nfc.scanCount, 2);
    rig.session.stop();
  });

  testWidgets('QR path: acceptHandoff claims for the matching nonce only', (tester) async {
    final rig = _Rig();
    rig.nfc.isEmulateSupported = false;
    rig.nfc.isScanSupported = false;
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start(amount: '25.50');
    final nonce = rig.state.request!.nonce!;

    expect(
      await rig.session.acceptHandoff(ChequeHandoff(chequeId: _chequeId, from: testSender, nonce: 'other')),
      isFalse,
    );
    expect(await rig.session.acceptHandoff(ChequeHandoff(chequeId: _chequeId, from: testSender)), isFalse);
    expect(rig.chequeApi.claimAttempts, 0);

    expect(
      await rig.session.acceptHandoff(ChequeHandoff(chequeId: _chequeId, from: testSender, nonce: nonce)),
      isTrue,
    );
    expect(rig.chequeApi.claimed, [_chequeId]);
    expect(rig.state.phase, ReceivePhase.done);
  });

  testWidgets('polling fallback claims a new matching cheque when no handoff arrives', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start(amount: '25.50');

    await tester.pump(const Duration(seconds: 3));
    expect(rig.syncApi.calls, 1);
    expect(rig.chequeApi.claimAttempts, 0, reason: 'nothing to claim yet');

    rig.syncApi.cheques = [testCheque(_chequeId, rig.me)];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(rig.chequeApi.claimed, [_chequeId]);
    expect(rig.state.phase, ReceivePhase.done);
  });

  testWidgets('polling ignores cheques that existed before the session started', (tester) async {
    final rig = _Rig(preexisting: (me) => [testCheque('01OLDOLDOLDOLDOLDOLDOLDOLD', me)]);
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();

    rig.syncApi.cheques = [testCheque('01OLDOLDOLDOLDOLDOLDOLDOLD', rig.me)];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(rig.chequeApi.claimAttempts, 0);
    expect(rig.state.phase, ReceivePhase.offering);
    rig.session.stop();
  });

  testWidgets('polling ignores a cheque whose amount differs from the request', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start(amount: '25.50');

    rig.syncApi.cheques = [testCheque(_chequeId, rig.me, amountRaw: '100000000')];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(rig.chequeApi.claimAttempts, 0);
    rig.session.stop();
  });

  testWidgets('polling only auto-claims cheques that are claimable and addressed to me', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();

    rig.syncApi.cheques = [
      testCheque('01AAAAAAAAAAAAAAAAAAAAAAAA', 'GSOMEONEELSE'),
      testCheque('01BBBBBBBBBBBBBBBBBBBBBBBB', rig.me, state: ChequeState.kapandi),
      testCheque('01CCCCCCCCCCCCCCCCCCCCCCCC', rig.me, state: ChequeState.fonlaniyor),
    ];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(rig.chequeApi.claimAttempts, 0);
    rig.session.stop();
  });

  testWidgets('a failing claim is attempted once, not retried every tick', (tester) async {
    final rig = _Rig();
    rig.chequeApi.claimError = StateError('boom');
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();
    rig.syncApi.cheques = [testCheque(_chequeId, rig.me)];

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
    }

    expect(rig.chequeApi.claimAttempts, 1);
    expect(rig.state.phase, ReceivePhase.offering, reason: 'the session resumes offering');
    expect(rig.container.read(signingOverlayProvider).step, SigningStep.error);
    rig.session.stop();
  });

  testWidgets('an unanswered request rotates to a fresh nonce after its ttl', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start(amount: '5');
    final first = rig.state.request!;

    rig.now = rig.now.add(ReceiveSessionNotifier.requestTtl);
    await tester.pump(ReceiveSessionNotifier.requestTtl);

    final second = rig.state.request!;
    expect(second.nonce, isNot(first.nonce));
    expect(second.amount, '5');
    expect(second.expiresAt, rig.now.add(ReceiveSessionNotifier.requestTtl));
    expect(rig.nfc.broadcasts.last, second.toUri());
    rig.session.stop();
  });

  testWidgets('waiting for a handoff that never comes goes back to offering', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();
    final first = rig.state.request!;

    rig.nfc.peerReads();
    await tester.pump();
    expect(rig.state.phase, ReceivePhase.awaitingCheque);

    // The reader session times out with nothing (startScan → null).
    rig.nfc.deliverNothing();
    await tester.pump();
    await tester.pump();

    expect(rig.state.phase, ReceivePhase.offering);
    expect(rig.state.request!.nonce, isNot(first.nonce));
    rig.session.stop();
  });

  testWidgets('stop() ends the session: idle, radios off, polling silent', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();

    rig.session.stop();
    final callsAtStop = rig.syncApi.calls;
    await tester.pump(const Duration(seconds: 30));

    expect(rig.state.phase, ReceivePhase.idle);
    expect(rig.nfc.cancels, greaterThan(0));
    expect(rig.syncApi.calls, callsAtStop);
  });

  testWidgets('restarting supersedes the old session (new request, one poller)', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start(amount: '1');
    final first = rig.state.request!;
    await rig.session.start(amount: '2');

    expect(rig.state.request!.nonce, isNot(first.nonce));
    expect(rig.state.request!.amount, '2');

    await tester.pump(const Duration(seconds: 3));
    expect(rig.syncApi.calls, 1, reason: 'the first session\'s timer must be gone');
    rig.session.stop();
  });

  testWidgets('manual claim() works outside a session and refreshes sync', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);

    final ok = await rig.session.claim(_chequeId);

    expect(ok, isTrue);
    expect(rig.chequeApi.claimed, [_chequeId]);
    expect(rig.state.phase, ReceivePhase.idle, reason: 'manual claim does not touch the session');
  });

  test('UsedNonces remembers what was added', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(usedNoncesProvider), isEmpty);
    container.read(usedNoncesProvider.notifier).add('n1');
    expect(container.read(usedNoncesProvider), {'n1'});
  });
}

