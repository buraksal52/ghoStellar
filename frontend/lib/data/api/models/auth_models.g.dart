// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'auth_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_TokenPair _$TokenPairFromJson(Map<String, dynamic> json) => _TokenPair(
  accessToken: json['accessToken'] as String,
  refreshToken: json['refreshToken'] as String,
  expiresIn: (json['expiresIn'] as num).toInt(),
);

Map<String, dynamic> _$TokenPairToJson(_TokenPair instance) =>
    <String, dynamic>{
      'accessToken': instance.accessToken,
      'refreshToken': instance.refreshToken,
      'expiresIn': instance.expiresIn,
    };

_AppUser _$AppUserFromJson(Map<String, dynamic> json) => _AppUser(
  stellarAddress: json['StellarAddress'] as String,
  displayName: json['DisplayName'] as String?,
  createdAt: json['CreatedAt'] as String?,
);

Map<String, dynamic> _$AppUserToJson(_AppUser instance) => <String, dynamic>{
  'StellarAddress': instance.stellarAddress,
  'DisplayName': instance.displayName,
  'CreatedAt': instance.createdAt,
};
