import 'package:freezed_annotation/freezed_annotation.dart';

part 'tx_models.freezed.dart';
part 'tx_models.g.dart';

enum TxKind {
  @JsonValue('classic')
  classic,
  @JsonValue('soroban')
  soroban,
}

enum SubmissionState {
  @JsonValue('pending')
  pending,
  @JsonValue('submitted')
  submitted,
  @JsonValue('success')
  success,
  @JsonValue('failed')
  failed,
}

@freezed
abstract class SubmitResponse with _$SubmitResponse {
  const factory SubmitResponse({
    required String hash,
    required bool successful,
    String? resultCode,
    required bool replayed,
  }) = _SubmitResponse;

  factory SubmitResponse.fromJson(Map<String, dynamic> json) =>
      _$SubmitResponseFromJson(json);
}

@freezed
abstract class Submission with _$Submission {
  const factory Submission({
    required String idempotencyKey,
    required String purpose,
    String? txHash,
    required SubmissionState state,
    String? resultCode,
    required String createdAt,
    required String updatedAt,
  }) = _Submission;

  factory Submission.fromJson(Map<String, dynamic> json) =>
      _$SubmissionFromJson(json);
}
