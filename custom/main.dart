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
// Helpers
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
      'pl_cover_${DateTime.now().microsecondsSinceEpoch}$ext',
    );
    await File(srcPath).copy(dst);
    return dst;
  } catch (_) {
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Models & State
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

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'cover': cover,
    'tracks': trackIds,
  };

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
    final fp = filePath;
    if (fp != null && fp.isNotEmpty && File(fp).existsSync()) {
      return Uri.file(fp);
    }
    return source.startsWith('content://')
        ? Uri.parse(source)
        : Uri.file(source);
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
  Color seedColor = const Color(0xFFD0BCFF);
  bool useAmoled = true;
  bool vinylSpinMode = true;
  bool linkSpeedAndPitch = false;
  double speed = 1.0;
  double pitch = 1.0;
  final Set<String> liked = {};
  final Set<String> deletedIds = {};
  Map<String, dynamic> _edits = {};
  final List<Playlist> playlists = [];

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    seedColor = Color(_prefs?.getInt('seed_color') ?? 0xFFD0BCFF);
    useAmoled = _prefs?.getBool('use_amoled') ?? true;
    vinylSpinMode = _prefs?.getBool('vinyl_spin_mode') ?? true;
    linkSpeedAndPitch = _prefs?.getBool('link_speed_pitch') ?? false;
    speed = _prefs?.getDouble('speed') ?? 1.0;
    pitch = _prefs?.getDouble('pitch') ?? 1.0;
    liked.addAll(_prefs?.getStringList('liked') ?? const []);
    deletedIds.addAll(_prefs?.getStringList('deleted') ?? const []);
    try {
      final raw = jsonDecode(_prefs?.getString('playlists') ?? '[]') as List;
      playlists
        ..clear()
        ..addAll(raw.map((e) => Playlist.fromJson(Map<String, dynamic>.from(e))));
    } catch (_) {}
    try {
      _edits = Map<String, dynamic>.from(
        jsonDecode(_prefs?.getString('edits') ?? '{}'),
      );
    } catch (_) {}
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

  void setVinylSpinMode(bool v) {
    vinylSpinMode = v;
    _prefs?.setBool('vinyl_spin_mode', v);
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
    _prefs?.setString(
      'playlists',
      jsonEncode(playlists.map((p) => p.toJson()).toList()),
    );
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

  bool inPlaylist(String pid, String tid) =>
      playlistById(pid)?.trackIds.contains(tid) ?? false;

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
// Audio Handler (Sonic ExoPlayer Native Speed & Pitch)
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
  TrackItem? get currentTrack =>
      (_index >= 0 && _index < tracks.length) ? tracks[_index] : null;

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
      await player.setSkipSilenceEnabled(false);
    } catch (_) {}

    player.playbackEventStream.map(_transformEvent).listen(
      playbackState.add,
      onError: (_, __) {},
    );

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
  }

  PlaybackState _transformEvent(PlaybackEvent event) => PlaybackState(
    controls: [
      MediaControl.skipToPrevious,
      player.playing ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
    ],
    systemActions: const {
      MediaAction.seek,
      MediaAction.seekForward,
      MediaAction.seekBackward,
    },
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
    try {
      try {
        await player.setAudioSource(AudioSource.uri(t.playbackUri));
      } catch (_) {
        final fallback = t.source.startsWith('content://')
            ? Uri.parse(t.source)
            : Uri.file(t.source);
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
    final prev = _shuffle
        ? math.Random().nextInt(tracks.length)
        : (_index - 1 + tracks.length) % tracks.length;
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
    await player.setLoopMode(
      r == AudioServiceRepeatMode.one ? LoopMode.one : LoopMode.off,
    );
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
  final res = await FilePicker.platform.pickFiles(
    type: FileType.audio,
    allowMultiple: true,
  );
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
// Artwork
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
  const CustomAlbumArtwork({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: loadArt(track),
      builder: (ctx, snap) {
        final placeholder = CustomPaint(
          painter: _ArtPainter(track.artStyle, track.artColors),
          child: const SizedBox.expand(),
        );
        if (snap.data != null && snap.data!.isNotEmpty) {
          return Image.memory(
            snap.data!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => placeholder,
          );
        }
        return placeholder;
      },
    );
  }
}

class _ArtPainter extends CustomPainter {
  final String style;
  final List<Color> colors;
  _ArtPainter(this.style, this.colors);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()..shader = LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight).createShader(rect),
    );
    final center = Offset(size.width / 2, size.height / 2);
    final s = size.shortestSide;

    if (style == 'vinyl_record') {
      final g = Paint()
        ..color = Colors.white12
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, s * 0.012);
      for (double r = s * 0.18; r < s * 0.46; r += s * 0.06) {
        canvas.drawCircle(center, r, g);
      }
      canvas.drawCircle(center, s * 0.14, Paint()..color = const Color(0xFFFFB77C));
      canvas.drawCircle(center, s * 0.035, Paint()..color = Colors.black);
    } else if (style == 'sound_wave') {
      final wave = Paint()
        ..color = colors.length > 1 ? colors[1] : Colors.white
        ..strokeWidth = math.max(2, s * 0.02)
        ..strokeCap = StrokeCap.round;
      const bars = [0.1, 0.22, 0.35, 0.28, 0.16, 0.32, 0.18, 0.08];
      double x = size.width * 0.18;
      for (final h in bars) {
        canvas.drawLine(Offset(x, center.dy - s * h), Offset(x, center.dy + s * h), wave);
        x += size.width * 0.09;
      }
    } else {
      final circle = Paint()
        ..color = Colors.white.withOpacity(0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      canvas.drawCircle(center, s * 0.28, circle);
      canvas.drawCircle(center, s * 0.15, Paint()..color = Colors.white24);
    }
  }

  @override
  bool shouldRepaint(covariant _ArtPainter old) => old.style != style;
}

