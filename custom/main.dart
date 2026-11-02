import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

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
// Globals
// ─────────────────────────────────────────────────────────────────────────────

late final MyAudioHandler audioHandler;
final AppState appState = AppState();
final ValueNotifier<String?> appNotice = ValueNotifier<String?>(null);
final ValueNotifier<bool> scanning = ValueNotifier<bool>(false);
const MethodChannel _mediaChannel = MethodChannel('com.alexlmp.app/media');
const MethodChannel _ytChannel = MethodChannel('com.alexlmp.app/ytmusic');

const List<String> kArtStyles = [
  'vinyl_record',
  'sound_wave',
  'music_note_grid',
  'equalizer_bars',
  'neon_vinyl',
];

class ColorStopSet {
  final List<Color> colors;
  const ColorStopSet(this.colors);
}

const List<ColorStopSet> kArtPalettes = [
  ColorStopSet([Color(0xFF3E1C0C), Color(0xFFD96B38), Color(0xFF1A0F0A)]),
  ColorStopSet([Color(0xFF42173B), Color(0xFFE0538A), Color(0xFF28193D)]),
  ColorStopSet([Color(0xFF062A4E), Color(0xFF1F7AE0), Color(0xFF0A2416)]),
  ColorStopSet([Color(0xFF1A3A2A), Color(0xFF9C27B0), Color(0xFF00BCD4)]),
  ColorStopSet([Color(0xFF4A1E0D), Color(0xFFE66833), Color(0xFF1B110E)]),
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
        androidNotificationChannelName: 'AlexLMP Music Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (_) {
    audioHandler = MyAudioHandler();
  }

  // Adaptive theme: follow the current song's album art colours.
  audioHandler.currentIndex.addListener(updateAdaptiveTheme);
  audioHandler.libraryRevision.addListener(updateAdaptiveTheme);
  appState.addListener(() {
    if (appState.isAdaptive) updateAdaptiveTheme();
  });

  // YouTube Music sign-in state (read-only library).
  unawaited(YouTubeMusic.refreshAccount());

  // Bring back liked / playlisted YouTube Music songs from last time.
  try {
    audioHandler.restoreTracks(appState.savedYouTubeTracks());
  } catch (_) {}

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
  final mins = (total ~/ 60).toString().padLeft(2, '0');
  final secs = (total % 60).toString().padLeft(2, '0');
  return '$mins:$secs';
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
// Palettes / AppState
// ─────────────────────────────────────────────────────────────────────────────

class AppPalette {
  final String name;
  final Color accent;
  final Color onAccent;
  final Color container;
  final Color bg;
  final Color surface;
  final Color playerBg;
  final Color playerSurface;
  final Color playerButton;
  final Color playerAccent;
  final Color playerOnAccent;

  const AppPalette({
    required this.name,
    required this.accent,
    required this.onAccent,
    required this.container,
    required this.bg,
    required this.surface,
    required this.playerBg,
    required this.playerSurface,
    required this.playerButton,
    required this.playerAccent,
    required this.playerOnAccent,
  });

  static const classicBlue = AppPalette(
    name: 'Classic Blue',
    accent: Color(0xFF8CD0F0),
    onAccent: Color(0xFF062938),
    container: Color(0xFF283740),
    bg: Color(0xFF111416),
    surface: Color(0xFF1C2124),
    playerBg: Color(0xFF141C24),
    playerSurface: Color(0xFF212D38),
    playerButton: Color(0xFF2C4254),
    playerAccent: Color(0xFF8CD0F0),
    playerOnAccent: Color(0xFF062938),
  );
  static const emerald = AppPalette(
    name: 'Emerald',
    accent: Color(0xFF9CF0C0),
    onAccent: Color(0xFF00391F),
    container: Color(0xFF22392D),
    bg: Color(0xFF0F1512),
    surface: Color(0xFF18211C),
    playerBg: Color(0xFF0E2014),
    playerSurface: Color(0xFF1F3527),
    playerButton: Color(0xFF2F5A40),
    playerAccent: Color(0xFF9CF0C0),
    playerOnAccent: Color(0xFF00391F),
  );
  static const sunsetPeach = AppPalette(
    name: 'Sunset Peach',
    accent: Color(0xFFFFB59C),
    onAccent: Color(0xFF4D1600),
    container: Color(0xFF3A2A23),
    bg: Color(0xFF151110),
    surface: Color(0xFF211A17),
    playerBg: Color(0xFF20130E),
    playerSurface: Color(0xFF362721),
    playerButton: Color(0xFF5D3A28),
    playerAccent: Color(0xFFFFB59C),
    playerOnAccent: Color(0xFF4D1600),
  );
  static const cyberpunk = AppPalette(
    name: 'Cyberpunk',
    accent: Color(0xFFF09CE2),
    onAccent: Color(0xFF3C0036),
    container: Color(0xFF3A2438),
    bg: Color(0xFF140F14),
    surface: Color(0xFF211820),
    playerBg: Color(0xFF200E20),
    playerSurface: Color(0xFF36213A),
    playerButton: Color(0xFF5A2A5A),
    playerAccent: Color(0xFFF09CE2),
    playerOnAccent: Color(0xFF3C0036),
  );
  static const amoled = AppPalette(
    name: 'AMOLED',
    accent: Color(0xFFD0BCFF),
    onAccent: Color(0xFF261059),
    container: Color(0xFF171520),
    bg: Color(0xFF000000),
    surface: Color(0xFF0A0A0E),
    playerBg: Color(0xFF000000),
    playerSurface: Color(0xFF121118),
    playerButton: Color(0xFF242038),
    playerAccent: Color(0xFFD0BCFF),
    playerOnAccent: Color(0xFF261059),
  );

  /// Builds a full dark palette from one seed colour (used for the extra
  /// themes and the Adaptive album-art theme).
  static AppPalette fromSeed(String name, Color seed, {double vivid = 1.0}) {
    final hsl = HSLColor.fromColor(seed);
    final h = hsl.hue;
    final sat =
        (hsl.saturation.clamp(0.45, 1.0) * vivid).clamp(0.0, 1.0).toDouble();
    Color c(double s, double l) =>
        HSLColor.fromAHSL(
            1, h, s.clamp(0.0, 1.0).toDouble(), l.clamp(0.0, 1.0).toDouble())
            .toColor();
    return AppPalette(
      name: name,
      accent: c(sat * 0.95, 0.74),
      onAccent: c(sat, 0.14),
      container: c(sat * 0.45, 0.20),
      bg: c(sat * 0.45, 0.065),
      surface: c(sat * 0.40, 0.11),
      playerBg: c(sat * 0.55, 0.08),
      playerSurface: c(sat * 0.45, 0.16),
      playerButton: c(sat * 0.50, 0.26),
      playerAccent: c(sat * 0.95, 0.74),
      playerOnAccent: c(sat, 0.14),
    );
  }

  static final List<AppPalette> extra = [
    fromSeed('Ocean', const Color(0xFF2E9BFF)),
    fromSeed('Teal', const Color(0xFF2EE6C8)),
    fromSeed('Lime', const Color(0xFF9BE15D)),
    fromSeed('Sunflower', const Color(0xFFFFC94D)),
    fromSeed('Tangerine', const Color(0xFFFF8A3D)),
    fromSeed('Crimson', const Color(0xFFFF4D5E)),
    fromSeed('Rose', const Color(0xFFFF6FAE)),
    fromSeed('Lavender', const Color(0xFFB79CFF)),
  ];

  static final List<AppPalette> all = [
    classicBlue,
    emerald,
    sunsetPeach,
    cyberpunk,
    amoled,
    ...extra,
  ];

  /// Special theme name: colours follow the current song's album art.
  static const adaptiveName = 'Adaptive';

  static AppPalette byName(String name) =>
      all.firstWhere((p) => p.name == name, orElse: () => classicBlue);
}

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
        trackIds: List<String>.from(j['tracks'] as List? ?? const []),
      );
}

class AppState extends ChangeNotifier {
  SharedPreferences? _prefs;
  String themeName = 'AMOLED';
  bool liquidGlass = false;
  bool vinylSpinMode = false;
  bool stopOnTaskClear = true;
  bool linkSpeedAndPitch = false;
  bool swipeRightForNext = true;
  bool animatedBackground = true;
  bool artBackdrop = true;
  AppPalette? _adaptivePalette;
  Color? _adaptiveSeed;
  double speed = 1.0;
  double pitch = 1.0;
  String playlistName = 'Your AlexLMP Mixes';
  String playlistStyle = 'equalizer_bars';
  final Set<String> liked = {};
  final Set<String> deletedIds = {};
  Map<String, dynamic> _edits = {};
  final List<Playlist> playlists = [];
  // YouTube Music songs the user liked or put in a playlist, keyed by track id.
  // Stored so they survive restarts (the library itself is rebuilt from the device).
  final Map<String, Map<String, dynamic>> _ytSaved = {};

  AppPalette get palette => themeName == AppPalette.adaptiveName
      ? (_adaptivePalette ?? AppPalette.amoled)
      : AppPalette.byName(themeName);

  bool get isAdaptive => themeName == AppPalette.adaptiveName;

  void refresh() => notifyListeners();

  void setAdaptiveSeed(Color seed) {
    if (_adaptiveSeed == seed) return;
    _adaptiveSeed = seed;
    _adaptivePalette = AppPalette.fromSeed(AppPalette.adaptiveName, seed);
    if (isAdaptive) notifyListeners();
  }

  void setSwipeRightForNext(bool v) {
    swipeRightForNext = v;
    _prefs?.setBool('swipe_right_next', v);
    notifyListeners();
  }

  void setAnimatedBackground(bool v) {
    animatedBackground = v;
    _prefs?.setBool('animated_bg', v);
    notifyListeners();
  }

  void setArtBackdrop(bool v) {
    artBackdrop = v;
    _prefs?.setBool('art_backdrop', v);
    notifyListeners();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    themeName = prefs.getString('theme_name') ?? themeName;
    liquidGlass = prefs.getBool('liquid_glass_beta') ?? false;
    vinylSpinMode = prefs.getBool('vinyl_spin_mode') ?? false;
    stopOnTaskClear = prefs.getBool('stop_on_task_clear') ?? true;
    linkSpeedAndPitch = prefs.getBool('link_speed_pitch') ?? false;
    swipeRightForNext = prefs.getBool('swipe_right_next') ?? true;
    animatedBackground = prefs.getBool('animated_bg') ?? true;
    artBackdrop = prefs.getBool('art_backdrop') ?? true;
    speed = prefs.getDouble('playback_speed') ?? 1.0;
    pitch = prefs.getDouble('playback_pitch') ?? 1.0;
    playlistName = prefs.getString('playlist_name') ?? playlistName;
    playlistStyle = prefs.getString('playlist_style') ?? playlistStyle;
    liked.addAll(prefs.getStringList('liked_ids') ?? const []);
    deletedIds.addAll(prefs.getStringList('deleted_ids') ?? const []);
    try {
      final raw = jsonDecode(prefs.getString('playlists') ?? '[]') as List;
      playlists
        ..clear()
        ..addAll(
          raw.map((e) => Playlist.fromJson(Map<String, dynamic>.from(e as Map))),
        );
    } catch (_) {
      playlists.clear();
    }
    try {
      _edits = Map<String, dynamic>.from(
        jsonDecode(prefs.getString('track_edits') ?? '{}') as Map,
      );
    } catch (_) {
      _edits = {};
    }
    try {
      final raw = jsonDecode(prefs.getString('yt_tracks') ?? '{}') as Map;
      _ytSaved.clear();
      raw.forEach((k, v) {
        if (v is Map) _ytSaved[k as String] = Map<String, dynamic>.from(v);
      });
      _pruneYt();
    } catch (_) {
      _ytSaved.clear();
    }
    notifyListeners();
  }

  bool _ytStillNeeded(String id) =>
      liked.contains(id) || playlists.any((pl) => pl.trackIds.contains(id));

  void _pruneYt() {
    final before = _ytSaved.length;
    _ytSaved.removeWhere((id, _) => !_ytStillNeeded(id) || deletedIds.contains(id));
    if (_ytSaved.length != before) _saveYt();
  }

  void _saveYt() {
    _prefs?.setString('yt_tracks', jsonEncode(_ytSaved));
  }

  /// Remember a YouTube Music song's details once it's liked or playlisted.
  void _rememberIfYt(String id) {
    if (!id.startsWith('yt_')) return;
    final t = audioHandler.trackById(id);
    if (t == null || !t.isYouTube) return;
    _ytSaved[id] = t.toYtJson();
    _saveYt();
  }

  void _forgetYtIfUnused(String id) {
    if (!_ytSaved.containsKey(id) || _ytStillNeeded(id)) return;
    _ytSaved.remove(id);
    _saveYt();
  }

  /// Saved YouTube Music songs, rebuilt as tracks for the library on startup.
  List<TrackItem> savedYouTubeTracks() {
    final out = <TrackItem>[];
    var i = 0;
    for (final m in _ytSaved.values) {
      final t = TrackItem.fromYtJson(m, i++);
      if (t == null) continue;
      applyEdits(t);
      out.add(t);
    }
    return out;
  }

  bool isDeleted(String id, [String? path]) {
    if (deletedIds.contains(id)) return true;
    if (path != null && path.isNotEmpty && deletedIds.contains(path)) {
      return true;
    }
    return false;
  }

  void markDeleted(TrackItem t) {
    deletedIds.add(t.id);
    if (_ytSaved.remove(t.id) != null) _saveYt();
    if (t.filePath != null && t.filePath!.isNotEmpty) {
      deletedIds.add(t.filePath!);
    }
    if (t.source.isNotEmpty) {
      deletedIds.add(t.source);
    }
    _prefs?.setStringList('deleted_ids', deletedIds.toList());
    liked.remove(t.id);
    _prefs?.setStringList('liked_ids', liked.toList());
    for (final pl in playlists) {
      pl.trackIds.remove(t.id);
    }
    _savePlaylists();
  }

  void unmarkDeleted(String id, [String? path]) {
    deletedIds.remove(id);
    if (path != null) deletedIds.remove(path);
    _prefs?.setStringList('deleted_ids', deletedIds.toList());
  }

  void setTheme(String name) {
    themeName = name;
    _prefs?.setString('theme_name', name);
    notifyListeners();
  }

  void setLiquidGlass(bool v) {
    liquidGlass = v;
    _prefs?.setBool('liquid_glass_beta', v);
    notifyListeners();
  }

  void setVinylSpinMode(bool v) {
    vinylSpinMode = v;
    _prefs?.setBool('vinyl_spin_mode', v);
    notifyListeners();
  }

  void setStopOnTaskClear(bool v) {
    stopOnTaskClear = v;
    _prefs?.setBool('stop_on_task_clear', v);
    notifyListeners();
  }

  void setLinkSpeedAndPitch(bool v) {
    linkSpeedAndPitch = v;
    _prefs?.setBool('link_speed_pitch', v);
    notifyListeners();
  }

  void setPlaylist(String name, String style) {
    playlistName = name;
    playlistStyle = style;
    _prefs?.setString('playlist_name', name);
    _prefs?.setString('playlist_style', style);
    notifyListeners();
  }

  void setSpeed(double v) {
    speed = v.clamp(0.5, 2.0);
    _prefs?.setDouble('playback_speed', speed);
    notifyListeners();
  }

  void setPitch(double v) {
    pitch = v.clamp(0.5, 2.0);
    _prefs?.setDouble('playback_pitch', pitch);
    notifyListeners();
  }

  bool isLiked(String id) => liked.contains(id);

  void toggleLike(String id) {
    if (!liked.remove(id)) {
      liked.add(id);
      _rememberIfYt(id);
    } else {
      _forgetYtIfUnused(id);
    }
    _prefs?.setStringList('liked_ids', liked.toList());
    notifyListeners();
  }

  Playlist? playlistById(String id) {
    for (final pl in playlists) {
      if (pl.id == id) return pl;
    }
    return null;
  }

  void _savePlaylists() {
    _prefs?.setString(
      'playlists',
      jsonEncode(playlists.map((pl) => pl.toJson()).toList()),
    );
    notifyListeners();
  }

  Playlist createPlaylist(String name, {String? cover}) {
    final pl = Playlist(
      id: 'pl_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'New Playlist' : name.trim(),
      cover: cover,
    );
    playlists.add(pl);
    _savePlaylists();
    return pl;
  }

  void setPlaylistInfo(String id, String name, String? cover) {
    final pl = playlistById(id);
    if (pl == null) return;
    pl.name = name.trim().isEmpty ? pl.name : name.trim();
    pl.cover = cover;
    _savePlaylists();
  }

  void deletePlaylist(String id) {
    playlists.removeWhere((pl) => pl.id == id);
    _pruneYt();
    _savePlaylists();
  }

  bool inPlaylist(String pid, String tid) =>
      playlistById(pid)?.trackIds.contains(tid) ?? false;

  void togglePlaylistTrack(String pid, String tid) {
    final pl = playlistById(pid);
    if (pl == null) return;
    if (!pl.trackIds.remove(tid)) {
      pl.trackIds.add(tid);
      _rememberIfYt(tid);
    } else {
      _forgetYtIfUnused(tid);
    }
    _savePlaylists();
  }

  void addToPlaylist(String pid, String tid) {
    final pl = playlistById(pid);
    if (pl == null || pl.trackIds.contains(tid)) return;
    pl.trackIds.add(tid);
    _rememberIfYt(tid);
    _savePlaylists();
  }

  void removeFromPlaylist(String pid, String tid) {
    final pl = playlistById(pid);
    if (pl == null) return;
    pl.trackIds.remove(tid);
    _forgetYtIfUnused(tid);
    _savePlaylists();
  }

  void movePlaylistTrack(String pid, int from, int to) {
    final pl = playlistById(pid);
    if (pl == null || from < 0 || from >= pl.trackIds.length) return;
    final id = pl.trackIds.removeAt(from);
    pl.trackIds.insert(to.clamp(0, pl.trackIds.length), id);
    _savePlaylists();
  }

  void applyEdits(TrackItem t) {
    final e = _edits[t.id];
    if (e is Map) {
      t.title = (e['title'] as String?) ?? t.title;
      t.artist = (e['artist'] as String?) ?? t.artist;
      t.artStyle = (e['style'] as String?) ?? t.artStyle;
    }
  }

