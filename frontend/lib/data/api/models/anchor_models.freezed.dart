// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'anchor_models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$AnchorInfo {

 String get id; String get domain; String get signingKey; String get webAuthEndpoint;// Omitted by the backend when the anchor publishes no SEP-24 server
// (the TR anchor is SEP-6 only), so it must not be required.
 String get transferServer24; String get assetCode; String get assetIssuer;
/// Create a copy of AnchorInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AnchorInfoCopyWith<AnchorInfo> get copyWith => _$AnchorInfoCopyWithImpl<AnchorInfo>(this as AnchorInfo, _$identity);

  /// Serializes this AnchorInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AnchorInfo&&(identical(other.id, id) || other.id == id)&&(identical(other.domain, domain) || other.domain == domain)&&(identical(other.signingKey, signingKey) || other.signingKey == signingKey)&&(identical(other.webAuthEndpoint, webAuthEndpoint) || other.webAuthEndpoint == webAuthEndpoint)&&(identical(other.transferServer24, transferServer24) || other.transferServer24 == transferServer24)&&(identical(other.assetCode, assetCode) || other.assetCode == assetCode)&&(identical(other.assetIssuer, assetIssuer) || other.assetIssuer == assetIssuer));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,domain,signingKey,webAuthEndpoint,transferServer24,assetCode,assetIssuer);

@override
String toString() {
  return 'AnchorInfo(id: $id, domain: $domain, signingKey: $signingKey, webAuthEndpoint: $webAuthEndpoint, transferServer24: $transferServer24, assetCode: $assetCode, assetIssuer: $assetIssuer)';
}


}

