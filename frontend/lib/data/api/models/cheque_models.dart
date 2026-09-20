import 'package:freezed_annotation/freezed_annotation.dart';

part 'cheque_models.freezed.dart';
part 'cheque_models.g.dart';

/// Mirrors `backend/services/cheque/model.go`'s state machine.
enum ChequeState {
  @JsonValue('TASLAK')
  taslak,
  @JsonValue('IMZALI_REZERVE')
  imzaliRezerve,
  @JsonValue('FONLANIYOR')
  fonlaniyor,
  @JsonValue('HAVUZDA')
  havuzda,
  @JsonValue('TALEP_EDILDI')
  talepEdildi,
  @JsonValue('ONAYLANDI')
  onaylandi,
  @JsonValue('KAPANDI')
  kapandi,
  @JsonValue('IADE_EDILEBILIR')
  iadeEdilebilir,
  @JsonValue('IADE_EDILDI')
  iadeEdildi,
  @JsonValue('HUKUMSUZ')
  hukumsuz,
  @JsonValue('ZORLA_TAHSIL_DENENDI')
  zorlaTahsilDenendi,
  @JsonValue('KARSILIKSIZ')
  karsiliksiz,
}

@freezed
abstract class Cheque with _$Cheque {
  const factory Cheque({
    required String id,
    required String senderAddress,
    required String receiverAddress,

    /// The single-use payment-request id this cheque answers (tap/scan
    /// flow); null for a plain cheque. Unique per receiver on the server.
    String? requestId,
    required String tokenContract,
    required String amountRaw,
    required int decimals,
    required ChequeState state,
    required String expiresAt,
    String? lockTxHash,
    required String createdAt,
    required String updatedAt,
  }) = _Cheque;

  factory Cheque.fromJson(Map<String, dynamic> json) =>
      _$ChequeFromJson(json);
}

@freezed
abstract class PoolDeposit with _$PoolDeposit {
  const factory PoolDeposit({
    required String ownerAddress,
    required String amountRaw,
    required int decimals,
    int? lastDepositLedger,
    required String updatedAt,
  }) = _PoolDeposit;

  factory PoolDeposit.fromJson(Map<String, dynamic> json) =>
      _$PoolDepositFromJson(json);
}

@freezed
abstract class SyncResponse with _$SyncResponse {
  const factory SyncResponse({
    required List<Cheque> cheques,
    required PoolDeposit pool,
    required bool trustlineReady,
    required int ledgerSeq,
    required int serverTimeUnix,
  }) = _SyncResponse;

  factory SyncResponse.fromJson(Map<String, dynamic> json) =>
      _$SyncResponseFromJson(json);
}

@freezed
abstract class CreateChequeResult with _$CreateChequeResult {
  const factory CreateChequeResult({
    required String chequeId,
    required String lockXdr,
    required String preauthEntryXdr,
    required String preauthPayloadHash,
    required String expiresAt,
  }) = _CreateChequeResult;

  factory CreateChequeResult.fromJson(Map<String, dynamic> json) =>
      _$CreateChequeResultFromJson(json);
}
