import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/core/errors/api_error.dart';
import 'package:ghostellar_app/core/errors/error_copy.dart';
import 'package:ghostellar_app/data/stellar/horizon_read_service.dart';
import 'package:ghostellar_app/features/activity/widgets/activity_item.dart';

import '../support/fakes.dart';

/// The app has ONE unit — native XLM by default (`PayAsset.configured`, see
/// `env.dart`). A non-native deployment instead shows an issued asset and
/// treats XLM as an invisible fee/reserve balance; that split is what
/// [AccountBalances.feeBalanceLow] exists for, and it is always false while
/// native IS the one asset (there's nothing separate left to warn about).
void main() {
  group('AccountBalances.feeBalanceLow (only meaningful for a non-native deployment)', () {
    test('always false for the default (native) deployment, however low the balance is', () {
      AccountBalances withNative(String native) => AccountBalances(native: native, other: const {});
      expect(withNative('0').feeBalanceLow, isFalse);
      expect(withNative('1.9999999').feeBalanceLow, isFalse);
      expect(withNative('9999.9999900').feeBalanceLow, isFalse);
    });

    test('an account that does not exist is "not funded", not "low"', () {
      expect(AccountBalances.notFunded.feeBalanceLow, isFalse);
    });
  });

  group('activity amounts use the app asset', () {
    test('a sent cheque reads in the configured asset', () {
      final item = ActivityItem.fromCheque(testCheque('c1', 'GRECEIVER', sender: testSender), myAddress: testSender);
      expect(item.amountDisplay, '−25.5 XLM');
    });

    test('a received cheque reads in the configured asset', () {
      final item = ActivityItem.fromCheque(testCheque('c2', testSender, sender: 'GOTHER'), myAddress: testSender);
      expect(item.amountDisplay, '+25.5 XLM');
    });
  });

  group('user-facing copy carries no stray unit', () {
    test('errors that used to hardcode a unit', () {
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
