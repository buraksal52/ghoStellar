// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cheque_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Cheque _$ChequeFromJson(Map<String, dynamic> json) => _Cheque(
  id: json['id'] as String,
  senderAddress: json['senderAddress'] as String,
  receiverAddress: json['receiverAddress'] as String,
  tokenContract: json['tokenContract'] as String,
  amountRaw: json['amountRaw'] as String,
  decimals: (json['decimals'] as num).toInt(),
  state: $enumDecode(_$ChequeStateEnumMap, json['state']),
  expiresAt: json['expiresAt'] as String,
  lockTxHash: json['lockTxHash'] as String?,
  createdAt: json['createdAt'] as String,
  updatedAt: json['updatedAt'] as String,
);

Map<String, dynamic> _$ChequeToJson(_Cheque instance) => <String, dynamic>{
  'id': instance.id,
  'senderAddress': instance.senderAddress,
  'receiverAddress': instance.receiverAddress,
  'tokenContract': instance.tokenContract,
  'amountRaw': instance.amountRaw,
  'decimals': instance.decimals,
  'state': _$ChequeStateEnumMap[instance.state]!,
  'expiresAt': instance.expiresAt,
  'lockTxHash': instance.lockTxHash,
  'createdAt': instance.createdAt,
  'updatedAt': instance.updatedAt,
};

const _$ChequeStateEnumMap = {
  ChequeState.taslak: 'TASLAK',
  ChequeState.imzaliRezerve: 'IMZALI_REZERVE',
  ChequeState.fonlaniyor: 'FONLANIYOR',
  ChequeState.havuzda: 'HAVUZDA',
  ChequeState.talepEdildi: 'TALEP_EDILDI',
  ChequeState.onaylandi: 'ONAYLANDI',
  ChequeState.kapandi: 'KAPANDI',
  ChequeState.iadeEdilebilir: 'IADE_EDILEBILIR',
  ChequeState.iadeEdildi: 'IADE_EDILDI',
  ChequeState.hukumsuz: 'HUKUMSUZ',
  ChequeState.zorlaTahsilDenendi: 'ZORLA_TAHSIL_DENENDI',
  ChequeState.karsiliksiz: 'KARSILIKSIZ',
};

_PoolDeposit _$PoolDepositFromJson(Map<String, dynamic> json) => _PoolDeposit(
  ownerAddress: json['ownerAddress'] as String,
  amountRaw: json['amountRaw'] as String,
  decimals: (json['decimals'] as num).toInt(),
  lastDepositLedger: (json['lastDepositLedger'] as num?)?.toInt(),
  updatedAt: json['updatedAt'] as String,
);

Map<String, dynamic> _$PoolDepositToJson(_PoolDeposit instance) =>
    <String, dynamic>{
      'ownerAddress': instance.ownerAddress,
      'amountRaw': instance.amountRaw,
      'decimals': instance.decimals,
      'lastDepositLedger': instance.lastDepositLedger,
      'updatedAt': instance.updatedAt,
    };

_SyncResponse _$SyncResponseFromJson(Map<String, dynamic> json) =>
    _SyncResponse(
      cheques: (json['cheques'] as List<dynamic>)
          .map((e) => Cheque.fromJson(e as Map<String, dynamic>))
          .toList(),
      pool: PoolDeposit.fromJson(json['pool'] as Map<String, dynamic>),
      trustlineReady: json['trustlineReady'] as bool,
      ledgerSeq: (json['ledgerSeq'] as num).toInt(),
      serverTimeUnix: (json['serverTimeUnix'] as num).toInt(),
    );

Map<String, dynamic> _$SyncResponseToJson(_SyncResponse instance) =>
    <String, dynamic>{
      'cheques': instance.cheques,
      'pool': instance.pool,
      'trustlineReady': instance.trustlineReady,
      'ledgerSeq': instance.ledgerSeq,
      'serverTimeUnix': instance.serverTimeUnix,
    };

_CreateChequeResult _$CreateChequeResultFromJson(Map<String, dynamic> json) =>
    _CreateChequeResult(
      chequeId: json['chequeId'] as String,
      lockXdr: json['lockXdr'] as String,
      preauthEntryXdr: json['preauthEntryXdr'] as String,
      preauthPayloadHash: json['preauthPayloadHash'] as String,
      expiresAt: json['expiresAt'] as String,
    );

Map<String, dynamic> _$CreateChequeResultToJson(_CreateChequeResult instance) =>
    <String, dynamic>{
      'chequeId': instance.chequeId,
      'lockXdr': instance.lockXdr,
      'preauthEntryXdr': instance.preauthEntryXdr,
      'preauthPayloadHash': instance.preauthPayloadHash,
      'expiresAt': instance.expiresAt,
    };
