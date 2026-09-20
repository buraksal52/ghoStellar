import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/config/pay_asset.dart';
import 'package:ghostellar_app/core/utils/anchor_status.dart';
import 'package:ghostellar_app/data/api/endpoints/anchor_api.dart';
import 'package:ghostellar_app/data/api/models/anchor_models.dart';
import 'package:ghostellar_app/data/storage/local_activity_log.dart';
import 'package:ghostellar_app/features/activity/widgets/activity_item.dart';
import 'package:ghostellar_app/state/activity_providers.dart';
import 'package:ghostellar_app/state/anchor_providers.dart';
import 'package:ghostellar_app/state/core_providers.dart';
import 'package:ghostellar_app/state/sync_providers.dart';
import 'package:ghostellar_app/state/wallet_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart' show KeyPair;

import '../support/fakes.dart';

const _anchor = AnchorInfo(
  id: 'default',
  domain: 'tr-mock-anchor.fly.dev',
  signingKey: 'GSIGNING',
  webAuthEndpoint: 'https://tr-mock-anchor.fly.dev/auth',
  assetCode: 'USDC',
  assetIssuer: 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5',
);

AnchorTransaction _tx({
  String id = 'sep_1',
  String kind = 'deposit',
  String state = 'pending_user_transfer_start',
  String? amount,
  int? decimals,
  String startedAt = '2026-09-20T08:00:00Z',
  String updatedAt = '2026-09-20T08:00:00Z',
}) =>
    AnchorTransaction(
      id: id,
      anchorId: 'default',
      kind: kind,
      state: state,
      amount: amount,
      decimals: decimals,
      startedAt: startedAt,
      updatedAt: updatedAt,
    );

class _LedgerApi extends Fake implements AnchorApi {
  List<AnchorTransaction> ledger = const [];
  Object? error;

