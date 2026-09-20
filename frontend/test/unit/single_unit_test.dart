import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/core/errors/error_copy.dart';
import 'package:ghostellar_app/data/stellar/horizon_read_service.dart';
import 'package:ghostellar_app/features/activity/widgets/activity_item.dart';

import '../support/fakes.dart';

/// The app has ONE unit (USDC). XLM exists on every account for fees and the
/// reserve, but must never be shown to the user as an amount or a unit.
void main() {
  group('AccountBalances.feeBalanceLow (the only place XLM matters to the UI)', () {
    AccountBalances withNative(String native) => AccountBalances(native: native, other: const {'USDC': '1'});

    test('below 2 → low', () {
      expect(withNative('1.9999999').feeBalanceLow, isTrue);
      expect(withNative('0.5000000').feeBalanceLow, isTrue);
      expect(withNative('0').feeBalanceLow, isTrue);
    });

    test('2 and above → not low', () {
      expect(withNative('2.0000000').feeBalanceLow, isFalse);
      expect(withNative('2').feeBalanceLow, isFalse);
      expect(withNative('9999.9999900').feeBalanceLow, isFalse);
    });

    test('an account that does not exist is "not funded", not "low"', () {
      expect(AccountBalances.notFunded.feeBalanceLow, isFalse);
    });

    test('a malformed balance never raises the warning', () {
      expect(withNative('not-a-number').feeBalanceLow, isFalse);
    });
  });

  group('activity amounts use the app asset, never XLM', () {
    test('a sent cheque reads in USDC', () {
      final item = ActivityItem.fromCheque(testCheque('c1', 'GRECEIVER', sender: testSender), myAddress: testSender);
      expect(item.amountDisplay, '−25.5 USDC');
      expect(item.amountDisplay, isNot(contains('XLM')));
    });

    test('a received cheque reads in USDC', () {
      final item = ActivityItem.fromCheque(testCheque('c2', testSender, sender: 'GOTHER'), myAddress: testSender);
      expect(item.amountDisplay, '+25.5 USDC');
    });
  });

  group('user-facing copy carries no XLM unit', () {
    test('errors that used to say XLM', () {
      for (final code in ['cheque.account_not_funded', 'anchor.account_not_funded']) {
        expect(ErrorCopy.forCode(code), isNot(contains('XLM')), reason: code);
      }
      for (final result in ['tx_insufficient_balance', 'tx_failed']) {
        final copy = ErrorCopy.forException(ApiException(code: 'tx.submit_failed', message: result));
        expect(copy, isNot(contains('XLM')), reason: result);
      }
    });
  });
}
