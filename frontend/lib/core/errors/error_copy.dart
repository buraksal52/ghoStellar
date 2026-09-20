import 'dart:convert';

import '../config/pay_asset.dart';
import 'api_error.dart';

/// Maps every backend error code this app is expected to see to a
/// user-facing message. Codes come straight from `backend/services/*`.
class ErrorCopy {
  ErrorCopy._();

  /// Built on each call (not const) so it always names the deployment's
  /// actual asset ([PayAsset.configured.label]) rather than a hardcoded one.
  static Map<String, String> get _messages {
    final asset = PayAsset.configured.label;
    return {
      'cheque.insufficient_balance':
          'You don\'t have enough balance to send this cheque.',
      'cheque.already_active':
          'You already have an active cheque to this recipient.',
      'cheque.invalid_receiver': 'That recipient address doesn\'t look right.',
      'cheque.receiver_no_trustline':
          'This recipient hasn\'t set up $asset yet, so they can\'t receive it.',
      'cheque.self_transfer': 'You can\'t send a cheque to yourself.',
      'cheque.request_used':
          'That payment request was already paid. Ask for a new one.',
      'cheque.invalid_request_id': 'That payment request isn\'t valid.',
      'network.error': 'No connection. Check your internet and try again.',
      'cheque.invalid_amount': 'Enter a valid amount.',
      'cheque.expired': 'This cheque has expired.',
      'cheque.terminal_state': 'This cheque can no longer be acted on.',
      'cheque.not_found': 'That cheque could not be found.',
      'cheque.account_not_funded':
          "Your wallet isn't set up yet — get test funds from Settings first.",
      'cheque.simulation_failed':
          'The network rejected this. Check that $asset is set up on your wallet and that you have enough $asset.',
      'cheque.bad_request': 'That request could not be processed. Please check it and try again.',
      'pool.withdraw_locked':
          'Your pool balance isn\'t withdrawable yet — deposits lock for a period after each deposit.',
      'chain.rpc_unavailable':
          'The Stellar network is temporarily unavailable. Try again shortly.',
      'cheque.db_not_ready': 'Service is starting up — try again in a moment.',
      'auth.invalid_signature': 'Could not verify your wallet signature.',
      'auth.invalid_token': 'Your session expired — please sign in again.',
      'auth.user_not_found': 'No profile found for this wallet yet.',
      'tx.duplicate_idempotency_key': 'This transaction is already being submitted.',
      'tx.bad_request': 'That transaction could not be submitted.',
      'tx.submit_failed': 'Submitting to Stellar failed. Try again.',
      'tx.not_found': 'That transaction could not be found.',
      'anchor.not_allowed': 'This anchor is not available.',
      'anchor.toml_unavailable': 'Could not reach the anchor right now.',
      'anchor.auth_required': 'Please connect to the anchor first.',
      'anchor.token_rejected': 'Your bank session expired — please try again.',
      'anchor.upstream_failed': 'The anchor could not complete this request.',
      'anchor.bad_request': 'That request to the anchor was invalid.',
      'anchor.db_not_ready': 'Service is starting up — try again in a moment.',
      'anchor.trustline_missing': 'Set up $asset before continuing.',
      'auth.fund_failed': "Couldn't set up your wallet right now. Try again in a moment.",
      'anchor.account_not_funded':
          "Your wallet isn't set up yet — get test funds from Settings first.",
    };
  }

  static String forCode(String code) =>
      _messages[code] ?? 'Something went wrong. Please try again.';

  /// Horizon transaction result codes carried in `tx.submit_failed`'s message
  /// (see `TxApi.submit`), worded for the user.
  static const Map<String, String> _submitResultMessages = {
    'tx_insufficient_balance':
        'Your account doesn\'t have enough balance to cover the network fee and account reserve. Get test funds from Settings.',
    'tx_failed':
        'The Stellar network rejected the transaction. Make sure your account has enough balance for the reserve and fee — you can get test funds from Settings.',
    'tx_bad_auth':
        'The transaction signature was not accepted. Check that the app is on the right Stellar network.',
    'tx_bad_seq': 'Your account changed while signing. Please try again.',
  };

  static String forException(ApiException e) {
    if (e.code == 'tx.submit_failed') {
      final specific = _submitResultMessages[e.message];
      if (specific != null) return specific;
    }
    if (e.code == 'anchor.upstream_failed') {
      // The anchor's own words when it refused (e.g. an amount outside its
      // limits) — carried as an embedded `{"error": "..."}` body.
      final body = RegExp(r'\{.*\}').firstMatch(e.message)?.group(0);
      if (body != null) {
        try {
          final json = jsonDecode(body);
          final msg = json is Map ? (json['error'] ?? json['message']) : null;
          if (msg is String && msg.isNotEmpty) return msg;
        } catch (_) {}
      }
    }
    return forCode(e.code);
  }
}