// ─────────────────────────────────────────────────────────────────────────────
// Squishy Physical Tap Animation
// ─────────────────────────────────────────────────────────────────────────────

class Squishy extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  const Squishy({super.key, required this.child, this.onTap, this.scale = 0.93});

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

  void _down() => _ctrl.animateTo(widget.scale, duration: const Duration(milliseconds: 100), curve: Curves.easeOut);
  void _up() {
    _ctrl.animateWith(SpringSimulation(const SpringDescription(mass: 1, stiffness: 450, damping: 15), _ctrl.value, 1.0, 0.0));
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
// App UI (Material 3 Expressive + Pure AMOLED)
// ─────────────────────────────────────────────────────────────────────────────

class AlexLmpApp extends StatelessWidget {
  const AlexLmpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final cs = ColorScheme.fromSeed(
          seedColor: appState.seedColor,
          brightness: Brightness.dark,
        );
        final bg = appState.useAmoled ? Colors.black : cs.surface;
        final cardColor = appState.useAmoled ? const Color(0xFF0F0F14) : cs.surfaceContainer;

        return MaterialApp(
          title: 'AlexLMP',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: cs.copyWith(
              surface: bg,
              surfaceContainer: cardColor,
              surfaceContainerHigh: appState.useAmoled ? const Color(0xFF181820) : cs.surfaceContainerHigh,
            ),
            scaffoldBackgroundColor: bg,
            navigationBarTheme: NavigationBarThemeData(
              backgroundColor: cardColor,
              indicatorColor: cs.primary.withOpacity(0.2),
              iconTheme: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return IconThemeData(color: cs.primary);
                }
                return IconThemeData(color: cs.onSurfaceVariant);
              }),
            ),
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
    if (appNotice.value == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(appNotice.value!, style: const TextStyle(fontWeight: FontWeight.bold)),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      );
    appNotice.value = null;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        audioHandler.currentIndex,
        audioHandler.libraryRevision,
      ]),
      builder: (ctx, _) {
        final track = audioHandler.currentTrack;
        return Scaffold(
          body: Stack(
            children: [
              IndexedStack(
                index: _tab,
                children: const [HomeTab(), LibraryTab()],
              ),
              if (track != null)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 84, // Above Material 3 NavigationBar
                  child: MiniPlayer(track: track),
                ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music_rounded),
                label: 'Library',
              ),
            ],
          ),
        );
      },
    );
  }
}

