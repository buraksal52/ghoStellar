import '../utils/amount_formatter.dart';
import '../utils/stellar_address.dart';

/// A payment request the receiver shows (NFC or QR) and the sender reads:
/// a SEP-7 `web+stellar:pay` URI with ghoStellar's own `x_req` / `x_exp`
/// extensions, or a bare `G...` address (what the app showed before amounts
/// existed, and what other wallets display).
///
/// Parsing is deliberately separate from policy: [tryParse] only says
/// "this is a well-formed request"; whether it is expired or already used is
/// the caller's decision ([isExpiredAt]) so the UI can tell the user *why*
/// a scan was refused.
///
/// The amount is a decimal string end to end — never a double.
class PaymentRequest {
  const PaymentRequest({
    required this.destination,
    this.amount,
    this.nonce,
    this.expiresAt,
  });

  static const scheme = 'web+stellar';
  static const assetCode = 'XLM';
  static const _maxNonceLength = 64;

  final String destination;

  /// Plain decimal string, or null when the sender chooses the amount.
  final String? amount;

  /// Single-use id; the sender remembers it so a replayed QR is refused.
  final String? nonce;

  final DateTime? expiresAt;

  bool isExpiredAt(DateTime now) => expiresAt != null && !now.isBefore(expiresAt!);

  /// Returns null for anything that is not a request we can act on: a
  /// foreign scheme, a secret seed / muxed address, a malformed or
  /// non-positive amount, or an asset other than the native one.
  static PaymentRequest? tryParse(String? raw) {
    if (raw == null) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;

    if (StellarAddress.isValid(text)) return PaymentRequest(destination: text);

    final uri = Uri.tryParse(text);
    if (uri == null || uri.scheme.toLowerCase() != scheme || uri.path != 'pay') return null;

    final q = uri.queryParameters;
    final destination = q['destination']?.trim();
    if (!StellarAddress.isValid(destination)) return null;

    final amount = q['amount'];
    if (amount != null && !AmountFormatter.isValidPositiveDecimal(amount)) return null;

    final asset = q['asset_code'];
    if (asset != null && asset != assetCode) return null;
    if (q.containsKey('asset_issuer')) return null;

    final nonce = q['x_req'];
    if (nonce != null && (nonce.isEmpty || nonce.length > _maxNonceLength)) return null;

    DateTime? expiresAt;
    final exp = q['x_exp'];
    if (exp != null) {
      final seconds = int.tryParse(exp);
      if (seconds == null || seconds <= 0) return null;
      expiresAt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    }

    return PaymentRequest(
      destination: destination!,
      amount: amount,
      nonce: nonce,
      expiresAt: expiresAt,
    );
  }

  String toUri() {
    return Uri(
      scheme: scheme,
      path: 'pay',
      queryParameters: {
        'destination': destination,
        if (amount != null) 'amount': amount!,
        'asset_code': assetCode,
        'msg': 'ghoStellar',
        if (nonce != null) 'x_req': nonce!,
        if (expiresAt != null) 'x_exp': '${expiresAt!.millisecondsSinceEpoch ~/ 1000}',
      },
    ).toString();
  }
}

/// What the sender hands back after the cheque is locked, so the receiver
/// can claim without waiting for `/sync`: `ghostellar://cheque?id=…`.
///
/// This is not SEP-7 on purpose — "pay" would tell another wallet to send
/// money. A leaked [chequeId] is harmless: the backend and the contract only
/// let the receiver fixed at lock time claim it.
class ChequeHandoff {
  const ChequeHandoff({
    required this.chequeId,
    required this.from,
    this.amount,
    this.nonce,
  });

  static const scheme = 'ghostellar';

  /// `chequeId` ends up in a URL path (`/cheques/{id}/claim-xdr`), and this
  /// value comes from a scanned payload — so it is pinned to the backend's
  /// ULID shape rather than passed through.
  static final _ulid = RegExp(r'^[0-9A-Za-z]{26}$');

  final String chequeId;
  final String from;
  final String? amount;

  /// The `x_req` of the request this answers.
  final String? nonce;

  static ChequeHandoff? tryParse(String? raw) {
    if (raw == null) return null;
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme.toLowerCase() != scheme || uri.host != 'cheque') return null;

    final q = uri.queryParameters;
    final id = q['id'];
    final from = q['from']?.trim();
    if (id == null || !_ulid.hasMatch(id)) return null;
    if (!StellarAddress.isValid(from)) return null;

    final amount = q['amount'];
    if (amount != null && !AmountFormatter.isValidPositiveDecimal(amount)) return null;

    return ChequeHandoff(chequeId: id, from: from!, amount: amount, nonce: q['req']);
  }

  String toUri() {
    return Uri(
      scheme: scheme,
      host: 'cheque',
      queryParameters: {
        'id': chequeId,
        'from': from,
        if (amount != null) 'amount': amount!,
        if (nonce != null) 'req': nonce!,
      },
    ).toString();
  }
}
