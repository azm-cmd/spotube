part of 'audio_player.dart';

final audioPlayer = SpotubeAudioPlayer();

class SpotubeAudioPlayer extends AudioPlayerInterface
    with SpotubeAudioPlayersStreams {
  Future<void> pause() async {
    await _mkPlayer.pause();
  }

  Future<void> resume() async {
    await _mkPlayer.play();
  }

  Future<void> stop() async {
    await _mkPlayer.stop();
  }

  Future<void> seek(Duration position) async {
    await _mkPlayer.seek(position);
  }

  /// Volume is between 0 and 1
  Future<void> setVolume(double volume) async {
    assert(volume >= 0 && volume <= 1);
    await _mkPlayer.setVolume(volume * 100);
  }

  Future<void> setSpeed(double speed) async {
    await _mkPlayer.setRate(speed);
  }

  Future<void> setAudioDevice(mk.AudioDevice device) async {
    await _mkPlayer.setAudioDevice(device);
  }

  Future<void> dispose() async {
    await _mkPlayer.dispose();
  }

  // Playlist related

  Future<void> openPlaylist(
    List<mk.Media> tracks, {
    bool autoPlay = true,
    int initialIndex = 0,
  }) async {
    assert(tracks.isNotEmpty);
    assert(initialIndex <= tracks.length - 1);
    await _mkPlayer.open(
      mk.Playlist(tracks, index: initialIndex),
      play: autoPlay,
    );
  }

  List<String> get sources {
    return _mkPlayer.state.playlist.medias.map((e) => e.uri).toList();
  }

  String? get currentSource {
    if (_mkPlayer.state.playlist.index == -1) return null;
    return _mkPlayer.state.playlist.medias
        .elementAtOrNull(_mkPlayer.state.playlist.index)
        ?.uri;
  }

  String? get nextSource {
    if (loopMode == PlaylistMode.loop &&
        _mkPlayer.state.playlist.index ==
            _mkPlayer.state.playlist.medias.length - 1) {
      return sources.first;
    }

    return _mkPlayer.state.playlist.medias
        .elementAtOrNull(_mkPlayer.state.playlist.index + 1)
        ?.uri;
  }

  String? get previousSource {
    if (loopMode == PlaylistMode.loop && _mkPlayer.state.playlist.index == 0) {
      return sources.last;
    }

    return _mkPlayer.state.playlist.medias
        .elementAtOrNull(_mkPlayer.state.playlist.index - 1)
        ?.uri;
  }

  int get currentIndex => _mkPlayer.state.playlist.index;

  Future<void> skipToNext() async {
    await _mkPlayer.next();
  }

  Future<void> skipToPrevious() async {
    await _mkPlayer.previous();
  }

  Future<void> jumpTo(int index) async {
    await _mkPlayer.jump(index);
  }

  Future<void> addTrack(mk.Media media) async {
    await _mkPlayer.add(media);
  }

  Future<void> addTrackAt(mk.Media media, int index) async {
    await _mkPlayer.insert(index, media);
  }

  Future<void> removeTrack(int index) async {
    await _mkPlayer.remove(index);
  }

  Future<void> moveTrack(int from, int to) async {
    await _mkPlayer.move(from, to);
  }

  Future<void> clearPlaylist() async {
    _mkPlayer.stop();
  }

  // --- Shuffle ----------------------------------------------------------------
  //
  // Every shuffle request in the app (player controls, tray, lock screen,
  // Connect, "shuffle play", restoring the saved queue) arrives at
  // [setShuffle]. mpv's own shuffle mixes the whole playlist and knows nothing
  // about queue groups, so [setShuffle] hands the request to [shuffleHandler],
  // which decides whether mpv may do it. [setFlatShuffle] is the only code that
  // calls mpv's shuffle, and the handler only uses it for a queue without
  // groups.

  /// Installed by the owner of the queue. Without one, requests go straight to
  /// mpv.
  Future<void> Function(bool shuffle)? shuffleHandler;

  /// Set while the shuffle is done by the app instead of by mpv. It is then the
  /// shuffle state everyone sees, whatever mpv's own flag says.
  bool? _shuffleOverride;

  late final StreamController<bool> _shuffleController = _startShuffleStream();

  StreamController<bool> _startShuffleStream() {
    final controller = StreamController<bool>.broadcast();
    _mkPlayer.shuffleStream.listen((shuffled) {
      if (_shuffleOverride == null) controller.add(shuffled);
    });
    return controller;
  }

  /// Whether the queue is shuffled, as the app reports it.
  @override
  bool get isShuffled => _shuffleOverride ?? _mkPlayer.shuffled;

  /// Changes of [isShuffled].
  @override
  Stream<bool> get shuffledStream => _shuffleController.stream;

  /// mpv's own shuffle flag, which can differ from [isShuffled] while the app
  /// does the shuffling.
  bool get isFlatShuffled => _mkPlayer.shuffled;

  Future<void> setShuffle(bool shuffle) async {
    final handler = shuffleHandler;
    if (handler != null) {
      await handler(shuffle);
      return;
    }
    await setFlatShuffle(shuffle);
  }

  /// mpv's shuffle of the whole playlist. It ignores queue groups and would
  /// break them up: only call it for a queue without groups.
  Future<void> setFlatShuffle(bool shuffle) async {
    await _mkPlayer.setShuffle(shuffle);
  }

  /// Reports [shuffled] as the shuffle state, whatever mpv's flag says.
  void publishShuffle(bool shuffled) {
    _shuffleOverride = shuffled;
    _shuffleController.add(shuffled);
  }

  /// Goes back to reporting mpv's own flag.
  void releaseShuffle() {
    // Nothing was overridden: mpv's own events already say everything.
    if (_shuffleOverride == null) return;
    _shuffleOverride = null;
    _shuffleController.add(_mkPlayer.shuffled);
  }

  Future<void> setLoopMode(PlaylistMode loop) async {
    await _mkPlayer.setPlaylistMode(loop);
  }

  Future<void> setAudioNormalization(bool normalize) async {
    await _mkPlayer.setAudioNormalization(normalize);
  }
}