  void saveEdit(TrackItem t) {
    _edits[t.id] = {'title': t.title, 'artist': t.artist, 'style': t.artStyle};
    _prefs?.setString('track_edits', jsonEncode(_edits));
    notifyListeners();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

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
  final String? ytVideoId;
  final String? artworkUrl;

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
    this.ytVideoId,
    this.artworkUrl,
  });

  bool get isYouTube => ytVideoId != null;

  Map<String, dynamic> toYtJson() => {
        'videoId': ytVideoId,
        'title': title,
        'artist': artist,
        'album': album,
        'durationSeconds': durationSeconds,
        'thumbnail': artworkUrl,
      };

  static TrackItem? fromYtJson(Map<String, dynamic> m, int i) {
    final videoId = (m['videoId'] ?? '').toString();
    if (videoId.isEmpty) return null;
    return TrackItem(
      id: 'yt_$videoId',
      title: cleanText(m['title'], 'Unknown Track'),
      artist: cleanText(m['artist'], 'Unknown Artist'),
      album: cleanText(m['album'], 'YouTube Music'),
      durationSeconds: (m['durationSeconds'] as num?)?.toInt() ?? 0,
      artColors: kArtPalettes[i % kArtPalettes.length].colors,
      artStyle: kArtStyles[i % kArtStyles.length],
      source: 'https://music.youtube.com/watch?v=$videoId',
      ytVideoId: videoId,
      artworkUrl: m['thumbnail'] as String?,
    );
  }

  Uri get playbackUri {
    final fp = filePath;
    if (fp != null && fp.isNotEmpty) {
      try {
        if (File(fp).existsSync()) {
          return Uri.file(fp);
        }
      } catch (_) {}
    }
    return source.startsWith('content://')
        ? Uri.parse(source)
        : Uri.file(source);
  }

  MediaItem toMediaItem() {
    return MediaItem(
      id: id,
      title: title,
      artist: artist,
      album: album,
      duration: durationSeconds > 0 ? Duration(seconds: durationSeconds) : null,
      artUri: artworkUrl != null ? Uri.tryParse(artworkUrl!) : null,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Audio handler (NO error snackbars!)
// ─────────────────────────────────────────────────────────────────────────────

class MyAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player = AudioPlayer(
    handleInterruptions: true,
    androidApplyAudioAttributes: true,
    handleAudioSessionActivation: true,
  );
  final Random _rng = Random();

  List<TrackItem> tracks = [];
  int _index = 0;
  int _loadSeq = 0;
  String? _loadedId;
  bool _shuffle = false;
  AudioServiceRepeatMode _repeat = AudioServiceRepeatMode.none;
  final List<int> _history = [];

  // YouTube Music stream recovery state
  bool _ytRecovering = false;
  String? _ytRecoverId;
  int _ytRecoverCount = 0;
  Duration _lastGoodPosition = Duration.zero;
  // Last position seen while actually playing (not counting the jump that
  // can happen when the player reports "completed").
  Duration _readyPosition = Duration.zero;
  String? _endRecoverId;
  int _endRecoverCount = 0;

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

  List<TrackItem> get likedTracks =>
      tracks.where((t) => appState.isLiked(t.id)).toList();

  Future<void> _init() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {}

    try {
      await player.setSkipSilenceEnabled(false);
    } catch (_) {}

    player.playbackEventStream.map(_transformEvent).listen(
      playbackState.add,
      onError: (Object _, StackTrace __) {
        _recoverYouTubeStream();
      },
    );

    player.positionStream.listen((p) {
      if (p > Duration.zero) _lastGoodPosition = p;
      if (player.processingState == ProcessingState.ready && p > Duration.zero) {
        _readyPosition = p;
      }
    });

    player.processingStateStream.listen((state) {
      if (state == ProcessingState.ready) {
        _applySpeedAndPitch();
      } else if (state == ProcessingState.completed) {
        if (_isPrematureYouTubeEnd()) {
          _resumeAfterPrematureEnd();
        } else {
          _onCompleted();
        }
      }
    });

    player.playingStream.listen((isPlaying) {
      if (isPlaying) {
        _applySpeedAndPitch();
      }
      _setKeepAwake(isPlaying);
    });

    player.durationStream.listen((d) {
      final item = mediaItem.value;
      if (d != null && item != null && d != item.duration) {
        mediaItem.add(item.copyWith(duration: d));
      }
    });
  }

  bool? _keepAwake;

  /// Holds a CPU wake lock + Wi-Fi lock while playing, so streaming (and loading
  /// the next song) keeps working with the app in the background / screen off.
  void _setKeepAwake(bool on) {
    if (_keepAwake == on || !Platform.isAndroid) return;
    _keepAwake = on;
    _ytChannel.invokeMethod('setKeepAwake', {'on': on}).catchError((_) {});
  }

  Future<void> _applySpeedAndPitch() async {
    final targetSpeed = appState.speed.clamp(0.5, 2.0);
    final targetPitch = appState.pitch.clamp(0.5, 2.0);
    try {
      if ((player.speed - targetSpeed).abs() > 0.005) {
        await player.setSpeed(targetSpeed);
      }
    } catch (_) {}
    try {
      await player.setPitch(targetPitch);
    } catch (_) {}
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
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
      shuffleMode: _shuffle
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      repeatMode: _repeat,
    );
  }

  void _publishQueue() {
    queue.add(tracks.map((t) => t.toMediaItem()).toList());
    libraryRevision.value++;
  }

  Future<void> setTracks(List<TrackItem> list) async {
    final currentId = currentTrack?.id;
    tracks = list;
    _publishQueue();
    if (list.isEmpty) return;
    final keep =
        currentId == null ? -1 : list.indexWhere((t) => t.id == currentId);
    if (keep >= 0) {
      _index = keep;
      currentIndex.value = keep;
      return;
    }
    await _load(0, play: false);
  }

  Future<void> addTracks(List<TrackItem> items, {bool playFirst = false}) async {
    final wasEmpty = tracks.isEmpty;
    tracks = [...items, ...tracks];
    if (!wasEmpty) {
      _index += items.length;
      currentIndex.value = _index;
    }
    _publishQueue();
    if (wasEmpty || playFirst) await _load(0, play: true);
  }

  Future<void> deleteTrackFromLibrary(TrackItem t) async {
    final removeIdx = tracks.indexWhere((x) => x.id == t.id);
    final wasCurrent = currentTrack?.id == t.id;

    appState.markDeleted(t);

    final fp = t.filePath ?? (t.source.startsWith('/') ? t.source : null);
    if (fp != null && fp.isNotEmpty) {
      try {
        final f = File(fp);
        if (f.existsSync()) {
          f.deleteSync();
        }
      } catch (_) {}
    }

    if (removeIdx >= 0) {
      final wasPlaying = player.playing;
      tracks.removeAt(removeIdx);
      if (tracks.isEmpty) {
        _index = 0;
        _loadedId = null;
        currentIndex.value = 0;
        await player.stop();
        mediaItem.add(null);
      } else if (wasCurrent) {
        if (_index >= tracks.length) _index = 0;
        currentIndex.value = _index;
        await _load(_index, play: wasPlaying);
      } else {
        if (removeIdx < _index) {
          _index = max(0, _index - 1);
          currentIndex.value = _index;
        }
      }
      _publishQueue();
    }
  }

  void moveTrack(int oldIndex, int newIndex) {
    final item = tracks.removeAt(oldIndex);
    tracks.insert(newIndex, item);
    if (_index == oldIndex) {
      _index = newIndex;
    } else if (oldIndex < _index && newIndex >= _index) {
      _index--;
    } else if (oldIndex > _index && newIndex <= _index) {
      _index++;
    }
    currentIndex.value = _index;
    _publishQueue();
  }

  void refreshMediaItem() {
    final t = currentTrack;
    if (t != null) {
      mediaItem.add(t.toMediaItem().copyWith(duration: player.duration));
    }
    _publishQueue();
  }

  Future<void> _load(int i, {bool play = true}) async {
    if (i < 0 || i >= tracks.length) return;
    final seq = ++_loadSeq;
    _index = i;
    currentIndex.value = i;
    final t = tracks[i];
    mediaItem.add(t.toMediaItem());
    _lastGoodPosition = Duration.zero;
    _readyPosition = Duration.zero;
    _ytRecoverId = null;
    _ytRecoverCount = 0;
    _endRecoverId = null;
    _endRecoverCount = 0;
    try {
      if (t.isYouTube) {
        await _setYouTubeSource(t, seq);
        if (seq != _loadSeq) return;
      } else {
        try {
          await player.setAudioSource(AudioSource.uri(t.playbackUri));
        } catch (_) {
          final fallbackUri = t.source.startsWith('content://')
              ? Uri.parse(t.source)
              : Uri.file(t.source);
          await player.setAudioSource(AudioSource.uri(fallbackUri));
        }
      }
      if (seq != _loadSeq) return;
      _loadedId = t.id;
      await _applySpeedAndPitch();
      if (play) {
        player.play();
      }
      _prefetchNextYouTube();
    } catch (e) {
      if (seq != _loadSeq) return;
      _loadedId = null;
      if (t.isYouTube && play) {
        final detail = e is PlatformException ? (e.message ?? e.code) : '$e';
        appNotice.value =
            'Couldn\'t load "${t.title}" from YouTube Music. ($detail)';
      }
    }
  }

  /// Resolves the song through the native bridge and loads it. If the first
  /// attempt fails (stale/expired stream), it re-resolves once and tries again.
  Future<void> _setYouTubeSource(TrackItem t, int seq) async {
    final id = t.ytVideoId!;
    try {
      final uri = await YouTubeMusic.prepare(id);
      if (seq != _loadSeq) return;
      await player.setAudioSource(AudioSource.uri(uri, tag: t.id));
    } catch (e) {
      if (seq != _loadSeq || e is PlayerInterruptedException) rethrow;
      final uri = await YouTubeMusic.prepare(id, refresh: true);
      if (seq != _loadSeq) return;
      await player.setAudioSource(AudioSource.uri(uri, tag: t.id));
    }
  }

  /// Called when just_audio reports a playback error. For YouTube Music
  /// tracks, fetch a fresh stream and resume from where it stopped.
  Future<void> _recoverYouTubeStream() async {
    final t = currentTrack;
    if (t == null || !t.isYouTube || _ytRecovering) return;
    if (_loadedId != t.id) return; // still loading — _load handles its own errors
    if (_ytRecoverId != t.id) {
      _ytRecoverId = t.id;
      _ytRecoverCount = 0;
    }
    if (_ytRecoverCount >= 3) {
      appNotice.value = 'Playback of "${t.title}" was interrupted.';
      return;
    }
    _ytRecoverCount++;
    _ytRecovering = true;
    final seq = _loadSeq;
    final resumeAt = player.position > _lastGoodPosition
        ? player.position
        : _lastGoodPosition;
    try {
      final uri = await YouTubeMusic.prepare(t.ytVideoId!, refresh: true);
      if (seq != _loadSeq) return;
      await player.setAudioSource(
        AudioSource.uri(uri, tag: t.id),
        initialPosition: resumeAt,
      );
      if (seq != _loadSeq) return;
      await _applySpeedAndPitch();
      player.play();
    } catch (_) {
    } finally {
      _ytRecovering = false;
    }
  }

  /// True when a YouTube song "finished" noticeably before its real length —
  /// i.e. the stream got cut off near the end rather than actually ending.
  bool _isPrematureYouTubeEnd() {
    final t = currentTrack;
    if (t == null || !t.isYouTube || _loadedId != t.id) return false;
    final dur = player.duration;
    if (dur == null || dur.inSeconds < 20) return false;
    if (_endRecoverId != t.id) {
      _endRecoverId = t.id;
      _endRecoverCount = 0;
    }
    if (_endRecoverCount >= 3) return false; // give up: move on normally
    return _readyPosition < dur - const Duration(seconds: 3);
  }

  /// Reloads the song with a fresh stream and continues from where it cut off.
  Future<void> _resumeAfterPrematureEnd() async {
    final t = currentTrack;
    if (t == null) return;
    _endRecoverCount++;
    final seq = _loadSeq;
    final resumeAt = _readyPosition;
    try {
      final uri = await YouTubeMusic.prepare(t.ytVideoId!, refresh: true);
      if (seq != _loadSeq) return;
      await player.setAudioSource(
        AudioSource.uri(uri, tag: t.id),
        initialPosition: resumeAt,
      );
      if (seq != _loadSeq) return;
      await _applySpeedAndPitch();
      player.play();
    } catch (_) {
      // Couldn't recover: behave like a normal song end.
      if (seq == _loadSeq) _onCompleted();
    }
  }

  /// Warm up the next YouTube Music track so skipping to it starts quickly.
  void _prefetchNextYouTube() {
    if (_shuffle) return;
    final n = _index + 1;
    if (n < tracks.length && tracks[n].isYouTube) {
      unawaited(
        YouTubeMusic.prepare(tracks[n].ytVideoId!).then((_) {}, onError: (_) {}),
      );
    }
  }

  /// Plays a YouTube Music result. If it's already in the queue it just
  /// plays it; otherwise it's added to the front of the queue.
  Future<void> playYouTubeTrack(TrackItem t) async {
    appState.unmarkDeleted(t.id, t.source);
    final existing = tracks.indexWhere((x) => x.id == t.id);
    if (existing >= 0) {
      await playIndex(existing);
    } else {
      await addTracks([t], playFirst: true);
    }
  }

  /// Plays a list of YouTube Music songs (an album or an artist's top songs)
  /// as the queue, starting at [start]. The rest of the library follows it.
  Future<void> playYouTubeList(List<TrackItem> list, int start) async {
    if (list.isEmpty) return;
    final merged = <TrackItem>[];
    final ids = <String>{};
    for (final t in list) {
      if (!ids.add(t.id)) continue;
      appState.unmarkDeleted(t.id, t.source);
      merged.add(trackById(t.id) ?? t);
    }
    final rest = tracks.where((t) => !ids.contains(t.id)).toList();
    tracks = [...merged, ...rest];
    _history.clear();
    _publishQueue();
    await _load(start.clamp(0, merged.length - 1), play: true);
  }

  /// Makes sure a YouTube Music song is in the library (without playing it),
  /// e.g. before adding it to a playlist from search.
  TrackItem ensureInLibrary(TrackItem t) {
    final existing = trackById(t.id);
    if (existing != null) return existing;
    appState.unmarkDeleted(t.id, t.source);
    tracks = [...tracks, t];
    _publishQueue();
    return t;
  }

  /// Adds saved YouTube Music songs to the library at startup. Doesn't load
  /// or play anything.
  void restoreTracks(List<TrackItem> list) {
    final have = tracks.map((t) => t.id).toSet();
    final add = list.where((t) => !have.contains(t.id)).toList();
    if (add.isEmpty) return;
    tracks = [...tracks, ...add];
    _publishQueue();
  }

  Future<void> playIndex(int i) async {
    if (i < 0 || i >= tracks.length) return;
    if (i == _index &&
        _loadedId == tracks[i].id &&
        player.processingState != ProcessingState.idle) {
      await _applySpeedAndPitch();
      player.play();
      return;
    }
    await _load(i, play: true);
  }

  Future<void> playTrackById(String id) async {
    final idx = tracks.indexWhere((t) => t.id == id);
    if (idx >= 0) await playIndex(idx);
  }

  int? _nextIndex({required bool auto}) {
    if (tracks.isEmpty) return null;
    if (_shuffle && tracks.length > 1) {
      int n;
      do {
        n = _rng.nextInt(tracks.length);
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
      _history.add(_index);
      await _load(n, play: true);
    }
  }

  @override
  Future<void> play() async {
    if (tracks.isEmpty) return;
    if (_loadedId == null) {
      await _load(_index, play: true);
    } else {
      await _applySpeedAndPitch();
      player.play();
    }
  }

  @override
  Future<void> pause() async {
    await player.pause();
  }

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() async {
    final n = _nextIndex(auto: false);
    if (n == null) return;
    _history.add(_index);
    if (_history.length > 50) _history.removeAt(0);
    await _load(n, play: true);
  }

  @override
  Future<void> skipToPrevious() async {
    if (tracks.isEmpty) return;
    if (player.position.inSeconds > 3) {
      await player.seek(Duration.zero);
      return;
    }
    int prev;
    if (_shuffle && _history.isNotEmpty) {
      prev = _history.removeLast();
    } else {
      prev = (_index - 1 + tracks.length) % tracks.length;
    }
    await _load(prev, play: true);
  }

  /// The song a "next" swipe would play, or null if unknown (shuffle) / none.
  TrackItem? get peekNext {
    if (tracks.length < 2 || _shuffle) return null;
    final n = _index + 1;
    if (n < tracks.length) return tracks[n];
    return tracks[0];
  }

  /// The song a "previous" swipe would play, or null if unknown / none.
  TrackItem? get peekPrevious {
    if (tracks.length < 2) return null;
    if (_shuffle) {
      return _history.isNotEmpty && _history.last < tracks.length
          ? tracks[_history.last]
          : null;
    }
    return tracks[(_index - 1 + tracks.length) % tracks.length];
  }

  /// Like skipToPrevious, but always goes to the previous song (never just
  /// restarts the current one). Used by the swipe carousel.
  Future<void> skipToPreviousTrack() async {
    if (tracks.isEmpty) return;
    int prev;
    if (_shuffle && _history.isNotEmpty) {
      prev = _history.removeLast();
    } else {
      prev = (_index - 1 + tracks.length) % tracks.length;
    }
    await _load(prev, play: true);
  }

  @override
  Future<void> skipToQueueItem(int i) => playIndex(i);

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    if (appState.stopOnTaskClear) await stop();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _shuffle = shuffleMode == AudioServiceShuffleMode.all;
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _repeat = repeatMode;
    await player.setLoopMode(
      repeatMode == AudioServiceRepeatMode.one ? LoopMode.one : LoopMode.off,
    );
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
  }

  @override
  Future<void> setSpeed(double speed) async {
    final clamped = speed.clamp(0.5, 2.0);
    try {
      await player.setSpeed(clamped);
    } catch (_) {}
    playbackState.add(playbackState.value.copyWith(speed: clamped));
  }

  Future<void> setPitch(double pitch) async {
    final clamped = pitch.clamp(0.5, 2.0);
    try {
      await player.setPitch(clamped);
    } catch (_) {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Library scanning / importing
// ─────────────────────────────────────────────────────────────────────────────

Future<bool> ensureMediaPermissions() async {
  var status = await Permission.audio.request();
  if (!status.isGranted) {
    status = await Permission.storage.request();
  }
  await Permission.notification.request();
  return status.isGranted;
}

Future<void> scanDeviceAudio() async {
  if (!Platform.isAndroid || scanning.value) return;
  scanning.value = true;
  try {
    final granted = await ensureMediaPermissions();
    if (!granted) {
      return;
    }
    final raw =
        await _mediaChannel.invokeMethod('scanDeviceAudio') as List? ??
            const [];
    final scanned = <TrackItem>[];
    for (var i = 0; i < raw.length; i++) {
      final m = Map<String, dynamic>.from(raw[i] as Map);
      final uri = (m['uri'] ?? '').toString();
      final path = (m['filePath'] ?? '').toString();
      final source = uri.isNotEmpty ? uri : path;
      if (source.isEmpty) continue;
      final id = 'ms_${m['id']}';
      if (appState.isDeleted(id, path.isEmpty ? source : path)) continue;
      final title = cleanText(m['title'], 'Unknown Track');
      if (title.toLowerCase().contains('306 bobby')) continue;
      final t = TrackItem(
        id: id,
        title: title,
        artist: cleanText(m['artist'], 'Unknown Artist'),
        album: cleanText(m['album'], 'Local Album'),
        durationSeconds: (m['durationSeconds'] as num?)?.toInt() ?? 0,
        artColors: kArtPalettes[i % kArtPalettes.length].colors,
        artStyle: kArtStyles[i % kArtStyles.length],
        source: source,
        filePath: path.isEmpty ? null : path,
      );
      appState.applyEdits(t);
      scanned.add(t);
    }
    final imported = audioHandler.tracks
        .where((t) =>
            (t.id.startsWith('local_') || t.id.startsWith('yt_')) &&
            !appState.isDeleted(t.id, t.filePath ?? t.source))
        .toList();
    final localImported = imported.where((t) => !t.isYouTube).toList();
    final ytImported = imported.where((t) => t.isYouTube).toList();
    await audioHandler.setTracks([...localImported, ...scanned, ...ytImported]);
  } catch (_) {
  } finally {
    scanning.value = false;
  }
}

Future<void> pickLocalFiles() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.audio,
    allowMultiple: true,
  );
  if (result == null) return;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final added = <TrackItem>[];
  for (var i = 0; i < result.files.length; i++) {
    final path = result.files[i].path;
    if (path == null) continue;
    final id = 'local_${stamp}_$i';
    appState.unmarkDeleted(id, path);
    final t = TrackItem(
      id: id,
      title: p.basenameWithoutExtension(path),
      artist: 'Unknown Artist',
      album: 'Local Files',
      durationSeconds: 0,
      artColors: kArtPalettes[i % kArtPalettes.length].colors,
      artStyle: kArtStyles[i % kArtStyles.length],
      source: path,
      filePath: path,
    );
    added.add(t);
  }
  if (added.isNotEmpty) await audioHandler.addTracks(added, playFirst: true);
}

// ─────────────────────────────────────────────────────────────────────────────
// Adaptive theme (colours from album art)
// ─────────────────────────────────────────────────────────────────────────────

String? _adaptiveTrackId;

Future<void> updateAdaptiveTheme() async {
  if (!appState.isAdaptive) return;
  final t = audioHandler.currentTrack;
  if (t == null || t.id == _adaptiveTrackId) return;
  _adaptiveTrackId = t.id;
  Color seed = t.artColors.first;
  try {
    final bytes = await loadArt(t);
    if (bytes != null && bytes.isNotEmpty) {
      seed = await _dominantColor(bytes) ?? seed;
    }
  } catch (_) {}
  if (audioHandler.currentTrack?.id != t.id) return; // song changed meanwhile
  appState.setAdaptiveSeed(seed);
}

/// Picks the most vivid colour from an image by averaging hues, weighted
/// towards saturated, mid-brightness pixels.
Future<Color?> _dominantColor(Uint8List bytes) async {
  final codec =
      await ui.instantiateImageCodec(bytes, targetWidth: 32, targetHeight: 32);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  if (data == null) return null;
  double sx = 0, sy = 0, sw = 0, satSum = 0;
  for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
    final c = Color.fromARGB(
        255, data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
    final hsl = HSLColor.fromColor(c);
    final w = hsl.saturation * (1 - (hsl.lightness - 0.5).abs() * 2);
    if (w <= 0.05) continue;
    final rad = hsl.hue * pi / 180;
    sx += cos(rad) * w;
    sy += sin(rad) * w;
    sw += w;
    satSum += hsl.saturation * w;
  }
  if (sw < 0.5) return null; // mostly grey art: keep the fallback colour
  var hue = atan2(sy, sx) * 180 / pi;
  if (hue < 0) hue += 360;
  final sat = (satSum / sw).clamp(0.45, 1.0).toDouble();
  return HSLColor.fromAHSL(1, hue, sat, 0.55).toColor();
}

// ─────────────────────────────────────────────────────────────────────────────
// YouTube Music (native bridge: android/.../YtMusicBridge.kt)
// ─────────────────────────────────────────────────────────────────────────────

class YtArtist {
  final String url;
  final String name;
  final String? thumbnail;
  final int subscribers;
  const YtArtist(this.url, this.name, this.thumbnail, this.subscribers);
}

class YtAlbum {
  final String url;
  final String title;
  final String artist;
  final String? thumbnail;
  final int trackCount;
  const YtAlbum(this.url, this.title, this.artist, this.thumbnail, this.trackCount);
}

class YtAlbumPage {
  final String title;
  final String artist;
  final String? thumbnail;
  final List<TrackItem> tracks;
  const YtAlbumPage(this.title, this.artist, this.thumbnail, this.tracks);
}

class YtArtistPage {
  final String name;
  final String? thumbnail;
  final int subscribers;
  final List<TrackItem> songs;
  final List<YtAlbum> albums;
  const YtArtistPage(
      this.name, this.thumbnail, this.subscribers, this.songs, this.albums);
}

class YtAccount {
  final bool signedIn;
  final String? name;
  final String? photo;
  const YtAccount(this.signedIn, {this.name, this.photo});
}

/// YouTube Music sign-in state (read-only library access).
final ValueNotifier<YtAccount> ytAccount =
    ValueNotifier<YtAccount>(const YtAccount(false));

class YtPlaylistRef {
  final String playlistId;
  final String title;
  final String subtitle;
  final String? thumbnail;
  const YtPlaylistRef(this.playlistId, this.title, this.subtitle, this.thumbnail);
}

class YtLinks {
  final String? artistUrl;
  final String? artistName;
  final String? albumUrl;
  final String? albumTitle;
  final String? albumThumbnail;
  const YtLinks(this.artistUrl, this.artistName, this.albumUrl, this.albumTitle,
      this.albumThumbnail);
}

