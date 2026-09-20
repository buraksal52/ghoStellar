// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'cheque_models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Cheque {

 String get id; String get senderAddress; String get receiverAddress;/// The single-use payment-request id this cheque answers (tap/scan
/// flow); null for a plain cheque. Unique per receiver on the server.
 String? get requestId; String get tokenContract; String get amountRaw; int get decimals; ChequeState get state; String get expiresAt; String? get lockTxHash; String get createdAt; String get updatedAt;
/// Create a copy of Cheque
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ChequeCopyWith<Cheque> get copyWith => _$ChequeCopyWithImpl<Cheque>(this as Cheque, _$identity);

  /// Serializes this Cheque to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Cheque&&(identical(other.id, id) || other.id == id)&&(identical(other.senderAddress, senderAddress) || other.senderAddress == senderAddress)&&(identical(other.receiverAddress, receiverAddress) || other.receiverAddress == receiverAddress)&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.tokenContract, tokenContract) || other.tokenContract == tokenContract)&&(identical(other.amountRaw, amountRaw) || other.amountRaw == amountRaw)&&(identical(other.decimals, decimals) || other.decimals == decimals)&&(identical(other.state, state) || other.state == state)&&(identical(other.expiresAt, expiresAt) || other.expiresAt == expiresAt)&&(identical(other.lockTxHash, lockTxHash) || other.lockTxHash == lockTxHash)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,senderAddress,receiverAddress,requestId,tokenContract,amountRaw,decimals,state,expiresAt,lockTxHash,createdAt,updatedAt);

@override
String toString() {
  return 'Cheque(id: $id, senderAddress: $senderAddress, receiverAddress: $receiverAddress, requestId: $requestId, tokenContract: $tokenContract, amountRaw: $amountRaw, decimals: $decimals, state: $state, expiresAt: $expiresAt, lockTxHash: $lockTxHash, createdAt: $createdAt, updatedAt: $updatedAt)';
}


}

