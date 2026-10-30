import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Globals & Palettes
// ─────────────────────────────────────────────────────────────────────────────

late final MyAudioHandler audioHandler;
final AppState appState = AppState();
final ValueNotifier<String?> appNotice = ValueNotifier<String?>(null);
final ValueNotifier<bool> scanning = ValueNotifier<bool>(false);
const MethodChannel _mediaChannel = MethodChannel('com.alexlmp.app/media');

const List<String> kArtStyles = [
  'vinyl_record',
  'sound_wave',
  'equalizer_bars',
  'cyber_neon',
  'music_grid',
];

const List<List<Color>> kArtPalettes = [
  [Color(0xFF2E1C59), Color(0xFFD0BCFF), Color(0xFF0F0B18)],
  [Color(0xFF003822), Color(0xFF86F8B5), Color(0xFF05150E)],
  [Color(0xFF381A00), Color(0xFFFFB77C), Color(0xFF140A02)],
  [Color(0xFF002F4A), Color(0xFF82CFFF), Color(0xFF04101A)],
  [Color(0xFF48003A), Color(0xFFFFADE3), Color(0xFF1A0015)],
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  await appState.load();
  try {
    audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.alexlmp.app.channel.audio',
        androidNotificationChannelName: 'AlexLMP Media Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (_) {
    audioHandler = MyAudioHandler();
  }
  runApp(const AlexLmpApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers & Physics
// ─────────────────────────────────────────────────────────────────────────────

String cleanText(dynamic v, String fallback) {
  final s = v?.toString().trim() ?? '';
  if (s.isEmpty || s == '<unknown>') return fallback;
  return s;
}

String formatDuration(Duration d) {
  final total = d.inSeconds;
  final m = (total ~/ 60).toString().padLeft(2, '0');
  final s = (total % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

Future<String?> pickAndSaveGalleryImage() async {
  try {
    final res = await FilePicker.platform.pickFiles(type: FileType.image);
    if (res == null || res.files.isEmpty) return null;
    final srcPath = res.files.single.path;
    if (srcPath == null) return null;
    final dir = await getApplicationDocumentsDirectory();
    final ext = p.extension(srcPath).isEmpty ? '.jpg' : p.extension(srcPath);
    final dst = p.join(
      dir.path,
      'pl_${DateTime.now().microsecondsSinceEpoch}$ext',
    );
    await File(srcPath).copy(dst);
    return dst;
  } catch (_) {
    return null;
  }
}

class Squishy extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  const Squishy({super.key, required this.child, this.onTap, this.scale = 0.94});

  @override
  State<Squishy> createState() => _SquishyState();
}

class _SquishyState extends State<Squishy> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController.unbounded(vsync: this, value: 1.0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _down() => _ctrl.animateTo(widget.scale, duration: const Duration(milliseconds: 90), curve: Curves.easeOut);
  void _up() {
    _ctrl.animateWith(SpringSimulation(const SpringDescription(mass: 1, stiffness: 480, damping: 16), _ctrl.value, 1.0, 0.0));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _down(),
      onTapUp: (_) {
        HapticFeedback.lightImpact();
        widget.onTap?.call();
        _up();
      },
      onTapCancel: _up,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (ctx, child) => Transform.scale(scale: _ctrl.value.clamp(0.7, 1.2), child: child),
        child: widget.child,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Models & AppState
// ─────────────────────────────────────────────────────────────────────────────

class Playlist {
  final String id;
  String name;
  String? cover;
  final List<String> trackIds;

  Playlist({
    required this.id,
    required this.name,
    this.cover,
    List<String>? trackIds,
  }) : trackIds = trackIds ?? [];

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'cover': cover, 'tracks': trackIds};
  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
    id: j['id'] as String,
    name: j['name'] as String,
    cover: j['cover'] as String?,
    trackIds: List<String>.from(j['tracks'] ?? const []),
  );
}

class TrackItem {
  final String id;
  String title;
  String artist;
  final String album;
  final int durationSeconds;
  final List<Color> artColors;
  String artStyle;
  final String source;
  final String? filePath;

  TrackItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    required this.artColors,
    required this.source,
    this.artStyle = 'vinyl_record',
    this.filePath,
  });

  Uri get playbackUri {
    if (filePath != null && filePath!.isNotEmpty && File(filePath!).existsSync()) {
      return Uri.file(filePath!);
    }
    return source.startsWith('content://') ? Uri.parse(source) : Uri.file(source);
  }

  MediaItem toMediaItem() => MediaItem(
    id: id,
    title: title,
    artist: artist,
    album: album,
    duration: durationSeconds > 0 ? Duration(seconds: durationSeconds) : null,
  );
}

class AppState extends ChangeNotifier {
  SharedPreferences? _prefs;
  Color seedColor = const Color(0xFF567CFF);
  bool useAmoled = true;
  String playerDesignStyle = 'Material Extended';
  bool showArtworkBlurBackdrop = true;
  bool skipSilence = false;
  bool audioNormalization = true;
  bool progressiveSeek = false;
  bool pauseAtZeroVolume = false;
  int crossfadeSeconds = 0;
  bool linkSpeedAndPitch = false;
  double speed = 1.0;
  double pitch = 1.0;

  final Set<String> liked = {};
  final Set<String> deletedIds = {};
  final Map<String, int> playCounts = {};
  Map<String, dynamic> _edits = {};
  final List<Playlist> playlists = [];

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    seedColor = Color(_prefs?.getInt('seed_color') ?? 0xFF567CFF);
    useAmoled = _prefs?.getBool('use_amoled') ?? true;
    playerDesignStyle = _prefs?.getString('player_style') ?? 'Material Extended';
    showArtworkBlurBackdrop = _prefs?.getBool('blur_backdrop') ?? true;
    skipSilence = _prefs?.getBool('skip_silence') ?? false;
    audioNormalization = _prefs?.getBool('norm_audio') ?? true;
    progressiveSeek = _prefs?.getBool('prog_seek') ?? false;
    pauseAtZeroVolume = _prefs?.getBool('pause_zero_vol') ?? false;
    crossfadeSeconds = _prefs?.getInt('crossfade_sec') ?? 0;
    linkSpeedAndPitch = _prefs?.getBool('link_speed_pitch') ?? false;
    speed = _prefs?.getDouble('speed') ?? 1.0;
    pitch = _prefs?.getDouble('pitch') ?? 1.0;

    liked.addAll(_prefs?.getStringList('liked') ?? const []);
    deletedIds.addAll(_prefs?.getStringList('deleted') ?? const []);

    try {
      final rawCounts = jsonDecode(_prefs?.getString('play_counts') ?? '{}') as Map;
      rawCounts.forEach((k, v) => playCounts[k.toString()] = (v as num).toInt());
    } catch (_) {}

    try {
      final raw = jsonDecode(_prefs?.getString('playlists') ?? '[]') as List;
      playlists..clear()..addAll(raw.map((e) => Playlist.fromJson(Map<String, dynamic>.from(e))));
    } catch (_) {}

    try {
      _edits = Map<String, dynamic>.from(jsonDecode(_prefs?.getString('edits') ?? '{}'));
    } catch (_) {}
    notifyListeners();
  }

  void setPlayerDesignStyle(String style) {
    playerDesignStyle = style;
    _prefs?.setString('player_style', style);
    notifyListeners();
  }

  void setSeedColor(Color c) {
    seedColor = c;
    _prefs?.setInt('seed_color', c.value);
    notifyListeners();
  }

  void setAmoled(bool v) {
    useAmoled = v;
    _prefs?.setBool('use_amoled', v);
    notifyListeners();
  }

  void setBlurBackdrop(bool v) {
    showArtworkBlurBackdrop = v;
    _prefs?.setBool('blur_backdrop', v);
    notifyListeners();
  }

  void setSkipSilence(bool v) {
    skipSilence = v;
    _prefs?.setBool('skip_silence', v);
    audioHandler.player.setSkipSilenceEnabled(v);
    notifyListeners();
  }

  void setAudioNormalization(bool v) {
    audioNormalization = v;
    _prefs?.setBool('norm_audio', v);
    notifyListeners();
  }

  void setProgressiveSeek(bool v) {
    progressiveSeek = v;
    _prefs?.setBool('prog_seek', v);
    notifyListeners();
  }

  void setPauseAtZeroVolume(bool v) {
    pauseAtZeroVolume = v;
    _prefs?.setBool('pause_zero_vol', v);
    notifyListeners();
  }

  void setCrossfadeSeconds(int sec) {
    crossfadeSeconds = sec;
    _prefs?.setInt('crossfade_sec', sec);
    notifyListeners();
  }

  void setLinkSpeedAndPitch(bool v) {
    linkSpeedAndPitch = v;
    _prefs?.setBool('link_speed_pitch', v);
    notifyListeners();
  }

  void setSpeed(double v) {
    speed = v.clamp(0.5, 2.0);
    _prefs?.setDouble('speed', speed);
    notifyListeners();
  }

  void setPitch(double v) {
    pitch = v.clamp(0.5, 2.0);
    _prefs?.setDouble('pitch', pitch);
    notifyListeners();
  }

  void incrementPlayCount(String id) {
    playCounts[id] = (playCounts[id] ?? 0) + 1;
    _prefs?.setString('play_counts', jsonEncode(playCounts));
    notifyListeners();
  }

  bool isDeleted(String id, [String? path]) =>
      deletedIds.contains(id) || (path != null && deletedIds.contains(path));

  void markDeleted(TrackItem t) {
    deletedIds.add(t.id);
    if (t.filePath != null) deletedIds.add(t.filePath!);
    if (t.source.isNotEmpty) deletedIds.add(t.source);
    _prefs?.setStringList('deleted', deletedIds.toList());
    liked.remove(t.id);
    _prefs?.setStringList('liked', liked.toList());
    for (final pl in playlists) {
      pl.trackIds.remove(t.id);
    }
    _savePlaylists();
  }

  void unmarkDeleted(String id, [String? path]) {
    deletedIds.remove(id);
    if (path != null) deletedIds.remove(path);
    _prefs?.setStringList('deleted', deletedIds.toList());
  }

  bool isLiked(String id) => liked.contains(id);

  void toggleLike(String id) {
    if (!liked.remove(id)) liked.add(id);
    _prefs?.setStringList('liked', liked.toList());
    notifyListeners();
  }

  Playlist? playlistById(String id) {
    for (final p in playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  void _savePlaylists() {
    _prefs?.setString('playlists', jsonEncode(playlists.map((p) => p.toJson()).toList()));
    notifyListeners();
  }

  Playlist createPlaylist(String name, {String? cover}) {
    final pl = Playlist(
      id: 'pl_${DateTime.now().microsecondsSinceEpoch}',
      name: name.isEmpty ? 'My Playlist' : name,
      cover: cover,
    );
    playlists.add(pl);
    _savePlaylists();
    return pl;
  }

  void setPlaylistInfo(String id, String name, String? cover) {
    final pl = playlistById(id);
    if (pl != null) {
      pl.name = name.isEmpty ? pl.name : name;
      pl.cover = cover;
      _savePlaylists();
    }
  }

  void deletePlaylist(String id) {
    playlists.removeWhere((p) => p.id == id);
    _savePlaylists();
  }

  bool inPlaylist(String pid, String tid) => playlistById(pid)?.trackIds.contains(tid) ?? false;

  void togglePlaylistTrack(String pid, String tid) {
    final pl = playlistById(pid);
    if (pl != null) {
      if (!pl.trackIds.remove(tid)) pl.trackIds.add(tid);
      _savePlaylists();
    }
  }

  void addToPlaylist(String pid, String tid) {
    final pl = playlistById(pid);
    if (pl != null && !pl.trackIds.contains(tid)) {
      pl.trackIds.add(tid);
      _savePlaylists();
    }
  }

  void removeFromPlaylist(String pid, String tid) {
    final pl = playlistById(pid);
    if (pl != null) {
      pl.trackIds.remove(tid);
      _savePlaylists();
    }
  }

  void movePlaylistTrack(String pid, int from, int to) {
    final pl = playlistById(pid);
    if (pl != null && from >= 0 && from < pl.trackIds.length) {
      final id = pl.trackIds.removeAt(from);
      pl.trackIds.insert(to.clamp(0, pl.trackIds.length), id);
      _savePlaylists();
    }
  }

  void applyEdits(TrackItem t) {
    if (_edits[t.id] is Map) {
      final e = _edits[t.id];
      t.title = e['title'] ?? t.title;
      t.artist = e['artist'] ?? t.artist;
      t.artStyle = e['style'] ?? t.artStyle;
    }
  }

  void saveEdit(TrackItem t) {
    _edits[t.id] = {'title': t.title, 'artist': t.artist, 'style': t.artStyle};
    _prefs?.setString('edits', jsonEncode(_edits));
    notifyListeners();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Audio Handler
// ─────────────────────────────────────────────────────────────────────────────

class MyAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player = AudioPlayer(
    handleInterruptions: true,
    androidApplyAudioAttributes: true,
  );
  List<TrackItem> tracks = [];
  int _index = 0;
  bool _shuffle = false;
  AudioServiceRepeatMode _repeat = AudioServiceRepeatMode.none;
  final ValueNotifier<int> currentIndex = ValueNotifier<int>(0);
  final ValueNotifier<int> libraryRevision = ValueNotifier<int>(0);

  MyAudioHandler() {
    _init();
  }

  int get index => _index;
  TrackItem? get currentTrack => (_index >= 0 && _index < tracks.length) ? tracks[_index] : null;
  TrackItem? trackById(String id) {
    for (final t in tracks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> _init() async {
    try {
      final s = await AudioSession.instance;
      await s.configure(const AudioSessionConfiguration.music());
    } catch (_) {}
    try {
      await player.setSkipSilenceEnabled(appState.skipSilence);
    } catch (_) {}

    player.playbackEventStream.map(_transformEvent).listen(playbackState.add, onError: (_, __) {});

    player.processingStateStream.listen((state) {
      if (state == ProcessingState.ready) {
        _applySpeedAndPitch();
      } else if (state == ProcessingState.completed) {
        _onCompleted();
      }
    });

    player.playingStream.listen((playing) {
      if (playing) _applySpeedAndPitch();
    });

    player.durationStream.listen((d) {
      final item = mediaItem.value;
      if (d != null && item != null && d != item.duration) {
        mediaItem.add(item.copyWith(duration: d));
      }
    });
  }

  Future<void> _applySpeedAndPitch() async {
    try {
      if ((player.speed - appState.speed).abs() > 0.005) {
        await player.setSpeed(appState.speed);
      }
    } catch (_) {}
    try {
      await player.setPitch(appState.pitch);
    } catch (_) {}
  }

  @override
  Future<void> setSpeed(double speed) async {
    appState.setSpeed(speed);
    await _applySpeedAndPitch();
    playbackState.add(playbackState.value.copyWith(speed: speed));
  }

  Future<void> setPitch(double pitch) async {
    appState.setPitch(pitch);
    await _applySpeedAndPitch();
  }

  void refreshMediaItem() {
    final t = currentTrack;
    if (t != null) {
      mediaItem.add(t.toMediaItem().copyWith(duration: player.duration));
    }
    libraryRevision.value++;
  }

  PlaybackState _transformEvent(PlaybackEvent event) => PlaybackState(
    controls: [
      MediaControl.skipToPrevious,
      player.playing ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
    ],
    systemActions: const {MediaAction.seek},
    androidCompactActionIndices: const [0, 1, 2],
    processingState: const {
      ProcessingState.idle: AudioProcessingState.idle,
      ProcessingState.loading: AudioProcessingState.loading,
      ProcessingState.buffering: AudioProcessingState.buffering,
      ProcessingState.ready: AudioProcessingState.ready,
      ProcessingState.completed: AudioProcessingState.completed,
    }[player.processingState]!,
    playing: player.playing,
    updatePosition: player.position,
    bufferedPosition: player.bufferedPosition,
    speed: player.speed,
    queueIndex: _index,
    shuffleMode: _shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
    repeatMode: _repeat,
  );

  Future<void> setTracks(List<TrackItem> list) async {
    final cid = currentTrack?.id;
    tracks = list;
    libraryRevision.value++;
    if (list.isEmpty) return;
    final keep = list.indexWhere((t) => t.id == cid);
    if (keep >= 0) {
      _index = keep;
      currentIndex.value = keep;
    } else {
      await _load(0, play: false);
    }
  }

  Future<void> deleteTrackFromLibrary(TrackItem t) async {
    final removeIdx = tracks.indexWhere((x) => x.id == t.id);
    final wasCurrent = currentTrack?.id == t.id;
    appState.markDeleted(t);
    if (t.filePath != null && t.filePath!.isNotEmpty) {
      try {
        File(t.filePath!).deleteSync();
      } catch (_) {}
    }
    if (removeIdx >= 0) {
      final wasPlaying = player.playing;
      tracks.removeAt(removeIdx);
      libraryRevision.value++;
      if (tracks.isEmpty) {
        _index = 0;
        currentIndex.value = 0;
        await player.stop();
        mediaItem.add(null);
      } else if (wasCurrent) {
        if (_index >= tracks.length) _index = 0;
        currentIndex.value = _index;
        await _load(_index, play: wasPlaying);
      } else if (removeIdx < _index) {
        _index = math.max(0, _index - 1);
        currentIndex.value = _index;
      }
    }
  }

  void moveTrack(int o, int n) {
    final item = tracks.removeAt(o);
    tracks.insert(n, item);
    if (_index == o) {
      _index = n;
    } else if (o < _index && n >= _index) {
      _index--;
    } else if (o > _index && n <= _index) {
      _index++;
    }
    currentIndex.value = _index;
    libraryRevision.value++;
  }

  Future<void> _load(int i, {bool play = true}) async {
    if (i < 0 || i >= tracks.length) return;
    _index = i;
    currentIndex.value = i;
    final t = tracks[i];
    mediaItem.add(t.toMediaItem());
    appState.incrementPlayCount(t.id);
    try {
      try {
        await player.setAudioSource(AudioSource.uri(t.playbackUri));
      } catch (_) {
        final fallback = t.source.startsWith('content://') ? Uri.parse(t.source) : Uri.file(t.source);
        await player.setAudioSource(AudioSource.uri(fallback));
      }
      await _applySpeedAndPitch();
      if (play) player.play();
    } catch (_) {}
  }

  Future<void> playIndex(int i) async {
    if (i == _index && player.processingState != ProcessingState.idle) {
      await _applySpeedAndPitch();
      player.play();
      return;
    }
    await _load(i, play: true);
  }

  Future<void> playTrackById(String id) async {
    final i = tracks.indexWhere((t) => t.id == id);
    if (i >= 0) await playIndex(i);
  }

  int? _nextIndex({required bool auto}) {
    if (tracks.isEmpty) return null;
    if (_shuffle && tracks.length > 1) {
      int n;
      do {
        n = math.Random().nextInt(tracks.length);
      } while (n == _index);
      return n;
    }
    final n = _index + 1;
    if (n < tracks.length) return n;
    if (_repeat == AudioServiceRepeatMode.all || !auto) return 0;
    return null;
  }

  Future<void> _onCompleted() async {
    if (_repeat == AudioServiceRepeatMode.one) {
      await player.seek(Duration.zero);
      player.play();
      return;
    }
    final n = _nextIndex(auto: true);
    if (n == null) {
      await _load(0, play: false);
    } else {
      await _load(n, play: true);
    }
  }

  @override
  Future<void> play() async {
    if (tracks.isNotEmpty) {
      await _applySpeedAndPitch();
      player.play();
    }
  }

  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() async {
    final n = _nextIndex(auto: false);
    if (n != null) await _load(n, play: true);
  }

  @override
  Future<void> skipToPrevious() async {
    if (tracks.isEmpty) return;
    if (player.position.inSeconds > 3) {
      await player.seek(Duration.zero);
      return;
    }
    final prev = _shuffle ? math.Random().nextInt(tracks.length) : (_index - 1 + tracks.length) % tracks.length;
    await _load(prev, play: true);
  }

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode s) async {
    _shuffle = s == AudioServiceShuffleMode.all;
    playbackState.add(playbackState.value.copyWith(shuffleMode: s));
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode r) async {
    _repeat = r;
    await player.setLoopMode(r == AudioServiceRepeatMode.one ? LoopMode.one : LoopMode.off);
    playbackState.add(playbackState.value.copyWith(repeatMode: r));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scanning & Local Files
// ─────────────────────────────────────────────────────────────────────────────

Future<void> scanDeviceAudio() async {
  if (!Platform.isAndroid || scanning.value) return;
  scanning.value = true;
  try {
    final audioGranted = await Permission.audio.request().isGranted;
    final storageGranted = await Permission.storage.request().isGranted;
    if (!audioGranted && !storageGranted) return;

    final raw = await _mediaChannel.invokeMethod('scanDeviceAudio') as List? ?? [];
    final scanned = <TrackItem>[];
    for (var i = 0; i < raw.length; i++) {
      final m = Map<String, dynamic>.from(raw[i]);
      final source = (m['uri'] ?? m['filePath'] ?? '').toString();
      if (source.isEmpty) continue;
      final id = 'ms_${m['id']}';
      final fp = (m['filePath'] ?? '').toString();
      if (appState.isDeleted(id, fp.isEmpty ? source : fp)) continue;

      final title = cleanText(m['title'], 'Unknown Track');
      final t = TrackItem(
        id: id,
        title: title,
        artist: cleanText(m['artist'], 'Unknown Artist'),
        album: cleanText(m['album'], 'Local Audio'),
        durationSeconds: (m['durationSeconds'] as num?)?.toInt() ?? 0,
        artColors: kArtPalettes[i % kArtPalettes.length],
        artStyle: kArtStyles[i % kArtStyles.length],
        source: source,
        filePath: fp.isEmpty ? null : fp,
      );
      appState.applyEdits(t);
      scanned.add(t);
    }
    final existingLocal = audioHandler.tracks
        .where((t) => t.id.startsWith('local_') && !appState.isDeleted(t.id, t.filePath))
        .toList();
    await audioHandler.setTracks([...existingLocal, ...scanned]);
  } catch (_) {} finally {
    scanning.value = false;
  }
}

Future<void> pickLocalFiles() async {
  final res = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: true);
  if (res == null) return;
  final added = <TrackItem>[];
  for (var i = 0; i < res.files.length; i++) {
    final path = res.files[i].path;
    if (path == null) continue;
    final id = 'local_${path.hashCode}';
    appState.unmarkDeleted(id, path);
    final t = TrackItem(
      id: id,
      title: p.basenameWithoutExtension(path),
      artist: 'Local File',
      album: 'Imported',
      durationSeconds: 0,
      artColors: kArtPalettes[i % kArtPalettes.length],
      artStyle: kArtStyles[i % kArtStyles.length],
      source: path,
      filePath: path,
    );
    added.add(t);
  }
  if (added.isNotEmpty) {
    await audioHandler.setTracks([...added, ...audioHandler.tracks]);
    await audioHandler.playIndex(0);
  }
}

Future<int> quickImportDownloads() async {
  int count = 0;
  try {
    final candidateDirs = [
      Directory('/storage/emulated/0/Download'),
      Directory('/storage/emulated/0/Music'),
    ];
    final existingPaths = audioHandler.tracks.map((t) => t.filePath ?? t.source).toSet();
    final found = <TrackItem>[];

    for (final dir in candidateDirs) {
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync(followLinks: false)) {
        if (f is! File) continue;
        final ext = p.extension(f.path).toLowerCase();
        if (!['.mp3', '.m4a', '.flac', '.wav', '.ogg', '.opus'].contains(ext)) continue;
        if (existingPaths.contains(f.path)) continue;

        final id = 'local_${f.path.hashCode}';
        if (appState.isDeleted(id, f.path)) continue;
        final base = p.basenameWithoutExtension(f.path);

        final t = TrackItem(
          id: id,
          title: base,
          artist: 'Downloads',
          album: 'Device Audio',
          durationSeconds: 0,
          artColors: kArtPalettes[found.length % kArtPalettes.length],
          artStyle: kArtStyles[found.length % kArtStyles.length],
          source: f.path,
          filePath: f.path,
        );
        appState.applyEdits(t);
        found.add(t);
        existingPaths.add(f.path);
        count++;
      }
    }
    if (found.isNotEmpty) {
      await audioHandler.setTracks([...found, ...audioHandler.tracks]);
    }
  } catch (_) {}
  return count;
}

// ─────────────────────────────────────────────────────────────────────────────
// Artwork & Procedural Cover Generators
// ─────────────────────────────────────────────────────────────────────────────

final Map<String, Object?> _artCache = {};

Future<Uint8List?> loadArt(TrackItem t) {
  final ex = _artCache[t.id];
  if (ex is Future<Uint8List?>) return ex;
  final fut = _fetchArt(t);
  _artCache[t.id] = fut;
  return fut;
}

Future<Uint8List?> _fetchArt(TrackItem t) async {
  if (!Platform.isAndroid) return null;
  try {
    final res = await _mediaChannel.invokeMethod('getArt', {
      'uri': t.source,
      'path': t.filePath ?? '',
    });
    return res is Uint8List ? res : null;
  } catch (_) {
    return null;
  }
}

class CustomAlbumArtwork extends StatelessWidget {
  final TrackItem track;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;

  const CustomAlbumArtwork({
    super.key,
    required this.track,
    this.width,
    this.height,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final placeholder = CustomPaint(
      painter: _ProceduralCoverPainter(track.artStyle, track.artColors, track.title),
      child: SizedBox(width: width, height: height),
    );

    final imageWidget = FutureBuilder<Uint8List?>(
      future: loadArt(track),
      builder: (ctx, snap) {
        if (snap.data != null && snap.data!.isNotEmpty) {
          return Image.memory(
            snap.data!,
            width: width,
            height: height,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => placeholder,
          );
        }
        return placeholder;
      },
    );

    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: imageWidget);
    }
    return imageWidget;
  }
}

class _ProceduralCoverPainter extends CustomPainter {
  final String style;
  final List<Color> colors;
  final String seed;

  _ProceduralCoverPainter(this.style, this.colors, this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final primary = colors.isNotEmpty ? colors[0] : const Color(0xFF1B2A4A);
    final secondary = colors.length > 1 ? colors[1] : const Color(0xFF567CFF);
    final dark = colors.length > 2 ? colors[2] : const Color(0xFF0A1020);

    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [primary, dark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(rect),
    );

    final center = Offset(size.width / 2, size.height / 2);
    final s = size.shortestSide;

    if (style == 'vinyl_record') {
      final g = Paint()
        ..color = Colors.white.withOpacity(0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, s * 0.015);
      for (double r = s * 0.16; r < s * 0.46; r += s * 0.06) {
        canvas.drawCircle(center, r, g);
      }
      canvas.drawCircle(center, s * 0.14, Paint()..color = secondary.withOpacity(0.9));
      canvas.drawCircle(center, s * 0.04, Paint()..color = Colors.black);
    } else if (style == 'sound_wave') {
      final wave = Paint()
        ..color = secondary
        ..strokeWidth = math.max(2.5, s * 0.035)
        ..strokeCap = StrokeCap.round;
      const bars = [0.12, 0.28, 0.42, 0.32, 0.20, 0.38, 0.24, 0.14];
      double x = size.width * 0.16;
      for (final h in bars) {
        canvas.drawLine(Offset(x, center.dy - s * h), Offset(x, center.dy + s * h), wave);
        x += size.width * 0.096;
      }
    } else if (style == 'music_note_grid') {
      final p = Paint()
        ..color = Colors.white.withOpacity(0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(center - Offset(s * 0.15, s * 0.1), s * 0.08, p);
      canvas.drawCircle(center + Offset(s * 0.15, s * 0.1), s * 0.08, p);
      canvas.drawLine(center - Offset(s * 0.07, s * 0.1), center + Offset(s * 0.23, s * 0.1), p);
    } else {
      final bar = Paint()..strokeWidth = math.max(3.0, s * 0.06);
      const heights = [0.25, 0.55, 0.85, 0.45, 0.70, 0.35];
      double x = size.width * 0.18;
      for (int i = 0; i < heights.length; i++) {
        bar.color = (i % 2 == 0) ? secondary : secondary.withOpacity(0.6);
        final h = size.height * 0.38 * heights[i];
        canvas.drawLine(Offset(x, center.dy + h * 0.5), Offset(x, center.dy - h * 0.5), bar);
        x += size.width * 0.125;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ProceduralCoverPainter old) => old.style != style || old.seed != seed;
}

class LikedHeaderCover extends StatelessWidget {
  const LikedHeaderCover({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF281C48),
            Color(0xFF141A38),
            Color(0xFF070B18),
          ],
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            painter: _LikedMeshPainter(),
            size: Size.infinite,
          ),
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF567CFF).withOpacity(0.2),
              border: Border.all(color: const Color(0xFF567CFF).withOpacity(0.4), width: 2),
            ),
            child: const Icon(Icons.favorite_rounded, color: Color(0xFFFF719A), size: 44),
          ),
        ],
      ),
    );
  }
}

