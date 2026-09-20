import 'package:freezed_annotation/freezed_annotation.dart';

part 'anchor_models.freezed.dart';
part 'anchor_models.g.dart';

@freezed
abstract class AnchorInfo with _$AnchorInfo {
  const factory AnchorInfo({
    required String id,
    required String domain,
    required String signingKey,
    required String webAuthEndpoint,
    // Omitted by the backend when the anchor publishes no SEP-24 server
    // (the TR anchor is SEP-6 only), so it must not be required.
    @Default('') String transferServer24,
    required String assetCode,
    required String assetIssuer,
  }) = _AnchorInfo;

  factory AnchorInfo.fromJson(Map<String, dynamic> json) =>
      _$AnchorInfoFromJson(json);
}

@freezed
abstract class AnchorTransaction with _$AnchorTransaction {
  const factory AnchorTransaction({
    required String id,
    required String anchorId,
    required String kind,
    required String state,
    String? amount,
    int? decimals,
    String? stellarTxHash,
    required String startedAt,
    required String updatedAt,
  }) = _AnchorTransaction;

  factory AnchorTransaction.fromJson(Map<String, dynamic> json) =>
      _$AnchorTransactionFromJson(json);
}
