/// User-facing wording for a SEP-6 transaction status, shared by the Bank
/// screen and the activity feed so both say the same thing about a transfer.
String anchorStatusLabel(String status, {required bool isDeposit}) => switch (status) {
      'pending_user_transfer_start' => isDeposit ? 'Waiting for your bank transfer' : 'Waiting for your USDC payment',
      'pending_anchor' => 'The anchor is processing it',
      'pending_stellar' => 'Sending on Stellar',
      'pending_external' => 'Waiting on the bank',
      'pending_trust' => 'Set up USDC to receive the funds',
      'completed' => 'Completed',
      'refunded' => 'Refunded',
      'expired' => 'Expired',
      'error' => 'Failed',
      'no_market' || 'too_small' || 'too_large' => 'Amount not accepted',
      _ => status.replaceAll('_', ' '),
    };

/// The same status as one short word or two, for the activity feed: its rows
/// share a line with the title, so the full sentences above would squeeze it.
String anchorStatusShortLabel(String status) => switch (status) {
      'pending_user_transfer_start' => 'Awaiting transfer',
      'pending_anchor' || 'pending_stellar' || 'pending_external' => 'Processing',
      'pending_trust' => 'Needs USDC setup',
      'completed' => 'Completed',
      'refunded' => 'Refunded',
      'expired' => 'Expired',
      'error' => 'Failed',
      'no_market' || 'too_small' || 'too_large' => 'Rejected',
      _ => status.replaceAll('_', ' '),
    };