  @override
  Future<List<AnchorTransaction>> transactions(String anchorId) async {
    if (error != null) throw error!;
    return ledger;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ActivityItem.fromAnchorTransaction', () {
    test('a deposit still waiting on the wire has no amount, only its status', () {
      final item = ActivityItem.fromAnchorTransaction(_tx(), assetCode: 'USDC');

      expect(item.title, 'Deposit from Bank');
      expect(item.category, 'anchor');
      expect(item.icon, ActivityIcon.bank);
      expect(item.amountDisplay, isEmpty);
      expect(item.statusLabel, 'Awaiting transfer');
      expect(item.isNegative, isFalse);
    });

    test('a completed deposit shows what arrived, as a credit, in the anchor\'s own asset', () {
      final item = ActivityItem.fromAnchorTransaction(
        _tx(state: 'completed', amount: '20000000', decimals: 7, updatedAt: '2026-09-20T09:30:00Z'),
        assetCode: 'USDC',
      );

      // Never the platform asset ([PayAsset.configured]) — a bank transfer
      // always moves the anchor's own asset.
      expect(item.amountDisplay, '+2 USDC');
      expect(item.statusLabel, 'Completed');
      expect(item.timestamp, DateTime.parse('2026-09-20T09:30:00Z'));
    });

    test('a withdrawal is a debit', () {
      final item = ActivityItem.fromAnchorTransaction(
        _tx(kind: 'withdraw', state: 'completed', amount: '55000000', decimals: 7),
        assetCode: 'USDC',
      );

      expect(item.title, 'Withdrawal to Bank');
      expect(item.amountDisplay, '−5.5 USDC');
      expect(item.isNegative, isTrue);
    });

    test('an empty amount string is treated like no amount, not formatted', () {
      final item = ActivityItem.fromAnchorTransaction(_tx(amount: '', decimals: 0), assetCode: 'USDC');

      expect(item.amountDisplay, isEmpty);
    });

    test('falls back to startedAt when updatedAt is unreadable', () {
      final item = ActivityItem.fromAnchorTransaction(
        _tx(startedAt: '2026-09-19T10:00:00Z', updatedAt: 'not a date'),
        assetCode: 'USDC',
      );

      expect(item.timestamp, DateTime.parse('2026-09-19T10:00:00Z'));
    });
  });

  test('short status labels stay short enough to share a row with the title', () {
    const statuses = [
      'pending_user_transfer_start',
      'pending_anchor',
      'pending_stellar',
      'pending_external',
      'pending_trust',
      'completed',
      'refunded',
      'expired',
      'error',
      'no_market',
      'too_small',
      'too_large',
    ];
    for (final s in statuses) {
      expect(anchorStatusShortLabel(s, assetCode: 'USDC').length, lessThanOrEqualTo(18), reason: s);
    }
    expect(anchorStatusShortLabel('pending_anchor', assetCode: 'USDC'), 'Processing');
    expect(anchorStatusShortLabel('error', assetCode: 'USDC'), 'Failed');
    // The Bank screen keeps the full sentence.
    expect(
      anchorStatusLabel('pending_user_transfer_start', isDeposit: true, assetCode: 'USDC'),
      'Waiting for your bank transfer',
    );
    expect(
      anchorStatusLabel('pending_user_transfer_start', isDeposit: false, assetCode: 'USDC'),
      'Waiting for your USDC payment',
    );
  });

  group('activityItemsProvider', () {
    final me = KeyPair.random();

    ProviderContainer container(_LedgerApi api, {List<String> chequeIds = const []}) {
      final c = ProviderContainer(overrides: [
        walletProvider.overrideWith(() => UnlockedWallet(me)),
        syncProvider.overrideWith(() => FakeSyncNotifier([for (final id in chequeIds) testCheque(id, me.accountId)])),
        anchorApiProvider.overrideWithValue(api),
        primaryAnchorProvider.overrideWithValue(_anchor),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    /// The feed re-runs once the ledger has loaded, so wait for the ledger
    /// first and read the feed after. A ledger that failed to load is part of
    /// what is under test, so its error is not this helper's to raise.
    Future<List<ActivityItem>> feed(ProviderContainer c) async {
      c.listen(activityItemsProvider, (_, _) {}); // keep it alive
      await c.read(syncProvider.future);
      try {
        await c.read(anchorTransactionsProvider.future);
      } catch (_) {}
      return c.read(activityItemsProvider.future);
    }

    test('lists bank transfers from the backend ledger next to cheques, newest first', () async {
      final api = _LedgerApi()
        ..ledger = [
          _tx(id: 'new', updatedAt: '2026-09-20T09:00:00Z'),
          _tx(id: 'old', kind: 'withdraw', state: 'completed', amount: '10000000', decimals: 7, updatedAt: '2026-09-01T09:00:00Z'),
        ];
      final items = await feed(container(api, chequeIds: ['01J8F2K9ABCDEFGHJKMNPQRSTV']));

      expect(items.where((i) => i.category == 'anchor'), hasLength(2));
      expect(items.where((i) => i.category == 'pay'), hasLength(1));
      final bank = items.where((i) => i.category == 'anchor').toList();
      expect(bank.first.statusLabel, 'Awaiting transfer', reason: 'the pending one is the newest');
      expect(bank.last.title, 'Withdrawal to Bank');
      final times = items.map((i) => i.timestamp).toList();
      expect(times, orderedEquals([...times]..sort((a, b) => b.compareTo(a))));
    });

    test('a pending transfer is listed even though nothing was ever logged locally', () async {
      final api = _LedgerApi()..ledger = [_tx()];
      final items = await feed(container(api));

      expect(items.single.statusLabel, 'Awaiting transfer');
    });

    test('legacy local anchor events are ignored so a transfer is not listed twice', () async {
      final log = LocalActivityLog();
      await log.append(LocalActivityEvent(
        kind: 'anchor_deposit',
        amount: '2.0000000',
        timestamp: DateTime.parse('2026-09-20T09:30:00Z'),
      ));
      await log.append(LocalActivityEvent(
        kind: 'pool_deposit',
        amount: '3',
        timestamp: DateTime.parse('2026-09-20T07:00:00Z'),
      ));
      final api = _LedgerApi()
        ..ledger = [_tx(state: 'completed', amount: '20000000', decimals: 7, updatedAt: '2026-09-20T09:30:00Z')];

      final items = await feed(container(api));

      expect(items.where((i) => i.category == 'anchor'), hasLength(1));
      final poolItems = items.where((i) => i.category == 'pool').toList();
      expect(poolItems, hasLength(1), reason: 'pool events still come from the log');
      // Regression: the pool is always in the platform's own asset, never
      // whatever the anchor happens to use (USDC here) — even for an event
      // logged before this device knew the difference.
      expect(poolItems.single.amountDisplay, endsWith(' ${PayAsset.configured.label}'));
      expect(poolItems.single.amountDisplay, isNot(contains('USDC')));
    });

    test('an unreachable anchor service leaves the cheques in place instead of failing the feed', () async {
      final api = _LedgerApi()..error = StateError('anchor down');
      final items = await feed(container(api, chequeIds: ['01J8F2K9ABCDEFGHJKMNPQRSTV']));

      expect(items.where((i) => i.category == 'pay'), hasLength(1));
      expect(items.where((i) => i.category == 'anchor'), isEmpty);
    });
  });
}