/// @nodoc
abstract mixin class $AnchorInfoCopyWith<$Res>  {
  factory $AnchorInfoCopyWith(AnchorInfo value, $Res Function(AnchorInfo) _then) = _$AnchorInfoCopyWithImpl;
@useResult
$Res call({
 String id, String domain, String signingKey, String webAuthEndpoint, String transferServer24, String assetCode, String assetIssuer
});




}
/// @nodoc
class _$AnchorInfoCopyWithImpl<$Res>
    implements $AnchorInfoCopyWith<$Res> {
  _$AnchorInfoCopyWithImpl(this._self, this._then);

  final AnchorInfo _self;
  final $Res Function(AnchorInfo) _then;

/// Create a copy of AnchorInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? domain = null,Object? signingKey = null,Object? webAuthEndpoint = null,Object? transferServer24 = null,Object? assetCode = null,Object? assetIssuer = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,domain: null == domain ? _self.domain : domain // ignore: cast_nullable_to_non_nullable
as String,signingKey: null == signingKey ? _self.signingKey : signingKey // ignore: cast_nullable_to_non_nullable
as String,webAuthEndpoint: null == webAuthEndpoint ? _self.webAuthEndpoint : webAuthEndpoint // ignore: cast_nullable_to_non_nullable
as String,transferServer24: null == transferServer24 ? _self.transferServer24 : transferServer24 // ignore: cast_nullable_to_non_nullable
as String,assetCode: null == assetCode ? _self.assetCode : assetCode // ignore: cast_nullable_to_non_nullable
as String,assetIssuer: null == assetIssuer ? _self.assetIssuer : assetIssuer // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [AnchorInfo].
extension AnchorInfoPatterns on AnchorInfo {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AnchorInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AnchorInfo() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AnchorInfo value)  $default,){
final _that = this;
switch (_that) {
case _AnchorInfo():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AnchorInfo value)?  $default,){
final _that = this;
switch (_that) {
case _AnchorInfo() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String domain,  String signingKey,  String webAuthEndpoint,  String transferServer24,  String assetCode,  String assetIssuer)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AnchorInfo() when $default != null:
return $default(_that.id,_that.domain,_that.signingKey,_that.webAuthEndpoint,_that.transferServer24,_that.assetCode,_that.assetIssuer);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String domain,  String signingKey,  String webAuthEndpoint,  String transferServer24,  String assetCode,  String assetIssuer)  $default,) {final _that = this;
switch (_that) {
case _AnchorInfo():
return $default(_that.id,_that.domain,_that.signingKey,_that.webAuthEndpoint,_that.transferServer24,_that.assetCode,_that.assetIssuer);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String domain,  String signingKey,  String webAuthEndpoint,  String transferServer24,  String assetCode,  String assetIssuer)?  $default,) {final _that = this;
switch (_that) {
case _AnchorInfo() when $default != null:
return $default(_that.id,_that.domain,_that.signingKey,_that.webAuthEndpoint,_that.transferServer24,_that.assetCode,_that.assetIssuer);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AnchorInfo implements AnchorInfo {
  const _AnchorInfo({required this.id, required this.domain, required this.signingKey, required this.webAuthEndpoint, this.transferServer24 = '', required this.assetCode, required this.assetIssuer});
  factory _AnchorInfo.fromJson(Map<String, dynamic> json) => _$AnchorInfoFromJson(json);

@override final  String id;
@override final  String domain;
@override final  String signingKey;
@override final  String webAuthEndpoint;
// Omitted by the backend when the anchor publishes no SEP-24 server
// (the TR anchor is SEP-6 only), so it must not be required.
@override@JsonKey() final  String transferServer24;
@override final  String assetCode;
@override final  String assetIssuer;

/// Create a copy of AnchorInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AnchorInfoCopyWith<_AnchorInfo> get copyWith => __$AnchorInfoCopyWithImpl<_AnchorInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AnchorInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AnchorInfo&&(identical(other.id, id) || other.id == id)&&(identical(other.domain, domain) || other.domain == domain)&&(identical(other.signingKey, signingKey) || other.signingKey == signingKey)&&(identical(other.webAuthEndpoint, webAuthEndpoint) || other.webAuthEndpoint == webAuthEndpoint)&&(identical(other.transferServer24, transferServer24) || other.transferServer24 == transferServer24)&&(identical(other.assetCode, assetCode) || other.assetCode == assetCode)&&(identical(other.assetIssuer, assetIssuer) || other.assetIssuer == assetIssuer));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,domain,signingKey,webAuthEndpoint,transferServer24,assetCode,assetIssuer);

@override
String toString() {
  return 'AnchorInfo(id: $id, domain: $domain, signingKey: $signingKey, webAuthEndpoint: $webAuthEndpoint, transferServer24: $transferServer24, assetCode: $assetCode, assetIssuer: $assetIssuer)';
}


}

/// @nodoc
abstract mixin class _$AnchorInfoCopyWith<$Res> implements $AnchorInfoCopyWith<$Res> {
  factory _$AnchorInfoCopyWith(_AnchorInfo value, $Res Function(_AnchorInfo) _then) = __$AnchorInfoCopyWithImpl;
@override @useResult
$Res call({
 String id, String domain, String signingKey, String webAuthEndpoint, String transferServer24, String assetCode, String assetIssuer
});




}
/// @nodoc
class __$AnchorInfoCopyWithImpl<$Res>
    implements _$AnchorInfoCopyWith<$Res> {
  __$AnchorInfoCopyWithImpl(this._self, this._then);

  final _AnchorInfo _self;
  final $Res Function(_AnchorInfo) _then;

/// Create a copy of AnchorInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? domain = null,Object? signingKey = null,Object? webAuthEndpoint = null,Object? transferServer24 = null,Object? assetCode = null,Object? assetIssuer = null,}) {
  return _then(_AnchorInfo(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,domain: null == domain ? _self.domain : domain // ignore: cast_nullable_to_non_nullable
as String,signingKey: null == signingKey ? _self.signingKey : signingKey // ignore: cast_nullable_to_non_nullable
as String,webAuthEndpoint: null == webAuthEndpoint ? _self.webAuthEndpoint : webAuthEndpoint // ignore: cast_nullable_to_non_nullable
as String,transferServer24: null == transferServer24 ? _self.transferServer24 : transferServer24 // ignore: cast_nullable_to_non_nullable
as String,assetCode: null == assetCode ? _self.assetCode : assetCode // ignore: cast_nullable_to_non_nullable
as String,assetIssuer: null == assetIssuer ? _self.assetIssuer : assetIssuer // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$AnchorTransaction {

 String get id; String get anchorId; String get kind; String get state; String? get amount; int? get decimals; String? get stellarTxHash; String get startedAt; String get updatedAt;
/// Create a copy of AnchorTransaction
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AnchorTransactionCopyWith<AnchorTransaction> get copyWith => _$AnchorTransactionCopyWithImpl<AnchorTransaction>(this as AnchorTransaction, _$identity);

  /// Serializes this AnchorTransaction to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AnchorTransaction&&(identical(other.id, id) || other.id == id)&&(identical(other.anchorId, anchorId) || other.anchorId == anchorId)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.state, state) || other.state == state)&&(identical(other.amount, amount) || other.amount == amount)&&(identical(other.decimals, decimals) || other.decimals == decimals)&&(identical(other.stellarTxHash, stellarTxHash) || other.stellarTxHash == stellarTxHash)&&(identical(other.startedAt, startedAt) || other.startedAt == startedAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,anchorId,kind,state,amount,decimals,stellarTxHash,startedAt,updatedAt);

@override
String toString() {
  return 'AnchorTransaction(id: $id, anchorId: $anchorId, kind: $kind, state: $state, amount: $amount, decimals: $decimals, stellarTxHash: $stellarTxHash, startedAt: $startedAt, updatedAt: $updatedAt)';
}


}

/// @nodoc
abstract mixin class $AnchorTransactionCopyWith<$Res>  {
  factory $AnchorTransactionCopyWith(AnchorTransaction value, $Res Function(AnchorTransaction) _then) = _$AnchorTransactionCopyWithImpl;
@useResult
$Res call({
 String id, String anchorId, String kind, String state, String? amount, int? decimals, String? stellarTxHash, String startedAt, String updatedAt
});




}
/// @nodoc
class _$AnchorTransactionCopyWithImpl<$Res>
    implements $AnchorTransactionCopyWith<$Res> {
  _$AnchorTransactionCopyWithImpl(this._self, this._then);

  final AnchorTransaction _self;
  final $Res Function(AnchorTransaction) _then;

/// Create a copy of AnchorTransaction
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? anchorId = null,Object? kind = null,Object? state = null,Object? amount = freezed,Object? decimals = freezed,Object? stellarTxHash = freezed,Object? startedAt = null,Object? updatedAt = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,anchorId: null == anchorId ? _self.anchorId : anchorId // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as String,amount: freezed == amount ? _self.amount : amount // ignore: cast_nullable_to_non_nullable
as String?,decimals: freezed == decimals ? _self.decimals : decimals // ignore: cast_nullable_to_non_nullable
as int?,stellarTxHash: freezed == stellarTxHash ? _self.stellarTxHash : stellarTxHash // ignore: cast_nullable_to_non_nullable
as String?,startedAt: null == startedAt ? _self.startedAt : startedAt // ignore: cast_nullable_to_non_nullable
as String,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [AnchorTransaction].
extension AnchorTransactionPatterns on AnchorTransaction {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AnchorTransaction value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AnchorTransaction() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AnchorTransaction value)  $default,){
final _that = this;
switch (_that) {
case _AnchorTransaction():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AnchorTransaction value)?  $default,){
final _that = this;
switch (_that) {
case _AnchorTransaction() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String anchorId,  String kind,  String state,  String? amount,  int? decimals,  String? stellarTxHash,  String startedAt,  String updatedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AnchorTransaction() when $default != null:
return $default(_that.id,_that.anchorId,_that.kind,_that.state,_that.amount,_that.decimals,_that.stellarTxHash,_that.startedAt,_that.updatedAt);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String anchorId,  String kind,  String state,  String? amount,  int? decimals,  String? stellarTxHash,  String startedAt,  String updatedAt)  $default,) {final _that = this;
switch (_that) {
case _AnchorTransaction():
return $default(_that.id,_that.anchorId,_that.kind,_that.state,_that.amount,_that.decimals,_that.stellarTxHash,_that.startedAt,_that.updatedAt);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String anchorId,  String kind,  String state,  String? amount,  int? decimals,  String? stellarTxHash,  String startedAt,  String updatedAt)?  $default,) {final _that = this;
switch (_that) {
case _AnchorTransaction() when $default != null:
return $default(_that.id,_that.anchorId,_that.kind,_that.state,_that.amount,_that.decimals,_that.stellarTxHash,_that.startedAt,_that.updatedAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AnchorTransaction implements AnchorTransaction {
  const _AnchorTransaction({required this.id, required this.anchorId, required this.kind, required this.state, this.amount, this.decimals, this.stellarTxHash, required this.startedAt, required this.updatedAt});
  factory _AnchorTransaction.fromJson(Map<String, dynamic> json) => _$AnchorTransactionFromJson(json);

@override final  String id;
@override final  String anchorId;
@override final  String kind;
@override final  String state;
@override final  String? amount;
@override final  int? decimals;
@override final  String? stellarTxHash;
@override final  String startedAt;
@override final  String updatedAt;

/// Create a copy of AnchorTransaction
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AnchorTransactionCopyWith<_AnchorTransaction> get copyWith => __$AnchorTransactionCopyWithImpl<_AnchorTransaction>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AnchorTransactionToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AnchorTransaction&&(identical(other.id, id) || other.id == id)&&(identical(other.anchorId, anchorId) || other.anchorId == anchorId)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.state, state) || other.state == state)&&(identical(other.amount, amount) || other.amount == amount)&&(identical(other.decimals, decimals) || other.decimals == decimals)&&(identical(other.stellarTxHash, stellarTxHash) || other.stellarTxHash == stellarTxHash)&&(identical(other.startedAt, startedAt) || other.startedAt == startedAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,anchorId,kind,state,amount,decimals,stellarTxHash,startedAt,updatedAt);

@override
String toString() {
  return 'AnchorTransaction(id: $id, anchorId: $anchorId, kind: $kind, state: $state, amount: $amount, decimals: $decimals, stellarTxHash: $stellarTxHash, startedAt: $startedAt, updatedAt: $updatedAt)';
}


}

/// @nodoc
abstract mixin class _$AnchorTransactionCopyWith<$Res> implements $AnchorTransactionCopyWith<$Res> {
  factory _$AnchorTransactionCopyWith(_AnchorTransaction value, $Res Function(_AnchorTransaction) _then) = __$AnchorTransactionCopyWithImpl;
@override @useResult
$Res call({
 String id, String anchorId, String kind, String state, String? amount, int? decimals, String? stellarTxHash, String startedAt, String updatedAt
});




}
/// @nodoc
class __$AnchorTransactionCopyWithImpl<$Res>
    implements _$AnchorTransactionCopyWith<$Res> {
  __$AnchorTransactionCopyWithImpl(this._self, this._then);

  final _AnchorTransaction _self;
  final $Res Function(_AnchorTransaction) _then;

/// Create a copy of AnchorTransaction
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? anchorId = null,Object? kind = null,Object? state = null,Object? amount = freezed,Object? decimals = freezed,Object? stellarTxHash = freezed,Object? startedAt = null,Object? updatedAt = null,}) {
  return _then(_AnchorTransaction(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,anchorId: null == anchorId ? _self.anchorId : anchorId // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as String,amount: freezed == amount ? _self.amount : amount // ignore: cast_nullable_to_non_nullable
as String?,decimals: freezed == decimals ? _self.decimals : decimals // ignore: cast_nullable_to_non_nullable
as int?,stellarTxHash: freezed == stellarTxHash ? _self.stellarTxHash : stellarTxHash // ignore: cast_nullable_to_non_nullable
as String?,startedAt: null == startedAt ? _self.startedAt : startedAt // ignore: cast_nullable_to_non_nullable
as String,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
