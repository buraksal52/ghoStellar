import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/core/payments/payment_uri.dart';
import 'package:ghostellar_app/data/api/models/cheque_models.dart';
import 'package:ghostellar_app/data/nfc/nfc_service.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/inbox_providers.dart';
import 'package:ghostellar_app/state/signing_overlay_provider.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/tap_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

const _chequeId = '01J8F2K9ABCDEFGHJKMNPQRSTV';

class _Rig {
  _Rig() {
    keyPair = KeyPair.random();
    me = keyPair.accountId;
    container = ProviderContainer(overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(keyPair)),
      nfcServiceProvider.overrideWithValue(nfc),
      syncApiProvider.overrideWithValue(syncApi),
      chequeApiProvider.overrideWithValue(chequeApi),
      txApiProvider.overrideWithValue(FakeTxApi()),
      stellarSigningServiceProvider.overrideWithValue(FakeSigning()),
      syncProvider.overrideWith(() => FakeSyncNotifier(const [])),
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
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
    expect(rig.nfc.presented, [request.toUri()]);
    expect(PaymentRequest.tryParse(rig.nfc.presented.single)!.amount, '25.50');
    // An Android receiver is the tag from the start, and takes writes.
    expect(rig.nfc.started.single.role, NfcRole.tag);
    expect(rig.nfc.started.single.offer, request.toUri());

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
    rig.nfc.canBeTag = false;
    rig.nfc.canRead = false;
    addTearDown(rig.container.dispose);
    await rig.ready(tester);

    await rig.session.start();

    expect(rig.state.phase, ReceivePhase.offering);
    expect(rig.nfc.presented, isEmpty);
    rig.session.stop();
  });

  testWidgets('Android: a peer reads the request, then hands the cheque over on the same tag', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start(amount: '25.50');
    final nonce = rig.state.request!.nonce!;

    rig.nfc.delivered();
    await tester.pump();

    expect(rig.state.phase, ReceivePhase.awaitingCheque);
    // Roles never flip: still the one tag session, not stopped, no reader started.
    expect(rig.nfc.started, hasLength(1));
    expect(rig.nfc.stops, 0);

    // The sender's phone writes the handoff to our tag.
    rig.nfc.receive(ChequeHandoff(chequeId: _chequeId, from: testSender, amount: '25.50', nonce: nonce).toUri());
    await tester.pump();
    await tester.pump();

    expect(rig.chequeApi.claimed, [_chequeId]);
    expect(rig.chequeApi.acked, [_chequeId]);
    expect(rig.state.phase, ReceivePhase.done);
    expect(rig.state.claimedChequeId, _chequeId);
    expect(rig.nfc.stops, greaterThan(0), reason: 'the radio is released once paid');
  });

  testWidgets('a repeated read of the tag does not move the phase twice', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();

    rig.nfc.delivered();
    rig.nfc.delivered();
    rig.nfc.delivered();
    await tester.pump();

    expect(rig.state.phase, ReceivePhase.awaitingCheque);
    expect(rig.nfc.started, hasLength(1));
    rig.session.stop();
  });

  testWidgets("a handoff for someone else's request is ignored", (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();
    rig.nfc.delivered();
    await tester.pump();

    rig.nfc.receive(ChequeHandoff(chequeId: _chequeId, from: testSender, nonce: 'not-ours').toUri());
    await tester.pump();

    expect(rig.chequeApi.claimAttempts, 0);
    expect(rig.state.phase, ReceivePhase.awaitingCheque);
    rig.session.stop();
  });

  testWidgets('a peer payload that is not a handoff is ignored', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();

    rig.nfc.receive('hello');
    rig.nfc.receive('web+stellar:pay?destination=${rig.me}');
    await tester.pump();

    expect(rig.chequeApi.claimAttempts, 0);
    expect(rig.state.phase, ReceivePhase.offering);
    rig.session.stop();
  });

  group('an iPhone (reader only)', () {
    testWidgets('does not start NFC by itself — Apple wants the user to start a read', (tester) async {
      final rig = _Rig();
      rig.nfc.canBeTag = false;
      addTearDown(rig.container.dispose);
      await rig.ready(tester);

      await rig.session.start(amount: '5');

      expect(rig.state.phase, ReceivePhase.offering, reason: 'the QR is on screen');
      expect(rig.nfc.started, isEmpty);
      rig.session.stop();
    });

    testWidgets('beginNfcRead reads and writes the request in one tap, twice: request, then handoff', (tester) async {
      final rig = _Rig();
      rig.nfc.canBeTag = false;
      addTearDown(rig.container.dispose);
      await rig.ready(tester);
      await rig.session.start(amount: '25.50');
      final request = rig.state.request!;

      // First tap: our request goes to the Android sender's tag.
      await rig.session.beginNfcRead();
      expect(rig.nfc.started.single.role, NfcRole.reader);
      expect(rig.nfc.started.single.offer, request.toUri());
      rig.nfc.delivered();
      await tester.pump();
      expect(rig.state.phase, ReceivePhase.awaitingCheque);

      // Second tap, once they've paid: their handoff comes back as the peer payload.
      await rig.session.beginNfcRead();
      expect(rig.nfc.started, hasLength(2));
      rig.nfc.receive(ChequeHandoff(chequeId: _chequeId, from: testSender, nonce: request.nonce).toUri());
      await tester.pump();
      await tester.pump();

      expect(rig.chequeApi.claimed, [_chequeId]);
      expect(rig.state.phase, ReceivePhase.done);
    });

    testWidgets(
      'beginNfcRead does not restart the radio on a device that is already '
      'the tag — it only shows the waiting state',
      (tester) async {
        final rig = _Rig();
        addTearDown(rig.container.dispose);
        await rig.ready(tester);
        await rig.session.start();
        expect(rig.nfc.started, hasLength(1));

        await rig.session.beginNfcRead();

        expect(rig.nfc.started, hasLength(1));
        expect(rig.state.nfcReading, isTrue);
        rig.session.stop();
      },
    );

    testWidgets('beginNfcRead times out with "no phone found" after nfcWait', (tester) async {
      final rig = _Rig();
      rig.nfc.canBeTag = false;
      addTearDown(rig.container.dispose);
      await rig.ready(tester);
      await rig.session.start();

      await rig.session.beginNfcRead();
      expect(rig.state.nfcReading, isTrue);

      await tester.pump(ReceiveSessionNotifier.nfcWait);

      expect(rig.state.nfcReading, isFalse);
      expect(
        rig.state.nfcError,
        "No phone found. An iPhone can only tap an Android phone — for another iPhone, scan their code.",
      );
      rig.session.stop();
    });

    testWidgets('a phase change (e.g. delivery) clears the NFC-read waiting state', (tester) async {
      final rig = _Rig();
      rig.nfc.canBeTag = false;
      addTearDown(rig.container.dispose);
      await rig.ready(tester);
      await rig.session.start();

      await rig.session.beginNfcRead();
      expect(rig.state.nfcReading, isTrue);

      rig.nfc.delivered();
      await tester.pump();

      expect(rig.state.phase, ReceivePhase.awaitingCheque);
      expect(rig.state.nfcReading, isFalse);
      rig.session.stop();
    });

    testWidgets('beginNfcRead survives NFC being switched off', (tester) async {
      final rig = _Rig();
      rig.nfc.canBeTag = false;
      rig.nfc.startError = StateError('NFC is off');
      addTearDown(rig.container.dispose);
      await rig.ready(tester);
      await rig.session.start();

      await rig.session.beginNfcRead(); // must not throw

      expect(rig.state.phase, ReceivePhase.offering);
      expect(rig.state.nfcReading, isFalse);
      expect(
        rig.state.nfcError,
        'NFC is turned off or unavailable. Scan their code instead.',
      );
      rig.session.stop();
    });
  });

  testWidgets('QR path: acceptHandoff claims for the matching nonce only', (tester) async {
    final rig = _Rig();
    rig.nfc.canBeTag = false;
    rig.nfc.canRead = false;
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

  testWidgets('polling claims the cheque that answers this session\'s request', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start(amount: '25.50');
    final nonce = rig.state.request!.nonce!;

    await tester.pump(const Duration(seconds: 3));
    expect(rig.syncApi.calls, 1);
    expect(rig.chequeApi.claimAttempts, 0, reason: 'nothing to claim yet');

    rig.syncApi.cheques = [testCheque(_chequeId, rig.me, requestId: nonce)];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(rig.chequeApi.claimed, [_chequeId]);
    expect(rig.state.phase, ReceivePhase.done);
  });

  testWidgets('polling leaves a cheque with no request id to the manual list', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();

    rig.syncApi.cheques = [testCheque(_chequeId, rig.me)];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(rig.chequeApi.claimAttempts, 0);
    expect(rig.state.phase, ReceivePhase.offering);
    rig.session.stop();
  });

  testWidgets('polling ignores a cheque that answers some other request', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();

    rig.syncApi.cheques = [testCheque(_chequeId, rig.me, requestId: 'somebody-elses')];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(rig.chequeApi.claimAttempts, 0);
    rig.session.stop();
  });

  testWidgets('a cheque for a rotated-out request is still claimed', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();
    final first = rig.state.request!.nonce!;

    // The QR nobody answered in time is replaced…
    await tester.pump(ReceiveSessionNotifier.requestTtl);
    expect(rig.state.request!.nonce, isNot(first));

    // …but a sender who scanned it just before that may finish paying now.
    rig.syncApi.cheques = [testCheque(_chequeId, rig.me, requestId: first)];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(rig.chequeApi.claimed, [_chequeId]);
  });

  testWidgets('editing the amount does not forget requests already offered', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start(amount: '1');
    final first = rig.state.request!.nonce!;
    await rig.session.start(amount: '2');
    expect(rig.state.request!.nonce, isNot(first));

    rig.syncApi.cheques = [testCheque(_chequeId, rig.me, requestId: first)];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(rig.chequeApi.claimed, [_chequeId]);
  });

  testWidgets('a new session does not honour the previous session\'s requests', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();
    final old = rig.state.request!.nonce!;
    rig.session.stop();

    await rig.session.start();
    rig.syncApi.cheques = [testCheque(_chequeId, rig.me, requestId: old)];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(rig.chequeApi.claimAttempts, 0);
    rig.session.stop();
  });

  testWidgets('polling only claims cheques that are claimable and addressed to me', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();
    final nonce = rig.state.request!.nonce!;

    rig.syncApi.cheques = [
      testCheque('01AAAAAAAAAAAAAAAAAAAAAAAA', 'GSOMEONEELSE', requestId: nonce),
      testCheque('01BBBBBBBBBBBBBBBBBBBBBBBB', rig.me, state: ChequeState.kapandi, requestId: nonce),
      testCheque('01CCCCCCCCCCCCCCCCCCCCCCCC', rig.me, state: ChequeState.fonlaniyor, requestId: nonce),
    ];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(rig.chequeApi.claimAttempts, 0);
    rig.session.stop();
  });

  testWidgets('a claim that keeps failing is saved to the offline inbox, not retried by the poll itself',
      (tester) async {
    final rig = _Rig();
    rig.chequeApi.claimError = StateError('boom'); // not an ApiException: treated as retryable/offline
    await rig.ready(tester);
    await rig.session.start();
    final nonce = rig.state.request!.nonce!;
    rig.syncApi.cheques = [testCheque(_chequeId, rig.me, requestId: nonce)];

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
    }

    // 1 from the session's own auto-claim + 1 immediate retry when the
    // inbox first saves it; its 15s timer hasn't fired in these 12s.
    expect(rig.chequeApi.claimAttempts, 2);
    expect(rig.state.phase, ReceivePhase.offering, reason: 'the session resumes offering');
    expect(rig.container.read(signingOverlayProvider).step, SigningStep.idle,
        reason: 'saved silently — not shown as a scary error');
    expect(await rig.container.read(pendingHandoffsProvider.notifier).future, hasLength(1));

    rig.session.stop();
    // The item is still pending (the fake keeps failing), so the inbox's own
    // retry timer is still running by design — disposing the container here
    // (rather than via addTearDown, which would run after this test's own
    // pending-timer check) is what actually cancels it.
    rig.container.dispose();
  });

  testWidgets('a claim that fails because the cheque itself is gone is shown as an error, not saved', (tester) async {
    final rig = _Rig();
    rig.chequeApi.claimError = ApiException(code: 'cheque.expired', message: 'expired', httpStatus: 409);
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();
    final nonce = rig.state.request!.nonce!;
    rig.syncApi.cheques = [testCheque(_chequeId, rig.me, requestId: nonce)];

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(rig.chequeApi.claimAttempts, 1);
    expect(rig.state.phase, ReceivePhase.offering);
    expect(rig.container.read(signingOverlayProvider).step, SigningStep.error);
    expect(await rig.container.read(pendingHandoffsProvider.notifier).future, isEmpty);
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
    expect(rig.nfc.presented.last, second.toUri());
    expect(rig.nfc.started, hasLength(1), reason: 'rotation swaps the payload, it does not restart the radio');
    rig.session.stop();
  });

  testWidgets('waiting for a handoff that never comes goes back to offering', (tester) async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    await rig.ready(tester);
    await rig.session.start();
    final first = rig.state.request!;

    rig.nfc.delivered();
    await tester.pump();
    expect(rig.state.phase, ReceivePhase.awaitingCheque);

    await tester.pump(ReceiveSessionNotifier.handoffWindow);
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
    expect(rig.nfc.stops, greaterThan(0));
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

  testWidgets('paidRequestIdsProvider is the request ids of cheques I sent, from /sync', (tester) async {
    final rig = _Rig();
    final me = rig.me;
    final container = ProviderContainer(overrides: <Override>[
      walletProvider.overrideWith(() => UnlockedWallet(rig.keyPair)),
      syncProvider.overrideWith(() => FakeSyncNotifier([
            testCheque('01AAAAAAAAAAAAAAAAAAAAAAAA', 'GSOMEONE', sender: me, requestId: 'mine-1'),
            testCheque('01BBBBBBBBBBBBBBBBBBBBBBBB', 'GSOMEONE', sender: me),
            // Addressed to me, i.e. a request somebody else paid — not "I paid".
            testCheque('01CCCCCCCCCCCCCCCCCCCCCCCC', me, requestId: 'theirs-1'),
          ])),
    ]);
    addTearDown(container.dispose);
    container.listen(syncProvider, (prev, next) {});
    await container.read(syncProvider.future);
    await tester.pump();

    expect(container.read(paidRequestIdsProvider), {'mine-1'});
  });
}