String formatCompactCount(int n) {
  if (n < 0) return '';
  if (n >= 1000000000) return '${(n / 1000000000).toStringAsFixed(1)}B';
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

class YouTubeMusic {
  static int _palette = 0;

  static Map<String, dynamic> _map(Object? e) =>
      Map<String, dynamic>.from(e as Map);

  static TrackItem? _track(Map<String, dynamic> m, {String? album}) {
    final videoId = (m['videoId'] ?? '').toString();
    if (videoId.isEmpty) return null;
    final id = 'yt_$videoId';
    // Reuse the library instance so edits/likes/active state line up.
    final existing = audioHandler.trackById(id);
    if (existing != null) return existing;
    final i = _palette++;
    final t = TrackItem(
      id: id,
      title: cleanText(m['title'], 'Unknown Track'),
      artist: cleanText(m['artist'], 'Unknown Artist'),
      album: album ??
          (((m['album'] ?? '').toString().isNotEmpty)
              ? m['album'].toString()
              : 'YouTube Music'),
      durationSeconds: (m['durationSeconds'] as num?)?.toInt() ?? 0,
      artColors: kArtPalettes[i % kArtPalettes.length].colors,
      artStyle: kArtStyles[i % kArtStyles.length],
      source: 'https://music.youtube.com/watch?v=$videoId',
      ytVideoId: videoId,
      artworkUrl: m['thumbnail'] as String?,
    );
    appState.applyEdits(t);
    return t;
  }

  static List<TrackItem> _tracks(Object? raw, {String? album}) {
    final out = <TrackItem>[];
    for (final e in (raw as List? ?? const [])) {
      final t = _track(_map(e), album: album);
      if (t != null) out.add(t);
    }
    return out;
  }

  static YtAlbum _album(Map<String, dynamic> m) => YtAlbum(
        (m['url'] ?? '').toString(),
        cleanText(m['title'], 'Unknown Album'),
        (m['artist'] ?? '').toString(),
        m['thumbnail'] as String?,
        (m['trackCount'] as num?)?.toInt() ?? -1,
      );

  /// Searches YouTube Music songs. Throws on network/extraction errors.
  static Future<List<TrackItem>> search(String query) async {
    if (!Platform.isAndroid) return const [];
    final raw = await _ytChannel.invokeMethod('ytSearch', {'query': query});
    return _tracks(raw);
  }

  static Future<List<YtArtist>> searchArtists(String query) async {
    if (!Platform.isAndroid) return const [];
    final raw = await _ytChannel.invokeMethod('ytSearchArtists', {'query': query})
            as List? ??
        const [];
    return raw.map((e) {
      final m = _map(e);
      return YtArtist(
        (m['url'] ?? '').toString(),
        cleanText(m['name'], 'Unknown Artist'),
        m['thumbnail'] as String?,
        (m['subscribers'] as num?)?.toInt() ?? -1,
      );
    }).where((a) => a.url.isNotEmpty).toList();
  }

  static Future<List<YtAlbum>> searchAlbums(String query) async {
    if (!Platform.isAndroid) return const [];
    final raw = await _ytChannel.invokeMethod('ytSearchAlbums', {'query': query})
            as List? ??
        const [];
    return raw.map((e) => _album(_map(e))).where((a) => a.url.isNotEmpty).toList();
  }

  static Future<YtAlbumPage> album(String url) async {
    final m = _map(await _ytChannel.invokeMethod('ytAlbum', {'url': url}));
    final title = cleanText(m['title'], 'Unknown Album');
    return YtAlbumPage(
      title,
      (m['artist'] ?? '').toString(),
      m['thumbnail'] as String?,
      _tracks(m['tracks'], album: title),
    );
  }

  static Future<YtArtistPage> artist(String url, String name) async {
    final m = _map(
        await _ytChannel.invokeMethod('ytArtist', {'url': url, 'name': name}));
    return YtArtistPage(
      cleanText(m['name'], name),
      m['thumbnail'] as String?,
      (m['subscribers'] as num?)?.toInt() ?? -1,
      _tracks(m['songs']),
      ((m['albums'] as List?) ?? const [])
          .map((e) => _album(_map(e)))
          .where((a) => a.url.isNotEmpty)
          .toList(),
    );
  }

  // ── Account (read-only) ────────────────────────────────────────────────

  static Future<void> refreshAccount() async {
    if (!Platform.isAndroid) return;
    try {
      final m = _map(await _ytChannel.invokeMethod('ytAccount'));
      ytAccount.value = YtAccount(
        m['signedIn'] == true,
        name: m['name'] as String?,
        photo: m['photo'] as String?,
      );
    } catch (_) {}
  }

  /// Opens Google's sign-in page. Returns true once signed in.
  static Future<bool> signIn() async {
    final ok = await _ytChannel.invokeMethod<bool>('ytSignIn') ?? false;
    if (ok) await refreshAccount();
    return ok;
  }

  static Future<void> signOut() async {
    await _ytChannel.invokeMethod('ytSignOut');
    ytAccount.value = const YtAccount(false);
    _libraryCache = null;
  }

  static Future<List<YtPlaylistRef>>? _libraryCache;

  /// Your YouTube Music library playlists. The request is shared/cached so
  /// rebuilding screens doesn't refetch; pass refresh to reload.
  static Future<List<YtPlaylistRef>> libraryPlaylists({bool refresh = false}) {
    if (!refresh && _libraryCache != null) return _libraryCache!;
    final f = _fetchLibraryPlaylists();
    _libraryCache = f;
    return f;
  }

  static Future<List<YtPlaylistRef>> _fetchLibraryPlaylists() async {
    final raw = await _ytChannel.invokeMethod('ytLibraryPlaylists') as List? ??
        const [];
    final out = raw
        .map((e) {
          final m = _map(e);
          return YtPlaylistRef(
            (m['playlistId'] ?? '').toString(),
            cleanText(m['title'], 'Playlist'),
            (m['subtitle'] ?? '').toString(),
            m['thumbnail'] as String?,
          );
        })
        // "Liked Music" (LM) gets its own tile.
        .where((p) => p.playlistId.isNotEmpty && p.playlistId != 'LM')
        .toList();
    return out;
  }

  static Future<YtAlbumPage> playlistPage(String playlistId,
      {String? title, String? thumbnail}) async {
    final m = _map(await _ytChannel.invokeMethod(
        'ytPlaylistTracks', {'playlistId': playlistId, 'auth': true}));
    final name = title ?? cleanText(m['title'], 'Playlist');
    return YtAlbumPage(
      name,
      'YouTube Music',
      thumbnail ?? m['thumbnail'] as String?,
      _tracks(m['tracks']),
    );
  }

  static final Map<String, YtLinks> _linksCache = {};

  static Future<YtLinks> trackLinks(String videoId) async {
    final cached = _linksCache[videoId];
    if (cached != null) return cached;
    final m = _map(
        await _ytChannel.invokeMethod('ytTrackLinks', {'videoId': videoId}));
    final links = YtLinks(
      m['artistUrl'] as String?,
      m['artistName'] as String?,
      m['albumUrl'] as String?,
      m['albumTitle'] as String?,
      m['albumThumbnail'] as String?,
    );
    _linksCache[videoId] = links;
    return links;
  }

  /// Resolves a song and returns the local URL the player should load.
  static Future<Uri> prepare(String videoId, {bool refresh = false}) async {
    final url = await _ytChannel.invokeMethod<String>('ytPrepare', {
      'videoId': videoId,
      'refresh': refresh,
    });
    if (url == null || url.isEmpty) {
      throw Exception('No stream URL for $videoId');
    }
    return Uri.parse(url);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// iOS 27 Liquid Glass (Beta) & Ambient Mesh Backdrop Components
// ─────────────────────────────────────────────────────────────────────────────

class LiquidGlassBox extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final Color fallbackColor;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final double tintOpacity;
  final List<BoxShadow>? boxShadow;

  const LiquidGlassBox({
    super.key,
    required this.child,
    required this.borderRadius,
    required this.fallbackColor,
    this.padding,
    this.blur = 24,
    this.tintOpacity = 0.12,
    this.boxShadow,
  });

  @override
  Widget build(BuildContext context) {
    if (!appState.liquidGlass) {
      return Container(
        padding: padding,
        decoration: BoxDecoration(
          color: fallbackColor,
          borderRadius: borderRadius,
          boxShadow: boxShadow,
        ),
        child: child,
      );
    }
    final pal = appState.palette;
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: boxShadow ??
            [
              BoxShadow(
                color: Colors.black.withOpacity(0.45),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
              BoxShadow(
                color: pal.accent.withOpacity(0.08),
                blurRadius: 18,
                spreadRadius: -2,
              ),
            ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(tintOpacity + 0.08),
                  pal.accent.withOpacity(0.06),
                  Colors.white.withOpacity(tintOpacity * 0.35),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
              border: Border.all(
                color: Colors.white.withOpacity(0.22),
                width: 1.1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Liquid Glass bottom bar (only used when Liquid Glass is on in Settings).
///
/// At rest the selected tab sits in a dark glass pill. Press and hold and the
/// pill swells into a clear, frosted lens that pokes out past the bar; slide
/// your finger and it follows (stretching with your speed), lighting up the
/// tab underneath. Let go and it springs onto the nearest tab.
class LiquidGlassNavBar extends StatefulWidget {
  final int selected;
  final List<(IconData, String)> items;
  final ValueChanged<int> onSelect;
  final AppPalette palette;

  const LiquidGlassNavBar({
    super.key,
    required this.selected,
    required this.items,
    required this.onSelect,
    required this.palette,
  });

  @override
  State<LiquidGlassNavBar> createState() => _LiquidGlassNavBarState();
}

class _LiquidGlassNavBarState extends State<LiquidGlassNavBar>
    with TickerProviderStateMixin {
  static const double _pad = 6;
  static const double _h = 56;

  // Indicator position measured in "tabs" (0 = first tab, 1 = second, ...).
  late final AnimationController _pos =
      AnimationController.unbounded(vsync: this, value: widget.selected.toDouble());
  // 0 = resting pill, 1 = pressed lens.
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    reverseDuration: const Duration(milliseconds: 320),
  );
  // Horizontal stretch from finger speed; decays back to 0.
  late final AnimationController _stretch =
      AnimationController.unbounded(vsync: this, value: 0);

  double _tabW = 100;
  bool _dragging = false;
  int _hovered = -1;
  Duration? _lastTs;

  int get _n => widget.items.length;

  @override
  void didUpdateWidget(covariant LiquidGlassNavBar old) {
    super.didUpdateWidget(old);
    if (!_dragging && widget.selected != old.selected) {
      _springPos(widget.selected.toDouble());
    }
  }

  @override
  void dispose() {
    _pos.dispose();
    _press.dispose();
    _stretch.dispose();
    super.dispose();
  }

  void _springPos(double target, [double velocity = 0]) {
    _pos.animateWith(SpringSimulation(
      // Slightly under-damped: lands with a small liquid wobble.
      const SpringDescription(mass: 1, stiffness: 380, damping: 22),
      _pos.value,
      target,
      velocity,
    ));
  }

  double _tabAt(double localX) =>
      ((localX - _pad) / _tabW - 0.5).clamp(0.0, (_n - 1).toDouble()).toDouble();

  void _pressDown(double localX) {
    HapticFeedback.lightImpact();
    _press.animateTo(1, curve: Curves.easeOutBack);
    _springPos(_tabAt(localX));
    _hovered = _tabAt(localX).round();
  }

  void _release({double velocityTabs = 0, bool select = true}) {
    _dragging = false;
    _lastTs = null;
    final target = (_pos.value + velocityTabs * 0.08)
        .round()
        .clamp(0, _n - 1)
        .toInt();
    _press.animateBack(0, curve: Curves.easeOutCubic);
    _stretch.animateWith(SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 300, damping: 18),
      _stretch.value,
      0,
      0,
    ));
    if (!select) {
      _springPos(widget.selected.toDouble());
      return;
    }
    _springPos(target.toDouble(), velocityTabs);
    if (target != widget.selected) {
      HapticFeedback.selectionClick();
      widget.onSelect(target);
    }
  }

  void _dragUpdate(DragUpdateDetails d) {
    _dragging = true;
    _pos.value = _tabAt(d.localPosition.dx);
    // Stretch with speed (px per ms), smoothed.
    final ts = d.sourceTimeStamp;
    double speed = d.delta.dx.abs() / 16.0;
    if (ts != null && _lastTs != null) {
      final ms = (ts - _lastTs!).inMicroseconds / 1000.0;
      if (ms > 0) speed = d.delta.dx.abs() / ms;
    }
    _lastTs = ts;
    final target = (speed * 0.18).clamp(0.0, 0.38).toDouble();
    _stretch.value = _stretch.value + (target - _stretch.value) * 0.35;
    final h = _pos.value.round();
    if (h != _hovered) {
      _hovered = h;
      HapticFeedback.selectionClick();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = widget.palette;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      _tabW = (w - _pad * 2) / _n;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _pressDown(d.localPosition.dx),
        onTapUp: (_) => _release(),
        onTapCancel: () {
          // A tap turns into a drag by cancelling first; only reset if no
          // drag actually started (e.g. the touch became a scroll).
          Future.delayed(const Duration(milliseconds: 60), () {
            if (mounted && !_dragging) _release(select: false);
          });
        },
        onHorizontalDragStart: (d) {
          _dragging = true;
          _press.animateTo(1, curve: Curves.easeOutBack);
          _pos.value = _tabAt(d.localPosition.dx);
        },
        onHorizontalDragUpdate: _dragUpdate,
        onHorizontalDragEnd: (d) =>
            _release(velocityTabs: d.velocity.pixelsPerSecond.dx / _tabW),
        onHorizontalDragCancel: () => _release(),
        child: AnimatedBuilder(
          animation: Listenable.merge([_pos, _press, _stretch]),
          builder: (context, _) {
            final p = _press.value; // may overshoot slightly (easeOutBack)
            final pc = p.clamp(0.0, 1.0).toDouble();
            final st = _stretch.value.clamp(0.0, 0.5).toDouble();
            final active = _pos.value.round().clamp(0, _n - 1);

            // Indicator geometry: grows past the bar when pressed, stretches
            // sideways with speed and squashes vertically to match.
            final indW = _tabW * (1 + 0.32 * p) * (1 + st);
            final indH = _h * (1 + 0.34 * p) * (1 - 0.22 * st);
            final cx = _pad + (_pos.value + 0.5) * _tabW;
            final left = cx - indW / 2;
            final top = _pad + (_h - indH) / 2;

            return SizedBox(
              height: _h + _pad * 2,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // ── The bar: frosted, see-through, thin bright rim.
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(36),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.40),
                            blurRadius: 22,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(36),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(36),
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white.withOpacity(0.10),
                                  pal.bg.withOpacity(0.35),
                                ],
                              ),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.16),
                                width: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // ── The selection pill / liquid lens.
                  Positioned(
                    left: left,
                    top: top,
                    width: indW,
                    height: indH,
                    child: _lens(pal, pc, indH),
                  ),
                  // ── Icons + labels (on top, so they stay readable).
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Padding(
                        padding: const EdgeInsets.all(_pad),
                        child: Row(
                          children: [
                            for (var i = 0; i < _n; i++)
                              Expanded(child: _tab(pal, i, i == active, pc)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    });
  }

  Widget _lens(AppPalette pal, double p, double h) {
    final r = BorderRadius.circular(h / 2);
    return Container(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18 + 0.22 * p),
            blurRadius: 10 + 14 * p,
            offset: Offset(0, 3 + 5 * p),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          // Resting: light frost. Pressed: heavier, lens-like frost.
          filter: ui.ImageFilter.blur(sigmaX: 4 + 10 * p, sigmaY: 4 + 10 * p),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: r,
              // Dark tinted pill at rest -> bright clear glass when pressed.
              color: Color.lerp(
                Colors.black.withOpacity(0.30),
                Colors.white.withOpacity(0.16),
                p,
              ),
              border: Border.all(
                color: Colors.white.withOpacity(0.10 + 0.45 * p),
                width: 1 + 0.6 * p,
              ),
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: r,
              // Specular highlight along the top edge + soft glow at the bottom.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withOpacity(0.06 + 0.30 * p),
                  Colors.white.withOpacity(0.0),
                  Colors.white.withOpacity(0.0),
                  Colors.white.withOpacity(0.04 + 0.14 * p),
                ],
                stops: const [0.0, 0.35, 0.7, 1.0],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(AppPalette pal, int i, bool active, double p) {
    final color = active ? pal.accent : const Color(0xFFE2E6EA);
    return AnimatedScale(
      scale: active ? 1.0 + 0.06 * p : 1.0,
      duration: const Duration(milliseconds: 160),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(widget.items[i].$1, size: 22, color: color),
          const SizedBox(height: 2),
          Text(
            widget.items[i].$2,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class AuroraPlasmaBackground extends StatefulWidget {
  final Color accent;
  final Color secondary;
  final bool intense;

  const AuroraPlasmaBackground({
    super.key,
    required this.accent,
    required this.secondary,
    this.intense = false,
  });

  @override
  State<AuroraPlasmaBackground> createState() => _AuroraPlasmaBackgroundState();
}

class _AuroraPlasmaBackgroundState extends State<AuroraPlasmaBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!appState.liquidGlass && !appState.animatedBackground) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final a = _c.value * 2 * pi;
          return CustomPaint(
            painter: _AuroraPainter(
              angle: a,
              c1: widget.accent,
              c2: widget.secondary,
              intense: widget.intense,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double angle;
  final Color c1;
  final Color c2;
  final bool intense;

  const _AuroraPainter({
    required this.angle,
    required this.c1,
    required this.c2,
    required this.intense,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final alpha1 = intense ? 0.28 : 0.16;
    final alpha2 = intense ? 0.22 : 0.12;
    final p1 = Offset(
      size.width * (0.28 + 0.22 * cos(angle)),
      size.height * (0.22 + 0.15 * sin(angle)),
    );
    final p2 = Offset(
      size.width * (0.75 + 0.20 * sin(angle * 0.8)),
      size.height * (0.68 + 0.18 * cos(angle * 0.8)),
    );
    final r1 = size.shortestSide * 0.65;
    final r2 = size.shortestSide * 0.72;

    canvas.drawCircle(
      p1,
      r1,
      Paint()
        ..shader = RadialGradient(
          colors: [c1.withOpacity(alpha1), Colors.transparent],
        ).createShader(Rect.fromCircle(center: p1, radius: r1)),
    );
    canvas.drawCircle(
      p2,
      r2,
      Paint()
        ..shader = RadialGradient(
          colors: [c2.withOpacity(alpha2), Colors.transparent],
        ).createShader(Rect.fromCircle(center: p2, radius: r2)),
    );
  }

  @override
  bool shouldRepaint(covariant _AuroraPainter old) =>
      old.angle != angle || old.c1 != c1 || old.intense != intense;
}

// ─────────────────────────────────────────────────────────────────────────────
// App
// ─────────────────────────────────────────────────────────────────────────────

class AlexLmpApp extends StatelessWidget {
  const AlexLmpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final pal = appState.palette;
        return MaterialApp(
          title: 'AlexLMP',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: pal.bg,
            colorScheme: ColorScheme.dark(
              primary: pal.accent,
              onPrimary: pal.onAccent,
              secondary: pal.accent,
              surface: pal.bg,
              surfaceContainer: pal.surface,
            ),
            splashFactory: InkSparkle.splashFactory,
            fontFamily: 'Roboto',
          ),
          home: const AlexLmpRoot(),
        );
      },
    );
  }
}

void openPlayer(BuildContext context) {
  if (audioHandler.tracks.isEmpty) {
    showAddMusicSheet(context);
    return;
  }
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 520),
      reverseTransitionDuration: const Duration(milliseconds: 360),
      pageBuilder: (_, __, ___) => const NowPlayingScreen(),
      transitionsBuilder: (_, anim, __, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: kEmphasizedDecel,
          reverseCurve: kEmphasizedAccel,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    ),
  );
}

void playAndOpen(BuildContext context, int index) {
  audioHandler.playIndex(index);
  openPlayer(context);
}

class AlexLmpRoot extends StatefulWidget {
  const AlexLmpRoot({super.key});

  @override
  State<AlexLmpRoot> createState() => _AlexLmpRootState();
}

class _AlexLmpRootState extends State<AlexLmpRoot> {
  int _tab = 0;
  int _dir = 1;
  int _libraryFilter = 0;

  @override
  void initState() {
    super.initState();
    appNotice.addListener(_onNotice);
    scanDeviceAudio();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onNotice());
  }

  @override
  void dispose() {
    appNotice.removeListener(_onNotice);
    super.dispose();
  }

  void _onNotice() {
    final msg = appNotice.value;
    if (msg == null || !mounted) return;
    appNotice.value = null;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 190),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        appState,
        audioHandler.libraryRevision,
        audioHandler.currentIndex,
        scanning,
      ]),
      builder: (context, _) {
        final pal = appState.palette;
        final tracks = audioHandler.tracks;
        final bottomInset = MediaQuery.of(context).padding.bottom;

        return Scaffold(
          backgroundColor: pal.bg,
          body: Stack(
            children: [
              AuroraPlasmaBackground(
                accent: pal.accent,
                secondary: const Color(0xFFF09CE2),
              ),
              SafeArea(
                bottom: false,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 380),
                  switchInCurve: kEmphasizedDecel,
                  switchOutCurve: kEmphasizedAccel,
                  transitionBuilder: (child, anim) {
                    final incoming = child.key == ValueKey(_tab);
                    final begin = Offset(0.08 * (incoming ? _dir : -_dir), 0);
                    return FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(begin: begin, end: Offset.zero)
                            .animate(anim),
                        child: child,
                      ),
                    );
                  },
                  child: KeyedSubtree(
                    key: ValueKey(_tab),
                    child: _tabBody(context, pal, tracks),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: bottomInset + 8,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (audioHandler.currentTrack != null)
                      Reveal(
                        dy: 40,
                        child: MiniPlayer(
                          track: audioHandler.currentTrack!,
                          palette: pal,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: appState.liquidGlass
                              ? LiquidGlassNavBar(
                                  selected: _tab,
                                  palette: pal,
                                  items: const [
                                    (Icons.home_rounded, 'Home'),
                                    (Icons.sensors_rounded, 'Mix'),
                                    (Icons.library_music_rounded, 'Library'),
                                  ],
                                  onSelect: (i) => setState(() {
                                    _dir = i >= _tab ? 1 : -1;
                                    _tab = i;
                                  }),
                                )
                              : _navBar(pal),
                        ),
                        const SizedBox(width: 10),
                        SquishyGesture(
                          onTap: () => showSearchSheet(context),
                          child: LiquidGlassBox(
                            borderRadius: BorderRadius.circular(32),
                            fallbackColor: pal.surface,
                            boxShadow: _shadow,
                            child: const SizedBox(
                              width: 64,
                              height: 64,
                              child: Icon(
                                Icons.search_rounded,
                                color: Color(0xFFD5DCE0),
                                size: 26,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tabBody(BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    switch (_tab) {
      case 1:
        return _mixTab(context, pal, tracks);
      case 2:
        return _libraryTab(context, pal, tracks);
      default:
        return _homeTab(context, pal, tracks);
    }
  }

  Widget _navBar(AppPalette pal) {
    return LiquidGlassBox(
      borderRadius: BorderRadius.circular(36),
      fallbackColor: pal.surface,
      padding: const EdgeInsets.all(6),
      boxShadow: _shadow,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            _navTab(pal, 0, Icons.home_rounded, 'Home'),
            _navTab(pal, 1, Icons.sensors_rounded, 'Mix'),
            _navTab(pal, 2, Icons.library_music_rounded, 'Library'),
          ],
        ),
      ),
    );
  }

  Widget _navTab(AppPalette pal, int i, IconData icon, String label) {
    final selected = _tab == i;
    return Expanded(
      child: SquishyGesture(
        pressedScale: 0.92,
        onTap: () => setState(() {
          _dir = i >= _tab ? 1 : -1;
          _tab = i;
        }),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected
                ? (appState.liquidGlass
                    ? pal.accent.withOpacity(0.24)
                    : pal.container)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(30),
            border: selected && appState.liquidGlass
                ? Border.all(color: pal.accent.withOpacity(0.45))
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: selected ? pal.accent : const Color(0xFFB3B9BE),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  color: selected ? pal.accent : const Color(0xFFB3B9BE),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────────────────── HOME ─────────────────────────────

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 5) return 'Good night';
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  Widget _roundIcon(AppPalette pal, IconData icon, VoidCallback onTap) {
    return SquishyGesture(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: pal.surface,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white10),
        ),
        child: Icon(icon, color: const Color(0xFFD5DCE0), size: 22),
      ),
    );
  }

  Widget _accountButton(BuildContext context, AppPalette pal) {
    return ValueListenableBuilder<YtAccount>(
      valueListenable: ytAccount,
      builder: (context, acc, _) => SquishyGesture(
        onTap: () => showYtAccountSheet(context),
        child: acc.signedIn
            ? Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: pal.accent, width: 2),
                ),
                child: YtNetworkImage(
                  url: acc.photo,
                  size: 36,
                  circle: true,
                  fallbackIcon: Icons.person_rounded,
                ),
              )
            : Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: pal.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white10),
                ),
                child: const Icon(Icons.account_circle_outlined,
                    color: Color(0xFFD5DCE0), size: 24),
              ),
      ),
    );
  }

  Widget _homeTab(BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ALEXLMP',
                  style: TextStyle(
                    color: pal.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _greeting(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
              ],
            ),
          ),
          _roundIcon(pal, Icons.add_rounded, () => showAddMusicSheet(context)),
          const SizedBox(width: 8),
          _roundIcon(pal, Icons.settings_rounded, () => showSettingsSheet(context)),
          const SizedBox(width: 8),
          _accountButton(context, pal),
        ],
      ),
    );

    if (tracks.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(top: 14, bottom: 185),
        children: [
          header,
          const SizedBox(height: 90),
          _emptyState(context, pal),
        ],
      );
    }

    final likedTracks = tracks.where((t) => appState.isLiked(t.id)).toList();
    final pls = appState.playlists;
    final current = audioHandler.currentTrack;
    final quick = tracks.take(8).toList();
    final col1 = quick.take(4).toList();
    final col2 = quick.skip(4).take(4).toList();
    final listenAgain = tracks.reversed.take(10).toList();
    final colWidth = MediaQuery.of(context).size.width - 42;
    final mixes = buildMixes(tracks).take(6).toList();
    final screenW = MediaQuery.of(context).size.width;
    final tileW = (screenW - 32 - 10) / 2;

    // Quick-access tiles (2 columns)
    final tiles = <Widget>[
      QuickTile(
        width: tileW,
        cover: GradientCover(
          icon: Icons.favorite_rounded,
          colors: [pal.accent, pal.playerButton],
          size: 54,
          iconColor: pal.onAccent,
        ),
        title: 'Liked Songs',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const LikedSongsScreen()),
        ),
      ),
      QuickTile(
        width: tileW,
        cover: GradientCover(
          icon: Icons.shuffle_rounded,
          colors: [pal.playerButton, pal.accent],
          size: 54,
          iconColor: pal.onAccent,
        ),
        title: 'Shuffle all',
        onTap: () {
          audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
          playAndOpen(context, Random().nextInt(tracks.length));
        },
      ),
      for (final pl in pls.take(4))
        QuickTile(
          width: tileW,
          cover: PlaylistCoverThumbnail(playlist: pl, size: 54),
          title: pl.name,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlaylistDetailScreen(playlistId: pl.id),
            ),
          ),
        ),
      if (pls.length < 4)
        for (final m in mixes.take(4 - pls.length))
          QuickTile(
            width: tileW,
            cover: MixCover(mix: m, size: 54, showTitle: false),
            title: m.title,
            onTap: () => openMix(context, m),
          ),
    ];

    return ListView(
      padding: const EdgeInsets.only(top: 14, bottom: 185),
      children: [
        Reveal(child: header),
        const SizedBox(height: 18),
        Reveal(
          delayMs: 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 10, runSpacing: 10, children: tiles),
          ),
        ),
        if (current != null) ...[
          const SizedBox(height: 22),
          Reveal(
            delayMs: 120,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ContinueListeningCard(track: current),
            ),
          ),
        ],
        const SizedBox(height: 26),
        _sectionHeader(
          'START LISTENING',
          'Quick picks',
          trailing: _pillButton(pal, 'Play all', () {
            if (quick.isNotEmpty) {
              audioHandler.playYouTubeList(quick, 0);
              openPlayer(context);
            }
          }),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 280,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 16),
            children: [
              SizedBox(
                width: colWidth,
                child: Column(
                  children: col1.map((t) => _trackRow(context, pal, t)).toList(),
                ),
              ),
              if (col2.isNotEmpty) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: colWidth,
                  child: Column(
                    children: col2.map((t) => _trackRow(context, pal, t)).toList(),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (mixes.isNotEmpty) ...[
          const SizedBox(height: 22),
          _sectionHeader('MADE FOR YOU', 'Your mixes',
              trailing: _pillButton(pal, 'See all', () {
            setState(() {
              _dir = 1;
              _tab = 1;
            });
          })),
          const SizedBox(height: 14),
          SizedBox(
            height: 214,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: mixes.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (context, i) => MixCard(mix: mixes[i], width: 156),
            ),
          ),
        ],
        const SizedBox(height: 22),
        _sectionHeader('JUMP BACK IN', 'Listen again'),
        const SizedBox(height: 14),
        SizedBox(
          height: 226,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: listenAgain.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final t = listenAgain[i];
              return MediaCard(
                width: 164,
                cover: CustomAlbumArtwork(track: t),
                title: t.title,
                subtitle: t.artist,
                onTap: () => playAndOpen(context, audioHandler.tracks.indexOf(t)),
              );
            },
          ),
        ),
        if (likedTracks.isNotEmpty) ...[
          const SizedBox(height: 22),
          _sectionHeader('YOUR FAVORITES', 'Liked songs',
              trailing: _pillButton(pal, 'Open', () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LikedSongsScreen()),
            );
          })),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: likedTracks
                  .take(4)
                  .map((t) => TrackRow(
                        track: t,
                        palette: pal,
                        active: audioHandler.currentTrack?.id == t.id,
                        onTap: () =>
                            playAndOpen(context, audioHandler.tracks.indexOf(t)),
                        onMore: () => showAddToPlaylistSheet(context, t),
                      ))
                  .toList(),
            ),
          ),
        ],
        ValueListenableBuilder<YtAccount>(
          valueListenable: ytAccount,
          builder: (context, acc, _) {
            if (!acc.signedIn) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 22),
                _sectionHeader('FROM YOUTUBE MUSIC', 'Your playlists'),
                const SizedBox(height: 14),
                SizedBox(
                  height: 214,
                  child: _ytPlaylistRow(context, pal),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _ytPlaylistRow(BuildContext context, AppPalette pal) {
    return FutureBuilder<List<YtPlaylistRef>>(
      future: YouTubeMusic.libraryPlaylists(),
      builder: (context, snap) {
        final items = <Widget>[
          MediaCard(
            width: 156,
            cover: GradientCover(
              icon: Icons.thumb_up_alt_rounded,
              colors: [const Color(0xFFFF4D5E), pal.playerButton],
              size: 156,
              iconColor: Colors.white,
            ),
            title: 'Liked on YouTube',
            subtitle: 'Auto playlist',
            onTap: () => openYtLikedMusic(context),
          ),
          ...?snap.data?.map((p) => MediaCard(
                width: 156,
                cover: YtNetworkImage(url: p.thumbnail, size: 156),
                title: p.title,
                subtitle: p.subtitle,
                onTap: () => openYtAccountPlaylist(context, p),
              )),
        ];
        return ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: items.length + (snap.connectionState == ConnectionState.waiting ? 1 : 0),
          separatorBuilder: (_, __) => const SizedBox(width: 14),
          itemBuilder: (context, i) => i < items.length
              ? items[i]
              : SizedBox(
                  width: 60,
                  child: Center(
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: pal.accent),
                  ),
                ),
        );
      },
    );
  }

  Widget _pillButton(AppPalette pal, String label, VoidCallback onTap) {
    return SquishyGesture(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: pal.container,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: pal.accent,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context, AppPalette pal) {
    final busy = scanning.value;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          busy
              ? SizedBox(
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(color: pal.accent),
                )
              : Icon(Icons.music_note_rounded, size: 64, color: pal.accent),
          const SizedBox(height: 16),
          Text(
            busy ? 'Scanning your music…' : 'No songs found on this device',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Scan device music or pick local audio files to get started.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFA6ADB2), fontSize: 14),
          ),
          const SizedBox(height: 24),
          SquishyGesture(
            onTap: () => showAddMusicSheet(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: pal.accent,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, color: pal.onAccent),
                  const SizedBox(width: 8),
                  Text(
                    'Add Music',
                    style: TextStyle(
                      color: pal.onAccent,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String eyebrow, String title, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  eyebrow,
                  style: const TextStyle(
                    color: Color(0xFF9EA6AC),
                    fontSize: 12,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _trackRow(BuildContext context, AppPalette pal, TrackItem t) {
    final idx = audioHandler.tracks.indexOf(t);
    return Reveal(
      delayMs: min(max(idx, 0), 8) * 40,
      dy: 16,
      child: TrackRow(
        track: t,
        palette: pal,
        active: audioHandler.currentTrack?.id == t.id,
        onTap: () => playAndOpen(context, idx),
        onMore: () => showAddToPlaylistSheet(context, t),
      ),
    );
  }

  // ───────────────────────────── MIXES ─────────────────────────────

  Widget _mixTab(BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    final mixes = buildMixes(tracks);
    final w = MediaQuery.of(context).size.width;
    final cardW = (w - 32 - 14) / 2;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 185),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'MADE FOR YOU',
                    style: TextStyle(
                      color: pal.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.4,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    appState.playlistName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6,
                    ),
                  ),
                ],
              ),
            ),
            _roundIcon(pal, Icons.edit_rounded, () => showPlaylistEditDialog(context)),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Fresh mixes built from your library every day.',
          style: TextStyle(color: Color(0xFFA6ADB2), fontSize: 14),
        ),
        const SizedBox(height: 18),
        if (mixes.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text(
                'Add some music to get your mixes.',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          )
        else ...[
          Reveal(
            child: FeaturedMixCard(mix: mixes.first),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 14,
            runSpacing: 18,
            children: [
              for (var i = 1; i < mixes.length; i++)
                Reveal(
                  delayMs: min(i, 8) * 50,
                  child: MixCard(mix: mixes[i], width: cardW),
                ),
            ],
          ),
        ],
      ],
    );
  }

  // ───────────────────────────── LIBRARY ─────────────────────────────

  Widget _libraryTab(
    BuildContext context,
    AppPalette pal,
    List<TrackItem> tracks,
  ) {
    const filters = [
      (Icons.queue_music_rounded, 'Playlists'),
      (Icons.music_note_rounded, 'Songs'),
      (Icons.person_rounded, 'Artists'),
      (Icons.album_rounded, 'Albums'),
      (Icons.play_circle_fill_rounded, 'YouTube Music'),
    ];
    if (_libraryFilter >= filters.length) _libraryFilter = 0;

    Widget body;
    switch (_libraryFilter) {
      case 1:
        body = _librarySongs(context, pal, tracks);
        break;
      case 2:
        body = _libraryArtists(context, pal, tracks);
        break;
      case 3:
        body = _libraryAlbums(context, pal, tracks);
        break;
      case 4:
        body = _libraryYouTube(context, pal);
        break;
      default:
        body = _libraryPlaylists(context, pal, tracks);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 185),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Library',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
              ),
              _roundIcon(pal, Icons.folder_open_rounded,
                  () => showAddMusicSheet(context)),
              const SizedBox(width: 8),
              _roundIcon(pal, Icons.playlist_add_rounded,
                  () => showCreateOrEditPlaylistDialog(context)),
              const SizedBox(width: 8),
              _accountButton(context, pal),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 42,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: filters.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final selected = _libraryFilter == i;
              return SquishyGesture(
                pressedScale: 0.94,
                onTap: () => setState(() => _libraryFilter = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: selected ? pal.accent : pal.surface,
                    borderRadius: BorderRadius.circular(21),
                    border: Border.all(
                      color: selected ? pal.accent : Colors.white12,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        filters[i].$1,
                        size: 17,
                        color: selected ? pal.onAccent : Colors.white70,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        filters[i].$2,
                        style: TextStyle(
                          color: selected ? pal.onAccent : Colors.white,
                          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: kEmphasizedDecel,
          transitionBuilder: (c, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.03),
                end: Offset.zero,
              ).animate(a),
              child: c,
            ),
          ),
          child: KeyedSubtree(
            key: ValueKey('lib_$_libraryFilter'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: body,
            ),
          ),
        ),
      ],
    );
  }

  double _gridItemWidth(BuildContext context, int columns, {double gap = 14}) {
    final w = MediaQuery.of(context).size.width - 32;
    return (w - gap * (columns - 1)) / columns;
  }

  Widget _libraryPlaylists(
      BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    final liked = tracks.where((t) => appState.isLiked(t.id)).toList();
    final pls = appState.playlists;
    final cw = _gridItemWidth(context, 2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 18,
          children: [
            MediaCard(
              width: cw,
              cover: GradientCover(
                icon: Icons.favorite_rounded,
                colors: [pal.accent, pal.playerButton],
                size: cw,
                iconColor: pal.onAccent,
              ),
              title: 'Liked Songs',
              subtitle: '${liked.length} ${liked.length == 1 ? 'song' : 'songs'}',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LikedSongsScreen()),
              ),
            ),
            ValueListenableBuilder<YtAccount>(
              valueListenable: ytAccount,
              builder: (context, acc, _) => acc.signedIn
                  ? MediaCard(
                      width: cw,
                      cover: GradientCover(
                        icon: Icons.thumb_up_alt_rounded,
                        colors: [const Color(0xFFFF4D5E), pal.playerButton],
                        size: cw,
                        iconColor: Colors.white,
                      ),
                      title: 'Liked on YouTube',
                      subtitle: 'YouTube Music',
                      onTap: () => openYtLikedMusic(context),
                    )
                  : const SizedBox.shrink(),
            ),
            for (int i = 0; i < pls.length; i++)
              Reveal(
                delayMs: min(i, 8) * 40,
                child: MediaCard(
                  width: cw,
                  cover: PlaylistCoverThumbnail(playlist: pls[i], size: cw),
                  title: pls[i].name,
                  subtitle:
                      '${pls[i].trackIds.length} ${pls[i].trackIds.length == 1 ? 'song' : 'songs'}',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PlaylistDetailScreen(playlistId: pls[i].id),
                    ),
                  ),
                  onLongPress: () =>
                      showCreateOrEditPlaylistDialog(context, existing: pls[i]),
                ),
              ),
            MediaCard(
              width: cw,
              cover: Container(
                width: cw,
                height: cw,
                decoration: BoxDecoration(
                  color: pal.accent.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: pal.accent.withOpacity(0.45)),
                ),
                child: Icon(Icons.add_rounded, color: pal.accent, size: 44),
              ),
              title: 'New playlist',
              subtitle: 'Name it, add a cover',
              onTap: () => showCreateOrEditPlaylistDialog(context),
            ),
          ],
        ),
        ValueListenableBuilder<YtAccount>(
          valueListenable: ytAccount,
          builder: (context, acc, _) {
            if (!acc.signedIn) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 24),
              child: _ytPlaylistGrid(context, pal, cw),
            );
          },
        ),
      ],
    );
  }

  Widget _ytPlaylistGrid(BuildContext context, AppPalette pal, double cw,
      {bool refresh = false}) {
    return FutureBuilder<List<YtPlaylistRef>>(
      future: YouTubeMusic.libraryPlaylists(refresh: refresh),
      builder: (context, snap) {
        final head = Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Icon(Icons.play_circle_fill_rounded, color: pal.accent, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'From YouTube Music',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              SquishyGesture(
                onTap: () async {
                  try {
                    await YouTubeMusic.libraryPlaylists(refresh: true);
                  } catch (_) {}
                  if (mounted) setState(() {});
                },
                child: Icon(Icons.refresh_rounded, color: pal.accent),
              ),
            ],
          ),
        );
        if (snap.hasError) {
          final e = snap.error;
          final detail =
              e is PlatformException ? (e.message ?? e.code) : '$e';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              head,
              SelectableText(
                'Couldn\'t load your YouTube Music playlists.\n\nDetails: $detail',
                style: const TextStyle(color: Colors.white54),
              ),
            ],
          );
        }
        if (!snap.hasData) {
          return Column(
            children: [
              head,
              Padding(
                padding: const EdgeInsets.all(20),
                child: CircularProgressIndicator(color: pal.accent),
              ),
            ],
          );
        }
        final list = snap.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            head,
            if (list.isEmpty)
              const Text('No playlists in your YouTube Music library.',
                  style: TextStyle(color: Colors.white54)),
            Wrap(
              spacing: 14,
              runSpacing: 18,
              children: [
                for (var i = 0; i < list.length; i++)
                  Reveal(
                    delayMs: min(i, 8) * 40,
                    child: MediaCard(
                      width: cw,
                      cover: YtNetworkImage(url: list[i].thumbnail, size: cw),
                      title: list[i].title,
                      subtitle: list[i].subtitle,
                      onTap: () => openYtAccountPlaylist(context, list[i]),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  int _songSort = 0; // 0 = A–Z, 1 = artist, 2 = recently added

  Widget _librarySongs(BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    final sorted = [...tracks];
    switch (_songSort) {
      case 0:
        sorted.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case 1:
        sorted.sort((a, b) {
          final c = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
          return c != 0 ? c : a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
        break;
      default:
        break; // library order (newest device songs first)
    }
    const sortNames = ['A–Z', 'Artist', 'Recent'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${tracks.length} ${tracks.length == 1 ? 'song' : 'songs'}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            SquishyGesture(
              onTap: () => setState(() => _songSort = (_songSort + 1) % 3),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: pal.surface,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    Icon(Icons.sort_rounded, color: pal.accent, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      sortNames[_songSort],
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (sorted.isNotEmpty) ...[
              _roundIcon(pal, Icons.shuffle_rounded, () {
                audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
                playAndOpen(context, Random().nextInt(tracks.length));
              }),
              const SizedBox(width: 8),
              SquishyGesture(
                onTap: () => playAndOpen(
                    context, audioHandler.tracks.indexOf(sorted.first)),
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(color: pal.accent, shape: BoxShape.circle),
                  child: Icon(Icons.play_arrow_rounded, color: pal.onAccent, size: 28),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        if (sorted.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(
              child: Text(
                'No songs yet. Tap the folder icon to import music.',
                style: TextStyle(color: Colors.white54, fontSize: 15),
              ),
            ),
          ),
        for (final t in sorted)
          TrackRow(
            track: t,
            palette: pal,
            active: audioHandler.currentTrack?.id == t.id,
            onTap: () => playAndOpen(context, audioHandler.tracks.indexOf(t)),
            onMore: () => showAddToPlaylistSheet(context, t),
          ),
      ],
    );
  }

  Widget _libraryArtists(BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    final byArtist = <String, List<TrackItem>>{};
    for (final t in tracks) {
      byArtist.putIfAbsent(t.artist, () => <TrackItem>[]).add(t);
    }
    final entries = byArtist.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 40),
        child: Center(
          child: Text('No artists yet.',
              style: TextStyle(color: Colors.white54, fontSize: 16)),
        ),
      );
    }
    final cw = _gridItemWidth(context, 3, gap: 12);
    return Wrap(
      spacing: 12,
      runSpacing: 18,
      children: [
        for (var i = 0; i < entries.length; i++)
          Reveal(
            delayMs: min(i, 9) * 35,
            child: SquishyGesture(
              pressedScale: 0.94,
              onTap: () =>
                  showArtistTracksSheet(context, entries[i].key, entries[i].value),
              child: SizedBox(
                width: cw,
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: entries[i].value.first.artColors,
                        ),
                      ),
                      child: ClipOval(
                        child: SizedBox(
                          width: cw - 6,
                          height: cw - 6,
                          child: CustomAlbumArtwork(track: entries[i].value.first),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      entries[i].key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                    Text(
                      '${entries[i].value.length} ${entries[i].value.length == 1 ? 'song' : 'songs'}',
                      style: const TextStyle(color: Color(0xFF9EA6AC), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _libraryAlbums(BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    final byAlbum = <String, List<TrackItem>>{};
    for (final t in tracks) {
      byAlbum.putIfAbsent(t.album, () => <TrackItem>[]).add(t);
    }
    final entries = byAlbum.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 40),
        child: Center(
          child: Text('No albums yet.',
              style: TextStyle(color: Colors.white54, fontSize: 16)),
        ),
      );
    }
    final cw = _gridItemWidth(context, 2);
    return Wrap(
      spacing: 14,
      runSpacing: 18,
      children: [
        for (var i = 0; i < entries.length; i++)
          Reveal(
            delayMs: min(i, 8) * 40,
            child: MediaCard(
              width: cw,
              cover: CustomAlbumArtwork(track: entries[i].value.first),
              title: entries[i].key,
              subtitle:
                  '${entries[i].value.first.artist} • ${entries[i].value.length} ${entries[i].value.length == 1 ? 'song' : 'songs'}',
              onTap: () =>
                  showArtistTracksSheet(context, entries[i].key, entries[i].value),
            ),
          ),
      ],
    );
  }

  Widget _libraryYouTube(BuildContext context, AppPalette pal) {
    return ValueListenableBuilder<YtAccount>(
      valueListenable: ytAccount,
      builder: (context, acc, _) {
        if (!acc.signedIn) {
          return LiquidGlassBox(
            borderRadius: BorderRadius.circular(26),
            fallbackColor: pal.surface,
            padding: const EdgeInsets.all(22),
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [const Color(0xFFFF4D5E), pal.accent],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 42),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Your YouTube Music library',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Sign in to see and play your playlists and liked songs. Read-only — AlexLMP never changes anything on your account.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFA6ADB2), fontSize: 13.5),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: pal.accent,
                    foregroundColor: pal.onAccent,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                  ),
                  onPressed: () => ytSignInFlow(context),
                  icon: const Icon(Icons.login_rounded),
                  label: const Text('Sign in with Google'),
                ),
              ],
            ),
          );
        }
        final cw = _gridItemWidth(context, 2);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SquishyGesture(
              pressedScale: 0.98,
              onTap: () => showYtAccountSheet(context),
              child: LiquidGlassBox(
                borderRadius: BorderRadius.circular(22),
                fallbackColor: pal.surface,
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    YtNetworkImage(
                      url: acc.photo,
                      size: 48,
                      circle: true,
                      fallbackIcon: Icons.person_rounded,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            acc.name ?? 'YouTube Music',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                          const Text(
                            'Signed in • read-only',
                            style: TextStyle(color: Color(0xFFA6ADB2), fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: pal.accent),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            MediaCard(
              width: double.infinity,
              horizontal: true,
              cover: GradientCover(
                icon: Icons.thumb_up_alt_rounded,
                colors: [const Color(0xFFFF4D5E), pal.playerButton],
                size: 72,
                iconColor: Colors.white,
              ),
              title: 'Liked on YouTube',
              subtitle: 'Every song you liked on YouTube Music',
              onTap: () => openYtLikedMusic(context),
            ),
            const SizedBox(height: 22),
            _ytPlaylistGrid(context, pal, cw),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared cards & covers (home / mixes / library)
// ─────────────────────────────────────────────────────────────────────────────

class GradientCover extends StatelessWidget {
  final IconData icon;
  final List<Color> colors;
  final double size;
  final Color iconColor;
  const GradientCover({
    super.key,
    required this.icon,
    required this.colors,
    required this.size,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(icon, color: iconColor, size: size * 0.42),
    );
  }
}

/// Square (or horizontal) card with cover, title and subtitle.
class MediaCard extends StatelessWidget {
  final double width;
  final Widget cover;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool horizontal;

  const MediaCard({
    super.key,
    required this.width,
    required this.cover,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.horizontal = false,
  });

  @override
  Widget build(BuildContext context) {
    final pal = appState.palette;
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFF9EA6AC), fontSize: 13),
          ),
        ],
      ],
    );
    final child = horizontal
        ? LiquidGlassBox(
            borderRadius: BorderRadius.circular(22),
            fallbackColor: pal.surface,
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(width: 72, height: 72, child: cover),
                ),
                const SizedBox(width: 14),
                Expanded(child: texts),
                Container(
                  width: 44,
                  height: 44,
                  decoration:
                      BoxDecoration(color: pal.accent, shape: BoxShape.circle),
                  child: Icon(Icons.play_arrow_rounded, color: pal.onAccent),
                ),
              ],
            ),
          )
        : SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.35),
                        blurRadius: 14,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: SizedBox(width: width, height: width, child: cover),
                  ),
                ),
                const SizedBox(height: 8),
                texts,
              ],
            ),
          );
    return GestureDetector(
      onLongPress: onLongPress,
      child: SquishyGesture(pressedScale: 0.95, onTap: onTap, child: child),
    );
  }
}

