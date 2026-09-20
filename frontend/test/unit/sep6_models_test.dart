import 'package:flutter_test/flutter_test.dart';
import 'package:ghostellar_app/data/api/models/sep6_models.dart';

// Payloads captured from the live TR anchor (tr-mock-anchor.fly.dev).
void main() {
  test('Sep6Deposit parses structured bank instructions', () {
    final d = Sep6Deposit.fromJson({
      'id': 'sep_7uvzvpqfvluq7gmnshi3',
      'how': 'Send TRY to IBAN TR05...',
      'instructions': {
        'bank_name': {'value': 'TR Mock Bank A.Ş.', 'description': 'Bank holding the anchor account'},
        'bank_account_number': {'value': 'TR050009900000000000000001', 'description': 'IBAN'},
        'external_transfer_memo': {'value': 'TRMA-A9LA-MULF', 'description': 'Reference'},
      },
      'eta': 5,
    });
    expect(d.id, 'sep_7uvzvpqfvluq7gmnshi3');
    expect(d.instructions.map((i) => i.value), ['TR Mock Bank A.Ş.', 'TR050009900000000000000001', 'TRMA-A9LA-MULF']);
    expect(d.instructions[1].label, 'Bank account number');
  });

  test('Sep6Deposit tolerates an anchor with no structured instructions', () {
    final d = Sep6Deposit.fromJson({'id': 'x', 'how': 'Wire to IBAN ...'});
    expect(d.instructions, isEmpty);
    expect(d.how, 'Wire to IBAN ...');
  });

  test('Sep6Withdraw parses destination, memo and the anchor message', () {
    final w = Sep6Withdraw.fromJson({
      'account_id': 'GCLCZEQZ2THTEDAOFI66LACNPLY4OBKN7VKLEZFMBIHYKYQOW2W7T3Z6',
      'memo_type': 'id',
      'memo': '586146517297',
      'id': 'sep_pnw27s7d389kcmippq5i',
      'extra_info': {'message': 'Send 5.0000000 USDC ...'},
    });
    expect(w.accountId, startsWith('GCLC'));
    expect(w.memoType, 'id');
    expect(w.memo, '586146517297');
    expect(w.message, startsWith('Send 5'));
  });

  test('Sep6Transaction unwraps {"transaction": ...} and reads status', () {
    final t = Sep6Transaction.fromJson({
      'transaction': {
        'id': 'sep_7uvzvpqfvluq7gmnshi3',
        'status': 'pending_user_transfer_start',
        'amount_in': '100.00',
        'amount_out': null,
        'stellar_transaction_id': null,
      },
    });
    expect(t.status, 'pending_user_transfer_start');
    expect(t.amountIn, '100.00');
    expect(t.amountOut, isNull);
    expect(t.isTerminal, isFalse);
  });

  test('terminal statuses stop polling; in-flight ones do not', () {
    Sep6Transaction tx(String s) => Sep6Transaction(id: 'x', status: s);
    for (final s in ['completed', 'error', 'refunded', 'expired', 'no_market', 'too_small', 'too_large']) {
      expect(tx(s).isTerminal, isTrue, reason: s);
    }
    for (final s in ['pending_user_transfer_start', 'pending_anchor', 'pending_stellar', 'pending_trust', 'pending_external']) {
      expect(tx(s).isTerminal, isFalse, reason: s);
    }
    expect(tx('completed').isCompleted, isTrue);
  });
}