class _LikedMeshPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFF567CFF).withOpacity(0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (double r = 40; r < size.width; r += 50) {
      canvas.drawCircle(Offset(size.width * 0.5, size.height * 0.45), r, p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// App Entry & Navigation Shell
// ─────────────────────────────────────────────────────────────────────────────

class AlexLmpApp extends StatelessWidget {
  const AlexLmpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        const bgNavy = Color(0xFF080C1E);
        const cardNavy = Color(0xFF101730);

        return MaterialApp(
          title: 'AlexLMP',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: appState.useAmoled ? Colors.black : bgNavy,
            colorScheme: ColorScheme.dark(
              primary: const Color(0xFF567CFF),
              onPrimary: Colors.white,
              primaryContainer: const Color(0xFF263A75),
              onPrimaryContainer: const Color(0xFFD6E2FF),
              secondary: const Color(0xFF7A9EFF),
              surface: appState.useAmoled ? Colors.black : bgNavy,
              surfaceContainer: appState.useAmoled ? const Color(0xFF0E0E12) : cardNavy,
              surfaceContainerHigh: appState.useAmoled ? const Color(0xFF16161C) : const Color(0xFF192244),
            ),
            fontFamily: 'sans-serif',
          ),
          home: const MainScaffold(),
        );
      },
    );
  }
}

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});
  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    scanDeviceAudio();
    appNotice.addListener(_showNotice);
  }

  @override
  void dispose() {
    appNotice.removeListener(_showNotice);
    super.dispose();
  }

  void _showNotice() {
    final msg = appNotice.value;
    if (msg == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontWeight: FontWeight.bold)),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      );
    appNotice.value = null;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([audioHandler.currentIndex, audioHandler.libraryRevision]),
      builder: (ctx, _) {
        final track = audioHandler.currentTrack;
        final isAmoled = appState.useAmoled;
        final barBg = isAmoled ? const Color(0xFF0A0A0E) : const Color(0xFF0F152E);

        return Scaffold(
          body: Stack(
            children: [
              IndexedStack(
                index: _tab,
                children: const [
                  HomeTab(),
                  SearchTab(),
                  LibraryTab(),
                ],
              ),
              if (track != null)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 82,
                  child: MiniPlayer(track: track),
                ),
            ],
          ),
          bottomNavigationBar: Container(
            decoration: BoxDecoration(
              color: barBg,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 16, offset: const Offset(0, -4)),
              ],
            ),
            child: SafeArea(
              child: SizedBox(
                height: 64,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _navItem(0, Icons.explore_rounded, 'Home'),
                    _navItem(1, Icons.search_rounded, 'Search'),
                    _navItem(2, Icons.grid_view_rounded, 'Library'),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _navItem(int idx, IconData icon, String label) {
    final active = _tab == idx;
    return Squishy(
      onTap: () => setState(() => _tab = idx),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF263A75) : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: active ? const Color(0xFF8AB4F8) : const Color(0xFF8E99B7), size: 22),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: active ? Colors.white : const Color(0xFF8E99B7),
                fontSize: 11,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _isPlayerOpening = false;
void openPlayer(BuildContext context) {
  if (audioHandler.tracks.isEmpty || _isPlayerOpening) return;
  _isPlayerOpening = true;
  Navigator.push(
    context,
    PageRouteBuilder(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (_, __, ___) => const NowPlayingScreen(),
      transitionsBuilder: (_, anim, __, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero).animate(
          CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        ),
        child: FadeTransition(opacity: anim, child: child),
      ),
    ),
  ).then((_) => _isPlayerOpening = false);
}

// ─────────────────────────────────────────────────────────────────────────────
// Home Screen (ArchiveTune Brand, Carousel, Mixes & Artists)
// ─────────────────────────────────────────────────────────────────────────────

class HomeTab extends StatelessWidget {
  const HomeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final tracks = audioHandler.tracks;
    final playlists = appState.playlists;
    final isAmoled = appState.useAmoled;
    final cardBg = isAmoled ? const Color(0xFF101014) : const Color(0xFF141C38);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.graphic_eq_rounded, color: Color(0xFF567CFF), size: 28),
            const SizedBox(width: 8),
            const Text(
              'AlexLMP',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: -0.5),
            ),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.history_rounded), onPressed: () {}),
          IconButton(icon: const Icon(Icons.calendar_today_rounded, size: 20), onPressed: () {}),
          IconButton(icon: const Icon(Icons.new_releases_outlined, size: 20), onPressed: () {}),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsHubScreen())),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          // Filter Chips
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: ['Podcasts', 'Energize', 'Party', 'Feel good', 'Underground', 'Lossless'].map((tag) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Squishy(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Text(tag, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          // Quick Picks Header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
              child: const Text('Quick picks', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            ),
          ),

          // Quick Picks Cards Carousel
          SliverToBoxAdapter(
            child: SizedBox(
              height: 250,
              child: tracks.isEmpty
                  ? Center(
                      child: TextButton.icon(
                        onPressed: pickLocalFiles,
                        icon: const Icon(Icons.folder_open_rounded),
                        label: const Text('Import Audio to Start'),
                      ),
                    )
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: math.min(tracks.length, 6),
                      itemBuilder: (ctx, i) {
                        final t = tracks[i];
                        return Padding(
                          padding: const EdgeInsets.only(right: 14),
                          child: Squishy(
                            onTap: () {
                              audioHandler.playIndex(i);
                              openPlayer(context);
                            },
                            child: SizedBox(
                              width: 200,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(22),
                                    child: AspectRatio(
                                      aspectRatio: 1,
                                      child: CustomAlbumArtwork(track: t),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                                  Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 13)),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),

          // AI / Mixes Banner
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  children: [
                    const Text('Top Mixes for You', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                    const SizedBox(height: 6),
                    const Text(
                      'Scan local files or create playlists to let AlexLMP generate personalized listening mixes.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 12.5),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF567CFF),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                      onPressed: () => scanDeviceAudio(),
                      child: const Text('Sync Music Engine', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Your Playlists Header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Your Playlists', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                  TextButton(
                    onPressed: () => showCreatePlaylistDialog(context),
                    child: const Text('Create New'),
                  ),
                ],
              ),
            ),
          ),

          // Playlists List
          SliverToBoxAdapter(
            child: SizedBox(
              height: 190,
              child: playlists.isEmpty
                  ? Center(
                      child: Text('No custom playlists created yet.', style: TextStyle(color: Colors.grey.shade600)),
                    )
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: playlists.length,
                      itemBuilder: (ctx, i) {
                        final pl = playlists[i];
                        return Padding(
                          padding: const EdgeInsets.only(right: 14),
                          child: Squishy(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlistId: pl.id)),
                            ),
                            child: SizedBox(
                              width: 140,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(18),
                                    child: AspectRatio(
                                      aspectRatio: 1,
                                      child: pl.cover != null && File(pl.cover!).existsSync()
                                          ? Image.file(File(pl.cover!), fit: BoxFit.cover)
                                          : Container(
                                              color: const Color(0xFF263A75),
                                              child: const Icon(Icons.queue_music_rounded, color: Colors.white, size: 40),
                                            ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                  Text('${pl.trackIds.length} tracks', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 160)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Search Screen (Explore & Moods Grid)
// ─────────────────────────────────────────────────────────────────────────────

class SearchTab extends StatefulWidget {
  const SearchTab({super.key});
  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  String _query = '';

  static const List> kGenres = [
    {'title': '1960s Classics', 'color': Color(0xFF388E3C), 'style': 'sound_wave'},
    {'title': 'Underground Rap', 'color': Color(0xFF7B1FA2), 'style': 'cyber_neon'},
    {'title': '2000s Hits', 'color': Color(0xFF1976D2), 'style': 'vinyl_record'},
    {'title': 'Electronic', 'color': Color(0xFF0097A7), 'style': 'equalizer_bars'},
    {'title': 'Bass Heavy', 'color': Color(0xFFD32F2F), 'style': 'sound_wave'},
    {'title': 'Lo-Fi Chill', 'color': Color(0xFF455A64), 'style': 'vinyl_record'},
    {'title': '1970s Disco', 'color': Color(0xFF689F38), 'style': 'cyber_neon'},
    {'title': 'Indie & Alt', 'color': Color(0xFF5D4037), 'style': 'music_note_grid'},
  ];

  @override
  Widget build(BuildContext context) {
    final tracks = audioHandler.tracks;
    final isAmoled = appState.useAmoled;
    final cardBg = isAmoled ? const Color(0xFF101014) : const Color(0xFF141C38);

    final filtered = _query.isEmpty
        ? const <TrackItem>[]
        : tracks.where((t) => t.title.toLowerCase().contains(_query.toLowerCase()) || t.artist.toLowerCase().contains(_query.toLowerCase())).toList();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Container(
          height: 48,
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white12),
          ),
          child: TextField(
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: const InputDecoration(
              hintText: 'Search local tracks & artists...',
              hintStyle: TextStyle(color: Colors.grey, fontSize: 14),
              prefixIcon: Icon(Icons.search_rounded, color: Color(0xFF567CFF)),
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
      ),
      body: _query.isNotEmpty
          ? ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 160),
              itemCount: filtered.length,
              itemBuilder: (ctx, i) {
                final t = filtered[i];
                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(width: 46, height: 46, child: CustomAlbumArtwork(track: t)),
                  ),
                  title: Text(t.title, maxLines: 1),
                  subtitle: Text(t.artist),
                  onTap: () {
                    audioHandler.playTrackById(t.id);
                    openPlayer(context);
                  },
                );
              },
            )
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    child: const Text('Mood & Genres', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.8,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) {
                        final g = kGenres[i];
                        final c = g['color'] as Color;
                        return Squishy(
                          onTap: () => setState(() => _query = g['title'].toString().split(' ').first),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              gradient: LinearGradient(
                                colors: [c.withOpacity(0.85), c.withOpacity(0.35)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                            ),
                            padding: const EdgeInsets.all(14),
                            child: Stack(
                              children: [
                                Positioned(
                                  right: -10,
                                  bottom: -10,
                                  child: Icon(Icons.music_note_rounded, size: 54, color: Colors.white.withOpacity(0.2)),
                                ),
                                Text(
                                  g['title'] as String,
                                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                      childCount: kGenres.length,
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 160)),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Library Screen (ArchiveTune 2x2 Grid + Liked + Most Played)
// ─────────────────────────────────────────────────────────────────────────────

class LibraryTab extends StatelessWidget {
  const LibraryTab({super.key});

  @override
  Widget build(BuildContext context) {
    final tracks = audioHandler.tracks;
    final likedCount = appState.liked.length;
    final isAmoled = appState.useAmoled;
    final cardBg = isAmoled ? const Color(0xFF101014) : const Color(0xFF141C38);

    TrackItem? mostPlayed;
    int highestPlays = -1;
    for (final t in tracks) {
      final p = appState.playCounts[t.id] ?? 0;
      if (p > highestPlays) {
        highestPlays = p;
        mostPlayed = t;
      }
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.graphic_eq_rounded, color: Color(0xFF567CFF), size: 28),
            const SizedBox(width: 8),
            const Text('AlexLMP', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_done_rounded),
            tooltip: 'Import Downloads Folder',
            onPressed: () async {
              final n = await quickImportDownloads();
              appNotice.value = n > 0 ? 'Imported $n tracks from phone Downloads!' : 'No new tracks in phone Downloads.';
            },
          ),
          IconButton(icon: const Icon(Icons.folder_open_rounded), onPressed: pickLocalFiles),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsHubScreen())),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 160),
        children: [
          // Filter Row Chips
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _topPill('Library', Icons.graphic_eq_rounded, true),
                const SizedBox(width: 8),
                _topPill('Playlists', Icons.queue_music_rounded, false),
                const SizedBox(width: 8),
                _topPill('Podcast', Icons.mic_none_rounded, false),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // Most Played Hero Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    width: 72,
                    height: 72,
                    child: mostPlayed != null
                        ? CustomAlbumArtwork(track: mostPlayed)
                        : Container(color: const Color(0xFF263A75), child: const Icon(Icons.music_note, color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF567CFF).withOpacity(0.18),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text('MOST PLAYED', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFF8AB4F8))),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        mostPlayed?.title ?? 'No Plays Yet',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                      ),
                      Text(
                        mostPlayed?.artist ?? 'Listen to songs to rank them',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Squishy(
                  onTap: () {
                    if (mostPlayed != null) {
                      audioHandler.playTrackById(mostPlayed.id);
                      openPlayer(context);
                    }
                  },
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      color: Color(0xFF567CFF),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2x2 Grid from Screenshot
          Row(
            children: [
              Expanded(
                child: _gridCard(
                  context,
                  title: 'Liked songs',
                  subtitle: '$likedCount tracks',
                  icon: Icons.favorite_rounded,
                  iconColor: const Color(0xFFFF719A),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LikedTracksScreen())),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _gridCard(
                  context,
                  title: 'Offline',
                  subtitle: '${tracks.length} Downloaded',
                  icon: Icons.check_circle_outline_rounded,
                  iconColor: const Color(0xFF86F8B5),
                  onTap: () => pickLocalFiles(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _gridCard(
                  context,
                  title: 'Playlists',
                  subtitle: '${appState.playlists.length} custom',
                  icon: Icons.queue_music_rounded,
                  iconColor: const Color(0xFFFFB77C),
                  onTap: () => showCreatePlaylistDialog(context),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _gridCard(
                  context,
                  title: 'Local Files',
                  subtitle: 'On device storage',
                  icon: Icons.folder_rounded,
                  iconColor: const Color(0xFF82CFFF),
                  onTap: () => scanDeviceAudio(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Engine Details Card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF263A75),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              children: [
                const Icon(Icons.star_rounded, color: Color(0xFFFFD54F), size: 32),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('AlexLMP Media Engine', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                      Text('Lossless local playback + ExoPlayer pitch shifter', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topPill(String text, IconData icon, bool active) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF263A75) : const Color(0xFF141C38),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: active ? Colors.white : Colors.grey),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: active ? Colors.white : Colors.grey)),
        ],
      ),
    );
  }

  Widget _gridCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    final isAmoled = appState.useAmoled;
    final cardBg = isAmoled ? const Color(0xFF101014) : const Color(0xFF141C38);

    return Squishy(
      onTap: onTap,
      child: Container(
        height: 110,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.18),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Liked Screen (Replicating Screenshot Layout without Faces)
// ─────────────────────────────────────────────────────────────────────────────

class LikedTracksScreen extends StatelessWidget {
  const LikedTracksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final allTracks = audioHandler.tracks;
    final likedTracks = allTracks.where((t) => appState.isLiked(t.id)).toList();
    final totalSeconds = likedTracks.fold<int>(0, (prev, t) => prev + t.durationSeconds);
    final totalHours = totalSeconds ~/ 3600;
    final totalMins = (totalSeconds % 3600) ~/ 60;
    final durationStr = totalHours > 0 ? '${totalHours}h ${totalMins}m' : '${totalMins}m';

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(icon: const Icon(Icons.search_rounded), onPressed: () {}),
              IconButton(icon: const Icon(Icons.more_vert_rounded), onPressed: () {}),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  const LikedHeaderCover(),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.transparent, Theme.of(context).scaffoldBackgroundColor],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 24,
                    left: 20,
                    right: 20,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Text(
                          'Liked',
                          style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${likedTracks.length} songs • $durationStr',
                          style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Squishy Action Controls from Screenshot
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _actionCircle(Icons.download_rounded, () {}),
                  const SizedBox(width: 12),
                  _actionCircle(Icons.shuffle_rounded, () {
                    audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
                    if (likedTracks.isNotEmpty) {
                      audioHandler.playTrackById(likedTracks.first.id);
                      openPlayer(context);
                    }
                  }),
                  const SizedBox(width: 14),
                  Squishy(
                    onTap: () {
                      if (likedTracks.isNotEmpty) {
                        audioHandler.playTrackById(likedTracks.first.id);
                        openPlayer(context);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(32),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.play_arrow_rounded, color: Colors.black, size: 26),
                          SizedBox(width: 8),
                          Text('Play', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  _actionCircle(Icons.playlist_play_rounded, () {}),
                ],
              ),
            ),
          ),

          // Date Added Filter Pill Row
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF263A75),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('Date added', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF263A75).withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.arrow_downward_rounded, size: 16),
                  ),
                ],
              ),
            ),
          ),

          // Liked Song List
          if (likedTracks.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text('No liked songs yet. Tap the heart icon in player!', style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final t = likedTracks[i];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: t)),
                    ),
                    title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Row(
                      children: [
                        const Icon(Icons.favorite_rounded, color: Color(0xFFFF719A), size: 14),
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(3)),
                          child: const Text('E', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 6),
                        Expanded(child: Text('${t.artist} • ${formatDuration(Duration(seconds: t.durationSeconds))}', maxLines: 1, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.more_vert_rounded),
                      onPressed: () => showAddToPlaylistSheet(context, t),
                    ),
                    onTap: () {
                      audioHandler.playTrackById(t.id);
                      openPlayer(context);
                    },
                  );
                },
                childCount: likedTracks.length,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 160)),
        ],
      ),
    );
  }

  Widget _actionCircle(IconData icon, VoidCallback onTap) {
    return Squishy(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: const Color(0xFF141C38),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white12),
        ),
        child: Icon(icon, color: Colors.white70, size: 22),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Now Playing Screen (Swipe Left/Right PageView + Swipe Down Dismiss)