/// Small horizontal tile for the home quick-access grid.
class QuickTile extends StatelessWidget {
  final double width;
  final Widget cover;
  final String title;
  final VoidCallback onTap;
  const QuickTile({
    super.key,
    required this.width,
    required this.cover,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = appState.palette;
    return SquishyGesture(
      pressedScale: 0.95,
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: LiquidGlassBox(
          borderRadius: BorderRadius.circular(14),
          fallbackColor: pal.surface,
          child: Row(
            children: [
              ClipRRect(
                borderRadius:
                    const BorderRadius.horizontal(left: Radius.circular(14)),
                child: SizedBox(width: 54, height: 54, child: cover),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Big "continue listening" card on Home for the current song.
class ContinueListeningCard extends StatelessWidget {
  final TrackItem track;
  const ContinueListeningCard({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final pal = appState.palette;
    return SquishyGesture(
      pressedScale: 0.97,
      onTap: () => openPlayer(context),
      child: Container(
        height: 132,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          boxShadow: _shadow,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Transform.scale(
                scale: 1.6,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  child: CustomAlbumArtwork(track: track),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      pal.bg.withOpacity(0.25),
                      pal.bg.withOpacity(0.75),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                        width: 104,
                        height: 104,
                        child: CustomAlbumArtwork(track: track),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'CONTINUE LISTENING',
                            style: TextStyle(
                              color: pal.accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            track.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Color(0xFFD0D5D9), fontSize: 13.5),
                          ),
                        ],
                      ),
                    ),
                    StreamBuilder<PlaybackState>(
                      stream: audioHandler.playbackState,
                      builder: (context, snap) {
                        final playing =
                            (snap.data ?? audioHandler.playbackState.value).playing;
                        return SquishyGesture(
                          onTap: () =>
                              playing ? audioHandler.pause() : audioHandler.play(),
                          child: Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: pal.accent,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: pal.onAccent,
                              size: 30,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Mixes ────────────────────────────────────────────────────────────────────

class Mix {
  final String id;
  final String title;
  final String description;
  final IconData icon;
  final List<TrackItem> tracks;
  final Color color;
  const Mix(this.id, this.title, this.description, this.icon, this.tracks,
      this.color);
}

/// Builds mixes from the library. Shuffles are seeded by the date so a mix
/// stays the same all day and refreshes tomorrow.
List<Mix> buildMixes(List<TrackItem> tracks) {
  if (tracks.isEmpty) return const [];
  final now = DateTime.now();
  final daySeed = now.year * 10000 + now.month * 100 + now.day;
  List<TrackItem> shuffled(List<TrackItem> l, int salt) =>
      [...l]..shuffle(Random(daySeed + salt));
  String artistsLine(List<TrackItem> l) {
    final names = <String>[];
    for (final t in l) {
      if (!names.contains(t.artist) && t.artist != 'Unknown Artist') {
        names.add(t.artist);
      }
      if (names.length == 3) break;
    }
    if (names.isEmpty) return '${l.length} songs';
    return '${names.join(', ')}${l.length > 3 ? ' and more' : ''}';
  }

  final mixes = <Mix>[];
  final daily = shuffled(tracks, 1).take(30).toList();
  mixes.add(Mix('daily', 'Daily Mix', artistsLine(daily),
      Icons.wb_sunny_rounded, daily, const Color(0xFFFFB74D)));

  final liked = tracks.where((t) => appState.isLiked(t.id)).toList();
  if (liked.length >= 2) {
    mixes.add(Mix('liked', 'Favorites Mix', artistsLine(liked),
        Icons.favorite_rounded, shuffled(liked, 2), const Color(0xFFFF6FAE)));
  }

  // Artist mixes: an artist's songs, padded with similar-sized random picks.
  final byArtist = <String, List<TrackItem>>{};
  for (final t in tracks) {
    if (t.artist == 'Unknown Artist' || t.artist.isEmpty) continue;
    byArtist.putIfAbsent(t.artist, () => []).add(t);
  }
  final topArtists = byArtist.entries.where((e) => e.value.length >= 2).toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  const artistColors = [
    Color(0xFF2E9BFF),
    Color(0xFF9BE15D),
    Color(0xFFB79CFF),
    Color(0xFF2EE6C8),
    Color(0xFFFF8A3D),
    Color(0xFFFF4D5E),
  ];
  for (var i = 0; i < topArtists.length && i < 6; i++) {
    final e = topArtists[i];
    final others = shuffled(
            tracks.where((t) => t.artist != e.key).toList(), 10 + i)
        .take(max(5, 20 - e.value.length))
        .toList();
    final list = shuffled([...e.value, ...others], 20 + i);
    mixes.add(Mix('artist_${e.key}', '${e.key} Mix', artistsLine(list),
        Icons.person_rounded, list, artistColors[i % artistColors.length]));
  }

  final yt = tracks.where((t) => t.isYouTube).toList();
  if (yt.length >= 2) {
    mixes.add(Mix('yt', 'YouTube Mix', artistsLine(yt),
        Icons.play_circle_fill_rounded, shuffled(yt, 3), const Color(0xFFFF4D5E)));
  }

  final fresh = tracks.take(25).toList();
  if (fresh.length >= 4) {
    mixes.add(Mix('fresh', 'Fresh Finds', artistsLine(fresh),
        Icons.auto_awesome_rounded, fresh, const Color(0xFF2EE6C8)));
  }

  final discover = shuffled(tracks, 4).reversed.take(25).toList();
  mixes.add(Mix('discover', 'Discover', artistsLine(discover),
      Icons.explore_rounded, discover, const Color(0xFFB79CFF)));
  return mixes;
}

void openMix(BuildContext context, Mix mix) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => MixScreen(mix: mix),
  ));
}

/// 2×2 album-art collage with the mix colour washed over it.
class MixCover extends StatelessWidget {
  final Mix mix;
  final double size;
  final bool showTitle;
  const MixCover(
      {super.key, required this.mix, required this.size, this.showTitle = true});

  @override
  Widget build(BuildContext context) {
    final arts = <TrackItem>[];
    for (final t in mix.tracks) {
      if (arts.length == 4) break;
      if (!arts.any((a) => a.album == t.album && a.artist == t.artist)) {
        arts.add(t);
      }
    }
    final half = size / 2;
    Widget art;
    if (arts.length >= 4) {
      art = Column(
        children: [
          Row(children: [
            SizedBox(width: half, height: half, child: CustomAlbumArtwork(track: arts[0])),
            SizedBox(width: half, height: half, child: CustomAlbumArtwork(track: arts[1])),
          ]),
          Row(children: [
            SizedBox(width: half, height: half, child: CustomAlbumArtwork(track: arts[2])),
            SizedBox(width: half, height: half, child: CustomAlbumArtwork(track: arts[3])),
          ]),
        ],
      );
    } else if (arts.isNotEmpty) {
      art = SizedBox(width: size, height: size, child: CustomAlbumArtwork(track: arts.first));
    } else {
      art = Container(width: size, height: size, color: mix.color);
    }
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          art,
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  mix.color.withOpacity(0.15),
                  mix.color.withOpacity(showTitle ? 0.85 : 0.35),
                ],
              ),
            ),
          ),
          if (showTitle)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(mix.icon, color: Colors.white, size: size * 0.13),
                  const SizedBox(height: 4),
                  Text(
                    mix.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: size * 0.115,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                      shadows: const [Shadow(color: Colors.black54, blurRadius: 8)],
                    ),
                  ),
                ],
              ),
            ),
          if (showTitle)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(height: 5, color: mix.color),
            ),
        ],
      ),
    );
  }
}