void openPlayer(BuildContext context) {
  if (audioHandler.tracks.isEmpty) return;
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
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Home Screen (Expressive M3 Header + Quick Grid + Recent Flow)
// ─────────────────────────────────────────────────────────────────────────────

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  String _activeChip = 'All';

  @override
  Widget build(BuildContext context) {
    final tracks = audioHandler.tracks;
    final cs = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          expandedHeight: 140,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AlexLMP',
                style: TextStyle(
                  color: cs.primary,
                  fontSize: 14,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Text(
                'Welcome Back',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 32),
              ),
            ],
          ),
          actions: [
            Squishy(
              onTap: () => showSettingsSheet(context),
              child: Container(
                margin: const EdgeInsets.only(right: 16),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.surfaceContainer,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white12),
                ),
                child: const Icon(Icons.settings_rounded, size: 22),
              ),
            ),
          ],
        ),

        // Quick Category Filter Chips
        SliverToBoxAdapter(
          child: SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: ['All', 'Favorites', 'Recently Played', 'Pitch Tuned'].map((label) {
                final selected = _activeChip == label;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: (_) => setState(() => _activeChip = label),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    backgroundColor: cs.surfaceContainer,
                    selectedColor: cs.primaryContainer,
                    side: BorderSide.none,
                  ),
                );
              }).toList(),
            ),
          ),
        ),

        if (tracks.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.graphic_eq_rounded, size: 72, color: cs.primary),
                  const SizedBox(height: 16),
                  const Text('Your Library is Empty', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Tap below to pull songs from your phone storage.', style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: pickLocalFiles,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('Import Audio Files'),
                  ),
                ],
              ),
            ),
          )
        else ...[
          // Tidal / Spotify 2-Column Quick Grid
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Quick Mix',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: cs.onSurface),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      audioHandler.playIndex(0);
                      openPlayer(context);
                    },
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Play All'),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.7,
              ),
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final t = tracks[i];
                  return Squishy(
                    onTap: () {
                      audioHandler.playIndex(i);
                      openPlayer(context);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: cs.surfaceContainer,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white.withOpacity(0.06)),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Row(
                        children: [
                          AspectRatio(
                            aspectRatio: 1,
                            child: CustomAlbumArtwork(track: t),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  t.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  );
                },
                childCount: math.min(tracks.length, 6),
              ),
            ),
          ),

          // Expressive Song Cards List
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 26, 16, 8),
              child: Text(
                'Tracks',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: cs.onSurface),
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) {
                final t = tracks[i];
                final isPlaying = audioHandler.currentTrack?.id == t.id;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Squishy(
                    onTap: () {
                      audioHandler.playIndex(i);
                      openPlayer(context);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isPlaying ? cs.primaryContainer.withOpacity(0.3) : cs.surfaceContainer.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(18),
                        border: isPlaying ? Border.all(color: cs.primary.withOpacity(0.4)) : null,
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: SizedBox(
                              width: 52,
                              height: 52,
                              child: CustomAlbumArtwork(track: t),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15.5,
                                    color: isPlaying ? cs.primary : cs.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    if (isPlaying) ...[
                                      Icon(Icons.volume_up_rounded, size: 14, color: cs.primary),
                                      const SizedBox(width: 4),
                                    ],
                                    Expanded(
                                      child: Text(
                                        t.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.more_vert_rounded),
                            color: cs.onSurfaceVariant,
                            onPressed: () => showAddToPlaylistSheet(context, t),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
              childCount: tracks.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 180)),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Library Screen
// ─────────────────────────────────────────────────────────────────────────────

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});
  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  int _filter = 0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          expandedHeight: 120,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          title: const Text('Your Library', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 32)),
          actions: [
            Squishy(
              onTap: () async {
                final added = await quickImportDownloads();
                appNotice.value = added > 0 ? 'Imported $added tracks from Downloads!' : 'No new tracks in phone Downloads folder.';
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Icon(Icons.download_done_rounded, size: 18, color: cs.onPrimaryContainer),
                    const SizedBox(width: 6),
                    Text('Grab DLs', style: TextStyle(fontWeight: FontWeight.bold, color: cs.onPrimaryContainer, fontSize: 13)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Playlists'), icon: Icon(Icons.queue_music_rounded)),
                ButtonSegment(value: 1, label: Text('Artists'), icon: Icon(Icons.person_rounded)),
              ],
              selected: {_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: cs.primaryContainer,
                selectedForegroundColor: cs.onPrimaryContainer,
              ),
            ),
          ),
        ),
        if (_filter == 0) _buildPlaylists(cs) else _buildArtists(cs),
        const SliverToBoxAdapter(child: SizedBox(height: 180)),
      ],
    );
  }

  Widget _buildPlaylists(ColorScheme cs) {
    final pls = appState.playlists;
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (ctx, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Squishy(
                onTap: () => showCreatePlaylistDialog(context),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainer,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: cs.primary.withOpacity(0.4), style: BorderStyle.solid),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: cs.primary.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(Icons.add_rounded, size: 28, color: cs.primary),
                      ),
                      const SizedBox(width: 16),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Create New Playlist', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                            Text('Custom gallery cover & reorderable queue', style: TextStyle(color: Colors.grey, fontSize: 12.5)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          final pl = pls[i - 1];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Squishy(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlistId: pl.id)),
              ),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox(
                        width: 60,
                        height: 60,
                        child: pl.cover != null && File(pl.cover!).existsSync()
                            ? Image.file(File(pl.cover!), fit: BoxFit.cover)
                            : Container(
                                color: cs.primaryContainer,
                                child: Icon(Icons.queue_music_rounded, color: cs.onPrimaryContainer, size: 28),
                              ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(pl.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                          const SizedBox(height: 4),
                          Text('${pl.trackIds.length} tracks', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                  ],
                ),
              ),
            ),
          );
        },
        childCount: pls.length + 1,
      ),
    );
  }

  Widget _buildArtists(ColorScheme cs) {
    final map = <String, List<TrackItem>>{};
    for (final t in audioHandler.tracks) {
      map.putIfAbsent(t.artist, () => []).add(t);
    }
    final entries = map.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (ctx, i) {
          final e = entries[i];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Squishy(
              onTap: () => showArtistTracksSheet(context, e.key, e.value),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      child: ClipOval(
                        child: SizedBox(
                          width: 56,
                          height: 56,
                          child: CustomAlbumArtwork(track: e.value.first),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.key, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                          const SizedBox(height: 2),
                          Text('${e.value.length} tracks', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                  ],
                ),
              ),
            ),
          );
        },
        childCount: entries.length,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Expressive MiniPlayer
