import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/data/storage/handoff_inbox.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/inbox_providers.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../support/fakes.dart';

const _chequeId = '01J8F2K9ABCDEFGHJKMNPQRSTV';
const _chequeId2 = '01ZZZZZZZZZZZZZZZZZZZZZZZZ';
final _receiver = 'GAAZI4TCR3TY5OJHCTJC2A4QSY6CJWJH5IAJTGKIN2ER7LBNVKOCCWN7';

PendingHandoff _handoff(String id, {String from = 'GSENDER'}) => PendingHandoff(
      chequeId: id,
      from: from,
      amount: '5',
      nonce: 'n-$id',
      receivedAt: DateTime.utc(2026, 9, 20),
    );

class _Rig {
  final chequeApi = FakeChequeApi();
  final keyPair = KeyPair.random();
  ProviderContainer? _container;

  ProviderContainer build({bool unlocked = true}) {
    final c = ProviderContainer(overrides: <Override>[
      chequeApiProvider.overrideWithValue(chequeApi),
      txApiProvider.overrideWithValue(FakeTxApi()),
      stellarSigningServiceProvider.overrideWithValue(FakeSigning()),
      syncProvider.overrideWith(() => FakeSyncNotifier(const [])),
      if (unlocked) walletProvider.overrideWith(() => UnlockedWallet(keyPair)),
    ]);
    _container = c;
    return c;
  }

  void dispose() => _container?.dispose();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('HandoffInboxStore', () {
    test('round-trips a list through prefs', () async {
      final store = HandoffInboxStore();
      final items = [_handoff(_chequeId), _handoff(_chequeId2, from: _receiver)];

      await store.writeAll(items);
      final read = await store.readAll();

      expect(read.map((h) => h.chequeId), [_chequeId, _chequeId2]);
      expect(read[1].from, _receiver);
      expect(read[1].amount, '5');
      expect(read[1].nonce, 'n-$_chequeId2');
      expect(read[1].receivedAt, DateTime.utc(2026, 9, 20));
    });

    test('starts empty', () async {
      expect(await HandoffInboxStore().readAll(), isEmpty);
    });

    test('an empty list can be written back', () async {
      final store = HandoffInboxStore();
      await store.writeAll([_handoff(_chequeId)]);
      await store.writeAll(const []);
      expect(await store.readAll(), isEmpty);
    });
  });

  group('PendingHandoffsNotifier', () {
    test('loads whatever was already on disk', () async {
      await HandoffInboxStore().writeAll([_handoff(_chequeId)]);
      final rig = _Rig();
      final container = rig.build();
      addTearDown(rig.dispose);

      expect(await container.read(pendingHandoffsProvider.notifier).future, hasLength(1));
    });

    test('add persists to disk and is retried once immediately', () async {
      final rig = _Rig();
      final container = rig.build();
      addTearDown(rig.dispose);

      await container.read(pendingHandoffsProvider.notifier).add(_handoff(_chequeId));
      await Future<void>.delayed(Duration.zero);

      expect(rig.chequeApi.claimed, [_chequeId]);
      expect(container.read(pendingHandoffsProvider).value, isEmpty, reason: 'claimed on the immediate retry');
      expect(await HandoffInboxStore().readAll(), isEmpty, reason: 'persisted, not just in memory');
    });

    test('adding the same chequeId twice does not queue it twice', () async {
      final rig = _Rig();
      rig.chequeApi.claimError = StateError('offline');
      final container = rig.build();
      addTearDown(() {
        rig.dispose();
      });

      final notifier = container.read(pendingHandoffsProvider.notifier);
      await notifier.add(_handoff(_chequeId));
      await notifier.add(_handoff(_chequeId));

      expect(await notifier.future, hasLength(1));
      container.dispose();
    });

    test('a network-style failure keeps the item; a terminal one drops it', () async {
      final rig = _Rig();
      rig.chequeApi.claimError = ApiException(code: 'network.error', message: 'offline', httpStatus: null);
      final container = rig.build();

      final notifier = container.read(pendingHandoffsProvider.notifier);
      await notifier.add(_handoff(_chequeId));
      expect(await notifier.future, hasLength(1));

      rig.chequeApi.claimError = ApiException(code: 'cheque.not_found', message: 'gone', httpStatus: 404);
      await notifier.retryAll();

      expect(await notifier.future, isEmpty);
      container.dispose();
    });

    test('retryAll with a locked wallet does nothing (nothing to sign with yet)', () async {
      final rig = _Rig();
      final container = rig.build(unlocked: false);
      await HandoffInboxStore().writeAll([_handoff(_chequeId)]);
      final notifier = container.read(pendingHandoffsProvider.notifier);
      await notifier.future;

      await notifier.retryAll();

      expect(rig.chequeApi.claimAttempts, 0);
      expect(await notifier.future, hasLength(1));
      container.dispose();
    });

    test('retryAll claims what it can and keeps the rest, in one pass', () async {
      final rig = _Rig();
      rig.chequeApi.claimError = StateError('offline');
      final container = rig.build();
      final notifier = container.read(pendingHandoffsProvider.notifier);
      await notifier.add(_handoff(_chequeId));
      await notifier.add(_handoff(_chequeId2));
      expect(await notifier.future, hasLength(2));

      rig.chequeApi.claimOnlyFor = _chequeId2; // claimError still applies to everything else
      await notifier.retryAll();

      final remaining = await notifier.future;
      expect(remaining.map((h) => h.chequeId), [_chequeId]);
      container.dispose();
    });

    test('an overlapping retryAll call is skipped rather than doubling attempts', () async {
      final rig = _Rig();
      rig.chequeApi.claimDelay = const Duration(milliseconds: 30);
      final container = rig.build();
      final notifier = container.read(pendingHandoffsProvider.notifier);
      await notifier.add(_handoff(_chequeId));
      await notifier.future;

      // add() already kicked one retry; call again while it's still running.
      final second = notifier.retryAll();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await second;

      expect(rig.chequeApi.claimAttempts, 1);
      container.dispose();
    });

    test('once everything is claimed, the retry timer stops (no leaked periodic Timer)', () async {
      final rig = _Rig();
      final container = rig.build();
      final notifier = container.read(pendingHandoffsProvider.notifier);

      await notifier.add(_handoff(_chequeId));
      await notifier.future;
      expect(await notifier.future, isEmpty);

      container.dispose(); // would throw "Timer still pending" if the loop weren't stopped
    });
  });
}
