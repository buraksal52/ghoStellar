// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'tx_models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$SubmitResponse {

 String get hash; bool get successful; String? get resultCode; bool get replayed;
/// Create a copy of SubmitResponse
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SubmitResponseCopyWith<SubmitResponse> get copyWith => _$SubmitResponseCopyWithImpl<SubmitResponse>(this as SubmitResponse, _$identity);

  /// Serializes this SubmitResponse to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SubmitResponse&&(identical(other.hash, hash) || other.hash == hash)&&(identical(other.successful, successful) || other.successful == successful)&&(identical(other.resultCode, resultCode) || other.resultCode == resultCode)&&(identical(other.replayed, replayed) || other.replayed == replayed));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,hash,successful,resultCode,replayed);

@override
String toString() {
  return 'SubmitResponse(hash: $hash, successful: $successful, resultCode: $resultCode, replayed: $replayed)';
}


}

/// @nodoc
abstract mixin class $SubmitResponseCopyWith<$Res>  {
  factory $SubmitResponseCopyWith(SubmitResponse value, $Res Function(SubmitResponse) _then) = _$SubmitResponseCopyWithImpl;
@useResult
$Res call({
 String hash, bool successful, String? resultCode, bool replayed
});




}
/// @nodoc
class _$SubmitResponseCopyWithImpl<$Res>
    implements $SubmitResponseCopyWith<$Res> {
  _$SubmitResponseCopyWithImpl(this._self, this._then);

  final SubmitResponse _self;
  final $Res Function(SubmitResponse) _then;

/// Create a copy of SubmitResponse
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? hash = null,Object? successful = null,Object? resultCode = freezed,Object? replayed = null,}) {
  return _then(_self.copyWith(
hash: null == hash ? _self.hash : hash // ignore: cast_nullable_to_non_nullable
as String,successful: null == successful ? _self.successful : successful // ignore: cast_nullable_to_non_nullable
as bool,resultCode: freezed == resultCode ? _self.resultCode : resultCode // ignore: cast_nullable_to_non_nullable
as String?,replayed: null == replayed ? _self.replayed : replayed // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [SubmitResponse].
extension SubmitResponsePatterns on SubmitResponse {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SubmitResponse value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SubmitResponse() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SubmitResponse value)  $default,){
final _that = this;
switch (_that) {
case _SubmitResponse():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SubmitResponse value)?  $default,){
final _that = this;
switch (_that) {
case _SubmitResponse() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String hash,  bool successful,  String? resultCode,  bool replayed)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SubmitResponse() when $default != null:
return $default(_that.hash,_that.successful,_that.resultCode,_that.replayed);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String hash,  bool successful,  String? resultCode,  bool replayed)  $default,) {final _that = this;
switch (_that) {
case _SubmitResponse():
return $default(_that.hash,_that.successful,_that.resultCode,_that.replayed);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String hash,  bool successful,  String? resultCode,  bool replayed)?  $default,) {final _that = this;
switch (_that) {
case _SubmitResponse() when $default != null:
return $default(_that.hash,_that.successful,_that.resultCode,_that.replayed);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _SubmitResponse implements SubmitResponse {
  const _SubmitResponse({required this.hash, required this.successful, this.resultCode, required this.replayed});
  factory _SubmitResponse.fromJson(Map<String, dynamic> json) => _$SubmitResponseFromJson(json);

@override final  String hash;
@override final  bool successful;
@override final  String? resultCode;
@override final  bool replayed;

/// Create a copy of SubmitResponse
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SubmitResponseCopyWith<_SubmitResponse> get copyWith => __$SubmitResponseCopyWithImpl<_SubmitResponse>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SubmitResponseToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SubmitResponse&&(identical(other.hash, hash) || other.hash == hash)&&(identical(other.successful, successful) || other.successful == successful)&&(identical(other.resultCode, resultCode) || other.resultCode == resultCode)&&(identical(other.replayed, replayed) || other.replayed == replayed));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,hash,successful,resultCode,replayed);

@override
String toString() {
  return 'SubmitResponse(hash: $hash, successful: $successful, resultCode: $resultCode, replayed: $replayed)';
}


}

/// @nodoc
abstract mixin class _$SubmitResponseCopyWith<$Res> implements $SubmitResponseCopyWith<$Res> {
  factory _$SubmitResponseCopyWith(_SubmitResponse value, $Res Function(_SubmitResponse) _then) = __$SubmitResponseCopyWithImpl;
@override @useResult
$Res call({
 String hash, bool successful, String? resultCode, bool replayed
});




}
/// @nodoc
class __$SubmitResponseCopyWithImpl<$Res>
    implements _$SubmitResponseCopyWith<$Res> {
  __$SubmitResponseCopyWithImpl(this._self, this._then);

  final _SubmitResponse _self;
  final $Res Function(_SubmitResponse) _then;

/// Create a copy of SubmitResponse
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? hash = null,Object? successful = null,Object? resultCode = freezed,Object? replayed = null,}) {
  return _then(_SubmitResponse(
hash: null == hash ? _self.hash : hash // ignore: cast_nullable_to_non_nullable
as String,successful: null == successful ? _self.successful : successful // ignore: cast_nullable_to_non_nullable
as bool,resultCode: freezed == resultCode ? _self.resultCode : resultCode // ignore: cast_nullable_to_non_nullable
as String?,replayed: null == replayed ? _self.replayed : replayed // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}


/// @nodoc
mixin _$Submission {

 String get idempotencyKey; String get purpose; String? get txHash; SubmissionState get state; String? get resultCode; String get createdAt; String get updatedAt;
/// Create a copy of Submission
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SubmissionCopyWith<Submission> get copyWith => _$SubmissionCopyWithImpl<Submission>(this as Submission, _$identity);

  /// Serializes this Submission to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Submission&&(identical(other.idempotencyKey, idempotencyKey) || other.idempotencyKey == idempotencyKey)&&(identical(other.purpose, purpose) || other.purpose == purpose)&&(identical(other.txHash, txHash) || other.txHash == txHash)&&(identical(other.state, state) || other.state == state)&&(identical(other.resultCode, resultCode) || other.resultCode == resultCode)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,idempotencyKey,purpose,txHash,state,resultCode,createdAt,updatedAt);

@override
String toString() {
  return 'Submission(idempotencyKey: $idempotencyKey, purpose: $purpose, txHash: $txHash, state: $state, resultCode: $resultCode, createdAt: $createdAt, updatedAt: $updatedAt)';
}


}

/// @nodoc
abstract mixin class $SubmissionCopyWith<$Res>  {
  factory $SubmissionCopyWith(Submission value, $Res Function(Submission) _then) = _$SubmissionCopyWithImpl;
@useResult
$Res call({
 String idempotencyKey, String purpose, String? txHash, SubmissionState state, String? resultCode, String createdAt, String updatedAt
});




}
/// @nodoc
class _$SubmissionCopyWithImpl<$Res>
    implements $SubmissionCopyWith<$Res> {
  _$SubmissionCopyWithImpl(this._self, this._then);

  final Submission _self;
  final $Res Function(Submission) _then;

/// Create a copy of Submission
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? idempotencyKey = null,Object? purpose = null,Object? txHash = freezed,Object? state = null,Object? resultCode = freezed,Object? createdAt = null,Object? updatedAt = null,}) {
  return _then(_self.copyWith(
idempotencyKey: null == idempotencyKey ? _self.idempotencyKey : idempotencyKey // ignore: cast_nullable_to_non_nullable
as String,purpose: null == purpose ? _self.purpose : purpose // ignore: cast_nullable_to_non_nullable
as String,txHash: freezed == txHash ? _self.txHash : txHash // ignore: cast_nullable_to_non_nullable
as String?,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as SubmissionState,resultCode: freezed == resultCode ? _self.resultCode : resultCode // ignore: cast_nullable_to_non_nullable
as String?,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as String,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [Submission].
extension SubmissionPatterns on Submission {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Submission value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Submission() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Submission value)  $default,){
final _that = this;
switch (_that) {
case _Submission():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Submission value)?  $default,){
final _that = this;
switch (_that) {
case _Submission() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String idempotencyKey,  String purpose,  String? txHash,  SubmissionState state,  String? resultCode,  String createdAt,  String updatedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Submission() when $default != null:
return $default(_that.idempotencyKey,_that.purpose,_that.txHash,_that.state,_that.resultCode,_that.createdAt,_that.updatedAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String idempotencyKey,  String purpose,  String? txHash,  SubmissionState state,  String? resultCode,  String createdAt,  String updatedAt)  $default,) {final _that = this;
switch (_that) {
case _Submission():
return $default(_that.idempotencyKey,_that.purpose,_that.txHash,_that.state,_that.resultCode,_that.createdAt,_that.updatedAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String idempotencyKey,  String purpose,  String? txHash,  SubmissionState state,  String? resultCode,  String createdAt,  String updatedAt)?  $default,) {final _that = this;
switch (_that) {
case _Submission() when $default != null:
return $default(_that.idempotencyKey,_that.purpose,_that.txHash,_that.state,_that.resultCode,_that.createdAt,_that.updatedAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Submission implements Submission {
  const _Submission({required this.idempotencyKey, required this.purpose, this.txHash, required this.state, this.resultCode, required this.createdAt, required this.updatedAt});
  factory _Submission.fromJson(Map<String, dynamic> json) => _$SubmissionFromJson(json);

@override final  String idempotencyKey;
@override final  String purpose;
@override final  String? txHash;
@override final  SubmissionState state;
@override final  String? resultCode;
@override final  String createdAt;
@override final  String updatedAt;

/// Create a copy of Submission
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SubmissionCopyWith<_Submission> get copyWith => __$SubmissionCopyWithImpl<_Submission>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SubmissionToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Submission&&(identical(other.idempotencyKey, idempotencyKey) || other.idempotencyKey == idempotencyKey)&&(identical(other.purpose, purpose) || other.purpose == purpose)&&(identical(other.txHash, txHash) || other.txHash == txHash)&&(identical(other.state, state) || other.state == state)&&(identical(other.resultCode, resultCode) || other.resultCode == resultCode)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,idempotencyKey,purpose,txHash,state,resultCode,createdAt,updatedAt);

@override
String toString() {
  return 'Submission(idempotencyKey: $idempotencyKey, purpose: $purpose, txHash: $txHash, state: $state, resultCode: $resultCode, createdAt: $createdAt, updatedAt: $updatedAt)';
}


}

/// @nodoc
abstract mixin class _$SubmissionCopyWith<$Res> implements $SubmissionCopyWith<$Res> {
  factory _$SubmissionCopyWith(_Submission value, $Res Function(_Submission) _then) = __$SubmissionCopyWithImpl;
@override @useResult
$Res call({
 String idempotencyKey, String purpose, String? txHash, SubmissionState state, String? resultCode, String createdAt, String updatedAt
});




}
/// @nodoc
class __$SubmissionCopyWithImpl<$Res>
    implements _$SubmissionCopyWith<$Res> {
  __$SubmissionCopyWithImpl(this._self, this._then);

  final _Submission _self;
  final $Res Function(_Submission) _then;

/// Create a copy of Submission
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? idempotencyKey = null,Object? purpose = null,Object? txHash = freezed,Object? state = null,Object? resultCode = freezed,Object? createdAt = null,Object? updatedAt = null,}) {
  return _then(_Submission(
idempotencyKey: null == idempotencyKey ? _self.idempotencyKey : idempotencyKey // ignore: cast_nullable_to_non_nullable
as String,purpose: null == purpose ? _self.purpose : purpose // ignore: cast_nullable_to_non_nullable
as String,txHash: freezed == txHash ? _self.txHash : txHash // ignore: cast_nullable_to_non_nullable
as String?,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as SubmissionState,resultCode: freezed == resultCode ? _self.resultCode : resultCode // ignore: cast_nullable_to_non_nullable
as String?,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as String,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