// ─────────────────────────────────────────────────────────────────────────────

class MiniPlayer extends StatelessWidget {
  final TrackItem track;
  const MiniPlayer({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Squishy(
      onTap: () => openPlayer(context),
      scale: 0.96,
      child: Container(
        height: 72,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.6),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: cs.primary.withOpacity(0.1),
              blurRadius: 10,
            ),
          ],
        ),
        child: Row(
          children: [
            // Circular Artwork with Progress Ring
            SizedBox(
              width: 52,
              height: 52,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  StreamBuilder<Duration?>(
                    stream: audioHandler.player.durationStream,
                    builder: (_, durSnap) {
                      final dur = durSnap.data ?? Duration(seconds: track.durationSeconds);
                      return StreamBuilder<Duration>(
                        stream: audioHandler.player.positionStream,
                        builder: (_, posSnap) {
                          final pos = posSnap.data ?? Duration.zero;
                          final frac = dur.inMilliseconds > 0 ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0) : 0.0;
                          return SizedBox(
                            width: 52,
                            height: 52,
                            child: CircularProgressIndicator(
                              value: frac,
                              strokeWidth: 3.2,
                              backgroundColor: Colors.white12,
                              valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                            ),
                          );
                        },
                      );
                    },
                  ),
                  Hero(
                    tag: 'now_playing_art',
                    child: ClipOval(
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: CustomAlbumArtwork(track: track),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15.5),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                appState.isLiked(track.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                color: appState.isLiked(track.id) ? cs.primary : cs.onSurfaceVariant,
              ),
              onPressed: () => appState.toggleLike(track.id),
            ),
            StreamBuilder<PlaybackState>(
              stream: audioHandler.playbackState,
              builder: (ctx, snap) {
                final playing = snap.data?.playing ?? false;
                return Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: cs.onPrimary),
                    onPressed: () => playing ? audioHandler.pause() : audioHandler.play(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Now Playing Screen (Tidal/Material You Powerhouse)
// ─────────────────────────────────────────────────────────────────────────────

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge([appState, audioHandler.currentIndex]),
      builder: (ctx, _) {
        final track = audioHandler.currentTrack;
        if (track == null) return const Scaffold();

        return Scaffold(
          body: Stack(
            children: [
              // Dynamic Ambient Glow
              Positioned(
                top: -100,
                left: -50,
                right: -50,
                height: 500,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.topCenter,
                      radius: 0.9,
                      colors: [
                        track.artColors.first.withOpacity(0.55),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),

              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      // Top App Bar Controls
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Squishy(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainer,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
                            ),
                          ),
                          Column(
                            children: [
                              Text(
                                'PLAYING FROM LIBRARY',
                                style: TextStyle(
                                  letterSpacing: 1.5,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 10.5,
                                  color: cs.primary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                track.album,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                          Squishy(
                            onTap: () => showAddToPlaylistSheet(context, track),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainer,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.more_vert_rounded, size: 22),
                            ),
                          ),
                        ],
                      ),

                      // Large Hero Interactive 3D / Vinyl Album Art
                      Expanded(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: Hero(
                                tag: 'now_playing_art',
                                child: InteractiveArtwork(track: track),
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Song Title & Artist + Like Button
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  track.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 17, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                          Squishy(
                            onTap: () => appState.toggleLike(track.id),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainer,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                appState.isLiked(track.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                color: appState.isLiked(track.id) ? cs.primary : cs.onSurfaceVariant,
                                size: 26,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      // Animated Wavy / Scrubbing Seekbar
                      WavySeekBar(track: track),
                      const SizedBox(height: 16),

                      // Transport Controls (Tidal/Material You Giant Play Button)
                      StreamBuilder<PlaybackState>(
                        stream: audioHandler.playbackState,
                        builder: (ctx, snap) {
                          final state = snap.data ?? audioHandler.playbackState.value;
                          final playing = state.playing;
                          final shuffle = state.shuffleMode == AudioServiceShuffleMode.all;
                          final repeat = state.repeatMode;

                          return Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                icon: Icon(shuffle ? Icons.shuffle_on_rounded : Icons.shuffle_rounded),
                                color: shuffle ? cs.primary : cs.onSurfaceVariant,
                                onPressed: () => audioHandler.setShuffleMode(
                                  shuffle ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all,
                                ),
                              ),
                              Squishy(
                                onTap: audioHandler.skipToPrevious,
                                child: Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: cs.surfaceContainer,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.skip_previous_rounded, size: 36),
                                ),
                              ),
                              Squishy(
                                onTap: () => playing ? audioHandler.pause() : audioHandler.play(),
                                scale: 0.9,
                                child: Container(
                                  width: 82,
                                  height: 82,
                                  decoration: BoxDecoration(
                                    color: cs.primary,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: cs.primary.withOpacity(0.4),
                                        blurRadius: 20,
                                        offset: const Offset(0, 6),
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                    size: 46,
                                    color: cs.onPrimary,
                                  ),
                                ),
                              ),
                              Squishy(
                                onTap: audioHandler.skipToNext,
                                child: Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: cs.surfaceContainer,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.skip_next_rounded, size: 36),
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  repeat == AudioServiceRepeatMode.one
                                      ? Icons.repeat_one_rounded
                                      : (repeat != AudioServiceRepeatMode.none ? Icons.repeat_on_rounded : Icons.repeat_rounded),
                                ),
                                color: repeat != AudioServiceRepeatMode.none ? cs.primary : cs.onSurfaceVariant,
                                onPressed: () {
                                  final next = switch (repeat) {
                                    AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
                                    AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
                                    _ => AudioServiceRepeatMode.none,
                                  };
                                  audioHandler.setRepeatMode(next);
                                },
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 24),

                      // Bottom Chips / Equalizer / Speed & Pitch Pill
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Squishy(
                            onTap: () => showPlaybackSheet(context),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              decoration: BoxDecoration(
                                color: (appState.speed != 1.0 || appState.pitch != 1.0) ? cs.primaryContainer : cs.surfaceContainer,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.tune_rounded,
                                    size: 18,
                                    color: (appState.speed != 1.0 || appState.pitch != 1.0) ? cs.onPrimaryContainer : cs.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${appState.speed.toStringAsFixed(2)}x Speed • ${appState.pitch.toStringAsFixed(2)}p',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 12.5,
                                      color: (appState.speed != 1.0 || appState.pitch != 1.0) ? cs.onPrimaryContainer : cs.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Squishy(
                            onTap: () => showEditTrackDialog(context, track),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainer,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.edit_rounded, size: 20),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Interactive 3D / Spinning Vinyl View
// ─────────────────────────────────────────────────────────────────────────────

class InteractiveArtwork extends StatefulWidget {
  final TrackItem track;
  const InteractiveArtwork({super.key, required this.track});

  @override
  State<InteractiveArtwork> createState() => _InteractiveArtworkState();
}

class _InteractiveArtworkState extends State<InteractiveArtwork> with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: const Duration(seconds: 14))..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spinMode = appState.vinylSpinMode;

    return StreamBuilder<bool>(
      stream: audioHandler.player.playingStream,
      builder: (_, snap) {
        final playing = snap.data ?? false;
        if (playing && !_spin.isAnimating && spinMode) {
          _spin.repeat();
        } else if (!playing && _spin.isAnimating) {
          _spin.stop();
        }

        return GestureDetector(
          onDoubleTap: () {
            HapticFeedback.mediumImpact();
            appState.setVinylSpinMode(!spinMode);
          },
          child: AnimatedBuilder(
            animation: _spin,
            builder: (ctx, child) {
              if (!spinMode) {
                return Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(32),
                    boxShadow: [
                      BoxShadow(
                        color: widget.track.artColors.first.withOpacity(0.4),
                        blurRadius: 32,
                        offset: const Offset(0, 16),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: CustomAlbumArtwork(track: widget.track),
                );
              }
              return Transform.rotate(
                angle: _spin.value * 2 * math.pi,
                child: ClipOval(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CustomAlbumArtwork(track: widget.track),
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.85),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 2),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Wavy Scrubbing Seekbar
// ─────────────────────────────────────────────────────────────────────────────

class WavySeekBar extends StatefulWidget {
  final TrackItem track;
  const WavySeekBar({super.key, required this.track});

  @override
  State<WavySeekBar> createState() => _WavySeekBarState();
}

class _WavySeekBarState extends State<WavySeekBar> with SingleTickerProviderStateMixin {
  double? _drag;
  late final AnimationController _wave;

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

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
            final frac = (currentMs / maxMs).clamp(0.0, 1.0);

            return Column(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (d) => setState(() => _drag = (d.localPosition.dx / context.size!.width).clamp(0.0, 1.0) * maxMs),
                  onHorizontalDragUpdate: (d) => setState(() => _drag = (d.localPosition.dx / context.size!.width).clamp(0.0, 1.0) * maxMs),
                  onHorizontalDragEnd: (_) {
                    if (_drag != null) {
                      audioHandler.seek(Duration(milliseconds: _drag!.toInt()));
                      setState(() => _drag = null);
                    }
                  },
                  onTapDown: (d) {
                    final target = (d.localPosition.dx / context.size!.width).clamp(0.0, 1.0) * maxMs;
                    audioHandler.seek(Duration(milliseconds: target.toInt()));
                  },
                  child: SizedBox(
                    height: 36,
                    child: AnimatedBuilder(
                      animation: _wave,
                      builder: (_, __) => CustomPaint(
                        painter: _WavePainter(
                          progress: frac,
                          phase: _wave.value * 2 * math.pi,
                          activeColor: cs.primary,
                          inactiveColor: Colors.white12,
                          waveAmplitude: audioHandler.player.playing ? 4.0 : 0.0,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(formatDuration(Duration(milliseconds: currentMs.toInt())), style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, fontWeight: FontWeight.bold)),
                      Text(formatDuration(dur), style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, fontWeight: FontWeight.bold)),
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

class _WavePainter extends CustomPainter {
  final double progress;
  final double phase;
  final Color activeColor;
  final Color inactiveColor;
  final double waveAmplitude;

  _WavePainter({
    required this.progress,
    required this.phase,
    required this.activeColor,
    required this.inactiveColor,
    required this.waveAmplitude,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final activeX = size.width * progress;

    if (activeX < size.width) {
      canvas.drawLine(
        Offset(activeX, cy),
        Offset(size.width, cy),
        Paint()..color = inactiveColor..strokeWidth = 4.0..strokeCap = StrokeCap.round,
      );
    }

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    final path = Path()..moveTo(0, cy);
    for (double x = 0; x <= activeX; x += 2.0) {
      path.lineTo(x, cy + math.sin((x / 24.0) * 2 * math.pi - phase) * waveAmplitude);
    }
    canvas.drawPath(path, activePaint);

    // Pill Thumb
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(activeX, cy), width: 10, height: 20), const Radius.circular(5)),
      Paint()..color = activeColor,
    );
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.progress != progress || old.phase != phase || old.waveAmplitude != waveAmplitude;
}

// ─────────────────────────────────────────────────────────────────────────────
// Playlists, Dialogs & Settings
// ─────────────────────────────────────────────────────────────────────────────

class PlaylistDetailScreen extends StatelessWidget {
  final String playlistId;
  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final pl = appState.playlistById(playlistId);
        if (pl == null) return const Scaffold();
        final tracks = pl.trackIds
            .map((id) => audioHandler.trackById(id))
            .whereType<TrackItem>()
            .toList();

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
              ? const Center(child: Text('Playlist is empty. Add tracks from the 3-dot menu!'))
              : ReorderableListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: tracks.length,
                  onReorder: (o, n) {
                    if (n > o) n -= 1;
                    appState.movePlaylistTrack(pl.id, o, n);
                  },
                  itemBuilder: (ctx, i) {
                    final t = tracks[i];
                    return ListTile(
                      key: ValueKey(t.id),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: t)),
                      ),
                      title: Text(t.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(t.artist),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline_rounded, color: Colors.redAccent),
                            onPressed: () => appState.removeFromPlaylist(pl.id, t.id),
                          ),
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

void showArtistTracksSheet(BuildContext context, String artist, List<TrackItem> tracks) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(artist, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          ),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              itemCount: tracks.length,
              itemBuilder: (_, i) => ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: tracks[i])),
                ),
                title: Text(tracks[i].title, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(tracks[i].album),
                onTap: () {
                  Navigator.pop(ctx);
                  audioHandler.playTrackById(tracks[i].id);
                  openPlayer(context);
                },
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

void showAddToPlaylistSheet(BuildContext context, TrackItem track) {
  final cs = Theme.of(context).colorScheme;

  showModalBottomSheet(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: track)),
              ),
              title: Text(track.title, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(track.artist),
              trailing: FilledButton.tonalIcon(
                onPressed: () => showCreatePlaylistDialog(context, initialTrackId: track.id),
                icon: const Icon(Icons.add),
                label: const Text('New'),
              ),
            ),
            const Divider(),
            if (appState.playlists.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Text('No playlists yet.'))
            else
              ...appState.playlists.map((pl) {
                final added = appState.inPlaylist(pl.id, track.id);
                return ListTile(
                  title: Text(pl.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('${pl.trackIds.length} songs'),
                  trailing: Icon(added ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded, color: added ? cs.primary : null),
                  onTap: () => appState.togglePlaylistTrack(pl.id, track.id),
                );
              }),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent),
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
        title: const Text('Create Playlist', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () async {
                final p = await pickAndSaveGalleryImage();
                if (p != null) setState(() => coverPath = p);
              },
              child: Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: coverPath != null
                    ? Image.file(File(coverPath!), fit: BoxFit.cover)
                    : const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [Icon(Icons.add_photo_alternate_rounded, size: 32), Text('Pick Icon', style: TextStyle(fontSize: 12))],
                      ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Playlist Name', border: OutlineInputBorder())),
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

void showEditTrackDialog(BuildContext context, TrackItem track) {
  final titleCtrl = TextEditingController(text: track.title);
  final artistCtrl = TextEditingController(text: track.artist);

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Edit Song Info', style: TextStyle(fontWeight: FontWeight.bold)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'Title')),
          const SizedBox(height: 12),
          TextField(controller: artistCtrl, decoration: const InputDecoration(labelText: 'Artist')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            track.title = titleCtrl.text.trim();
            track.artist = artistCtrl.text.trim();
            appState.saveEdit(track);
            audioHandler.refreshMediaItem();
            Navigator.pop(ctx);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

void showPlaybackSheet(BuildContext context) {
  final cs = Theme.of(context).colorScheme;

  showModalBottomSheet(
    context: context,
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
                  const Text('Speed & Pitch Shifter', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
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
                contentPadding: EdgeInsets.zero,
                title: const Text('Link Speed & Pitch (Turntable / Nightcore)'),
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
                  const SizedBox(width: 14),
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
                  Text('${appState.speed.toStringAsFixed(2)}x', style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              Row(
                children: [
                  const Icon(Icons.graphic_eq_rounded),
                  const SizedBox(width: 14),
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
                  Text('${appState.pitch.toStringAsFixed(2)}p', style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 10),
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

void showSettingsSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('AlexLMP Settings', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
            const SizedBox(height: 20),
            const Text('Material You Dynamic Color Seed', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                Colors.blue,
                Colors.redAccent,
                Colors.green,
                Colors.purple,
                Colors.orange,
                const Color(0xFFD0BCFF),
              ].map((c) => InkWell(
                onTap: () => appState.setSeedColor(c),
                child: CircleAvatar(
                  backgroundColor: c,
                  radius: 20,
                  child: appState.seedColor.value == c.value ? const Icon(Icons.check, color: Colors.white) : null,
                ),
              )).toList(),
            ),
            const SizedBox(height: 20),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Pure AMOLED Black (#000000)'),
              value: appState.useAmoled,
              onChanged: appState.setAmoled,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Spinning Vinyl Album Artwork'),
              value: appState.vinylSpinMode,
              onChanged: appState.setVinylSpinMode,
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () {
                Navigator.pop(ctx);
                scanDeviceAudio();
              },
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Rescan Device Storage'),
            ),
          ],
        ),
      ),
    ),
  );
}