/// @nodoc
abstract mixin class $ChequeCopyWith<$Res>  {
  factory $ChequeCopyWith(Cheque value, $Res Function(Cheque) _then) = _$ChequeCopyWithImpl;
@useResult
$Res call({
 String id, String senderAddress, String receiverAddress, String? requestId, String tokenContract, String amountRaw, int decimals, ChequeState state, String expiresAt, String? lockTxHash, String createdAt, String updatedAt
});




}
/// @nodoc
class _$ChequeCopyWithImpl<$Res>
    implements $ChequeCopyWith<$Res> {
  _$ChequeCopyWithImpl(this._self, this._then);

  final Cheque _self;
  final $Res Function(Cheque) _then;

/// Create a copy of Cheque
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? senderAddress = null,Object? receiverAddress = null,Object? requestId = freezed,Object? tokenContract = null,Object? amountRaw = null,Object? decimals = null,Object? state = null,Object? expiresAt = null,Object? lockTxHash = freezed,Object? createdAt = null,Object? updatedAt = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,senderAddress: null == senderAddress ? _self.senderAddress : senderAddress // ignore: cast_nullable_to_non_nullable
as String,receiverAddress: null == receiverAddress ? _self.receiverAddress : receiverAddress // ignore: cast_nullable_to_non_nullable
as String,requestId: freezed == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String?,tokenContract: null == tokenContract ? _self.tokenContract : tokenContract // ignore: cast_nullable_to_non_nullable
as String,amountRaw: null == amountRaw ? _self.amountRaw : amountRaw // ignore: cast_nullable_to_non_nullable
as String,decimals: null == decimals ? _self.decimals : decimals // ignore: cast_nullable_to_non_nullable
as int,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as ChequeState,expiresAt: null == expiresAt ? _self.expiresAt : expiresAt // ignore: cast_nullable_to_non_nullable
as String,lockTxHash: freezed == lockTxHash ? _self.lockTxHash : lockTxHash // ignore: cast_nullable_to_non_nullable
as String?,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as String,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [Cheque].
extension ChequePatterns on Cheque {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Cheque value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Cheque() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Cheque value)  $default,){
final _that = this;
switch (_that) {
case _Cheque():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Cheque value)?  $default,){
final _that = this;
switch (_that) {
case _Cheque() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String senderAddress,  String receiverAddress,  String? requestId,  String tokenContract,  String amountRaw,  int decimals,  ChequeState state,  String expiresAt,  String? lockTxHash,  String createdAt,  String updatedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Cheque() when $default != null:
return $default(_that.id,_that.senderAddress,_that.receiverAddress,_that.requestId,_that.tokenContract,_that.amountRaw,_that.decimals,_that.state,_that.expiresAt,_that.lockTxHash,_that.createdAt,_that.updatedAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String senderAddress,  String receiverAddress,  String? requestId,  String tokenContract,  String amountRaw,  int decimals,  ChequeState state,  String expiresAt,  String? lockTxHash,  String createdAt,  String updatedAt)  $default,) {final _that = this;
switch (_that) {
case _Cheque():
return $default(_that.id,_that.senderAddress,_that.receiverAddress,_that.requestId,_that.tokenContract,_that.amountRaw,_that.decimals,_that.state,_that.expiresAt,_that.lockTxHash,_that.createdAt,_that.updatedAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String senderAddress,  String receiverAddress,  String? requestId,  String tokenContract,  String amountRaw,  int decimals,  ChequeState state,  String expiresAt,  String? lockTxHash,  String createdAt,  String updatedAt)?  $default,) {final _that = this;
switch (_that) {
case _Cheque() when $default != null:
return $default(_that.id,_that.senderAddress,_that.receiverAddress,_that.requestId,_that.tokenContract,_that.amountRaw,_that.decimals,_that.state,_that.expiresAt,_that.lockTxHash,_that.createdAt,_that.updatedAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Cheque implements Cheque {
  const _Cheque({required this.id, required this.senderAddress, required this.receiverAddress, this.requestId, required this.tokenContract, required this.amountRaw, required this.decimals, required this.state, required this.expiresAt, this.lockTxHash, required this.createdAt, required this.updatedAt});
  factory _Cheque.fromJson(Map<String, dynamic> json) => _$ChequeFromJson(json);

@override final  String id;
@override final  String senderAddress;
@override final  String receiverAddress;
/// The single-use payment-request id this cheque answers (tap/scan
/// flow); null for a plain cheque. Unique per receiver on the server.
@override final  String? requestId;
@override final  String tokenContract;
@override final  String amountRaw;
@override final  int decimals;
@override final  ChequeState state;
@override final  String expiresAt;
@override final  String? lockTxHash;
@override final  String createdAt;
@override final  String updatedAt;

/// Create a copy of Cheque
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ChequeCopyWith<_Cheque> get copyWith => __$ChequeCopyWithImpl<_Cheque>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ChequeToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Cheque&&(identical(other.id, id) || other.id == id)&&(identical(other.senderAddress, senderAddress) || other.senderAddress == senderAddress)&&(identical(other.receiverAddress, receiverAddress) || other.receiverAddress == receiverAddress)&&(identical(other.requestId, requestId) || other.requestId == requestId)&&(identical(other.tokenContract, tokenContract) || other.tokenContract == tokenContract)&&(identical(other.amountRaw, amountRaw) || other.amountRaw == amountRaw)&&(identical(other.decimals, decimals) || other.decimals == decimals)&&(identical(other.state, state) || other.state == state)&&(identical(other.expiresAt, expiresAt) || other.expiresAt == expiresAt)&&(identical(other.lockTxHash, lockTxHash) || other.lockTxHash == lockTxHash)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,senderAddress,receiverAddress,requestId,tokenContract,amountRaw,decimals,state,expiresAt,lockTxHash,createdAt,updatedAt);

@override
String toString() {
  return 'Cheque(id: $id, senderAddress: $senderAddress, receiverAddress: $receiverAddress, requestId: $requestId, tokenContract: $tokenContract, amountRaw: $amountRaw, decimals: $decimals, state: $state, expiresAt: $expiresAt, lockTxHash: $lockTxHash, createdAt: $createdAt, updatedAt: $updatedAt)';
}


}

/// @nodoc
abstract mixin class _$ChequeCopyWith<$Res> implements $ChequeCopyWith<$Res> {
  factory _$ChequeCopyWith(_Cheque value, $Res Function(_Cheque) _then) = __$ChequeCopyWithImpl;
@override @useResult
$Res call({
 String id, String senderAddress, String receiverAddress, String? requestId, String tokenContract, String amountRaw, int decimals, ChequeState state, String expiresAt, String? lockTxHash, String createdAt, String updatedAt
});




}
/// @nodoc
class __$ChequeCopyWithImpl<$Res>
    implements _$ChequeCopyWith<$Res> {
  __$ChequeCopyWithImpl(this._self, this._then);

  final _Cheque _self;
  final $Res Function(_Cheque) _then;

/// Create a copy of Cheque
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? senderAddress = null,Object? receiverAddress = null,Object? requestId = freezed,Object? tokenContract = null,Object? amountRaw = null,Object? decimals = null,Object? state = null,Object? expiresAt = null,Object? lockTxHash = freezed,Object? createdAt = null,Object? updatedAt = null,}) {
  return _then(_Cheque(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,senderAddress: null == senderAddress ? _self.senderAddress : senderAddress // ignore: cast_nullable_to_non_nullable
as String,receiverAddress: null == receiverAddress ? _self.receiverAddress : receiverAddress // ignore: cast_nullable_to_non_nullable
as String,requestId: freezed == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String?,tokenContract: null == tokenContract ? _self.tokenContract : tokenContract // ignore: cast_nullable_to_non_nullable
as String,amountRaw: null == amountRaw ? _self.amountRaw : amountRaw // ignore: cast_nullable_to_non_nullable
as String,decimals: null == decimals ? _self.decimals : decimals // ignore: cast_nullable_to_non_nullable
as int,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as ChequeState,expiresAt: null == expiresAt ? _self.expiresAt : expiresAt // ignore: cast_nullable_to_non_nullable
as String,lockTxHash: freezed == lockTxHash ? _self.lockTxHash : lockTxHash // ignore: cast_nullable_to_non_nullable
as String?,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as String,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$PoolDeposit {

 String get ownerAddress; String get amountRaw; int get decimals; int? get lastDepositLedger; String get updatedAt;
/// Create a copy of PoolDeposit
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PoolDepositCopyWith<PoolDeposit> get copyWith => _$PoolDepositCopyWithImpl<PoolDeposit>(this as PoolDeposit, _$identity);

  /// Serializes this PoolDeposit to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PoolDeposit&&(identical(other.ownerAddress, ownerAddress) || other.ownerAddress == ownerAddress)&&(identical(other.amountRaw, amountRaw) || other.amountRaw == amountRaw)&&(identical(other.decimals, decimals) || other.decimals == decimals)&&(identical(other.lastDepositLedger, lastDepositLedger) || other.lastDepositLedger == lastDepositLedger)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,ownerAddress,amountRaw,decimals,lastDepositLedger,updatedAt);

@override
String toString() {
  return 'PoolDeposit(ownerAddress: $ownerAddress, amountRaw: $amountRaw, decimals: $decimals, lastDepositLedger: $lastDepositLedger, updatedAt: $updatedAt)';
}


}

/// @nodoc
abstract mixin class $PoolDepositCopyWith<$Res>  {
  factory $PoolDepositCopyWith(PoolDeposit value, $Res Function(PoolDeposit) _then) = _$PoolDepositCopyWithImpl;
@useResult
$Res call({
 String ownerAddress, String amountRaw, int decimals, int? lastDepositLedger, String updatedAt
});




}
/// @nodoc
class _$PoolDepositCopyWithImpl<$Res>
    implements $PoolDepositCopyWith<$Res> {
  _$PoolDepositCopyWithImpl(this._self, this._then);

  final PoolDeposit _self;
  final $Res Function(PoolDeposit) _then;

/// Create a copy of PoolDeposit
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? ownerAddress = null,Object? amountRaw = null,Object? decimals = null,Object? lastDepositLedger = freezed,Object? updatedAt = null,}) {
  return _then(_self.copyWith(
ownerAddress: null == ownerAddress ? _self.ownerAddress : ownerAddress // ignore: cast_nullable_to_non_nullable
as String,amountRaw: null == amountRaw ? _self.amountRaw : amountRaw // ignore: cast_nullable_to_non_nullable
as String,decimals: null == decimals ? _self.decimals : decimals // ignore: cast_nullable_to_non_nullable
as int,lastDepositLedger: freezed == lastDepositLedger ? _self.lastDepositLedger : lastDepositLedger // ignore: cast_nullable_to_non_nullable
as int?,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [PoolDeposit].
extension PoolDepositPatterns on PoolDeposit {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PoolDeposit value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PoolDeposit() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PoolDeposit value)  $default,){
final _that = this;
switch (_that) {
case _PoolDeposit():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PoolDeposit value)?  $default,){
final _that = this;
switch (_that) {
case _PoolDeposit() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String ownerAddress,  String amountRaw,  int decimals,  int? lastDepositLedger,  String updatedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PoolDeposit() when $default != null:
return $default(_that.ownerAddress,_that.amountRaw,_that.decimals,_that.lastDepositLedger,_that.updatedAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String ownerAddress,  String amountRaw,  int decimals,  int? lastDepositLedger,  String updatedAt)  $default,) {final _that = this;
switch (_that) {
case _PoolDeposit():
return $default(_that.ownerAddress,_that.amountRaw,_that.decimals,_that.lastDepositLedger,_that.updatedAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String ownerAddress,  String amountRaw,  int decimals,  int? lastDepositLedger,  String updatedAt)?  $default,) {final _that = this;
switch (_that) {
case _PoolDeposit() when $default != null:
return $default(_that.ownerAddress,_that.amountRaw,_that.decimals,_that.lastDepositLedger,_that.updatedAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PoolDeposit implements PoolDeposit {
  const _PoolDeposit({required this.ownerAddress, required this.amountRaw, required this.decimals, this.lastDepositLedger, required this.updatedAt});
  factory _PoolDeposit.fromJson(Map<String, dynamic> json) => _$PoolDepositFromJson(json);

@override final  String ownerAddress;
@override final  String amountRaw;
@override final  int decimals;
@override final  int? lastDepositLedger;
@override final  String updatedAt;

/// Create a copy of PoolDeposit
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PoolDepositCopyWith<_PoolDeposit> get copyWith => __$PoolDepositCopyWithImpl<_PoolDeposit>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PoolDepositToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PoolDeposit&&(identical(other.ownerAddress, ownerAddress) || other.ownerAddress == ownerAddress)&&(identical(other.amountRaw, amountRaw) || other.amountRaw == amountRaw)&&(identical(other.decimals, decimals) || other.decimals == decimals)&&(identical(other.lastDepositLedger, lastDepositLedger) || other.lastDepositLedger == lastDepositLedger)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,ownerAddress,amountRaw,decimals,lastDepositLedger,updatedAt);

@override
String toString() {
  return 'PoolDeposit(ownerAddress: $ownerAddress, amountRaw: $amountRaw, decimals: $decimals, lastDepositLedger: $lastDepositLedger, updatedAt: $updatedAt)';
}


}

/// @nodoc
abstract mixin class _$PoolDepositCopyWith<$Res> implements $PoolDepositCopyWith<$Res> {
  factory _$PoolDepositCopyWith(_PoolDeposit value, $Res Function(_PoolDeposit) _then) = __$PoolDepositCopyWithImpl;
@override @useResult
$Res call({
 String ownerAddress, String amountRaw, int decimals, int? lastDepositLedger, String updatedAt
});




}
/// @nodoc
class __$PoolDepositCopyWithImpl<$Res>
    implements _$PoolDepositCopyWith<$Res> {
  __$PoolDepositCopyWithImpl(this._self, this._then);

  final _PoolDeposit _self;
  final $Res Function(_PoolDeposit) _then;

/// Create a copy of PoolDeposit
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? ownerAddress = null,Object? amountRaw = null,Object? decimals = null,Object? lastDepositLedger = freezed,Object? updatedAt = null,}) {
  return _then(_PoolDeposit(
ownerAddress: null == ownerAddress ? _self.ownerAddress : ownerAddress // ignore: cast_nullable_to_non_nullable
as String,amountRaw: null == amountRaw ? _self.amountRaw : amountRaw // ignore: cast_nullable_to_non_nullable
as String,decimals: null == decimals ? _self.decimals : decimals // ignore: cast_nullable_to_non_nullable
as int,lastDepositLedger: freezed == lastDepositLedger ? _self.lastDepositLedger : lastDepositLedger // ignore: cast_nullable_to_non_nullable
as int?,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$SyncResponse {

 List<Cheque> get cheques; PoolDeposit get pool; bool get trustlineReady; int get ledgerSeq; int get serverTimeUnix;
/// Create a copy of SyncResponse
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncResponseCopyWith<SyncResponse> get copyWith => _$SyncResponseCopyWithImpl<SyncResponse>(this as SyncResponse, _$identity);

  /// Serializes this SyncResponse to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncResponse&&const DeepCollectionEquality().equals(other.cheques, cheques)&&(identical(other.pool, pool) || other.pool == pool)&&(identical(other.trustlineReady, trustlineReady) || other.trustlineReady == trustlineReady)&&(identical(other.ledgerSeq, ledgerSeq) || other.ledgerSeq == ledgerSeq)&&(identical(other.serverTimeUnix, serverTimeUnix) || other.serverTimeUnix == serverTimeUnix));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(cheques),pool,trustlineReady,ledgerSeq,serverTimeUnix);

@override
String toString() {
  return 'SyncResponse(cheques: $cheques, pool: $pool, trustlineReady: $trustlineReady, ledgerSeq: $ledgerSeq, serverTimeUnix: $serverTimeUnix)';
}


}

/// @nodoc
abstract mixin class $SyncResponseCopyWith<$Res>  {
  factory $SyncResponseCopyWith(SyncResponse value, $Res Function(SyncResponse) _then) = _$SyncResponseCopyWithImpl;
@useResult
$Res call({
 List<Cheque> cheques, PoolDeposit pool, bool trustlineReady, int ledgerSeq, int serverTimeUnix
});


$PoolDepositCopyWith<$Res> get pool;

}
/// @nodoc
class _$SyncResponseCopyWithImpl<$Res>
    implements $SyncResponseCopyWith<$Res> {
  _$SyncResponseCopyWithImpl(this._self, this._then);

  final SyncResponse _self;
  final $Res Function(SyncResponse) _then;

/// Create a copy of SyncResponse
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? cheques = null,Object? pool = null,Object? trustlineReady = null,Object? ledgerSeq = null,Object? serverTimeUnix = null,}) {
  return _then(_self.copyWith(
cheques: null == cheques ? _self.cheques : cheques // ignore: cast_nullable_to_non_nullable
as List<Cheque>,pool: null == pool ? _self.pool : pool // ignore: cast_nullable_to_non_nullable
as PoolDeposit,trustlineReady: null == trustlineReady ? _self.trustlineReady : trustlineReady // ignore: cast_nullable_to_non_nullable
as bool,ledgerSeq: null == ledgerSeq ? _self.ledgerSeq : ledgerSeq // ignore: cast_nullable_to_non_nullable
as int,serverTimeUnix: null == serverTimeUnix ? _self.serverTimeUnix : serverTimeUnix // ignore: cast_nullable_to_non_nullable
as int,
  ));
}
/// Create a copy of SyncResponse
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PoolDepositCopyWith<$Res> get pool {
  
  return $PoolDepositCopyWith<$Res>(_self.pool, (value) {
    return _then(_self.copyWith(pool: value));
  });
}
}


/// Adds pattern-matching-related methods to [SyncResponse].
extension SyncResponsePatterns on SyncResponse {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SyncResponse value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SyncResponse() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SyncResponse value)  $default,){
final _that = this;
switch (_that) {
case _SyncResponse():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SyncResponse value)?  $default,){
final _that = this;
switch (_that) {
case _SyncResponse() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<Cheque> cheques,  PoolDeposit pool,  bool trustlineReady,  int ledgerSeq,  int serverTimeUnix)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SyncResponse() when $default != null:
return $default(_that.cheques,_that.pool,_that.trustlineReady,_that.ledgerSeq,_that.serverTimeUnix);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<Cheque> cheques,  PoolDeposit pool,  bool trustlineReady,  int ledgerSeq,  int serverTimeUnix)  $default,) {final _that = this;
switch (_that) {
case _SyncResponse():
return $default(_that.cheques,_that.pool,_that.trustlineReady,_that.ledgerSeq,_that.serverTimeUnix);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<Cheque> cheques,  PoolDeposit pool,  bool trustlineReady,  int ledgerSeq,  int serverTimeUnix)?  $default,) {final _that = this;
switch (_that) {
case _SyncResponse() when $default != null:
return $default(_that.cheques,_that.pool,_that.trustlineReady,_that.ledgerSeq,_that.serverTimeUnix);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _SyncResponse implements SyncResponse {
  const _SyncResponse({required final  List<Cheque> cheques, required this.pool, required this.trustlineReady, required this.ledgerSeq, required this.serverTimeUnix}): _cheques = cheques;
  factory _SyncResponse.fromJson(Map<String, dynamic> json) => _$SyncResponseFromJson(json);

 final  List<Cheque> _cheques;
@override List<Cheque> get cheques {
  if (_cheques is EqualUnmodifiableListView) return _cheques;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_cheques);
}

@override final  PoolDeposit pool;
@override final  bool trustlineReady;
@override final  int ledgerSeq;
@override final  int serverTimeUnix;

/// Create a copy of SyncResponse
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SyncResponseCopyWith<_SyncResponse> get copyWith => __$SyncResponseCopyWithImpl<_SyncResponse>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncResponseToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SyncResponse&&const DeepCollectionEquality().equals(other._cheques, _cheques)&&(identical(other.pool, pool) || other.pool == pool)&&(identical(other.trustlineReady, trustlineReady) || other.trustlineReady == trustlineReady)&&(identical(other.ledgerSeq, ledgerSeq) || other.ledgerSeq == ledgerSeq)&&(identical(other.serverTimeUnix, serverTimeUnix) || other.serverTimeUnix == serverTimeUnix));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_cheques),pool,trustlineReady,ledgerSeq,serverTimeUnix);

@override
String toString() {
  return 'SyncResponse(cheques: $cheques, pool: $pool, trustlineReady: $trustlineReady, ledgerSeq: $ledgerSeq, serverTimeUnix: $serverTimeUnix)';
}


}

/// @nodoc
abstract mixin class _$SyncResponseCopyWith<$Res> implements $SyncResponseCopyWith<$Res> {
  factory _$SyncResponseCopyWith(_SyncResponse value, $Res Function(_SyncResponse) _then) = __$SyncResponseCopyWithImpl;
@override @useResult
$Res call({
 List<Cheque> cheques, PoolDeposit pool, bool trustlineReady, int ledgerSeq, int serverTimeUnix
});


@override $PoolDepositCopyWith<$Res> get pool;

}
/// @nodoc
class __$SyncResponseCopyWithImpl<$Res>
    implements _$SyncResponseCopyWith<$Res> {
  __$SyncResponseCopyWithImpl(this._self, this._then);

  final _SyncResponse _self;
  final $Res Function(_SyncResponse) _then;

/// Create a copy of SyncResponse
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? cheques = null,Object? pool = null,Object? trustlineReady = null,Object? ledgerSeq = null,Object? serverTimeUnix = null,}) {
  return _then(_SyncResponse(
cheques: null == cheques ? _self._cheques : cheques // ignore: cast_nullable_to_non_nullable
as List<Cheque>,pool: null == pool ? _self.pool : pool // ignore: cast_nullable_to_non_nullable
as PoolDeposit,trustlineReady: null == trustlineReady ? _self.trustlineReady : trustlineReady // ignore: cast_nullable_to_non_nullable
as bool,ledgerSeq: null == ledgerSeq ? _self.ledgerSeq : ledgerSeq // ignore: cast_nullable_to_non_nullable
as int,serverTimeUnix: null == serverTimeUnix ? _self.serverTimeUnix : serverTimeUnix // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

/// Create a copy of SyncResponse
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PoolDepositCopyWith<$Res> get pool {
  
  return $PoolDepositCopyWith<$Res>(_self.pool, (value) {
    return _then(_self.copyWith(pool: value));
  });
}
}


/// @nodoc
mixin _$CreateChequeResult {

 String get chequeId; String get lockXdr; String get preauthEntryXdr; String get preauthPayloadHash; String get expiresAt;
/// Create a copy of CreateChequeResult
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CreateChequeResultCopyWith<CreateChequeResult> get copyWith => _$CreateChequeResultCopyWithImpl<CreateChequeResult>(this as CreateChequeResult, _$identity);

  /// Serializes this CreateChequeResult to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CreateChequeResult&&(identical(other.chequeId, chequeId) || other.chequeId == chequeId)&&(identical(other.lockXdr, lockXdr) || other.lockXdr == lockXdr)&&(identical(other.preauthEntryXdr, preauthEntryXdr) || other.preauthEntryXdr == preauthEntryXdr)&&(identical(other.preauthPayloadHash, preauthPayloadHash) || other.preauthPayloadHash == preauthPayloadHash)&&(identical(other.expiresAt, expiresAt) || other.expiresAt == expiresAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chequeId,lockXdr,preauthEntryXdr,preauthPayloadHash,expiresAt);

@override
String toString() {
  return 'CreateChequeResult(chequeId: $chequeId, lockXdr: $lockXdr, preauthEntryXdr: $preauthEntryXdr, preauthPayloadHash: $preauthPayloadHash, expiresAt: $expiresAt)';
}


}

/// @nodoc
abstract mixin class $CreateChequeResultCopyWith<$Res>  {
  factory $CreateChequeResultCopyWith(CreateChequeResult value, $Res Function(CreateChequeResult) _then) = _$CreateChequeResultCopyWithImpl;
@useResult
$Res call({
 String chequeId, String lockXdr, String preauthEntryXdr, String preauthPayloadHash, String expiresAt
});




}
/// @nodoc
class _$CreateChequeResultCopyWithImpl<$Res>
    implements $CreateChequeResultCopyWith<$Res> {
  _$CreateChequeResultCopyWithImpl(this._self, this._then);

  final CreateChequeResult _self;
  final $Res Function(CreateChequeResult) _then;

/// Create a copy of CreateChequeResult
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? chequeId = null,Object? lockXdr = null,Object? preauthEntryXdr = null,Object? preauthPayloadHash = null,Object? expiresAt = null,}) {
  return _then(_self.copyWith(
chequeId: null == chequeId ? _self.chequeId : chequeId // ignore: cast_nullable_to_non_nullable
as String,lockXdr: null == lockXdr ? _self.lockXdr : lockXdr // ignore: cast_nullable_to_non_nullable
as String,preauthEntryXdr: null == preauthEntryXdr ? _self.preauthEntryXdr : preauthEntryXdr // ignore: cast_nullable_to_non_nullable
as String,preauthPayloadHash: null == preauthPayloadHash ? _self.preauthPayloadHash : preauthPayloadHash // ignore: cast_nullable_to_non_nullable
as String,expiresAt: null == expiresAt ? _self.expiresAt : expiresAt // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [CreateChequeResult].
extension CreateChequeResultPatterns on CreateChequeResult {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _CreateChequeResult value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _CreateChequeResult() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _CreateChequeResult value)  $default,){
final _that = this;
switch (_that) {
case _CreateChequeResult():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _CreateChequeResult value)?  $default,){
final _that = this;
switch (_that) {
case _CreateChequeResult() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String chequeId,  String lockXdr,  String preauthEntryXdr,  String preauthPayloadHash,  String expiresAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _CreateChequeResult() when $default != null:
return $default(_that.chequeId,_that.lockXdr,_that.preauthEntryXdr,_that.preauthPayloadHash,_that.expiresAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String chequeId,  String lockXdr,  String preauthEntryXdr,  String preauthPayloadHash,  String expiresAt)  $default,) {final _that = this;
switch (_that) {
case _CreateChequeResult():
return $default(_that.chequeId,_that.lockXdr,_that.preauthEntryXdr,_that.preauthPayloadHash,_that.expiresAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String chequeId,  String lockXdr,  String preauthEntryXdr,  String preauthPayloadHash,  String expiresAt)?  $default,) {final _that = this;
switch (_that) {
case _CreateChequeResult() when $default != null:
return $default(_that.chequeId,_that.lockXdr,_that.preauthEntryXdr,_that.preauthPayloadHash,_that.expiresAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _CreateChequeResult implements CreateChequeResult {
  const _CreateChequeResult({required this.chequeId, required this.lockXdr, required this.preauthEntryXdr, required this.preauthPayloadHash, required this.expiresAt});
  factory _CreateChequeResult.fromJson(Map<String, dynamic> json) => _$CreateChequeResultFromJson(json);

@override final  String chequeId;
@override final  String lockXdr;
@override final  String preauthEntryXdr;
@override final  String preauthPayloadHash;
@override final  String expiresAt;

/// Create a copy of CreateChequeResult
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$CreateChequeResultCopyWith<_CreateChequeResult> get copyWith => __$CreateChequeResultCopyWithImpl<_CreateChequeResult>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$CreateChequeResultToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _CreateChequeResult&&(identical(other.chequeId, chequeId) || other.chequeId == chequeId)&&(identical(other.lockXdr, lockXdr) || other.lockXdr == lockXdr)&&(identical(other.preauthEntryXdr, preauthEntryXdr) || other.preauthEntryXdr == preauthEntryXdr)&&(identical(other.preauthPayloadHash, preauthPayloadHash) || other.preauthPayloadHash == preauthPayloadHash)&&(identical(other.expiresAt, expiresAt) || other.expiresAt == expiresAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chequeId,lockXdr,preauthEntryXdr,preauthPayloadHash,expiresAt);

@override
String toString() {
  return 'CreateChequeResult(chequeId: $chequeId, lockXdr: $lockXdr, preauthEntryXdr: $preauthEntryXdr, preauthPayloadHash: $preauthPayloadHash, expiresAt: $expiresAt)';
}


}

/// @nodoc
abstract mixin class _$CreateChequeResultCopyWith<$Res> implements $CreateChequeResultCopyWith<$Res> {
  factory _$CreateChequeResultCopyWith(_CreateChequeResult value, $Res Function(_CreateChequeResult) _then) = __$CreateChequeResultCopyWithImpl;
@override @useResult
$Res call({
 String chequeId, String lockXdr, String preauthEntryXdr, String preauthPayloadHash, String expiresAt
});




}
/// @nodoc
class __$CreateChequeResultCopyWithImpl<$Res>
    implements _$CreateChequeResultCopyWith<$Res> {
  __$CreateChequeResultCopyWithImpl(this._self, this._then);

  final _CreateChequeResult _self;
  final $Res Function(_CreateChequeResult) _then;

/// Create a copy of CreateChequeResult
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? chequeId = null,Object? lockXdr = null,Object? preauthEntryXdr = null,Object? preauthPayloadHash = null,Object? expiresAt = null,}) {
  return _then(_CreateChequeResult(
chequeId: null == chequeId ? _self.chequeId : chequeId // ignore: cast_nullable_to_non_nullable
as String,lockXdr: null == lockXdr ? _self.lockXdr : lockXdr // ignore: cast_nullable_to_non_nullable
as String,preauthEntryXdr: null == preauthEntryXdr ? _self.preauthEntryXdr : preauthEntryXdr // ignore: cast_nullable_to_non_nullable
as String,preauthPayloadHash: null == preauthPayloadHash ? _self.preauthPayloadHash : preauthPayloadHash // ignore: cast_nullable_to_non_nullable
as String,expiresAt: null == expiresAt ? _self.expiresAt : expiresAt // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
