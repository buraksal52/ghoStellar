// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'anchor_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_AnchorInfo _$AnchorInfoFromJson(Map<String, dynamic> json) => _AnchorInfo(
  id: json['id'] as String,
  domain: json['domain'] as String,
  signingKey: json['signingKey'] as String,
  webAuthEndpoint: json['webAuthEndpoint'] as String,
  transferServer24: json['transferServer24'] as String? ?? '',
  assetCode: json['assetCode'] as String,
  assetIssuer: json['assetIssuer'] as String,
);

Map<String, dynamic> _$AnchorInfoToJson(_AnchorInfo instance) =>
    <String, dynamic>{
      'id': instance.id,
      'domain': instance.domain,
      'signingKey': instance.signingKey,
      'webAuthEndpoint': instance.webAuthEndpoint,
      'transferServer24': instance.transferServer24,
      'assetCode': instance.assetCode,
      'assetIssuer': instance.assetIssuer,
    };

_AnchorTransaction _$AnchorTransactionFromJson(Map<String, dynamic> json) =>
    _AnchorTransaction(
      id: json['id'] as String,
      anchorId: json['anchorId'] as String,
      kind: json['kind'] as String,
      state: json['state'] as String,
      amount: json['amount'] as String?,
      decimals: (json['decimals'] as num?)?.toInt(),
      stellarTxHash: json['stellarTxHash'] as String?,
      startedAt: json['startedAt'] as String,
      updatedAt: json['updatedAt'] as String,
    );

Map<String, dynamic> _$AnchorTransactionToJson(_AnchorTransaction instance) =>
    <String, dynamic>{
      'id': instance.id,
      'anchorId': instance.anchorId,
      'kind': instance.kind,
      'state': instance.state,
      'amount': instance.amount,
      'decimals': instance.decimals,
      'stellarTxHash': instance.stellarTxHash,
      'startedAt': instance.startedAt,
      'updatedAt': instance.updatedAt,
    };