class MixCard extends StatelessWidget {
  final Mix mix;
  final double width;
  const MixCard({super.key, required this.mix, required this.width});

  @override
  Widget build(BuildContext context) {
    return MediaCard(
      width: width,
      cover: MixCover(mix: mix, size: width),
      title: mix.title,
      subtitle: mix.description,
      onTap: () => openMix(context, mix),
    );
  }
}

/// Wide featured mix card at the top of the Mixes tab.
class FeaturedMixCard extends StatelessWidget {
  final Mix mix;
  const FeaturedMixCard({super.key, required this.mix});

  @override
  Widget build(BuildContext context) {
    final pal = appState.palette;
    return SquishyGesture(
      pressedScale: 0.97,
      onTap: () => openMix(context, mix),
      child: Container(
        height: 170,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: LinearGradient(
            colors: [mix.color.withOpacity(0.85), pal.playerButton],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: mix.color.withOpacity(0.35),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: MixCover(mix: mix, size: 138, showTitle: false),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'TODAY\'S PICK',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    mix.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    mix.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  SquishyGesture(
                    onTap: () {
                      audioHandler.playYouTubeList(mix.tracks, 0);
                      openPlayer(context);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 9),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.play_arrow_rounded, color: mix.color.withOpacity(1)),
                          const SizedBox(width: 4),
                          const Text(
                            'Play',
                            style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MixScreen extends StatelessWidget {
  final Mix mix;
  const MixScreen({super.key, required this.mix});

  @override
  Widget build(BuildContext context) {
    return _YtPageShell(buildBody: (context) {
      final pal = appState.palette;
      final tracks = mix.tracks;
      return [
        const SizedBox(height: 8),
        Center(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: mix.color.withOpacity(0.4),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: MixCover(mix: mix, size: 220),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          mix.description,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFFA6ADB2), fontSize: 14),
        ),
        const SizedBox(height: 4),
        Text(
          '${tracks.length} songs • refreshes daily',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white38, fontSize: 12.5),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _ytPlayButton(pal, 'Play', () {
              audioHandler.setShuffleMode(AudioServiceShuffleMode.none);
              audioHandler.playYouTubeList(tracks, 0);
              openPlayer(context);
            }),
            const SizedBox(width: 10),
            SquishyGesture(
              onTap: () {
                audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
                audioHandler.playYouTubeList(
                    tracks, Random().nextInt(tracks.length));
                openPlayer(context);
              },
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: pal.container,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.shuffle_rounded, color: pal.accent),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < tracks.length; i++)
          TrackRow(
            track: tracks[i],
            palette: pal,
            active: audioHandler.currentTrack?.id == tracks[i].id,
            onTap: () {
              audioHandler.playYouTubeList(tracks, i);
              openPlayer(context);
            },
            onMore: () => tracks[i].isYouTube
                ? showYtAddToPlaylist(context, tracks[i])
                : showAddToPlaylistSheet(context, tracks[i]),
          ),
      ];
    });
  }
}

final List<BoxShadow> _shadow = [
  BoxShadow(
    color: Colors.black.withOpacity(0.45),
    blurRadius: 16,
    offset: const Offset(0, 6),
  ),
];

// ─────────────────────────────────────────────────────────────────────────────
// Dedicated Liked Songs Screen
// ─────────────────────────────────────────────────────────────────────────────

class LikedSongsScreen extends StatelessWidget {
  const LikedSongsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        appState,
        audioHandler.libraryRevision,
        audioHandler.currentIndex,
      ]),
      builder: (context, _) {
        final pal = appState.palette;
        final allTracks = audioHandler.tracks;
        final likedTracks =
            allTracks.where((t) => appState.isLiked(t.id)).toList();

        return Scaffold(
          backgroundColor: pal.bg,
          body: Stack(
            children: [
              AuroraPlasmaBackground(
                accent: pal.accent,
                secondary: const Color(0xFFF09CE2),
                intense: true,
              ),
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                      child: Row(
                        children: [
                          SquishyGesture(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: pal.surface,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.arrow_back_rounded,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (likedTracks.isNotEmpty)
                            SquishyGesture(
                              onTap: () {
                                audioHandler.setShuffleMode(
                                  AudioServiceShuffleMode.all,
                                );
                                final pick = likedTracks[
                                    Random().nextInt(likedTracks.length)];
                                final idx = allTracks.indexOf(pick);
                                if (idx >= 0) playAndOpen(context, idx);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 9,
                                ),
                                decoration: BoxDecoration(
                                  color: pal.container,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.shuffle_rounded,
                                      color: pal.accent,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Shuffle',
                                      style: TextStyle(
                                        color: pal.accent,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 104,
                            height: 104,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [pal.accent, pal.container],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(25),
                            ),
                            child: Icon(
                              Icons.favorite_rounded,
                              color: pal.onAccent,
                              size: 48,
                            ),
                          ),
                          const SizedBox(width: 18),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Liked Songs',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.4,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${likedTracks.length} ${likedTracks.length == 1 ? 'song' : 'songs'} saved',
                                  style: const TextStyle(
                                    color: Color(0xFFA6ADB2),
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                if (likedTracks.isNotEmpty)
                                  SquishyGesture(
                                    onTap: () {
                                      final idx =
                                          allTracks.indexOf(likedTracks.first);
                                      if (idx >= 0) playAndOpen(context, idx);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 9,
                                      ),
                                      decoration: BoxDecoration(
                                        color: pal.accent,
                                        borderRadius: BorderRadius.circular(24),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.play_arrow_rounded,
                                            color: pal.onAccent,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Play Liked',
                                            style: TextStyle(
                                              color: pal.onAccent,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(color: Colors.white12, height: 20),
                    Expanded(
                      child: likedTracks.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.favorite_border_rounded,
                                    size: 54,
                                    color: pal.accent.withOpacity(0.6),
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'No liked songs yet',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Tap the heart icon on any track to add it to Liked Songs.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                4,
                                16,
                                40,
                              ),
                              itemCount: likedTracks.length,
                              itemBuilder: (context, i) {
                                final t = likedTracks[i];
                                final idx = allTracks.indexOf(t);
                                return TrackRow(
                                  track: t,
                                  palette: pal,
                                  active: audioHandler.currentTrack?.id == t.id,
                                  onTap: () => playAndOpen(context, idx),
                                  onMore: () => showAddToPlaylistSheet(context, t),
                                );
                              },
                            ),
                    ),
                  ],
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
// Playlist Cover & Full Playlist Detail Screen
// ─────────────────────────────────────────────────────────────────────────────

class PlaylistCoverThumbnail extends StatelessWidget {
  final Playlist playlist;
  final double size;

  const PlaylistCoverThumbnail({
    super.key,
    required this.playlist,
    this.size = 60,
  });

  @override
  Widget build(BuildContext context) {
    final pal = appState.palette;
    final cover = playlist.cover;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.file(
          File(cover),
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    }
    TrackItem? firstTrack;
    if (playlist.trackIds.isNotEmpty) {
      firstTrack = audioHandler.trackById(playlist.trackIds.first);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: SizedBox(
        width: size,
        height: size,
        child: firstTrack != null
            ? CustomAlbumArtwork(track: firstTrack)
            : Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [pal.accent, pal.container],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Icon(
                  Icons.queue_music_rounded,
                  color: pal.onAccent,
                  size: size * 0.48,
                ),
              ),
      ),
    );
  }
}

class PlaylistDetailScreen extends StatelessWidget {
  final String playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        appState,
        audioHandler.libraryRevision,
        audioHandler.currentIndex,
      ]),
      builder: (context, _) {
        final pal = appState.palette;
        final pl = appState.playlistById(playlistId);
        if (pl == null) {
          return Scaffold(
            backgroundColor: pal.bg,
            body: const Center(child: Text('Playlist deleted')),
          );
        }

        final resolvedTracks = <TrackItem>[];
        for (final id in pl.trackIds) {
          final t = audioHandler.trackById(id);
          if (t != null) resolvedTracks.add(t);
        }

        return Scaffold(
          backgroundColor: pal.bg,
          body: Stack(
            children: [
              AuroraPlasmaBackground(
                accent: pal.accent,
                secondary: const Color(0xFF8CD0F0),
                intense: true,
              ),
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                      child: Row(
                        children: [
                          SquishyGesture(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: pal.surface,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.arrow_back_rounded,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const Spacer(),
                          SquishyGesture(
                            onTap: () => showAddTracksToPlaylistPicker(
                              context,
                              pl,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: pal.container,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.playlist_add_rounded,
                                    color: pal.accent,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Add Songs',
                                    style: TextStyle(
                                      color: pal.accent,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SquishyGesture(
                            onTap: () => showCreateOrEditPlaylistDialog(
                              context,
                              existing: pl,
                            ),
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: pal.surface,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.edit_rounded,
                                color: pal.accent,
                                size: 20,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SquishyGesture(
                            onTap: () {
                              appState.deletePlaylist(pl.id);
                              Navigator.pop(context);
                            },
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: pal.surface,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.delete_outline_rounded,
                                color: Colors.redAccent,
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          SquishyGesture(
                            onTap: () => showCreateOrEditPlaylistDialog(
                              context,
                              existing: pl,
                            ),
                            child: Stack(
                              alignment: Alignment.bottomRight,
                              children: [
                                PlaylistCoverThumbnail(playlist: pl, size: 104),
                                Container(
                                  margin: const EdgeInsets.all(6),
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.7),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.photo_library_rounded,
                                    color: pal.accent,
                                    size: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 18),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  pl.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.4,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${resolvedTracks.length} songs • Drag handle to sort order',
                                  style: const TextStyle(
                                    color: Color(0xFFA6ADB2),
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                if (resolvedTracks.isNotEmpty)
                                  SquishyGesture(
                                    onTap: () {
                                      audioHandler.playTrackById(
                                        resolvedTracks.first.id,
                                      );
                                      openPlayer(context);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 9,
                                      ),
                                      decoration: BoxDecoration(
                                        color: pal.accent,
                                        borderRadius: BorderRadius.circular(24),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.play_arrow_rounded,
                                            color: pal.onAccent,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Play Playlist',
                                            style: TextStyle(
                                              color: pal.onAccent,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(color: Colors.white12, height: 20),
                    Expanded(
                      child: resolvedTracks.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.queue_music_rounded,
                                    size: 54,
                                    color: pal.accent.withOpacity(0.6),
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'Playlist is empty',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Tap "Add Songs" above or use the 3-dot menu in Now Playing.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ReorderableListView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                4,
                                16,
                                40,
                              ),
                              buildDefaultDragHandles: false,
                              itemCount: resolvedTracks.length,
                              onReorder: (oldIndex, newIndex) {
                                if (newIndex > oldIndex) newIndex -= 1;
                                HapticFeedback.mediumImpact();
                                appState.movePlaylistTrack(
                                  pl.id,
                                  oldIndex,
                                  newIndex,
                                );
                              },
                              itemBuilder: (context, i) {
                                final t = resolvedTracks[i];
                                final active =
                                    audioHandler.currentTrack?.id == t.id;
                                return Container(
                                  key: ValueKey('pl_${pl.id}_${t.id}'),
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: pal.surface.withOpacity(
                                      appState.liquidGlass ? 0.55 : 1.0,
                                    ),
                                    borderRadius: BorderRadius.circular(18),
                                    border: appState.liquidGlass
                                        ? Border.all(
                                            color: Colors.white.withOpacity(
                                              0.12,
                                            ),
                                          )
                                        : null,
                                  ),
                                  child: Row(
                                    children: [
                                      ReorderableDragStartListener(
                                        index: i,
                                        child: const Padding(
                                          padding: EdgeInsets.only(right: 10),
                                          child: Icon(
                                            Icons.drag_indicator_rounded,
                                            color: Colors.white54,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () {
                                            audioHandler.playTrackById(t.id);
                                            openPlayer(context);
                                          },
                                          child: Row(
                                            children: [
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                child: SizedBox(
                                                  width: 48,
                                                  height: 48,
                                                  child: CustomAlbumArtwork(
                                                    track: t,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      t.title,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: active
                                                            ? pal.accent
                                                            : Colors.white,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 15.5,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      t.artist,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        color:
                                                            Color(0xFFA6ADB2),
                                                        fontSize: 13,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      PopupMenuButton<String>(
                                        icon: const Icon(
                                          Icons.more_vert_rounded,
                                          color: Colors.white70,
                                        ),
                                        color: pal.surface,
                                        onSelected: (action) {
                                          if (action == 'first') {
                                            appState.movePlaylistTrack(
                                              pl.id,
                                              i,
                                              0,
                                            );
                                          } else if (action == 'last') {
                                            appState.movePlaylistTrack(
                                              pl.id,
                                              i,
                                              resolvedTracks.length - 1,
                                            );
                                          } else if (action == 'remove') {
                                            appState.removeFromPlaylist(
                                              pl.id,
                                              t.id,
                                            );
                                          }
                                        },
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                            value: 'first',
                                            child: Text(
                                              'Move to First',
                                              style: TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                          PopupMenuItem(
                                            value: 'last',
                                            child: Text(
                                              'Move to Last',
                                              style: TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                          PopupMenuItem(
                                            value: 'remove',
                                            child: Text(
                                              'Remove from Playlist',
                                              style: TextStyle(
                                                color: Colors.redAccent,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
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
// Reusable animations & interactive widgets
// ─────────────────────────────────────────────────────────────────────────────

const Curve kEmphasized = Cubic(0.2, 0.0, 0.0, 1.0);
const Curve kEmphasizedDecel = Cubic(0.05, 0.7, 0.1, 1.0);
const Curve kEmphasizedAccel = Cubic(0.3, 0.0, 0.8, 0.15);

class Reveal extends StatelessWidget {
  final int delayMs;
  final double dy;
  final Widget child;

  const Reveal({
    super.key,
    this.delayMs = 0,
    this.dy = 22,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final total = 480 + delayMs;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delayMs / total, 1.0, curve: kEmphasizedDecel),
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0).toDouble(),
        child: Transform.translate(
          offset: Offset(0, (1 - t) * dy),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class Interactive3DArtwork extends StatefulWidget {
  final TrackItem track;
  final bool playing;

  const Interactive3DArtwork({
    super.key,
    required this.track,
    required this.playing,
  });

  @override
  State<Interactive3DArtwork> createState() => _Interactive3DArtworkState();
}

/// Album art face: vinyl spin mode + double-tap to toggle it. (Dragging no
/// longer tilts the art; horizontal swipes belong to the carousel and vertical
/// swipes to swipe-down-to-close.)
class _Interactive3DArtworkState extends State<Interactive3DArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spinCtrl;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    if (widget.playing) _spinCtrl.repeat();
  }

  @override
  void didUpdateWidget(covariant Interactive3DArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !_spinCtrl.isAnimating) {
      _spinCtrl.repeat();
    } else if (!widget.playing && _spinCtrl.isAnimating) {
      _spinCtrl.stop();
    }
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spinMode = appState.vinylSpinMode;
    return GestureDetector(
      onDoubleTap: () {
        HapticFeedback.mediumImpact();
        appState.setVinylSpinMode(!spinMode);
      },
      child: AnimatedBuilder(
        animation: _spinCtrl,
        builder: (context, artChild) {
          if (!spinMode) return artChild!;
          return Transform.rotate(
            angle: _spinCtrl.value * 2 * pi,
            child: ClipOval(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  artChild!,
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.82),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white38, width: 2),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
        child: CustomAlbumArtwork(track: widget.track),
      ),
    );
  }
}

/// Swipeable album-art carousel for Now Playing.
///
/// By default swiping RIGHT plays the next song and swiping LEFT the previous
/// one (Settings can flip this). The art follows your finger, the neighbouring
/// song's art slides in, and skips from the buttons/notification animate too.
class SwipeArtCarousel extends StatefulWidget {
  final TrackItem track;
  final bool playing;
  final double radius;

  const SwipeArtCarousel({
    super.key,
    required this.track,
    required this.playing,
    required this.radius,
  });

  @override
  State<SwipeArtCarousel> createState() => _SwipeArtCarouselState();
}

class _SwipeArtCarouselState extends State<SwipeArtCarousel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dx; // horizontal offset in pixels
  double _width = 1;
  bool _busy = false;
  // Which side the *incoming* art comes from during a programmatic change.
  String? _lastTrackId;
  TrackItem? _outgoing;
  double _outgoingSide = 0; // -1 = left, +1 = right

  @override
  void initState() {
    super.initState();
    _dx = AnimationController.unbounded(vsync: this, value: 0);
    _lastTrackId = widget.track.id;
  }

  @override
  void didUpdateWidget(covariant SwipeArtCarousel old) {
    super.didUpdateWidget(old);
    final newId = widget.track.id;
    if (newId != _lastTrackId) {
      final prevTrack = old.track;
      _lastTrackId = newId;
      if (!_busy) {
        // Changed from a button / notification / auto-advance: slide it in.
        // "Next" content enters from the side a next-swipe pulls from.
        final forward = !_wasPrevious(prevTrack, widget.track);
        final nextFromLeft = appState.swipeRightForNext;
        final enterSide = forward
            ? (nextFromLeft ? -1.0 : 1.0)
            : (nextFromLeft ? 1.0 : -1.0);
        _outgoing = prevTrack;
        _outgoingSide = -enterSide;
        _dx.value = enterSide * _width;
        _springTo(0).whenComplete(() {
          if (mounted) setState(() => _outgoing = null);
        });
      }
    }
  }

  bool _wasPrevious(TrackItem from, TrackItem to) {
    final tracks = audioHandler.tracks;
    final a = tracks.indexWhere((t) => t.id == from.id);
    final b = tracks.indexWhere((t) => t.id == to.id);
    if (a < 0 || b < 0) return false;
    return b == a - 1 || (a == 0 && b == tracks.length - 1 && tracks.length > 2);
  }

  @override
  void dispose() {
    _dx.dispose();
    super.dispose();
  }

  TickerFuture _springTo(double target, [double velocity = 0]) {
    return _dx.animateWith(SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 420, damping: 34),
      _dx.value,
      target,
      velocity,
    ));
  }

  void _onUpdate(DragUpdateDetails d) {
    if (_busy) return;
    _outgoing = null;
    _dx.value += d.delta.dx;
  }

  Future<void> _onEnd(DragEndDetails d) async {
    if (_busy) return;
    final v = d.velocity.pixelsPerSecond.dx;
    final x = _dx.value;
    final commit = x.abs() > _width * 0.22 || v.abs() > 650;
    if (!commit || x == 0) {
      _springTo(0, v);
      return;
    }
    final dir = x > 0 ? 1.0 : -1.0; // +1 = finger moved right
    final goNext = appState.swipeRightForNext ? dir > 0 : dir < 0;
    _busy = true;
    HapticFeedback.selectionClick();
    // Fly the current art out the way it was thrown...
    await _dx.animateTo(
      dir * _width,
      duration: const Duration(milliseconds: 170),
      curve: Curves.easeOutCubic,
    );
    // ...then bring the new song in from the opposite side.
    _lastTrackId = null; // let didUpdateWidget accept the change silently
    if (goNext) {
      audioHandler.skipToNext();
    } else {
      audioHandler.skipToPreviousTrack();
    }
    _dx.value = -dir * _width;
    await _springTo(0);
    _busy = false;
    if (mounted) _lastTrackId = widget.track.id;
  }

  Widget _face(TrackItem t, {bool live = false}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: live
          ? Interactive3DArtwork(track: t, playing: widget.playing)
          : CustomAlbumArtwork(track: t),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _width = c.maxWidth + 24;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: _onUpdate,
        onHorizontalDragEnd: _onEnd,
        onHorizontalDragCancel: () => _springTo(0),
        child: AnimatedBuilder(
          animation: _dx,
          builder: (context, _) {
            final x = _dx.value;
            final p = (x.abs() / _width).clamp(0.0, 1.0).toDouble();
            // Neighbour revealed while dragging (swipe direction decides which).
            TrackItem? neighbour;
            double neighbourSide = 0;
            if (_outgoing != null) {
              neighbour = _outgoing;
              neighbourSide = _outgoingSide;
            } else if (x != 0 && !_busy) {
              final fingerRight = x > 0;
              final wantsNext = appState.swipeRightForNext ? fingerRight : !fingerRight;
              neighbour = wantsNext
                  ? audioHandler.peekNext
                  : audioHandler.peekPrevious;
              neighbourSide = fingerRight ? -1 : 1;
            }
            return Stack(
              clipBehavior: Clip.none,
              children: [
                if (neighbour != null)
                  Positioned.fill(
                    child: Transform.translate(
                      offset: Offset(x + neighbourSide * _width, 0),
                      child: Opacity(
                        opacity: (0.35 + 0.65 * p).clamp(0.0, 1.0).toDouble(),
                        child: _face(neighbour),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: Transform.translate(
                    offset: Offset(x, 0),
                    child: Transform.rotate(
                      angle: (x / _width) * 0.12,
                      child: Transform.scale(
                        scale: 1 - 0.08 * p,
                        child: _face(widget.track, live: true),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
    });
  }
}

class EqBars extends StatefulWidget {
  final Color color;
  const EqBars({super.key, required this.color});

  @override
  State<EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<EqBars> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: audioHandler.player.playingStream,
      initialData: audioHandler.player.playing,
      builder: (context, snap) {
        final playing = snap.data ?? false;
        return AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            return SizedBox(
              width: 22,
              height: 20,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(3, (i) {
                  final h = playing
                      ? 5 + 15 * (0.5 + 0.5 * sin(2 * pi * (_c.value + i / 3)))
                      : 5.0;
                  return Container(
                    width: 4.5,
                    height: h,
                    decoration: BoxDecoration(
                      color: widget.color,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  );
                }),
              ),
            );
          },
        );
      },
    );
  }
}

class ThemeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final List<Color> swatch;
  final Color accent;
  final Color onAccent;
  final VoidCallback onTap;

  const ThemeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.swatch,
    required this.accent,
    required this.onAccent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = appState.palette;
    return SquishyGesture(
      pressedScale: 0.92,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: kEmphasized,
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
        decoration: BoxDecoration(
          color: selected ? accent : pal.container,
          borderRadius: BorderRadius.circular(22),
          boxShadow: selected
              ? [BoxShadow(color: accent.withOpacity(0.45), blurRadius: 14)]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white38, width: 1),
                gradient: SweepGradient(colors: [...swatch, swatch.first]),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: selected ? onAccent : Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Blurred, slowly drifting album art behind the Now Playing screen.
/// Cross-fades when the song changes.
class AlbumArtBackdrop extends StatefulWidget {
  final TrackItem track;
  const AlbumArtBackdrop({super.key, required this.track});

  @override
  State<AlbumArtBackdrop> createState() => _AlbumArtBackdropState();
}

class _AlbumArtBackdropState extends State<AlbumArtBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift;

  @override
  void initState() {
    super.initState();
    _drift = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    )..repeat();
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = appState.palette;
    return IgnorePointer(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 800),
              switchInCurve: Curves.easeOut,
              child: AnimatedBuilder(
                key: ValueKey(widget.track.id),
                animation: _drift,
                builder: (context, child) {
                  final a = _drift.value * 2 * pi;
                  return Transform.translate(
                    offset: Offset(18 * cos(a), 24 * sin(a)),
                    child: Transform.scale(
                      scale: 1.45 + 0.05 * sin(a * 2),
                      child: child,
                    ),
                  );
                },
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 46, sigmaY: 46),
                  child: CustomAlbumArtwork(track: widget.track),
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    pal.playerBg.withOpacity(0.35),
                    pal.playerBg.withOpacity(0.55),
                    pal.playerBg.withOpacity(0.92),
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SwipeDownDismiss extends StatefulWidget {
  final Widget child;
  const SwipeDownDismiss({super.key, required this.child});

  @override
  State<SwipeDownDismiss> createState() => _SwipeDownDismissState();
}

class _SwipeDownDismissState extends State<SwipeDownDismiss>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _c = AnimationController.unbounded(vsync: this, value: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    if (_dismissing) return;
    _c.value = (_c.value + d.delta.dy).clamp(-24.0, double.infinity).toDouble();
  }

  void _springBack(double velocity) {
    _c.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 320, damping: 26),
        _c.value,
        0,
        velocity,
      ),
    );
  }

  void _end(DragEndDetails d) {
    if (_dismissing) return;
    final v = d.velocity.pixelsPerSecond.dy;
    final h = MediaQuery.of(context).size.height;
    if (_c.value > h * 0.08 || v > 450) {
      HapticFeedback.lightImpact();
      setState(() => _dismissing = true);
      _c
          .animateTo(
            h,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeInCubic,
          )
          .whenComplete(() {
        if (mounted) Navigator.of(context).pop();
      });
    } else {
      _springBack(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragUpdate: _update,
      onVerticalDragEnd: _end,
      onVerticalDragCancel: () => _springBack(0),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final h = MediaQuery.of(context).size.height;
          final p = (_c.value / h).clamp(0.0, 1.0).toDouble();
          return Transform.translate(
            offset: Offset(0, _c.value),
            child: Transform.scale(
              scale: 1 - 0.05 * p,
              alignment: Alignment.topCenter,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(min(1.0, p * 8) * 36),
                child: child,
              ),
            ),
          );
        },
        child: HeroMode(enabled: !_dismissing, child: widget.child),
      ),
    );
  }
}

Widget _artShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromContext,
  BuildContext toContext,
) {
  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final t = direction == HeroFlightDirection.push
          ? animation.value
          : 1 - animation.value;
      final track = audioHandler.currentTrack;
      return ClipRRect(
        borderRadius: BorderRadius.circular(18 + 10 * t),
        child:
            track == null ? const SizedBox() : CustomAlbumArtwork(track: track),
      );
    },
  );
}

RectTween _arcTween(Rect? begin, Rect? end) =>
    MaterialRectArcTween(begin: begin, end: end);

class SquishyGesture extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;

  const SquishyGesture({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.88,
  });

  @override
  State<SquishyGesture> createState() => _SquishyGestureState();
}

class _SquishyGestureState extends State<SquishyGesture>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  DateTime _downAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _c = AnimationController.unbounded(vsync: this, value: 1.0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down() {
    _downAt = DateTime.now();
    _c.animateTo(
      widget.pressedScale,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
    );
  }

  void _release() {
    if (!mounted) return;
    _c.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 380, damping: 13),
        _c.value,
        1.0,
        0.0,
      ),
    );
  }

  void _up() {
    final elapsed = DateTime.now().difference(_downAt).inMilliseconds;
    final wait = max(0, 90 - elapsed);
    if (wait == 0) {
      _release();
    } else {
      Future.delayed(Duration(milliseconds: wait), _release);
    }
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
        animation: _c,
        builder: (context, child) => Transform.scale(
          scale: _c.value.clamp(0.5, 1.15).toDouble(),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

class TrackRow extends StatelessWidget {
  final TrackItem track;
  final AppPalette palette;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onMore;

  const TrackRow({
    super.key,
    required this.track,
    required this.palette,
    required this.active,
    required this.onTap,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return SquishyGesture(
      pressedScale: 0.97,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 54,
                height: 54,
                child: CustomAlbumArtwork(track: track),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? palette.accent : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFA6ADB2),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            if (active)
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 4),
                child: EqBars(color: palette.accent),
              ),
            if (onMore != null)
              SquishyGesture(
                onTap: onMore,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(
                    Icons.more_vert_rounded,
                    color: Colors.white54,
                    size: 20,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class TrackProgress extends StatelessWidget {
  final int fallbackSeconds;
  final Widget Function(
    BuildContext context,
    Duration position,
    Duration duration,
  ) builder;

  const TrackProgress({
    super.key,
    required this.fallbackSeconds,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    final player = audioHandler.player;
    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      initialData: player.duration,
      builder: (context, durSnap) {
        final dur = durSnap.data ?? Duration(seconds: fallbackSeconds);
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          initialData: player.position,
          builder: (context, posSnap) {
            return builder(context, posSnap.data ?? Duration.zero, dur);
          },
        );
      },
    );
  }
}

/// Mini player: tap or swipe up to open Now Playing; swipe sideways to skip
/// (same direction setting as the album-art carousel: by default swipe right
/// = next, swipe left = previous).
class MiniPlayer extends StatefulWidget {
  final TrackItem track;
  final AppPalette palette;

  const MiniPlayer({super.key, required this.track, required this.palette});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dx =
      AnimationController.unbounded(vsync: this, value: 0);
  double _dy = 0;
  double _w = 360;
  bool _busy = false;

  @override
  void dispose() {
    _dx.dispose();
    super.dispose();
  }

  TickerFuture _spring(double to, [double v = 0]) => _dx.animateWith(
        SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 500, damping: 36),
          _dx.value,
          to,
          v,
        ),
      );

  Future<void> _endHorizontal(DragEndDetails d) async {
    if (_busy) return;
    final w = _w;
    final v = d.velocity.pixelsPerSecond.dx;
    final x = _dx.value;
    if (x.abs() < w * 0.2 && v.abs() < 500) {
      _spring(0, v);
      return;
    }
    final dir = (x != 0 ? x : v) > 0 ? 1.0 : -1.0;
    final goNext = appState.swipeRightForNext ? dir > 0 : dir < 0;
    _busy = true;
    HapticFeedback.selectionClick();
    await _dx.animateTo(dir * w,
        duration: const Duration(milliseconds: 150), curve: Curves.easeIn);
    if (goNext) {
      audioHandler.skipToNext();
    } else {
      audioHandler.skipToPreviousTrack();
    }
    _dx.value = -dir * w;
    await _spring(0);
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth.isFinite) _w = c.maxWidth;
      return _gestures(context);
    });
  }

  Widget _gestures(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        if (!_busy) _dx.value += d.delta.dx;
      },
      onHorizontalDragEnd: _endHorizontal,
      onHorizontalDragCancel: () => _spring(0),
      onVerticalDragStart: (_) => _dy = 0,
      onVerticalDragUpdate: (d) => _dy += d.delta.dy,
      onVerticalDragEnd: (d) {
        if (_dy < -24 || d.velocity.pixelsPerSecond.dy < -300) {
          HapticFeedback.lightImpact();
          openPlayer(context);
        }
      },
      child: AnimatedBuilder(
        animation: _dx,
        builder: (context, child) {
          final p = (_dx.value.abs() / _w).clamp(0.0, 1.0).toDouble();
          return Transform.translate(
            offset: Offset(_dx.value, 0),
            child: Opacity(opacity: 1 - 0.6 * p, child: child),
          );
        },
        child: _content(context),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final track = widget.track;
    final palette = widget.palette;
    return SquishyGesture(
      pressedScale: 0.97,
      onTap: () => openPlayer(context),
      child: LiquidGlassBox(
        borderRadius: BorderRadius.circular(34),
        fallbackColor: palette.surface,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        boxShadow: _shadow,
        child: SizedBox(
          height: 66,
          child: Row(
            children: [
              SizedBox(
                width: 46,
                height: 46,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    TrackProgress(
                      fallbackSeconds: track.durationSeconds,
                      builder: (_, pos, dur) {
                        final v = dur.inMilliseconds > 0
                            ? (pos.inMilliseconds / dur.inMilliseconds)
                                .clamp(0.0, 1.0)
                            : 0.0;
                        return SizedBox(
                          width: 46,
                          height: 46,
                          child: CircularProgressIndicator(
                            value: v,
                            strokeWidth: 2.6,
                            backgroundColor: const Color(0xFF2E373D),
                            valueColor:
                                AlwaysStoppedAnimation<Color>(palette.accent),
                          ),
                        );
                      },
                    ),
                    Hero(
                      tag: 'now_playing_art',
                      createRectTween: _arcTween,
                      flightShuttleBuilder: _artShuttle,
                      child: ClipOval(
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: CustomAlbumArtwork(track: track),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFB3B9BE),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              SquishyGesture(
                onTap: () => appState.toggleLike(track.id),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: palette.container,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    appState.isLiked(track.id)
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: appState.isLiked(track.id)
                        ? palette.accent
                        : const Color(0xFFD5DCE0),
                    size: 21,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              StreamBuilder<PlaybackState>(
                stream: audioHandler.playbackState,
                builder: (context, snap) {
                  final playing =
                      (snap.data ?? audioHandler.playbackState.value).playing;
                  return SquishyGesture(
                    onTap: () =>
                        playing ? audioHandler.pause() : audioHandler.play(),
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: palette.accent,
                        shape: BoxShape.circle,
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (c, a) => ScaleTransition(
                          scale: a,
                          child: FadeTransition(opacity: a, child: c),
                        ),
                        child: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          key: ValueKey(playing),
                          color: palette.onAccent,
                          size: 26,
                        ),
                      ),
                    ),
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
// Now Playing
// ─────────────────────────────────────────────────────────────────────────────

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        appState,
        audioHandler.libraryRevision,
        audioHandler.currentIndex,
      ]),
      builder: (context, _) {
        final pal = appState.palette;
        final track = audioHandler.currentTrack;
        if (track == null) {
          return Scaffold(backgroundColor: pal.playerBg);
        }
        return StreamBuilder<PlaybackState>(
          stream: audioHandler.playbackState,
          builder: (context, snap) {
            final state = snap.data ?? audioHandler.playbackState.value;
            final playing = state.playing;
            final loading =
                state.processingState == AudioProcessingState.loading;
            final shuffle = state.shuffleMode == AudioServiceShuffleMode.all;
            final repeat = state.repeatMode;
            final liked = appState.isLiked(track.id);

            return SwipeDownDismiss(
              child: Scaffold(
                backgroundColor: pal.playerBg,
                body: Stack(
                  children: [
                    if (appState.artBackdrop)
                      Positioned.fill(child: AlbumArtBackdrop(track: track)),
                    AuroraPlasmaBackground(
                      accent: pal.accent,
                      secondary: track.artColors.first,
                      intense: true,
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                SquishyGesture(
                                  onTap: () => Navigator.of(context).pop(),
                                  child: LiquidGlassBox(
                                    borderRadius: BorderRadius.circular(23),
                                    fallbackColor: pal.playerSurface,
                                    child: const SizedBox(
                                      width: 46,
                                      height: 46,
                                      child: Icon(
                                        Icons.keyboard_arrow_down_rounded,
                                        color: Colors.white,
                                        size: 28,
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: Column(
                                      children: [
                                        const Text(
                                          'NOW PLAYING',
                                          style: TextStyle(
                                            color: Color(0xFFE5DDD9),
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 1.0,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          track.album,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 15.5,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                SquishyGesture(
                                  onTap: () =>
                                      showEditTrackDialog(context, track),
                                  child: LiquidGlassBox(
                                    borderRadius: BorderRadius.circular(16),
                                    fallbackColor: pal.playerSurface,
                                    child: const SizedBox(
                                      width: 44,
                                      height: 44,
                                      child: Icon(
                                        Icons.edit_rounded,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SquishyGesture(
                                  onTap: () =>
                                      showAddToPlaylistSheet(context, track),
                                  child: LiquidGlassBox(
                                    borderRadius: BorderRadius.circular(16),
                                    fallbackColor: pal.playerSurface,
                                    child: const SizedBox(
                                      width: 44,
                                      height: 44,
                                      child: Icon(
                                        Icons.more_vert_rounded,
                                        color: Colors.white,
                                        size: 22,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                child: Center(
                                  child: AspectRatio(
                                    aspectRatio: 1.0,
                                    child: AnimatedScale(
                                      scale: playing ? 1.0 : 0.91,
                                      duration: const Duration(
                                        milliseconds: 450,
                                      ),
                                      curve: Curves.easeOutBack,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            appState.vinylSpinMode ? 999 : 28,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(
                                                0.55,
                                              ),
                                              blurRadius: 24,
                                              offset: const Offset(0, 12),
                                            ),
                                          ],
                                        ),
                                        child: Hero(
                                          tag: 'now_playing_art',
                                          createRectTween: _arcTween,
                                          flightShuttleBuilder: _artShuttle,
                                          child: SwipeArtCarousel(
                                            track: track,
                                            playing: playing,
                                            radius: appState.vinylSpinMode
                                                ? 999
                                                : 28,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Reveal(
                              delayMs: 100,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: AnimatedSwitcher(
                                      duration:
                                          const Duration(milliseconds: 380),
                                      switchInCurve: kEmphasizedDecel,
                                      switchOutCurve: Curves.easeIn,
                                      layoutBuilder: (current, previous) =>
                                          Stack(
                                        alignment: Alignment.centerLeft,
                                        children: [
                                          ...previous,
                                          if (current != null) current,
                                        ],
                                      ),
                                      transitionBuilder: (c, a) =>
                                          FadeTransition(
                                        opacity: a,
                                        child: SlideTransition(
                                          position: Tween<Offset>(
                                            begin: const Offset(0, 0.35),
                                            end: Offset.zero,
                                          ).animate(a),
                                          child: c,
                                        ),
                                      ),
                                      child: Column(
                                      key: ValueKey('title_${track.id}'),
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          track.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 24,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.4,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          track.artist,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Color(0xFFC8BDB7),
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  if (appState.speed != 1.0 ||
                                      appState.pitch != 1.0)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: SquishyGesture(
                                        onTap: () => showPlaybackSheet(context),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: pal.accent.withOpacity(0.2),
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                            border: Border.all(
                                              color: pal.accent,
                                            ),
                                          ),
                                          child: Text(
                                            '${appState.speed.toStringAsFixed(2)}x • ${appState.pitch.toStringAsFixed(2)}p',
                                            style: TextStyle(
                                              color: pal.accent,
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  SquishyGesture(
                                    onTap: () => appState.toggleLike(track.id),
                                    child: LiquidGlassBox(
                                      borderRadius: BorderRadius.circular(26),
                                      fallbackColor: pal.playerSurface,
                                      child: SizedBox(
                                        width: 52,
                                        height: 52,
                                        child: AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 520,
                                          ),
                                          switchInCurve: Curves.elasticOut,
                                          transitionBuilder: (c, a) =>
                                              ScaleTransition(
                                            scale: a,
                                            child: c,
                                          ),
                                          child: Icon(
                                            liked
                                                ? Icons.favorite_rounded
                                                : Icons.favorite_border_rounded,
                                            key: ValueKey(liked),
                                            color: liked
                                                ? pal.accent
                                                : const Color(0xFFEAE0DC),
                                            size: 24,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            Reveal(
                              delayMs: 160,
                              child: WavySeekBar(
                                fallbackSeconds: track.durationSeconds,
                                active: pal.accent,
                                playing: playing,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Reveal(
                              delayMs: 220,
                              child: Row(
                                children: [
                                  SquishyGesture(
                                    onTap: audioHandler.skipToPrevious,
                                    child: LiquidGlassBox(
                                      borderRadius: BorderRadius.circular(35),
                                      fallbackColor: pal.playerButton,
                                      child: const SizedBox(
                                        width: 88,
                                        height: 70,
                                        child: Icon(
                                          Icons.skip_previous_rounded,
                                          color: Color(0xFFF6E6DF),
                                          size: 32,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: SquishyGesture(
                                      pressedScale: 0.94,
                                      onTap: () => playing
                                          ? audioHandler.pause()
                                          : audioHandler.play(),
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 450,
                                        ),
                                        curve: kEmphasized,
                                        height: 70,
                                        decoration: BoxDecoration(
                                          color: pal.accent,
                                          borderRadius: BorderRadius.circular(
                                            playing ? 22 : 35,
                                          ),
                                        ),
                                        child: loading
                                            ? Center(
                                                child: SizedBox(
                                                  width: 26,
                                                  height: 26,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 3,
                                                    color: pal.onAccent,
                                                  ),
                                                ),
                                              )
                                            : AnimatedSwitcher(
                                                duration: const Duration(
                                                  milliseconds: 200,
                                                ),
                                                transitionBuilder: (c, a) =>
                                                    ScaleTransition(
                                                  scale: a,
                                                  child: FadeTransition(
                                                    opacity: a,
                                                    child: c,
                                                  ),
                                                ),
                                                child: Icon(
                                                  playing
                                                      ? Icons.pause_rounded
                                                      : Icons
                                                          .play_arrow_rounded,
                                                  key: ValueKey(playing),
                                                  color: pal.onAccent,
                                                  size: 36,
                                                ),
                                              ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  SquishyGesture(
                                    onTap: audioHandler.skipToNext,
                                    child: LiquidGlassBox(
                                      borderRadius: BorderRadius.circular(35),
                                      fallbackColor: pal.playerButton,
                                      child: const SizedBox(
                                        width: 88,
                                        height: 70,
                                        child: Icon(
                                          Icons.skip_next_rounded,
                                          color: Color(0xFFF6E6DF),
                                          size: 32,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            Reveal(
                              delayMs: 280,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(26),
                                child: SizedBox(
                                  height: 52,
                                  child: Row(
                                    children: [
                                      _segBtn(
                                        pal,
                                        Icons.info_rounded,
                                        false,
                                        () =>
                                            showTrackInfoDialog(context, track),
                                        isFirst: true,
                                      ),
                                      const SizedBox(width: 3),
                                      _segBtn(
                                        pal,
                                        Icons.tune_rounded,
                                        appState.speed != 1.0 ||
                                            appState.pitch != 1.0,
                                        () => showPlaybackSheet(context),
                                      ),
                                      const SizedBox(width: 3),
                                      _segBtn(
                                        pal,
                                        Icons.shuffle_rounded,
                                        shuffle,
                                        () {
                                          audioHandler.setShuffleMode(
                                            shuffle
                                                ? AudioServiceShuffleMode.none
                                                : AudioServiceShuffleMode.all,
                                          );
                                        },
                                      ),
                                      const SizedBox(width: 3),
                                      _segBtn(
                                        pal,
                                        repeat == AudioServiceRepeatMode.one
                                            ? Icons.repeat_one_rounded
                                            : Icons.repeat_rounded,
                                        repeat != AudioServiceRepeatMode.none,
                                        () {
                                          final next = switch (repeat) {
                                            AudioServiceRepeatMode.none =>
                                              AudioServiceRepeatMode.all,
                                            AudioServiceRepeatMode.all =>
                                              AudioServiceRepeatMode.one,
                                            _ => AudioServiceRepeatMode.none,
                                          };
                                          audioHandler.setRepeatMode(next);
                                        },
                                      ),
                                      const SizedBox(width: 3),
                                      _segBtn(
                                        pal,
                                        Icons.playlist_add_rounded,
                                        false,
                                        () => showAddToPlaylistSheet(
                                          context,
                                          track,
                                        ),
                                      ),
                                      const SizedBox(width: 3),
                                      _segBtn(
                                        pal,
                                        Icons.queue_music_rounded,
                                        false,
                                        () => showQueueSheet(context),
                                      ),
                                      const SizedBox(width: 3),
                                      _segBtn(
                                        pal,
                                        Icons.album_rounded,
                                        appState.vinylSpinMode,
                                        () => appState.setVinylSpinMode(
                                          !appState.vinylSpinMode,
                                        ),
                                        isLast: true,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _segBtn(
    AppPalette pal,
    IconData icon,
    bool active,
    VoidCallback onTap, {
    bool isFirst = false,
    bool isLast = false,
  }) {
    return Expanded(
      child: SquishyGesture(
        pressedScale: 0.9,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          height: 52,
          decoration: BoxDecoration(
            color: active ? pal.playerButton : pal.playerSurface,
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(isFirst ? 26 : 6),
              right: Radius.circular(isLast ? 26 : 6),
            ),
          ),
          child: Icon(
            icon,
            color: active ? pal.accent : const Color(0xFFEAE0DC),
            size: 21,
          ),
        ),
      ),
    );
  }
}

class WavySeekBar extends StatefulWidget {
  final int fallbackSeconds;
  final Color active;
  final bool playing;

  const WavySeekBar({
    super.key,
    required this.fallbackSeconds,
    required this.active,
    required this.playing,
  });

  @override
  State<WavySeekBar> createState() => _WavySeekBarState();
}

class _WavySeekBarState extends State<WavySeekBar>
    with SingleTickerProviderStateMixin {
  double? _drag;
  late final AnimationController _waveCtrl;

  @override
  void initState() {
    super.initState();
    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _waveCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TrackProgress(
      fallbackSeconds: widget.fallbackSeconds,
      builder: (context, pos, dur) {
        final maxMs = max(dur.inMilliseconds, 1).toDouble();
        final value = (_drag ?? pos.inMilliseconds.toDouble())
            .clamp(0.0, maxMs)
            .toDouble();
        final frac = (value / maxMs).clamp(0.0, 1.0);
        final shown = Duration(milliseconds: value.toInt());

        return Column(
          children: [
            SizedBox(
              height: 32,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (d) {
                      final f = (d.localPosition.dx / w).clamp(0.0, 1.0);
                      setState(() => _drag = f * maxMs);
                    },
                    onHorizontalDragUpdate: (d) {
                      final f = (d.localPosition.dx / w).clamp(0.0, 1.0);
                      setState(() => _drag = f * maxMs);
                    },
                    onHorizontalDragEnd: (_) {
                      if (_drag != null) {
                        audioHandler.seek(
                          Duration(milliseconds: _drag!.toInt()),
                        );
                        setState(() => _drag = null);
                      }
                    },
                    onTapDown: (d) {
                      final f = (d.localPosition.dx / w).clamp(0.0, 1.0);
                      audioHandler.seek(
                        Duration(milliseconds: (f * maxMs).toInt()),
                      );
                    },
                    child: AnimatedBuilder(
                      animation: _waveCtrl,
                      builder: (context, _) {
                        return CustomPaint(
                          painter: _WavyTrackPainter(
                            progress: frac,
                            phase: _waveCtrl.value * 2 * pi,
                            activeColor: widget.active,
                            inactiveColor: Colors.white24,
                            waveAmplitude: widget.playing ? 4.2 : 0.0,
                          ),
                          size: Size(w, 32),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    formatDuration(shown),
                    style: const TextStyle(
                      color: Color(0xFFC8BDB7),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    formatDuration(dur),
                    style: const TextStyle(
                      color: Color(0xFFC8BDB7),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _WavyTrackPainter extends CustomPainter {
  final double progress;
  final double phase;
  final Color activeColor;
  final Color inactiveColor;
  final double waveAmplitude;

  const _WavyTrackPainter({
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

    final inactivePaint = Paint()
      ..color = inactiveColor
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;
    if (activeX < size.width) {
      canvas.drawLine(
        Offset(activeX, cy),
        Offset(size.width, cy),
        inactivePaint,
      );
    }

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;

    final path = Path();
    path.moveTo(0, cy);
    const wavelength = 28.0;
    for (double x = 0; x <= activeX; x += 2.0) {
      final y = cy + sin((x / wavelength) * 2 * pi - phase) * waveAmplitude;
      path.lineTo(x, y);
    }
    canvas.drawPath(path, activePaint);

    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(activeX, cy), width: 10, height: 22),
      const Radius.circular(6),
    );
    canvas.drawRRect(thumbRect, Paint()..color = activeColor);
  }

  @override
  bool shouldRepaint(covariant _WavyTrackPainter old) =>
      old.progress != progress ||
      old.phase != phase ||
      old.waveAmplitude != waveAmplitude ||
      old.activeColor != activeColor;
}

// ─────────────────────────────────────────────────────────────────────────────
// Sheets & Dialogs (With Delete Song from Library inside 3-Dot Menu!)
// ─────────────────────────────────────────────────────────────────────────────

Future<dynamic> _sheet(
  BuildContext context,
  WidgetBuilder builder, {
  bool scroll = false,
  Color? color,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: scroll,
    showDragHandle: true,
    backgroundColor: color ?? appState.palette.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: builder,
  );
}

Widget _sheetTile(
  AppPalette pal,
  IconData icon,
  String title,
  String subtitle,
  VoidCallback onTap,
) {
  return SquishyGesture(
    pressedScale: 0.97,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: pal.container,
            child: Icon(icon, color: pal.accent),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFFA6ADB2),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _menuAction(
    AppPalette pal, IconData icon, String label, VoidCallback onTap) {
  return SquishyGesture(
    pressedScale: 0.95,
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        color: pal.container,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: pal.accent, size: 20),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ],
      ),
    ),
  );
}

void showAddToPlaylistSheet(BuildContext context, TrackItem track) {
  _sheet(
    context,
    (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final pal = appState.palette;
        final pls = appState.playlists;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 46,
                        height: 46,
                        child: CustomAlbumArtwork(track: track),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: pal.accent,
                        foregroundColor: pal.onAccent,
                      ),
                      onPressed: () {
                        showCreateOrEditPlaylistDialog(
                          context,
                          initialTrackId: track.id,
                        );
                      },
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('New Playlist'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _menuAction(pal, Icons.album_rounded, 'Go to album',
                          () {
                        Navigator.pop(ctx);
                        goToAlbum(context, track);
                      }),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _menuAction(
                          pal, Icons.person_rounded, 'Go to artist', () {
                        Navigator.pop(ctx);
                        goToArtist(context, track);
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'ADD TO PLAYLIST',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                if (pls.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: Text(
                        'No playlists yet — tap "New Playlist" above!',
                        style: TextStyle(color: Colors.white60),
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: pls.length,
                      itemBuilder: (_, i) {
                        final pl = pls[i];
                        final added = appState.inPlaylist(pl.id, track.id);
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: PlaylistCoverThumbnail(
                            playlist: pl,
                            size: 46,
                          ),
                          title: Text(
                            pl.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Text(
                            '${pl.trackIds.length} songs',
                            style: const TextStyle(color: Colors.white54),
                          ),
                          trailing: Icon(
                            added
                                ? Icons.check_circle_rounded
                                : Icons.add_circle_outline_rounded,
                            color: added ? pal.accent : Colors.white54,
                            size: 26,
                          ),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            appState.togglePlaylistTrack(pl.id, track.id);
                          },
                        );
                      },
                    ),
                  ),
                const Divider(color: Colors.white12, height: 24),
                SquishyGesture(
                  pressedScale: 0.97,
                  onTap: () async {
                    Navigator.pop(ctx);
                    await audioHandler.deleteTrackFromLibrary(track);
                    appNotice.value = 'Deleted "${track.title}" from library.';
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: Colors.redAccent.withOpacity(0.45),
                      ),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.delete_forever_rounded,
                          color: Colors.redAccent,
                          size: 22,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Delete Song from Library',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
    scroll: true,
  );
}

void showCreateOrEditPlaylistDialog(
  BuildContext context, {
  Playlist? existing,
  String? initialTrackId,
}) {
  final pal = appState.palette;
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  String? coverPath = existing?.cover;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: pal.surface,
        title: Text(
          existing == null ? 'Create Playlist' : 'Edit Playlist',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SquishyGesture(
                onTap: () async {
                  final picked = await pickAndSaveGalleryImage();
                  if (picked != null) {
                    setDialogState(() => coverPath = picked);
                  }
                },
                child: Column(
                  children: [
                    Container(
                      width: 112,
                      height: 112,
                      decoration: BoxDecoration(
                        color: pal.container,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: pal.accent.withOpacity(0.5),
                          width: 1.5,
                        ),
                      ),
                      child: (coverPath != null && File(coverPath!).existsSync())
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(22),
                              child: Image.file(
                                File(coverPath!),
                                fit: BoxFit.cover,
                              ),
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.add_photo_alternate_rounded,
                                  color: pal.accent,
                                  size: 36,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Pick Gallery Icon',
                                  style: TextStyle(
                                    color: pal.accent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                    ),
                    if (coverPath != null)
                      TextButton(
                        onPressed: () => setDialogState(() => coverPath = null),
                        child: const Text(
                          'Remove custom photo',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: nameCtrl,
                autofocus: existing == null,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Playlist Name',
                  labelStyle: const TextStyle(color: Colors.white70),
                  filled: true,
                  fillColor: pal.container,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: pal.accent,
              foregroundColor: pal.onAccent,
            ),
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (existing == null) {
                final created = appState.createPlaylist(
                  name.isEmpty ? 'My Playlist' : name,
                  cover: coverPath,
                );
                if (initialTrackId != null) {
                  appState.addToPlaylist(created.id, initialTrackId);
                }
              } else {
                appState.setPlaylistInfo(
                  existing.id,
                  name.isEmpty ? existing.name : name,
                  coverPath,
                );
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

void showAddTracksToPlaylistPicker(BuildContext context, Playlist pl) {
  _sheet(
    context,
    (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.75,
      child: ListenableBuilder(
        listenable: appState,
        builder: (ctx, _) {
          final pal = appState.palette;
          final tracks = audioHandler.tracks;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add Songs to "${pl.name}"',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    itemCount: tracks.length,
                    itemBuilder: (_, i) {
                      final t = tracks[i];
                      final inPl = appState.inPlaylist(pl.id, t.id);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 46,
                            height: 46,
                            child: CustomAlbumArtwork(track: t),
                          ),
                        ),
                        title: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white60),
                        ),
                        trailing: Icon(
                          inPl
                              ? Icons.check_circle_rounded
                              : Icons.add_circle_outline_rounded,
                          color: inPl ? pal.accent : Colors.white54,
                        ),
                        onTap: () => appState.togglePlaylistTrack(pl.id, t.id),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
    scroll: true,
  );
}

void showArtistTracksSheet(
  BuildContext context,
  String artist,
  List<TrackItem> tracks,
) {
  final pal = appState.palette;
  _sheet(
    context,
    (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.65,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              artist,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              '${tracks.length} songs',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: tracks.length,
                itemBuilder: (_, i) {
                  final t = tracks[i];
                  return TrackRow(
                    track: t,
                    palette: pal,
                    active: audioHandler.currentTrack?.id == t.id,
                    onTap: () {
                      Navigator.pop(ctx);
                      final idx = audioHandler.tracks.indexOf(t);
                      playAndOpen(context, idx);
                    },
                    onMore: () => showAddToPlaylistSheet(context, t),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
    scroll: true,
  );
}

void showAddMusicSheet(BuildContext context) {
  final pal = appState.palette;
  _sheet(
    context,
    (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add Music to AlexLMP',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            _sheetTile(
              pal,
              Icons.folder_open_rounded,
              'Pick Local Audio Files',
              'Import MP3, FLAC, WAV, M4A from device',
              () {
                Navigator.pop(ctx);
                pickLocalFiles();
              },
            ),
            _sheetTile(
              pal,
              Icons.radar_rounded,
              'Scan Device Music',
              'Index all music files on phone storage',
              () {
                Navigator.pop(ctx);
                scanDeviceAudio();
              },
            ),
          ],
        ),
      ),
    ),
  );
}

void showSettingsSheet(BuildContext context) {
  _sheet(
    context,
    (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final pal = appState.palette;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'AlexLMP Settings',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Made by Alex Desrosier',
                    style: TextStyle(
                      fontSize: 14,
                      color: pal.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Color Theme',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ThemeChip(
                        label: 'Adaptive',
                        selected: appState.isAdaptive,
                        swatch: const [
                          Color(0xFFFF6FAE),
                          Color(0xFFFFC94D),
                          Color(0xFF2EE6C8),
                          Color(0xFF2E9BFF),
                        ],
                        accent: pal.accent,
                        onAccent: pal.onAccent,
                        onTap: () => appState.setTheme(AppPalette.adaptiveName),
                      ),
                      for (final t in AppPalette.all)
                        ThemeChip(
                          label: t.name.split(' ').first,
                          selected: appState.themeName == t.name,
                          swatch: [t.accent, t.playerButton, t.bg],
                          accent: t.accent,
                          onAccent: t.onAccent,
                          onTap: () => appState.setTheme(t.name),
                        ),
                    ],
                  ),
                  if (appState.isAdaptive)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Colors change to match the album art of what\'s playing.',
                        style: TextStyle(color: pal.accent, fontSize: 12.5),
                      ),
                    ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Animated color backgrounds',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'Slowly moving color glow behind the app and player',
                    ),
                    value: appState.animatedBackground,
                    activeColor: pal.accent,
                    onChanged: appState.setAnimatedBackground,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Album art background in player',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'Blurred cover art fills the Now Playing screen',
                    ),
                    value: appState.artBackdrop,
                    activeColor: pal.accent,
                    onChanged: appState.setArtBackdrop,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Swipe right for next song',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      appState.swipeRightForNext
                          ? 'On the album art: swipe right = next, left = previous'
                          : 'On the album art: swipe left = next, right = previous',
                    ),
                    value: appState.swipeRightForNext,
                    activeColor: pal.accent,
                    onChanged: appState.setSwipeRightForNext,
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Row(
                      children: [
                        const Text(
                          'iOS 27 Liquid Glass UI',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: pal.accent.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: pal.accent),
                          ),
                          child: Text(
                            'BETA',
                            style: TextStyle(
                              color: pal.accent,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                    subtitle: const Text(
                      'Experimental frosted blur cards & aurora plasma mesh (Off by default)',
                    ),
                    value: appState.liquidGlass,
                    activeColor: pal.accent,
                    onChanged: appState.setLiquidGlass,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Spinning Vinyl Artwork Mode',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'Rotates album art like a turntable record (or double-tap art)',
                    ),
                    value: appState.vinylSpinMode,
                    activeColor: pal.accent,
                    onChanged: appState.setVinylSpinMode,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Stop music on task clear'),
                    subtitle: const Text(
                      'Stops playback when swiped away from recents',
                    ),
                    value: appState.stopOnTaskClear,
                    activeColor: pal.accent,
                    onChanged: appState.setStopOnTaskClear,
                  ),
                  _sheetTile(
                    pal,
                    Icons.refresh_rounded,
                    'Rescan music library',
                    'Pick up newly added songs',
                    () {
                      Navigator.pop(ctx);
                      scanDeviceAudio();
                    },
                  ),
                  FutureBuilder<bool>(
                    future: Permission.ignoreBatteryOptimizations.isGranted,
                    builder: (context, snap) {
                      final ok = snap.data ?? false;
                      return _sheetTile(
                        pal,
                        ok
                            ? Icons.battery_charging_full_rounded
                            : Icons.battery_alert_rounded,
                        'Background playback',
                        ok
                            ? 'Battery optimization is off for AlexLMP'
                            : 'Tap to stop Android pausing music in the background',
                        () async {
                          await Permission.ignoreBatteryOptimizations.request();
                          appState.refresh();
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
    scroll: true,
  );
}

void showPlaybackSheet(BuildContext context) {
  _sheet(
    context,
    (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final pal = appState.palette;
        final semitones = (12 * (log(appState.pitch) / ln2)).round();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Speed & Pitch Shifter',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    SquishyGesture(
                      onTap: () {
                        appState.setSpeed(1.0);
                        appState.setPitch(1.0);
                        audioHandler.setSpeed(1.0);
                        audioHandler.setPitch(1.0);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          'Reset',
                          style: TextStyle(
                            color: pal.accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    'Link Speed & Pitch (Vinyl / Nightcore Mode)',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                  subtitle: const Text(
                    'Shifts pitch & tempo together like a real turntable',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  value: appState.linkSpeedAndPitch,
                  activeColor: pal.accent,
                  onChanged: (v) {
                    appState.setLinkSpeedAndPitch(v);
                    if (v) {
                      appState.setSpeed(appState.pitch);
                      audioHandler.setSpeed(appState.pitch);
                    }
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  'Speed: ${appState.speed.toStringAsFixed(2)}x',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Slider(
                  value: appState.speed.clamp(0.5, 2.0),
                  min: 0.5,
                  max: 2.0,
                  divisions: 30,
                  activeColor: pal.accent,
                  onChanged: (v) {
                    appState.setSpeed(v);
                    audioHandler.setSpeed(v);
                    if (appState.linkSpeedAndPitch) {
                      appState.setPitch(v);
                      audioHandler.setPitch(v);
                    }
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  'Pitch: ${appState.pitch.toStringAsFixed(2)}x  (${semitones >= 0 ? '+$semitones' : '$semitones'} semitones)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Slider(
                  value: appState.pitch.clamp(0.5, 2.0),
                  min: 0.5,
                  max: 2.0,
                  divisions: 60,
                  activeColor: pal.accent,
                  onChanged: (v) {
                    appState.setPitch(v);
                    audioHandler.setPitch(v);
                    if (appState.linkSpeedAndPitch) {
                      appState.setSpeed(v);
                      audioHandler.setSpeed(v);
                    }
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [-6, -3, -1, 0, 1, 3, 6].map((st) {
                    final targetPitch = pow(2.0, st / 12.0).toDouble();
                    final active = (appState.pitch - targetPitch).abs() < 0.02;
                    return ChoiceChip(
                      label: Text(
                        st == 0 ? '0 st' : (st > 0 ? '+$st st' : '$st st'),
                      ),
                      selected: active,
                      showCheckmark: false,
                      selectedColor: pal.accent,
                      backgroundColor: pal.playerButton,
                      labelStyle: TextStyle(
                        color: active ? pal.onAccent : Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                      onSelected: (_) {
                        appState.setPitch(targetPitch);
                        audioHandler.setPitch(targetPitch);
                        if (appState.linkSpeedAndPitch) {
                          appState.setSpeed(targetPitch);
                          audioHandler.setSpeed(targetPitch);
                        }
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      },
    ),
    color: appState.palette.playerSurface,
  );
}

void showQueueSheet(BuildContext context) {
  _sheet(
    context,
    (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.7,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          audioHandler.libraryRevision,
          audioHandler.currentIndex,
          appState,
        ]),
        builder: (ctx, _) {
          final pal = appState.palette;
          final tracks = audioHandler.tracks;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              children: [
                const Text(
                  'Reorder Queue',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: tracks.length,
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex -= 1;
                      audioHandler.moveTrack(oldIndex, newIndex);
                    },
                    itemBuilder: (_, i) {
                      final t = tracks[i];
                      final active = i == audioHandler.index;
                      return ListTile(
                        key: ValueKey(t.id),
                        contentPadding: EdgeInsets.zero,
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: CustomAlbumArtwork(track: t),
                          ),
                        ),
                        title: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: active ? pal.accent : Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        trailing: ReorderableDragStartListener(
                          index: i,
                          child: const Icon(
                            Icons.drag_handle_rounded,
                            color: Colors.white54,
                          ),
                        ),
                        onTap: () => audioHandler.playIndex(i),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
    scroll: true,
    color: appState.palette.playerSurface,
  );
}

void showTrackInfoDialog(BuildContext context, TrackItem track) {
  final pal = appState.palette;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: pal.playerSurface,
      title: Text(track.title, style: const TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Artist: ${track.artist}',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 6),
          Text(
            'Album: ${track.album}',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 6),
          Text(
            'File: ${track.filePath ?? track.source}',
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text('Close', style: TextStyle(color: pal.accent)),
        ),
      ],
    ),
  );
}

Widget _styleChips(
  String selected,
  ValueChanged<String> onSelect,
  AppPalette pal,
) {
  const labels = {
    'vinyl_record': 'Vinyl Record',
    'sound_wave': 'Sound Wave',
    'music_note_grid': 'Music Notes',
    'equalizer_bars': 'Equalizer Bars',
    'neon_vinyl': 'Neon Vinyl',
  };
  return Wrap(
    spacing: 8,
    runSpacing: 8,
    children: labels.entries.map((e) {
      final sel = selected == e.key;
      return ChoiceChip(
        label: Text(e.value),
        selected: sel,
        showCheckmark: false,
        selectedColor: pal.accent,
        backgroundColor: pal.container,
        labelStyle: TextStyle(
          color: sel ? pal.onAccent : Colors.white,
          fontWeight: FontWeight.w600,
        ),
        side: BorderSide.none,
        onSelected: (_) => onSelect(e.key),
      );
    }).toList(),
  );
}

void showEditTrackDialog(BuildContext context, TrackItem track) {
  final pal = appState.palette;
  final titleCtrl = TextEditingController(text: track.title);
  final artistCtrl = TextEditingController(text: track.artist);
  String style = track.artStyle;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: pal.surface,
        title: const Text(
          'Edit Song Details',
          style: TextStyle(color: Colors.white),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: titleCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Song Title',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: artistCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Artist Name',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Album art style',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 8),
              _styleChips(style, (s) => setDialogState(() => style = s), pal),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: pal.accent,
              foregroundColor: pal.onAccent,
            ),
            onPressed: () {
              final title = titleCtrl.text.trim();
              final artist = artistCtrl.text.trim();
              if (title.isNotEmpty) track.title = title;
              if (artist.isNotEmpty) track.artist = artist;
              track.artStyle = style;
              appState.saveEdit(track);
              audioHandler.refreshMediaItem();
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

void showPlaylistEditDialog(BuildContext context) {
  final pal = appState.palette;
  final nameCtrl = TextEditingController(text: appState.playlistName);
  String style = appState.playlistStyle;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: pal.surface,
        title: const Text(
          'Edit Mix Title',
          style: TextStyle(color: Colors.white),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Mix Title',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Cover style',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 8),
              _styleChips(style, (s) => setDialogState(() => style = s), pal),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: pal.accent,
              foregroundColor: pal.onAccent,
            ),
            onPressed: () {
              final name = nameCtrl.text.trim();
              appState.setPlaylist(
                name.isEmpty ? appState.playlistName : name,
                style,
              );
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

void showSearchSheet(BuildContext context) {
  _sheet(
    context,
    (ctx) => SearchSheet(parentContext: context),
    scroll: true,
    color: appState.palette.bg,
  );
}

class SearchSheet extends StatefulWidget {
  final BuildContext parentContext;
  const SearchSheet({super.key, required this.parentContext});

  @override
  State<SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<SearchSheet> {
  static int _lastTab = 0; // 0 = Library, 1 = YouTube Music (kept while app runs)

  String _query = '';
  int _tab = _lastTab;
  Timer? _debounce;
  int _ytSeq = 0;
  String _ytQuery = '';

  bool _songsLoading = false;
  bool _artistsLoading = false;
  bool _albumsLoading = false;
  String? _songsError;
  List<TrackItem> _songs = const [];
  List<YtArtist> _artists = const [];
  List<YtAlbum> _albums = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _setTab(int t) {
    if (t == _tab) return;
    _lastTab = t;
    setState(() => _tab = t);
    final q = _query.trim();
    if (t == 1 && q.length >= 2 && q != _ytQuery) _searchYt(q);
  }

  void _onQueryChanged(String v) {
    setState(() => _query = v);
    _debounce?.cancel();
    final q = v.trim();
    if (q.length < 2) {
      _ytSeq++;
      _ytQuery = '';
      setState(() {
        _songsLoading = _artistsLoading = _albumsLoading = false;
        _songsError = null;
        _songs = const [];
        _artists = const [];
        _albums = const [];
      });
      return;
    }
    if (_tab == 1) {
      _debounce = Timer(const Duration(milliseconds: 450), () => _searchYt(q));
    }
  }

  void _searchYt(String q) {
    final seq = ++_ytSeq;
    _ytQuery = q;
    setState(() {
      _songsLoading = _artistsLoading = _albumsLoading = true;
      _songsError = null;
    });
    YouTubeMusic.search(q).then((r) {
      if (!mounted || seq != _ytSeq) return;
      setState(() {
        _songs = r;
        _songsLoading = false;
      });
    }, onError: (Object e) {
      if (!mounted || seq != _ytSeq) return;
      final detail = e is PlatformException ? (e.message ?? e.code) : '$e';
      setState(() {
        _songs = const [];
        _songsLoading = false;
        _songsError = 'Couldn\'t reach YouTube Music.\n\nDetails: $detail';
      });
    });
    // Artists and albums are extras: if they fail, their rows just stay hidden.
    YouTubeMusic.searchArtists(q).then((r) {
      if (!mounted || seq != _ytSeq) return;
      setState(() {
        _artists = r;
        _artistsLoading = false;
      });
    }, onError: (Object _) {
      if (!mounted || seq != _ytSeq) return;
      setState(() {
        _artists = const [];
        _artistsLoading = false;
      });
    });
    YouTubeMusic.searchAlbums(q).then((r) {
      if (!mounted || seq != _ytSeq) return;
      setState(() {
        _albums = r;
        _albumsLoading = false;
      });
    }, onError: (Object _) {
      if (!mounted || seq != _ytSeq) return;
      setState(() {
        _albums = const [];
        _albumsLoading = false;
      });
    });
  }

  Widget _tabs(AppPalette pal) {
    Widget pill(int index, IconData icon, String label) {
      final selected = _tab == index;
      return Expanded(
        child: SquishyGesture(
          pressedScale: 0.96,
          onTap: () => _setTab(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            height: 42,
            decoration: BoxDecoration(
              color: selected ? pal.accent : pal.surface,
              borderRadius: BorderRadius.circular(21),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    size: 18,
                    color: selected ? pal.onAccent : Colors.white70),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? pal.onAccent : Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        pill(0, Icons.library_music_rounded, 'Library'),
        const SizedBox(width: 10),
        pill(1, Icons.play_circle_fill_rounded, 'YouTube Music'),
      ],
    );
  }

  Widget _note(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
      child: SelectableText(text, style: const TextStyle(color: Colors.white54)),
    );
  }

  Widget _spinner(AppPalette pal) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: pal.accent),
          ),
        ),
      );

  List<Widget> _libraryResults(AppPalette pal) {
    final tracks = audioHandler.tracks;
    final q = _query.toLowerCase();
    final filtered = tracks.where((t) {
      return t.title.toLowerCase().contains(q) ||
          t.artist.toLowerCase().contains(q) ||
          t.album.toLowerCase().contains(q);
    }).toList();
    if (filtered.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.only(top: 40),
          child: Center(
            child: Text('No songs found.',
                style: TextStyle(color: Colors.white54)),
          ),
        ),
      ];
    }
    return [
      for (final t in filtered)
        TrackRow(
          track: t,
          palette: pal,
          active: audioHandler.currentTrack?.id == t.id,
          onTap: () {
            final idx = tracks.indexOf(t);
            Navigator.pop(context);
            playAndOpen(widget.parentContext, idx);
          },
          onMore: () => showAddToPlaylistSheet(context, t),
        ),
    ];
  }

  List<Widget> _ytResults(AppPalette pal) {
    if (_query.trim().length < 2) {
      return [
        const Padding(
          padding: EdgeInsets.only(top: 40),
          child: Center(
            child: Text(
              'Search YouTube Music for songs, artists and albums.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ),
      ];
    }
    final out = <Widget>[];

    if (_artists.isNotEmpty) {
      out.add(ytSectionHeader('Artists'));
      out.add(SizedBox(
        height: 132,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _artists.length,
          separatorBuilder: (_, __) => const SizedBox(width: 14),
          itemBuilder: (_, i) => YtArtistTile(artist: _artists[i]),
        ),
      ));
    } else if (_artistsLoading) {
      out.add(const SizedBox(height: 4));
    }

    out.add(ytSectionHeader('Songs'));
    if (_songsLoading && _songs.isEmpty) {
      out.add(_spinner(pal));
    } else if (_songsError != null) {
      out.add(_note(_songsError!));
    } else if (_songs.isEmpty) {
      out.add(_note('No songs found on YouTube Music.'));
    } else {
      for (final t in _songs) {
        out.add(YtTrackRow(track: t, onPlay: () {
          Navigator.pop(context);
          audioHandler.playYouTubeTrack(t);
          openPlayer(widget.parentContext);
        }));
      }
    }

    if (_albums.isNotEmpty) {
      out.add(ytSectionHeader('Albums'));
      out.add(SizedBox(
        height: 196,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _albums.length,
          separatorBuilder: (_, __) => const SizedBox(width: 14),
          itemBuilder: (_, i) => YtAlbumTile(album: _albums[i]),
        ),
      ));
    }
    out.add(const SizedBox(height: 24));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final pal = appState.palette;
    final ytAvailable = Platform.isAndroid;
    final children = (_tab == 1 && ytAvailable)
        ? _ytResults(pal)
        : _libraryResults(pal);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Column(
            children: [
              TextField(
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: _tab == 1
                      ? 'Search YouTube Music...'
                      : 'Search your library...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  prefixIcon: Icon(Icons.search, color: pal.accent),
                  filled: true,
                  fillColor: pal.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                ),
                textInputAction: TextInputAction.search,
                onChanged: _onQueryChanged,
                onSubmitted: (v) {
                  final q = v.trim();
                  if (_tab == 1 && q.length >= 2) {
                    _debounce?.cancel();
                    _searchYt(q);
                  }
                },
              ),
              if (ytAvailable) ...[
                const SizedBox(height: 12),
                _tabs(pal),
              ],
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  children: children,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// YouTube Music: shared widgets, artist page, album page
// ─────────────────────────────────────────────────────────────────────────────

Widget ytSectionHeader(String text) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(2, 16, 2, 8),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 17,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class YtNetworkImage extends StatelessWidget {
  final String? url;
  final double size;
  final bool circle;
  final IconData fallbackIcon;

  const YtNetworkImage({
    super.key,
    required this.url,
    required this.size,
    this.circle = false,
    this.fallbackIcon = Icons.album_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final pal = appState.palette;
    final placeholder = Container(
      width: size,
      height: size,
      color: pal.container,
      child: Icon(fallbackIcon, color: pal.accent, size: size * 0.4),
    );
    final img = (url == null || url!.isEmpty)
        ? placeholder
        : Image.network(
            url!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => placeholder,
          );
    return circle
        ? ClipOval(child: SizedBox(width: size, height: size, child: img))
        : ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(width: size, height: size, child: img),
          );
  }
}

void openYtArtist(BuildContext context, String url, String name,
    {String? thumbnail}) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => YtArtistScreen(url: url, name: name, thumbnail: thumbnail),
  ));
}

void openYtAlbum(BuildContext context, YtAlbum album) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => YtAlbumScreen(album: album),
  ));
}

void openYtAccountPlaylist(BuildContext context, YtPlaylistRef p) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => YtAlbumScreen(
      album: YtAlbum('', p.title, p.subtitle, p.thumbnail, -1),
      loader: () => YouTubeMusic.playlistPage(p.playlistId,
          title: p.title, thumbnail: p.thumbnail),
      playLabel: 'Play',
    ),
  ));
}

void openYtLikedMusic(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => YtAlbumScreen(
      album: const YtAlbum('', 'Liked on YouTube', 'YouTube Music', null, -1),
      loader: () async {
        final page =
            await YouTubeMusic.playlistPage('LM', title: 'Liked on YouTube');
        return YtAlbumPage(page.title, 'Your YouTube Music likes',
            page.tracks.isNotEmpty ? page.tracks.first.artworkUrl : null,
            page.tracks);
      },
      playLabel: 'Play',
    ),
  ));
}

Future<void> ytSignInFlow(BuildContext context) async {
  try {
    final ok = await YouTubeMusic.signIn();
    appNotice.value = ok
        ? 'Signed in to YouTube Music.'
        : 'Sign-in was cancelled.';
  } catch (e) {
    final detail = e is PlatformException ? (e.message ?? e.code) : '$e';
    appNotice.value = 'Sign-in failed: $detail';
  }
}

void showYtAccountSheet(BuildContext context) {
  _sheet(
    context,
    (ctx) => ValueListenableBuilder<YtAccount>(
      valueListenable: ytAccount,
      builder: (ctx, acc, _) {
        final pal = appState.palette;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                YtNetworkImage(
                  url: acc.photo,
                  size: 72,
                  circle: true,
                  fallbackIcon: Icons.person_rounded,
                ),
                const SizedBox(height: 12),
                Text(
                  acc.signedIn
                      ? (acc.name ?? 'YouTube Music account')
                      : 'YouTube Music',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  acc.signedIn
                      ? 'Your playlists and likes show in Library. AlexLMP only reads them — it never changes anything on your account.'
                      : 'Sign in to see your YouTube Music playlists and liked songs in your Library. Read-only: AlexLMP never changes your account.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60, fontSize: 13.5),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          acc.signedIn ? Colors.redAccent.withOpacity(0.2) : pal.accent,
                      foregroundColor:
                          acc.signedIn ? Colors.redAccent : pal.onAccent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      if (acc.signedIn) {
                        await YouTubeMusic.signOut();
                        appNotice.value = 'Signed out of YouTube Music.';
                      } else {
                        await ytSignInFlow(context);
                      }
                    },
                    icon: Icon(acc.signedIn
                        ? Icons.logout_rounded
                        : Icons.login_rounded),
                    label: Text(acc.signedIn ? 'Sign out' : 'Sign in with Google'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// "Go to album" from a song's menu.
Future<void> goToAlbum(BuildContext context, TrackItem t) async {
  if (!t.isYouTube) {
    final list = audioHandler.tracks.where((x) => x.album == t.album).toList();
    showArtistTracksSheet(context, t.album, list);
    return;
  }
  appNotice.value = 'Finding album…';
  try {
    final links = await YouTubeMusic.trackLinks(t.ytVideoId!);
    if (!context.mounted) return;
    if (links.albumUrl == null) {
      appNotice.value = 'This song isn\'t part of an album on YouTube Music.';
      return;
    }
    openYtAlbum(
      context,
      YtAlbum(links.albumUrl!, links.albumTitle ?? t.album,
          links.artistName ?? t.artist, links.albumThumbnail ?? t.artworkUrl, -1),
    );
  } catch (e) {
    final detail = e is PlatformException ? (e.message ?? e.code) : '$e';
    appNotice.value = 'Couldn\'t open the album: $detail';
  }
}

/// "Go to artist" from a song's menu.
Future<void> goToArtist(BuildContext context, TrackItem t) async {
  if (!t.isYouTube) {
    final list = audioHandler.tracks.where((x) => x.artist == t.artist).toList();
    showArtistTracksSheet(context, t.artist, list);
    return;
  }
  appNotice.value = 'Finding artist…';
  try {
    final links = await YouTubeMusic.trackLinks(t.ytVideoId!);
    if (!context.mounted) return;
    if (links.artistUrl != null) {
      openYtArtist(context, links.artistUrl!, links.artistName ?? t.artist);
      return;
    }
    // Fallback: search by name.
    final found = await YouTubeMusic.searchArtists(t.artist);
    if (!context.mounted) return;
    if (found.isEmpty) {
      appNotice.value = 'Couldn\'t find this artist on YouTube Music.';
      return;
    }
    openYtArtist(context, found.first.url, found.first.name,
        thumbnail: found.first.thumbnail);
  } catch (e) {
    final detail = e is PlatformException ? (e.message ?? e.code) : '$e';
    appNotice.value = 'Couldn\'t open the artist: $detail';
  }
}

/// Opens the add-to-playlist sheet for a YouTube song (adds it to the library first).
void showYtAddToPlaylist(BuildContext context, TrackItem t) {
  final lib = audioHandler.ensureInLibrary(t);
  showAddToPlaylistSheet(context, lib);
}

class YtTrackRow extends StatelessWidget {
  final TrackItem track;
  final VoidCallback onPlay;
  const YtTrackRow({super.key, required this.track, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    return TrackRow(
      track: track,
      palette: appState.palette,
      active: audioHandler.currentTrack?.id == track.id,
      onTap: onPlay,
      onMore: () => showYtAddToPlaylist(context, track),
    );
  }
}

class YtArtistTile extends StatelessWidget {
  final YtArtist artist;
  const YtArtistTile({super.key, required this.artist});

  @override
  Widget build(BuildContext context) {
    return SquishyGesture(
      pressedScale: 0.95,
      onTap: () => openYtArtist(context, artist.url, artist.name,
          thumbnail: artist.thumbnail),
      child: SizedBox(
        width: 96,
        child: Column(
          children: [
            YtNetworkImage(
              url: artist.thumbnail,
              size: 88,
              circle: true,
              fallbackIcon: Icons.person_rounded,
            ),
            const SizedBox(height: 8),
            Text(
              artist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class YtAlbumTile extends StatelessWidget {
  final YtAlbum album;
  const YtAlbumTile({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
    return SquishyGesture(
      pressedScale: 0.95,
      onTap: () => openYtAlbum(context, album),
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            YtNetworkImage(url: album.thumbnail, size: 140),
            const SizedBox(height: 8),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
            Text(
              album.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFA6ADB2), fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared page shell for artist/album pages: background, back button, scrolling body.
class _YtPageShell extends StatelessWidget {
  final List<Widget> Function(BuildContext context) buildBody;
  const _YtPageShell({required this.buildBody});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        appState,
        audioHandler.libraryRevision,
        audioHandler.currentIndex,
      ]),
      builder: (context, _) {
        final pal = appState.palette;
        return Scaffold(
          backgroundColor: pal.bg,
          body: Stack(
            children: [
              AuroraPlasmaBackground(
                accent: pal.accent,
                secondary: const Color(0xFF8CD0F0),
                intense: true,
              ),
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: Row(
                        children: [
                          SquishyGesture(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: pal.surface,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.arrow_back_rounded,
                                  color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                        children: buildBody(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Widget _ytPlayButton(AppPalette pal, String label, VoidCallback onTap) {
  return SquishyGesture(
    pressedScale: 0.95,
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
      decoration: BoxDecoration(
        color: pal.accent,
        borderRadius: BorderRadius.circular(26),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.play_arrow_rounded, color: pal.onAccent),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: pal.onAccent, fontWeight: FontWeight.w800)),
        ],
      ),
    ),
  );
}

Widget _ytLoadError(Object? error, VoidCallback retry) {
  final detail = error is PlatformException
      ? (error.message ?? error.code)
      : '$error';
  return Padding(
    padding: const EdgeInsets.only(top: 40),
    child: Column(
      children: [
        const Text('Couldn\'t load this page.',
            style: TextStyle(color: Colors.white70, fontSize: 16)),
        const SizedBox(height: 8),
        SelectableText(detail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
        const SizedBox(height: 16),
        TextButton(onPressed: retry, child: const Text('Try again')),
      ],
    ),
  );
}

class YtAlbumScreen extends StatefulWidget {
  final YtAlbum album;
  /// Custom loader (e.g. your own YouTube Music playlists); defaults to the
  /// public album page.
  final Future<YtAlbumPage> Function()? loader;
  final String playLabel;
  const YtAlbumScreen({
    super.key,
    required this.album,
    this.loader,
    this.playLabel = 'Play album',
  });

  @override
  State<YtAlbumScreen> createState() => _YtAlbumScreenState();
}

class _YtAlbumScreenState extends State<YtAlbumScreen> {
  late Future<YtAlbumPage> _future;

  Future<YtAlbumPage> _load() =>
      widget.loader != null ? widget.loader!() : YouTubeMusic.album(widget.album.url);

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<YtAlbumPage>(
      future: _future,
      builder: (context, snap) {
        return _YtPageShell(buildBody: (context) {
          final pal = appState.palette;
          final page = snap.data;
          final cover = page?.thumbnail ?? widget.album.thumbnail;
          final title = page?.title ?? widget.album.title;
          final artist = (page?.artist.isNotEmpty ?? false)
              ? page!.artist
              : widget.album.artist;
          final header = <Widget>[
            const SizedBox(height: 8),
            Center(child: YtNetworkImage(url: cover, size: 220)),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(artist,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFA6ADB2), fontSize: 15)),
            const SizedBox(height: 16),
          ];
          if (snap.hasError) {
            return [
              ...header,
              _ytLoadError(snap.error, () {
                setState(() => _future = _load());
              }),
            ];
          }
          if (page == null) {
            return [
              ...header,
              Center(child: CircularProgressIndicator(color: pal.accent)),
            ];
          }
          final tracks = page.tracks;
          return [
            ...header,
            if (tracks.isNotEmpty)
              Center(
                child: _ytPlayButton(pal, widget.playLabel, () {
                  audioHandler.playYouTubeList(tracks, 0);
                  openPlayer(context);
                }),
              ),
            const SizedBox(height: 12),
            if (tracks.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${tracks.length} ${tracks.length == 1 ? 'song' : 'songs'}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            if (tracks.isEmpty)
              const Center(
                child: Text('No playable songs here.',
                    style: TextStyle(color: Colors.white54)),
              ),
            for (var i = 0; i < tracks.length; i++)
              YtTrackRow(
                track: tracks[i],
                onPlay: () {
                  audioHandler.playYouTubeList(tracks, i);
                  openPlayer(context);
                },
              ),
          ];
        });
      },
    );
  }
}

class YtArtistScreen extends StatefulWidget {
  final String url;
  final String name;
  final String? thumbnail;
  const YtArtistScreen(
      {super.key, required this.url, required this.name, this.thumbnail});

  @override
  State<YtArtistScreen> createState() => _YtArtistScreenState();
}

class _YtArtistScreenState extends State<YtArtistScreen> {
  late Future<YtArtistPage> _future;

  @override
  void initState() {
    super.initState();
    _future = YouTubeMusic.artist(widget.url, widget.name);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<YtArtistPage>(
      future: _future,
      builder: (context, snap) {
        return _YtPageShell(buildBody: (context) {
          final pal = appState.palette;
          final page = snap.data;
          final subs = page == null ? '' : formatCompactCount(page.subscribers);
          final header = <Widget>[
            const SizedBox(height: 8),
            Center(
              child: YtNetworkImage(
                url: page?.thumbnail ?? widget.thumbnail,
                size: 180,
                circle: true,
                fallbackIcon: Icons.person_rounded,
              ),
            ),
            const SizedBox(height: 16),
            Text(page?.name ?? widget.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800)),
            if (subs.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('$subs subscribers',
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Color(0xFFA6ADB2), fontSize: 14)),
            ],
            const SizedBox(height: 16),
          ];
          if (snap.hasError) {
            return [
              ...header,
              _ytLoadError(snap.error, () {
                setState(() =>
                    _future = YouTubeMusic.artist(widget.url, widget.name));
              }),
            ];
          }
          if (page == null) {
            return [
              ...header,
              Center(child: CircularProgressIndicator(color: pal.accent)),
            ];
          }
          final songs = page.songs;
          return [
            ...header,
            if (songs.isNotEmpty)
              Center(
                child: _ytPlayButton(pal, 'Play', () {
                  audioHandler.playYouTubeList(songs, 0);
                  openPlayer(context);
                }),
              ),
            if (songs.isNotEmpty) ytSectionHeader('Top songs'),
            for (var i = 0; i < songs.length; i++)
              YtTrackRow(
                track: songs[i],
                onPlay: () {
                  audioHandler.playYouTubeList(songs, i);
                  openPlayer(context);
                },
              ),
            if (page.albums.isNotEmpty) ...[
              ytSectionHeader('Albums'),
              SizedBox(
                height: 196,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: page.albums.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 14),
                  itemBuilder: (_, i) => YtAlbumTile(album: page.albums[i]),
                ),
              ),
            ],
            if (songs.isEmpty && page.albums.isEmpty)
              const Center(
                child: Text('Nothing found for this artist.',
                    style: TextStyle(color: Colors.white54)),
              ),
          ];
        });
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Artwork
// ─────────────────────────────────────────────────────────────────────────────

final Map<String, Object?> _artCache = {};

Future<Uint8List?> loadArt(TrackItem t) {
  final existing = _artCache[t.id];
  if (existing is Future<Uint8List?>) return existing;
  final url = t.artworkUrl;
  final fut = url != null ? _fetchArtFromUrl(url) : _fetchArtFromChannel(t);
  _artCache[t.id] = fut;
  return fut;
}

Future<Uint8List?> _fetchArtFromUrl(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

Future<Uint8List?> _fetchArtFromChannel(TrackItem t) async {
  if (!Platform.isAndroid) return null;
  try {
    final res = await _mediaChannel.invokeMethod('getArt', {
      'uri': t.source,
      'path': t.filePath ?? '',
    });
    if (res is Uint8List) return res;
    return null;
  } catch (_) {
    return null;
  }
}

class CustomAlbumArtwork extends StatelessWidget {
  final TrackItem track;

  const CustomAlbumArtwork({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final placeholder = CustomPaint(
      painter: _ArtworkSymbolPainter(
        style: track.artStyle,
        colors: track.artColors,
      ),
      child: const SizedBox.expand(),
    );
    return FutureBuilder<Uint8List?>(
      future: loadArt(track),
      builder: (context, snap) {
        final bytes = snap.data;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: (bytes != null && bytes.isNotEmpty)
              ? SizedBox.expand(
                  key: ValueKey('art_${track.id}'),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    cacheWidth: 512,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => placeholder,
                  ),
                )
              : SizedBox.expand(
                  key: ValueKey('ph_${track.id}'),
                  child: placeholder,
                ),
        );
      },
    );
  }
}

class _ArtworkSymbolPainter extends CustomPainter {
  final String style;
  final List<Color> colors;

  const _ArtworkSymbolPainter({required this.style, required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(rect),
    );

    final center = Offset(size.width / 2, size.height / 2);
    final s = size.shortestSide;

    if (style == 'vinyl_record') {
      final groove = Paint()
        ..color = Colors.white.withOpacity(0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1.0, s * 0.01);
      for (double r = s * 0.15; r < s * 0.45; r += s * 0.05) {
        canvas.drawCircle(center, r, groove);
      }
      canvas.drawCircle(
        center,
        s * 0.12,
        Paint()..color = const Color(0xFFFFB59C),
      );
      canvas.drawCircle(center, s * 0.03, Paint()..color = Colors.black);
    } else if (style == 'sound_wave') {
      final wave = Paint()
        ..color = const Color(0xFF8CD0F0)
        ..strokeWidth = max(1.5, s * 0.015)
        ..strokeCap = StrokeCap.round;
      const bars = [0.09, 0.17, 0.26, 0.34, 0.21, 0.13, 0.30, 0.20, 0.11];
      double x = size.width * 0.15;
      for (final h in bars) {
        canvas.drawLine(
          Offset(x, center.dy - s * h),
          Offset(x, center.dy + s * h),
          wave,
        );
        x += size.width * 0.08;
      }
    } else if (style == 'music_note_grid') {
      final k = s / 90;
      final note = Paint()..color = Colors.white;
      final stem = Paint()
        ..color = Colors.white
        ..strokeWidth = max(1.5, 3 * k);
      canvas.drawCircle(
        Offset(center.dx - 15 * k, center.dy + 10 * k),
        8 * k,
        note,
      );
      canvas.drawCircle(
        Offset(center.dx + 15 * k, center.dy + 5 * k),
        8 * k,
        note,
      );
      canvas.drawLine(
        Offset(center.dx - 7 * k, center.dy + 10 * k),
        Offset(center.dx - 7 * k, center.dy - 15 * k),
        stem,
      );
      canvas.drawLine(
        Offset(center.dx + 23 * k, center.dy + 5 * k),
        Offset(center.dx + 23 * k, center.dy - 20 * k),
        stem,
      );
      canvas.drawLine(
        Offset(center.dx - 7 * k, center.dy - 15 * k),
        Offset(center.dx + 23 * k, center.dy - 20 * k),
        stem,
      );
    } else if (style == 'equalizer_bars') {
      final bar = Paint()..strokeWidth = max(2.0, s * 0.045);
      const heights = [0.3, 0.6, 0.9, 0.5, 0.7, 0.4];
      double x = size.width * 0.2;
      for (int i = 0; i < heights.length; i++) {
        bar.color =
            i % 2 == 0 ? const Color(0xFF8CD0F0) : const Color(0xFFFFB59C);
        final h = size.height * 0.4 * heights[i];
        canvas.drawLine(
          Offset(x, center.dy + h),
          Offset(x, center.dy - h),
          bar,
        );
        x += size.width * 0.12;
      }
    } else if (style == 'neon_vinyl') {
      final neon = Paint()
        ..color = const Color(0xFFF09CE2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(2.0, s * 0.02);
      canvas.drawCircle(center, s * 0.35, neon);
      canvas.drawCircle(center, s * 0.22, neon);
      canvas.drawCircle(
        center,
        s * 0.08,
        Paint()..color = const Color(0xFF9CF0C0),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ArtworkSymbolPainter old) =>
      old.style != style || old.colors != colors;
}
