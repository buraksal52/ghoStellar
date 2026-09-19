// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tx_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_SubmitResponse _$SubmitResponseFromJson(Map<String, dynamic> json) =>
    _SubmitResponse(
      hash: json['hash'] as String,
      successful: json['successful'] as bool,
      resultCode: json['resultCode'] as String?,
      replayed: json['replayed'] as bool,
    );

Map<String, dynamic> _$SubmitResponseToJson(_SubmitResponse instance) =>
    <String, dynamic>{
      'hash': instance.hash,
      'successful': instance.successful,
      'resultCode': instance.resultCode,
      'replayed': instance.replayed,
    };

_Submission _$SubmissionFromJson(Map<String, dynamic> json) => _Submission(
  idempotencyKey: json['idempotencyKey'] as String,
  purpose: json['purpose'] as String,
  txHash: json['txHash'] as String?,
  state: $enumDecode(_$SubmissionStateEnumMap, json['state']),
  resultCode: json['resultCode'] as String?,
  createdAt: json['createdAt'] as String,
  updatedAt: json['updatedAt'] as String,
);

Map<String, dynamic> _$SubmissionToJson(_Submission instance) =>
    <String, dynamic>{
      'idempotencyKey': instance.idempotencyKey,
      'purpose': instance.purpose,
      'txHash': instance.txHash,
      'state': _$SubmissionStateEnumMap[instance.state]!,
      'resultCode': instance.resultCode,
      'createdAt': instance.createdAt,
      'updatedAt': instance.updatedAt,
    };

const _$SubmissionStateEnumMap = {
  SubmissionState.pending: 'pending',
  SubmissionState.submitted: 'submitted',
  SubmissionState.success: 'success',
  SubmissionState.failed: 'failed',
};