// ─────────────────────────────────────────────────────────────────────────────

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  late PageController _pageCtrl;
  double _dragDownOffset = 0.0;

  @override
  void initState() {
    super.initState();
    final initPage = audioHandler.tracks.isEmpty
        ? 0
        : audioHandler.index.clamp(0, math.max(0, audioHandler.tracks.length - 1));
    _pageCtrl = PageController(
      initialPage: initPage,
      viewportFraction: 0.90,
    );
    audioHandler.currentIndex.addListener(_onIndexChanged);
  }

  void _onIndexChanged() {
    if (_pageCtrl.hasClients && _pageCtrl.page?.round() != audioHandler.index) {
      _pageCtrl.animateToPage(
        audioHandler.index,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    audioHandler.currentIndex.removeListener(_onIndexChanged);
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appState, audioHandler.currentIndex]),
      builder: (ctx, _) {
        final track = audioHandler.currentTrack;
        if (track == null) return const Scaffold();

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (details) {
            if (details.primaryDelta != null && details.primaryDelta! > 0) {
              setState(() {
                _dragDownOffset += details.primaryDelta!;
              });
            } else if (details.primaryDelta != null && details.primaryDelta! < 0 && _dragDownOffset > 0) {
              setState(() {
                _dragDownOffset = math.max(0.0, _dragDownOffset + details.primaryDelta!);
              });
            }
          },
          onVerticalDragEnd: (details) {
            if (_dragDownOffset > 100 || (details.primaryVelocity != null && details.primaryVelocity! > 500)) {
              Navigator.pop(context);
            } else {
              setState(() {
                _dragDownOffset = 0.0;
              });
            }
          },
          onVerticalDragCancel: () {
            if (_dragDownOffset > 0) {
              setState(() => _dragDownOffset = 0.0);
            }
          },
          child: AnimatedContainer(
            duration: _dragDownOffset == 0.0 ? const Duration(milliseconds: 180) : Duration.zero,
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(0, _dragDownOffset, 0),
            child: Scaffold(
              body: Stack(
                children: [
                  // Subtle backdrop blur
                  if (appState.showArtworkBlurBackdrop)
                    Positioned.fill(
                      child: Opacity(
                        opacity: 0.25,
                        child: CustomAlbumArtwork(track: track),
                      ),
                    ),
                  Container(color: Colors.black.withOpacity(appState.useAmoled ? 0.88 : 0.80)),

                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      child: Column(
                        children: [
                          // Header Row
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
                                onPressed: () => Navigator.pop(context),
                              ),
                              const Text(
                                'Now Playing',
                                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                              ),
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.chat_bubble_outline_rounded, size: 22),
                                    onPressed: () {},
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.format_list_bulleted_rounded, size: 22),
                                    onPressed: () => showQueueSheet(context),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),

                          // Large Album Art Swipeable Carousel
                          Expanded(
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: PageView.builder(
                                  controller: _pageCtrl,
                                  physics: const BouncingScrollPhysics(),
                                  itemCount: audioHandler.tracks.length,
                                  onPageChanged: (newIdx) {
                                    if (newIdx != audioHandler.index) {
                                      audioHandler.playIndex(newIdx);
                                    }
                                  },
                                  itemBuilder: (ctx, i) {
                                    final t = audioHandler.tracks[i];
                                    final isCurrent = i == audioHandler.index;
                                    final art = ClipRRect(
                                      borderRadius: BorderRadius.circular(32),
                                      child: CustomAlbumArtwork(track: t),
                                    );
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6),
                                      child: isCurrent
                                          ? Hero(tag: 'now_playing_art', child: art)
                                          : art,
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),

                          // Track Info + Explicit Badge + Like
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            track.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 24),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)),
                                          child: const Text('E', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      track.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.grey, fontSize: 16),
                                    ),
                                  ],
                                ),
                              ),
                              Squishy(
                                onTap: () => appState.toggleLike(track.id),
                                child: Icon(
                                  appState.isLiked(track.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                  color: appState.isLiked(track.id) ? const Color(0xFFFF719A) : Colors.white70,
                                  size: 28,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),

                          // Scrubbing Bar
                          WavySeekBar(track: track),
                          const SizedBox(height: 20),

                          // Pill-Shaped Primary Controls
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _pillButton(Icons.skip_previous_rounded, 80, audioHandler.skipToPrevious),
                              StreamBuilder<PlaybackState>(
                                stream: audioHandler.playbackState,
                                builder: (ctx, snap) {
                                  final playing = snap.data?.playing ?? false;
                                  return Squishy(
                                    onTap: () => playing ? audioHandler.pause() : audioHandler.play(),
                                    child: Container(
                                      width: 104,
                                      height: 64,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF7D8D5),
                                        borderRadius: BorderRadius.circular(32),
                                      ),
                                      child: Icon(
                                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                        color: Colors.black,
                                        size: 38,
                                      ),
                                    ),
                                  );
                                },
                              ),
                              _pillButton(Icons.skip_next_rounded, 80, audioHandler.skipToNext),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // Bottom Sub-Pills (Shuffle, Repeat, More Menu)
                          StreamBuilder<PlaybackState>(
                            stream: audioHandler.playbackState,
                            builder: (ctx, snap) {
                              final state = snap.data ?? audioHandler.playbackState.value;
                              final shuffle = state.shuffleMode == AudioServiceShuffleMode.all;
                              final repeat = state.repeatMode;

                              return Row(
                                children: [
                                  Expanded(
                                    child: _subPill(
                                      icon: Icons.shuffle_rounded,
                                      active: shuffle,
                                      onTap: () => audioHandler.setShuffleMode(shuffle ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _subPill(
                                      icon: repeat == AudioServiceRepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                                      active: repeat != AudioServiceRepeatMode.none,
                                      onTap: () {
                                        final next = switch (repeat) {
                                          AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
                                          AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
                                          _ => AudioServiceRepeatMode.none,
                                        };
                                        audioHandler.setRepeatMode(next);
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _subPill(
                                      icon: Icons.more_horiz_rounded,
                                      active: false,
                                      onTap: () => showAddToPlaylistSheet(context, track),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _pillButton(IconData icon, double width, VoidCallback onTap) {
    return Squishy(
      onTap: onTap,
      child: Container(
        width: width,
        height: 64,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1A1A),
          borderRadius: BorderRadius.circular(32),
        ),
        child: Icon(icon, color: Colors.white, size: 30),
      ),
    );
  }

  Widget _subPill({required IconData icon, required bool active, required VoidCallback onTap}) {
    return Squishy(
      onTap: onTap,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1A1A),
          borderRadius: BorderRadius.circular(26),
        ),
        child: Icon(icon, color: active ? const Color(0xFF567CFF) : Colors.white70, size: 22),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Wavy Scrubbing Bar
// ─────────────────────────────────────────────────────────────────────────────

class WavySeekBar extends StatefulWidget {
  final TrackItem track;
  const WavySeekBar({super.key, required this.track});

  @override
  State<WavySeekBar> createState() => _WavySeekBarState();
}

class _WavySeekBarState extends State<WavySeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: audioHandler.player.durationStream,
      builder: (_, durSnap) {
        final dur = durSnap.data ?? Duration(seconds: widget.track.durationSeconds);
        final maxMs = math.max(1.0, dur.inMilliseconds.toDouble());

        return StreamBuilder<Duration>(
          stream: audioHandler.player.positionStream,
          builder: (_, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final currentMs = (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, maxMs);

            return Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3.5,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    activeTrackColor: const Color(0xFFF7D8D5),
                    inactiveTrackColor: Colors.white24,
                    thumbColor: const Color(0xFFF7D8D5),
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: currentMs,
                    min: 0.0,
                    max: maxMs,
                    onChangeStart: (v) => setState(() => _drag = v),
                    onChanged: (v) => setState(() => _drag = v),
                    onChangeEnd: (v) {
                      audioHandler.seek(Duration(milliseconds: v.toInt()));
                      setState(() => _drag = null);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(formatDuration(Duration(milliseconds: currentMs.toInt())), style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                      Text(formatDuration(dur), style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MiniPlayer (Swipe Up Reveal Support)
// ─────────────────────────────────────────────────────────────────────────────

class MiniPlayer extends StatelessWidget {
  final TrackItem track;
  const MiniPlayer({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final isAmoled = appState.useAmoled;
    final bg = isAmoled ? const Color(0xFF141418) : const Color(0xFF141C38);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        if (details.primaryDelta != null && details.primaryDelta! < -8) {
          openPlayer(context);
        }
      },
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! < -150) {
          openPlayer(context);
        }
      },
      child: Squishy(
        onTap: () => openPlayer(context),
        scale: 0.97,
        child: Container(
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(34),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 16, offset: const Offset(0, 4)),
            ],
          ),
          child: Row(
            children: [
              ClipOval(
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: CustomAlbumArtwork(track: track),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  appState.isLiked(track.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  color: appState.isLiked(track.id) ? const Color(0xFFFF719A) : Colors.white70,
                ),
                onPressed: () => appState.toggleLike(track.id),
              ),
              StreamBuilder<PlaybackState>(
                stream: audioHandler.playbackState,
                builder: (ctx, snap) {
                  final playing = snap.data?.playing ?? false;
                  return IconButton(
                    icon: Icon(playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded, size: 38, color: Colors.white),
                    onPressed: () => playing ? audioHandler.pause() : audioHandler.play(),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Settings Screens
// ─────────────────────────────────────────────────────────────────────────────

class SettingsHubScreen extends StatelessWidget {
  const SettingsHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 28)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _settingsTile(Icons.person_outline_rounded, 'Account', 'Sign in and manage local profiles', () {}),
          _settingsTile(Icons.bar_chart_rounded, 'Listening Stats', 'Your top songs, artists, and playback time', () {}),
          _settingsTile(Icons.palette_outlined, 'Appearance', 'Themes, layout, and visual styles', () {
            Navigator.push(context, MaterialPageRoute(builder: (_) => const AppearanceSettingsScreen()));
          }),
          _settingsTile(Icons.music_note_rounded, 'Playback', 'Audio behavior, crossfade, and engine', () {
            Navigator.push(context, MaterialPageRoute(builder: (_) => const PlaybackSettingsScreen()));
          }),
          _settingsTile(Icons.cached_rounded, 'AlexLMP Canvas', 'Sources, local data, and storage cache', () {}),
          _settingsTile(Icons.chat_bubble_outline_rounded, 'Lyrics', 'Lyrics providers and synchronization', () {}),
          _settingsTile(Icons.public_rounded, 'Content', 'Language, country, and scanner filters', () {}),
          _settingsTile(Icons.tune_rounded, 'Behavior', 'History, defaults, and volume controls', () {}),
        ],
      ),
    );
  }

  Widget _settingsTile(IconData icon, String title, String subtitle, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Squishy(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF141C38),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(color: Color(0xFF263A75), shape: BoxShape.circle),
                child: Icon(icon, color: const Color(0xFF8AB4F8), size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Appearance', style: TextStyle(fontWeight: FontWeight.w900))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SwitchListTile(
                title: const Text('Pure AMOLED Black Background'),
                subtitle: const Text('Saves battery on OLED panels (#000000)'),
                value: appState.useAmoled,
                onChanged: appState.setAmoled,
              ),
              SwitchListTile(
                title: const Text('Show artwork as blurred backdrop'),
                subtitle: const Text('Renders ambient blur on the player'),
                value: appState.showArtworkBlurBackdrop,
                onChanged: appState.setBlurBackdrop,
              ),
              const Divider(height: 32),
              ListTile(
                title: const Text('Player design style', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(appState.playerDesignStyle),
                trailing: const Icon(Icons.arrow_drop_down_circle_outlined),
                onTap: () => showPlayerDesignStyleModal(context),
              ),
            ],
          ),
        );
      },
    );
  }
}

void showPlayerDesignStyleModal(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF101014),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        const styles = ['Little', 'Expressive', 'Immersive', 'Immersive Extended', 'Material Extended', 'Editorial'];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey, borderRadius: BorderRadius.circular(2))),
                ),
                const SizedBox(height: 16),
                const Text('Player design style', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 24)),
                const SizedBox(height: 16),
                ...styles.map((s) {
                  final active = appState.playerDesignStyle == s;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Squishy(
                      onTap: () {
                        appState.setPlayerDesignStyle(s);
                        Navigator.pop(ctx);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        decoration: BoxDecoration(
                          color: active ? const Color(0xFFF7D8D5) : const Color(0xFF1E1A1A),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              s,
                              style: TextStyle(
                                color: active ? Colors.black : Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            if (active) const Icon(Icons.check_rounded, color: Colors.black),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class PlaybackSettingsScreen extends StatelessWidget {
  const PlaybackSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Player and audio', style: TextStyle(fontWeight: FontWeight.w900))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _audioCard(
                title: 'Audio quality',
                subtitle: 'Lossless / Auto (Local)',
                icon: Icons.graphic_eq_rounded,
                onTap: () {},
              ),
              SwitchListTile(
                title: const Text('Skip silence'),
                subtitle: const Text('Skip silent intervals automatically'),
                value: appState.skipSilence,
                onChanged: appState.setSkipSilence,
              ),
              SwitchListTile(
                title: const Text('Audio normalization'),
                subtitle: const Text('Normalize dynamic track levels'),
                value: appState.audioNormalization,
                onChanged: appState.setAudioNormalization,
              ),
              SwitchListTile(
                title: const Text('Progressive seek'),
                subtitle: const Text('Adds up 5 extra seconds incrementally on seek'),
                value: appState.progressiveSeek,
                onChanged: appState.setProgressiveSeek,
              ),
              SwitchListTile(
                title: const Text('Pause when device volume is 0'),
                subtitle: const Text('Pause at zero volume and resume when raised'),
                value: appState.pauseAtZeroVolume,
                onChanged: appState.setPauseAtZeroVolume,
              ),
              const Divider(height: 32),
              ListTile(
                title: const Text('Speed & Pitch Shifter', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('${appState.speed.toStringAsFixed(2)}x Speed • ${appState.pitch.toStringAsFixed(2)}p Pitch'),
                trailing: const Icon(Icons.tune_rounded),
                onTap: () => showPlaybackSheet(context),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _audioCard({required String title, required String subtitle, required IconData icon, required VoidCallback onTap}) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF567CFF)),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.arrow_forward_rounded, size: 20),
      onTap: onTap,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Playlists & Management Sheets
// ─────────────────────────────────────────────────────────────────────────────

class PlaylistDetailScreen extends StatelessWidget {
  final String playlistId;
  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final pl = appState.playlistById(playlistId);
        if (pl == null) return const Scaffold();
        final tracks = pl.trackIds.map((id) => audioHandler.trackById(id)).whereType<TrackItem>().toList();

        return Scaffold(
          appBar: AppBar(
            title: Text(pl.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            actions: [
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                onPressed: () {
                  appState.deletePlaylist(pl.id);
                  Navigator.pop(context);
                },
              ),
            ],
          ),
          body: tracks.isEmpty
              ? const Center(child: Text('Playlist is empty. Add songs from 3-dot menu!'))
              : ReorderableListView.builder(
                  itemCount: tracks.length,
                  onReorder: (o, n) {
                    if (n > o) n -= 1;
                    appState.movePlaylistTrack(pl.id, o, n);
                  },
                  itemBuilder: (ctx, i) {
                    final t = tracks[i];
                    return ListTile(
                      key: ValueKey(t.id),
                      leading: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: t)),
                      title: Text(t.title),
                      subtitle: Text(t.artist),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => appState.removeFromPlaylist(pl.id, t.id)),
                          const Icon(Icons.drag_handle_rounded),
                        ],
                      ),
                      onTap: () {
                        audioHandler.playTrackById(t.id);
                        openPlayer(context);
                      },
                    );
                  },
                ),
        );
      },
    );
  }
}

void showAddToPlaylistSheet(BuildContext context, TrackItem track) {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF141C38),
    builder: (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: SizedBox(width: 44, height: 44, child: CustomAlbumArtwork(track: track)),
              title: Text(track.title, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(track.artist),
              trailing: FilledButton.tonal(
                onPressed: () => showCreatePlaylistDialog(context, initialTrackId: track.id),
                child: const Text('New'),
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: appState.playlists.length,
                itemBuilder: (_, i) {
                  final pl = appState.playlists[i];
                  final added = appState.inPlaylist(pl.id, track.id);
                  return ListTile(
                    title: Text(pl.name),
                    trailing: Icon(added ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded, color: added ? const Color(0xFF567CFF) : null),
                    onTap: () => appState.togglePlaylistTrack(pl.id, track.id),
                  );
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
              title: const Text('Delete from Library', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
              onTap: () {
                Navigator.pop(ctx);
                audioHandler.deleteTrackFromLibrary(track);
              },
            ),
          ],
        ),
      ),
    ),
  );
}

