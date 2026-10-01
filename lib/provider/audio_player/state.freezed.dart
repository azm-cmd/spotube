// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

AudioPlayerState _$AudioPlayerStateFromJson(Map<String, dynamic> json) {
  return _AudioPlayerState.fromJson(json);
}

/// @nodoc
mixin _$AudioPlayerState {
  bool get playing => throw _privateConstructorUsedError;
  PlaylistMode get loopMode => throw _privateConstructorUsedError;
  bool get shuffled => throw _privateConstructorUsedError;
  List<String> get collections => throw _privateConstructorUsedError;
  int get currentIndex => throw _privateConstructorUsedError;
  List<SpotubeTrackObject> get tracks => throw _privateConstructorUsedError;
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<String> get entryIds => throw _privateConstructorUsedError;

  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;
  @JsonKey(ignore: true)
  $AudioPlayerStateCopyWith<AudioPlayerState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $AudioPlayerStateCopyWith<$Res> {
  factory $AudioPlayerStateCopyWith(
          AudioPlayerState value, $Res Function(AudioPlayerState) then) =
      _$AudioPlayerStateCopyWithImpl<$Res, AudioPlayerState>;
  @useResult
  $Res call(
      {bool playing,
      PlaylistMode loopMode,
      bool shuffled,
      List<String> collections,
      int currentIndex,
      List<SpotubeTrackObject> tracks,
      @JsonKey(includeFromJson: false, includeToJson: false)
      List<String> entryIds});
}

/// @nodoc
class _$AudioPlayerStateCopyWithImpl<$Res, $Val extends AudioPlayerState>
    implements $AudioPlayerStateCopyWith<$Res> {
  _$AudioPlayerStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? playing = null,
    Object? loopMode = null,
    Object? shuffled = null,
    Object? collections = null,
    Object? currentIndex = null,
    Object? tracks = null,
    Object? entryIds = null,
  }) {
    return _then(_value.copyWith(
      playing: null == playing
          ? _value.playing
          : playing // ignore: cast_nullable_to_non_nullable
              as bool,
      loopMode: null == loopMode
          ? _value.loopMode
          : loopMode // ignore: cast_nullable_to_non_nullable
              as PlaylistMode,
      shuffled: null == shuffled
          ? _value.shuffled
          : shuffled // ignore: cast_nullable_to_non_nullable
              as bool,
      collections: null == collections
          ? _value.collections
          : collections // ignore: cast_nullable_to_non_nullable
              as List<String>,
      currentIndex: null == currentIndex
          ? _value.currentIndex
          : currentIndex // ignore: cast_nullable_to_non_nullable
              as int,
      tracks: null == tracks
          ? _value.tracks
          : tracks // ignore: cast_nullable_to_non_nullable
              as List<SpotubeTrackObject>,
      entryIds: null == entryIds
          ? _value.entryIds
          : entryIds // ignore: cast_nullable_to_non_nullable
              as List<String>,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$AudioPlayerStateImplCopyWith<$Res>
    implements $AudioPlayerStateCopyWith<$Res> {
  factory _$$AudioPlayerStateImplCopyWith(_$AudioPlayerStateImpl value,
          $Res Function(_$AudioPlayerStateImpl) then) =
      __$$AudioPlayerStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {bool playing,
      PlaylistMode loopMode,
      bool shuffled,
      List<String> collections,
      int currentIndex,
      List<SpotubeTrackObject> tracks,
      @JsonKey(includeFromJson: false, includeToJson: false)
      List<String> entryIds});
}

/// @nodoc
class __$$AudioPlayerStateImplCopyWithImpl<$Res>
    extends _$AudioPlayerStateCopyWithImpl<$Res, _$AudioPlayerStateImpl>
    implements _$$AudioPlayerStateImplCopyWith<$Res> {
  __$$AudioPlayerStateImplCopyWithImpl(_$AudioPlayerStateImpl _value,
      $Res Function(_$AudioPlayerStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? playing = null,
    Object? loopMode = null,
    Object? shuffled = null,
    Object? collections = null,
    Object? currentIndex = null,
    Object? tracks = null,
    Object? entryIds = null,
  }) {
    return _then(_$AudioPlayerStateImpl(
      playing: null == playing
          ? _value.playing
          : playing // ignore: cast_nullable_to_non_nullable
              as bool,
      loopMode: null == loopMode
          ? _value.loopMode
          : loopMode // ignore: cast_nullable_to_non_nullable
              as PlaylistMode,
      shuffled: null == shuffled
          ? _value.shuffled
          : shuffled // ignore: cast_nullable_to_non_nullable
              as bool,
      collections: null == collections
          ? _value._collections
          : collections // ignore: cast_nullable_to_non_nullable
              as List<String>,
      currentIndex: null == currentIndex
          ? _value.currentIndex
          : currentIndex // ignore: cast_nullable_to_non_nullable
              as int,
      tracks: null == tracks
          ? _value._tracks
          : tracks // ignore: cast_nullable_to_non_nullable
              as List<SpotubeTrackObject>,
      entryIds: null == entryIds
          ? _value._entryIds
          : entryIds // ignore: cast_nullable_to_non_nullable
              as List<String>,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _$AudioPlayerStateImpl extends _AudioPlayerState {
  _$AudioPlayerStateImpl(
      {required this.playing,
      required this.loopMode,
      required this.shuffled,
      required final List<String> collections,
      this.currentIndex = 0,
      final List<SpotubeTrackObject> tracks = const [],
      @JsonKey(includeFromJson: false, includeToJson: false)
      final List<String> entryIds = const []})
      : _collections = collections,
        _tracks = tracks,
        _entryIds = entryIds,
        super._();

  factory _$AudioPlayerStateImpl.fromJson(Map<String, dynamic> json) =>
      _$$AudioPlayerStateImplFromJson(json);

  @override
  final bool playing;
  @override
  final PlaylistMode loopMode;
  @override
  final bool shuffled;
  final List<String> _collections;
  @override
  List<String> get collections {
    if (_collections is EqualUnmodifiableListView) return _collections;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_collections);
  }

  @override
  @JsonKey()
  final int currentIndex;
  final List<SpotubeTrackObject> _tracks;
  @override
  @JsonKey()
  List<SpotubeTrackObject> get tracks {
    if (_tracks is EqualUnmodifiableListView) return _tracks;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_tracks);
  }

  final List<String> _entryIds;
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<String> get entryIds {
    if (_entryIds is EqualUnmodifiableListView) return _entryIds;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_entryIds);
  }

  @override
  String toString() {
    return 'AudioPlayerState._inner(playing: $playing, loopMode: $loopMode, shuffled: $shuffled, collections: $collections, currentIndex: $currentIndex, tracks: $tracks, entryIds: $entryIds)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$AudioPlayerStateImpl &&
            (identical(other.playing, playing) || other.playing == playing) &&
            (identical(other.loopMode, loopMode) ||
                other.loopMode == loopMode) &&
            (identical(other.shuffled, shuffled) ||
                other.shuffled == shuffled) &&
            const DeepCollectionEquality()
                .equals(other._collections, _collections) &&
            (identical(other.currentIndex, currentIndex) ||
                other.currentIndex == currentIndex) &&
            const DeepCollectionEquality().equals(other._tracks, _tracks) &&
            const DeepCollectionEquality().equals(other._entryIds, _entryIds));
  }

  @JsonKey(ignore: true)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      playing,
      loopMode,
      shuffled,
      const DeepCollectionEquality().hash(_collections),
      currentIndex,
      const DeepCollectionEquality().hash(_tracks),
      const DeepCollectionEquality().hash(_entryIds));

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$AudioPlayerStateImplCopyWith<_$AudioPlayerStateImpl> get copyWith =>
      __$$AudioPlayerStateImplCopyWithImpl<_$AudioPlayerStateImpl>(
          this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$AudioPlayerStateImplToJson(
      this,
    );
  }
}

abstract class _AudioPlayerState extends AudioPlayerState {
  factory _AudioPlayerState(
      {required final bool playing,
      required final PlaylistMode loopMode,
      required final bool shuffled,
      required final List<String> collections,
      final int currentIndex,
      final List<SpotubeTrackObject> tracks,
      @JsonKey(includeFromJson: false, includeToJson: false)
      final List<String> entryIds}) = _$AudioPlayerStateImpl;
  _AudioPlayerState._() : super._();

  factory _AudioPlayerState.fromJson(Map<String, dynamic> json) =
      _$AudioPlayerStateImpl.fromJson;

  @override
  bool get playing;
  @override
  PlaylistMode get loopMode;
  @override
  bool get shuffled;
  @override
  List<String> get collections;
  @override
  int get currentIndex;
  @override
  List<SpotubeTrackObject> get tracks;
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<String> get entryIds;
  @override
  @JsonKey(ignore: true)
  _$$AudioPlayerStateImplCopyWith<_$AudioPlayerStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