void showCreatePlaylistDialog(BuildContext context, {String? initialTrackId}) {
  final ctrl = TextEditingController();
  String? coverPath;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: const Color(0xFF141C38),
        title: const Text('New Playlist'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () async {
                final p = await pickAndSaveGalleryImage();
                if (p != null) setState(() => coverPath = p);
              },
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(16)),
                child: coverPath != null
                    ? Image.file(File(coverPath!), fit: BoxFit.cover)
                    : const Icon(Icons.add_photo_alternate_rounded, size: 36),
              ),
            ),
            const SizedBox(height: 16),
            TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Playlist Name')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final pl = appState.createPlaylist(ctrl.text, cover: coverPath);
              if (initialTrackId != null) appState.addToPlaylist(pl.id, initialTrackId);
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

void showPlaybackSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF141C38),
    builder: (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Speed & Pitch Shifter', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  TextButton(
                    onPressed: () {
                      audioHandler.setSpeed(1.0);
                      audioHandler.setPitch(1.0);
                    },
                    child: const Text('Reset'),
                  ),
                ],
              ),
              SwitchListTile(
                title: const Text('Link Speed & Pitch (Vinyl Mode)'),
                value: appState.linkSpeedAndPitch,
                onChanged: (v) {
                  appState.setLinkSpeedAndPitch(v);
                  if (v) {
                    audioHandler.setSpeed(appState.pitch);
                    audioHandler.setPitch(appState.pitch);
                  }
                },
              ),
              Row(
                children: [
                  const Icon(Icons.speed_rounded),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Slider(
                      value: appState.speed,
                      min: 0.5,
                      max: 2.0,
                      divisions: 30,
                      onChanged: (v) {
                        audioHandler.setSpeed(v);
                        if (appState.linkSpeedAndPitch) audioHandler.setPitch(v);
                      },
                    ),
                  ),
                  Text('${appState.speed.toStringAsFixed(2)}x'),
                ],
              ),
              Row(
                children: [
                  const Icon(Icons.graphic_eq_rounded),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Slider(
                      value: appState.pitch,
                      min: 0.5,
                      max: 2.0,
                      divisions: 60,
                      onChanged: (v) {
                        audioHandler.setPitch(v);
                        if (appState.linkSpeedAndPitch) audioHandler.setSpeed(v);
                      },
                    ),
                  ),
                  Text('${appState.pitch.toStringAsFixed(2)}p'),
                ],
              ),
              Wrap(
                spacing: 8,
                children: [-6, -3, -1, 0, 1, 3, 6].map((st) {
                  final tp = math.pow(2.0, st / 12.0).toDouble();
                  return ChoiceChip(
                    label: Text(st >= 0 ? '+$st st' : '$st st'),
                    selected: (appState.pitch - tp).abs() < 0.02,
                    onSelected: (_) {
                      audioHandler.setPitch(tp);
                      if (appState.linkSpeedAndPitch) audioHandler.setSpeed(tp);
                    },
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void showQueueSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF141C38),
    builder: (ctx) => ListenableBuilder(
      listenable: audioHandler.libraryRevision,
      builder: (ctx, _) => SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Playback Queue', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ),
            Expanded(
              child: ReorderableListView.builder(
                itemCount: audioHandler.tracks.length,
                onReorder: (o, n) {
                  if (n > o) n -= 1;
                  audioHandler.moveTrack(o, n);
                },
                itemBuilder: (ctx, i) {
                  final t = audioHandler.tracks[i];
                  final active = i == audioHandler.index;
                  return ListTile(
                    key: ValueKey(t.id),
                    leading: SizedBox(width: 44, height: 44, child: CustomAlbumArtwork(track: t)),
                    title: Text(t.title, style: TextStyle(color: active ? const Color(0xFF567CFF) : Colors.white, fontWeight: active ? FontWeight.bold : FontWeight.normal)),
                    subtitle: Text(t.artist),
                    onTap: () => audioHandler.playIndex(i),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
