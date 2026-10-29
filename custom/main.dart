import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
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

const List<String> kArtStyles = [
  'vinyl_record',
  'sound_wave',
  'music_note_grid',
  'equalizer_bars',
  'neon_vinyl',
];

const List<List<Color>> kArtPalettes = [
  [Color(0xFF3E1C0C), Color(0xFFD96B38), Color(0xFF1A0F0A)],
  [Color(0xFF42173B), Color(0xFFE0538A), Color(0xFF28193D)],
  [Color(0xFF062A4E), Color(0xFF1F7AE0), Color(0xFF0A2416)],
  [Color(0xFF1A3A2A), Color(0xFF9C27B0), Color(0xFF00BCD4)],
  [Color(0xFF4A1E0D), Color(0xFFE66833), Color(0xFF1B110E)],
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
    // Registers the foreground media service => lock screen / notification
    // controls and background playback with the screen off.
    audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.alexlmp.app.channel.audio',
        androidNotificationChannelName: 'AlexLMP Music Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (e) {
    // Still lets the app play audio in the foreground if the service fails.
    audioHandler = MyAudioHandler();
    appNotice.value = 'Lock screen controls unavailable: $e';
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
  final mins = (total ~/ 60).toString().padLeft(2, '0');
  final secs = (total % 60).toString().padLeft(2, '0');
  return '$mins:$secs';
}

// ─────────────────────────────────────────────────────────────────────────────
// Palettes / app state
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
    playerBg: Color(0xFF20130E),
    playerSurface: Color(0xFF362721),
    playerButton: Color(0xFF5D3A28),
    playerAccent: Color(0xFFFFB59C),
    playerOnAccent: Color(0xFF4D1600),
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
    playerAccent: Color(0xFFFFC09C),
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

  static const all = [classicBlue, emerald, sunsetPeach, cyberpunk];

  static AppPalette byName(String name) =>
      all.firstWhere((p) => p.name == name, orElse: () => classicBlue);
}

class AppState extends ChangeNotifier {
  SharedPreferences? _prefs;
  String themeName = 'Classic Blue';
  bool stopOnTaskClear = true;
  double speed = 1.0;
  double pitch = 1.0;
  String playlistName = 'Your AlexLMP Mixes';
  String playlistStyle = 'equalizer_bars';
  final Set<String> liked = {};
  Map<String, dynamic> _edits = {};

  AppPalette get palette => AppPalette.byName(themeName);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    themeName = prefs.getString('theme_name') ?? themeName;
    stopOnTaskClear = prefs.getBool('stop_on_task_clear') ?? true;
    playlistName = prefs.getString('playlist_name') ?? playlistName;
    playlistStyle = prefs.getString('playlist_style') ?? playlistStyle;
    liked.addAll(prefs.getStringList('liked_ids') ?? const []);
    try {
      _edits = Map<String, dynamic>.from(
        jsonDecode(prefs.getString('track_edits') ?? '{}') as Map,
      );
    } catch (_) {
      _edits = {};
    }
    notifyListeners();
  }

  void setTheme(String name) {
    themeName = name;
    _prefs?.setString('theme_name', name);
    notifyListeners();
  }

  void setStopOnTaskClear(bool v) {
    stopOnTaskClear = v;
    _prefs?.setBool('stop_on_task_clear', v);
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
    speed = v;
    notifyListeners();
  }

  void setPitch(double v) {
    pitch = v;
    notifyListeners();
  }

  bool isLiked(String id) => liked.contains(id);

  void toggleLike(String id) {
    if (!liked.remove(id)) liked.add(id);
    _prefs?.setStringList('liked_ids', liked.toList());
    notifyListeners();
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
  final String source; // content:// uri or file path
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

  Uri get uri =>
      source.startsWith('content://') ? Uri.parse(source) : Uri.file(source);

  MediaItem toMediaItem() {
    return MediaItem(
      id: id,
      title: title,
      artist: artist,
      album: album,
      duration: durationSeconds > 0 ? Duration(seconds: durationSeconds) : null,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Audio handler (real playback + lock screen / notification controls)
// ─────────────────────────────────────────────────────────────────────────────

class MyAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player = AudioPlayer();
  final Random _rng = Random();

  List<TrackItem> tracks = [];
  int _index = 0;
  int _loadSeq = 0;
  String? _loadedId;
  bool _shuffle = false;
  AudioServiceRepeatMode _repeat = AudioServiceRepeatMode.none;
  final List<int> _history = [];

  final ValueNotifier<int> currentIndex = ValueNotifier<int>(0);
  final ValueNotifier<int> libraryRevision = ValueNotifier<int>(0);

  MyAudioHandler() {
    _init();
  }

  int get index => _index;
  TrackItem? get currentTrack =>
      (_index >= 0 && _index < tracks.length) ? tracks[_index] : null;

  Future<void> _init() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {}

    player.playbackEventStream.map(_transformEvent).listen(
      playbackState.add,
      onError: (Object e, StackTrace st) {
        appNotice.value = 'Playback error: $e';
      },
    );

    player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) _onCompleted();
    });

    player.durationStream.listen((d) {
      final item = mediaItem.value;
      if (d != null && item != null && d != item.duration) {
        mediaItem.add(item.copyWith(duration: d));
      }
    });
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

  // ── Library management ────────────────────────────────────────────────────

  Future<void> setTracks(List<TrackItem> list) async {
    final currentId = currentTrack?.id;
    tracks = list;
    _publishQueue();
    if (list.isEmpty) return;
    final keep = currentId == null
        ? -1
        : list.indexWhere((t) => t.id == currentId);
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

  // ── Loading / playing ─────────────────────────────────────────────────────

  Future<void> _load(int i, {bool play = true}) async {
    if (i < 0 || i >= tracks.length) return;
    final seq = ++_loadSeq;
    _index = i;
    currentIndex.value = i;
    final t = tracks[i];
    mediaItem.add(t.toMediaItem());
    try {
      await player.setAudioSource(AudioSource.uri(t.uri));
      if (seq != _loadSeq) return;
      _loadedId = t.id;
      if (play) player.play();
    } on PlayerInterruptedException {
      return;
    } catch (e) {
      if (seq != _loadSeq) return;
      _loadedId = null;
      appNotice.value = 'Couldn\'t play "${t.title}".';
    }
  }

  /// Plays the track at [i]; if it is already loaded it just resumes.
  Future<void> playIndex(int i) async {
    if (i < 0 || i >= tracks.length) return;
    if (i == _index &&
        _loadedId == tracks[i].id &&
        player.processingState != ProcessingState.idle) {
      player.play();
      return;
    }
    await _load(i, play: true);
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
    // Let the player itself loop the current track for "repeat one".
    await player.setLoopMode(
      repeatMode == AudioServiceRepeatMode.one ? LoopMode.one : LoopMode.off,
    );
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
  }

  @override
  Future<void> setSpeed(double speed) async {
    await player.setSpeed(speed);
    playbackState.add(playbackState.value.copyWith(speed: speed));
  }

  Future<void> setPitch(double pitch) async {
    try {
      await player.setPitch(pitch);
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
  // Needed on Android 13+ so the media notification / lock screen shows.
  await Permission.notification.request();
  return status.isGranted;
}

Future<void> scanDeviceAudio() async {
  if (!Platform.isAndroid || scanning.value) return;
  scanning.value = true;
  try {
    final granted = await ensureMediaPermissions();
    if (!granted) {
      appNotice.value = 'Allow music access to load your songs.';
      return;
    }
    final raw =
        await _mediaChannel.invokeMethod<List<dynamic>>('scanDeviceAudio') ??
            const [];
    final scanned = <TrackItem>[];
    for (var i = 0; i < raw.length; i++) {
      final m = Map<String, dynamic>.from(raw[i] as Map);
      final uri = (m['uri'] ?? '').toString();
      final path = (m['filePath'] ?? '').toString();
      final source = uri.isNotEmpty ? uri : path;
      if (source.isEmpty) continue;
      final t = TrackItem(
        id: 'ms_${m['id']}',
        title: cleanText(m['title'], 'Unknown Track'),
        artist: cleanText(m['artist'], 'Unknown Artist'),
        album: cleanText(m['album'], 'Local Album'),
        durationSeconds: (m['durationSeconds'] as num?)?.toInt() ?? 0,
        artColors: kArtPalettes[i % kArtPalettes.length],
        artStyle: kArtStyles[i % kArtStyles.length],
        source: source,
        filePath: path.isEmpty ? null : path,
      );
      appState.applyEdits(t);
      scanned.add(t);
    }
    final imported =
        audioHandler.tracks.where((t) => t.id.startsWith('local_')).toList();
    await audioHandler.setTracks([...imported, ...scanned]);
    if (scanned.isEmpty && imported.isEmpty) {
      appNotice.value = 'No music files found on this device.';
    }
  } catch (e) {
    appNotice.value = 'Scan failed: $e';
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
    final t = TrackItem(
      id: 'local_${stamp}_$i',
      title: p.basenameWithoutExtension(path),
      artist: 'Unknown Artist',
      album: 'Local Files',
      durationSeconds: 0,
      artColors: kArtPalettes[i % kArtPalettes.length],
      artStyle: kArtStyles[i % kArtStyles.length],
      source: path,
      filePath: path,
    );
    added.add(t);
  }
  if (added.isNotEmpty) await audioHandler.addTracks(added, playFirst: true);
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
  int _tab = 0; // 0 Home, 1 Mix, 2 Library
  int _dir = 1; // slide direction of the last tab change
  String _chip = 'All';

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
              SafeArea(
                bottom: false,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 380),
                  switchInCurve: kEmphasizedDecel,
                  switchOutCurve: kEmphasizedAccel,
                  transitionBuilder: (child, anim) {
                    // shared-axis: new tab slides in from the travel direction,
                    // old tab slides out the opposite way.
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
                        child: MiniPlayer(track: audioHandler.currentTrack!, palette: pal),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _navBar(pal)),
                        const SizedBox(width: 10),
                        SquishyGesture(
                          onTap: () => showSearchSheet(context),
                          child: Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: pal.surface,
                              shape: BoxShape.circle,
                              boxShadow: _shadow,
                            ),
                            child: const Icon(
                              Icons.search_rounded,
                              color: Color(0xFFD5DCE0),
                              size: 26,
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
    return Container(
      height: 68,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(36),
        boxShadow: _shadow,
      ),
      child: Row(
        children: [
          _navTab(pal, 0, Icons.home_rounded, 'Home'),
          _navTab(pal, 1, Icons.sensors_rounded, 'Mix'),
          _navTab(pal, 2, Icons.library_music_rounded, 'Library'),
        ],
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
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected ? pal.container : Colors.transparent,
            borderRadius: BorderRadius.circular(30),
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
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? pal.accent : const Color(0xFFB3B9BE),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Home ──────────────────────────────────────────────────────────────────

  Widget _homeTab(BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(color: pal.container, shape: BoxShape.circle),
            child: Icon(Icons.headphones_rounded, color: pal.accent, size: 24),
          ),
          const SizedBox(width: 12),
          _chipButton(pal, 'All'),
          const SizedBox(width: 10),
          _chipButton(pal, 'Mood'),
          const Spacer(),
          SquishyGesture(
            onTap: () => showAddMusicSheet(context),
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: pal.surface,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF333B40)),
              ),
              child: const Icon(Icons.add_rounded, color: Color(0xFFD5DCE0), size: 24),
            ),
          ),
          const SizedBox(width: 12),
          SquishyGesture(
            onTap: () => showSettingsSheet(context),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.settings_rounded, color: Colors.white, size: 26),
            ),
          ),
        ],
      ),
    );

    if (tracks.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(top: 10, bottom: 185),
        children: [
          header,
          const SizedBox(height: 90),
          _emptyState(context, pal),
        ],
      );
    }

    final col1 = tracks.take(4).toList();
    final col2 = tracks.skip(4).take(4).toList();
    final listenAgain = tracks.reversed.take(8).toList();
    final colWidth = MediaQuery.of(context).size.width - 42;

    return ListView(
      padding: const EdgeInsets.only(top: 10, bottom: 185),
      children: [
        Reveal(child: header),
        const SizedBox(height: 24),
        _sectionHeader(
          "LET'S START WITH A RADIO",
          'Quick picks',
          trailing: SquishyGesture(
            onTap: () => playAndOpen(context, 0),
            child: const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Text(
                'Play all',
                style: TextStyle(
                  color: Color(0xFFB3B9BE),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
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
        const SizedBox(height: 22),
        _sectionHeader('LIBRARY RECENT', 'Listen again'),
        const SizedBox(height: 14),
        SizedBox(
          height: 230,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: listenAgain.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final t = listenAgain[i];
              return SquishyGesture(
                pressedScale: 0.95,
                onTap: () => playAndOpen(context, tracks.indexOf(t)),
                child: SizedBox(
                  width: 168,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          width: 168,
                          height: 168,
                          child: CustomAlbumArtwork(track: t),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFF9EA6AC), fontSize: 13),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
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
            'Allow music access, then scan or pick files to get started.',
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

  Widget _chipButton(AppPalette pal, String label) {
    final selected = _chip == label;
    return SquishyGesture(
      onTap: () => setState(() => _chip = label),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? pal.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected ? pal.accent : const Color(0xFF3A4146),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? pal.onAccent : Colors.white,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            fontSize: 15,
          ),
        ),
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
                    fontWeight: FontWeight.w500,
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
      delayMs: min(max(idx, 0), 8) * 45,
      dy: 16,
      child: TrackRow(
        track: t,
        palette: pal,
        active: audioHandler.currentTrack?.id == t.id,
        onTap: () => playAndOpen(context, idx),
      ),
    );
  }

  // ── Mix ───────────────────────────────────────────────────────────────────

  Widget _mixTab(BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 185),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'CUSTOM STATIONS',
              style: TextStyle(color: Color(0xFF9EA6AC), fontSize: 12, letterSpacing: 0.8),
            ),
            SquishyGesture(
              onTap: () => showPlaylistEditDialog(context),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(Icons.edit_rounded, color: pal.accent, size: 20),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          appState.playlistName,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 16),
        if (tracks.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text('No tracks available for mix', style: TextStyle(color: Colors.white54)),
            ),
          ),
        for (var i = 0; i < tracks.length; i++)
          Reveal(
            delayMs: min(i, 8) * 45,
            child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SquishyGesture(
              pressedScale: 0.97,
              onTap: () => playAndOpen(context, i),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C2226),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: CustomAlbumArtwork(track: tracks[i]),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tracks[i].title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            tracks[i].artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Color(0xFFA6ADB2)),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: pal.accent, shape: BoxShape.circle),
                      child: Icon(Icons.play_arrow_rounded, color: pal.onAccent),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ),
      ],
    );
  }

  // ── Library ───────────────────────────────────────────────────────────────

  Widget _libraryTab(BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 185),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Library',
              style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800),
            ),
            SquishyGesture(
              onTap: () => showAddMusicSheet(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: pal.container,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_open_rounded, color: pal.accent, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Import',
                      style: TextStyle(color: pal.accent, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (tracks.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(
              child: Text(
                'No local audio files found.',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
            ),
          ),
        ...tracks.map((t) => _trackRow(context, pal, t)),
      ],
    );
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
// Reusable widgets
// ─────────────────────────────────────────────────────────────────────────────

// Material 3 motion curves
const Curve kEmphasized = Cubic(0.2, 0.0, 0.0, 1.0);
const Curve kEmphasizedDecel = Cubic(0.05, 0.7, 0.1, 1.0);
const Curve kEmphasizedAccel = Cubic(0.3, 0.0, 0.8, 0.15);

/// Fade + slide-up entrance (staggered with [delayMs]).
class Reveal extends StatelessWidget {
  final int delayMs;
  final double dy;
  final Widget child;

  const Reveal({super.key, this.delayMs = 0, this.dy = 22, required this.child});

  @override
  Widget build(BuildContext context) {
    final total = 480 + delayMs;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delayMs / total, 1.0, curve: kEmphasizedDecel),
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0).toDouble(),
        child: Transform.translate(offset: Offset(0, (1 - t) * dy), child: child),
      ),
      child: child,
    );
  }
}

/// Animated equalizer bars shown on the currently playing row.
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
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
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

/// Drag the whole screen down to dismiss it (follows the finger, springs back).
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
    if (_c.value > h * 0.16 || v > 900) {
      HapticFeedback.lightImpact();
      setState(() => _dismissing = true); // disables the hero flight
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
        child: track == null ? const SizedBox() : CustomAlbumArtwork(track: track),
      );
    },
  );
}

RectTween _arcTween(Rect? begin, Rect? end) =>
    MaterialRectArcTween(begin: begin, end: end);

/// Wraps any widget with a springy "squish" press effect + light haptic.
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
    // Make sure even very quick taps visibly squish before bouncing back.
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

  const TrackRow({
    super.key,
    required this.track,
    required this.palette,
    required this.active,
    required this.onTap,
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
              borderRadius: BorderRadius.circular(10),
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
          ],
        ),
      ),
    );
  }
}

/// Rebuilds with live position + duration of the current track.
class TrackProgress extends StatelessWidget {
  final int fallbackSeconds;
  final Widget Function(BuildContext context, Duration position, Duration duration)
      builder;

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

class MiniPlayer extends StatelessWidget {
  final TrackItem track;
  final AppPalette palette;

  const MiniPlayer({super.key, required this.track, required this.palette});

  @override
  Widget build(BuildContext context) {
    return SquishyGesture(
      pressedScale: 0.97,
      onTap: () => openPlayer(context),
      child: Container(
        height: 66,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(34),
          boxShadow: _shadow,
        ),
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
                          ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                          : 0.0;
                      return SizedBox(
                        width: 46,
                        height: 46,
                        child: CircularProgressIndicator(
                          value: v,
                          strokeWidth: 2.6,
                          backgroundColor: const Color(0xFF2E373D),
                          valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
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
                decoration: BoxDecoration(color: palette.container, shape: BoxShape.circle),
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
                final playing = (snap.data ?? audioHandler.playbackState.value).playing;
                return SquishyGesture(
                  onTap: () => playing ? audioHandler.pause() : audioHandler.play(),
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(color: palette.accent, shape: BoxShape.circle),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (c, a) => ScaleTransition(
                        scale: a,
                        child: FadeTransition(opacity: a, child: c),
                      ),
                      child: Icon(
                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
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
            final loading = state.processingState == AudioProcessingState.loading;
            final shuffle = state.shuffleMode == AudioServiceShuffleMode.all;
            final repeat = state.repeatMode;
            final liked = appState.isLiked(track.id);

            return SwipeDownDismiss(
              child: Scaffold(
              backgroundColor: pal.playerBg,
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          SquishyGesture(
                            onTap: () => Navigator.of(context).pop(),
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: pal.playerSurface,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                          ),
                          Column(
                            children: [
                              const Text(
                                'NOW PLAYING',
                                style: TextStyle(
                                  color: Color(0xFFE5DDD9),
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.8,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                track.album,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                          SquishyGesture(
                            onTap: () => showEditTrackDialog(context, track),
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: pal.playerSurface,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Icon(Icons.edit_rounded, color: Colors.white, size: 22),
                            ),
                          ),
                        ],
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: 1.0,
                              child: AnimatedScale(
                                scale: playing ? 1.0 : 0.9,
                                duration: const Duration(milliseconds: 450),
                                curve: Curves.easeOutBack,
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(28),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.45),
                                        blurRadius: 24,
                                        offset: const Offset(0, 12),
                                      ),
                                    ],
                                  ),
                                  child: Hero(
                                    tag: 'now_playing_art',
                                    createRectTween: _arcTween,
                                    flightShuttleBuilder: _artShuttle,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(28),
                                      child: AnimatedSwitcher(
                                        duration: const Duration(milliseconds: 450),
                                        switchInCurve: kEmphasizedDecel,
                                        transitionBuilder: (c, a) => FadeTransition(
                                          opacity: a,
                                          child: ScaleTransition(
                                            scale: Tween<double>(begin: 0.92, end: 1.0)
                                                .animate(a),
                                            child: c,
                                          ),
                                        ),
                                        child: KeyedSubtree(
                                          key: ValueKey('${track.id}_${track.artStyle}'),
                                          child: CustomAlbumArtwork(track: track),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Reveal(
                        delayMs: 120,
                        child: Row(
                        children: [
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
                          const SizedBox(width: 12),
                          SquishyGesture(
                            onTap: () => appState.toggleLike(track.id),
                            child: Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: pal.playerSurface,
                                shape: BoxShape.circle,
                              ),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                                child: Icon(
                                  liked
                                      ? Icons.favorite_rounded
                                      : Icons.favorite_border_rounded,
                                  key: ValueKey(liked),
                                  color: liked ? pal.playerAccent : const Color(0xFFEAE0DC),
                                  size: 24,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      ),
                      const SizedBox(height: 14),
                      Reveal(
                        delayMs: 180,
                        child: SeekBar(
                          fallbackSeconds: track.durationSeconds,
                          active: pal.playerAccent,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Reveal(
                        delayMs: 240,
                        child: Row(
                        children: [
                          SquishyGesture(
                            onTap: audioHandler.skipToPrevious,
                            child: Container(
                              width: 88,
                              height: 70,
                              decoration: BoxDecoration(
                                color: pal.playerButton,
                                borderRadius: BorderRadius.circular(35),
                              ),
                              child: const Icon(
                                Icons.skip_previous_rounded,
                                color: Color(0xFFF6E6DF),
                                size: 32,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SquishyGesture(
                              pressedScale: 0.94,
                              onTap: () =>
                                  playing ? audioHandler.pause() : audioHandler.play(),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 450),
                                curve: kEmphasized,
                                height: 70,
                                decoration: BoxDecoration(
                                  color: pal.playerAccent,
                                  borderRadius: BorderRadius.circular(playing ? 24 : 35),
                                ),
                                child: loading
                                    ? Center(
                                        child: SizedBox(
                                          width: 26,
                                          height: 26,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 3,
                                            color: pal.playerOnAccent,
                                          ),
                                        ),
                                      )
                                    : AnimatedSwitcher(
                                        duration: const Duration(milliseconds: 200),
                                        transitionBuilder: (c, a) => ScaleTransition(
                                          scale: a,
                                          child: FadeTransition(opacity: a, child: c),
                                        ),
                                        child: Icon(
                                          playing
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                          key: ValueKey(playing),
                                          color: pal.playerOnAccent,
                                          size: 36,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SquishyGesture(
                            onTap: audioHandler.skipToNext,
                            child: Container(
                              width: 88,
                              height: 70,
                              decoration: BoxDecoration(
                                color: pal.playerButton,
                                borderRadius: BorderRadius.circular(35),
                              ),
                              child: const Icon(
                                Icons.skip_next_rounded,
                                color: Color(0xFFF6E6DF),
                                size: 32,
                              ),
                            ),
                          ),
                        ],
                      ),
                      ),
                      const SizedBox(height: 18),
                      Reveal(
                        delayMs: 300,
                        child: ClipRRect(
                        borderRadius: BorderRadius.circular(26),
                        child: SizedBox(
                          height: 52,
                          child: Row(
                            children: [
                              _segBtn(pal, Icons.info_rounded, false,
                                  () => showTrackInfoDialog(context, track),
                                  isFirst: true),
                              const SizedBox(width: 3),
                              _segBtn(pal, Icons.tune_rounded, false,
                                  () => showPlaybackSheet(context)),
                              const SizedBox(width: 3),
                              _segBtn(pal, Icons.shuffle_rounded, shuffle, () {
                                audioHandler.setShuffleMode(
                                  shuffle
                                      ? AudioServiceShuffleMode.none
                                      : AudioServiceShuffleMode.all,
                                );
                              }),
                              const SizedBox(width: 3),
                              _segBtn(
                                pal,
                                repeat == AudioServiceRepeatMode.one
                                    ? Icons.repeat_one_rounded
                                    : Icons.repeat_rounded,
                                repeat != AudioServiceRepeatMode.none,
                                () {
                                  final next = switch (repeat) {
                                    AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
                                    AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
                                    _ => AudioServiceRepeatMode.none,
                                  };
                                  audioHandler.setRepeatMode(next);
                                },
                              ),
                              const SizedBox(width: 3),
                              _segBtn(pal, Icons.playlist_add_rounded, false,
                                  () => showAddMusicSheet(context)),
                              const SizedBox(width: 3),
                              _segBtn(pal, Icons.queue_music_rounded, false,
                                  () => showQueueSheet(context)),
                              const SizedBox(width: 3),
                              _segBtn(pal, Icons.comment_rounded, false,
                                  () => showLyricsSheet(context, track),
                                  isLast: true),
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
            ));
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
            color: active ? pal.playerAccent : const Color(0xFFEAE0DC),
            size: 21,
          ),
        ),
      ),
    );
  }
}

class SeekBar extends StatefulWidget {
  final int fallbackSeconds;
  final Color active;

  const SeekBar({super.key, required this.fallbackSeconds, required this.active});

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return TrackProgress(
      fallbackSeconds: widget.fallbackSeconds,
      builder: (context, pos, dur) {
        final maxMs = max(dur.inMilliseconds, 1).toDouble();
        final value =
            (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, maxMs).toDouble();
        final shown = Duration(milliseconds: value.toInt());
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 5,
                activeTrackColor: widget.active,
                inactiveTrackColor: const Color(0xFF42312B),
                thumbColor: widget.active,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7.5),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: value,
                min: 0,
                max: maxMs,
                onChanged: (v) => setState(() => _drag = v),
                onChangeEnd: (v) {
                  audioHandler.seek(Duration(milliseconds: v.toInt()));
                  setState(() => _drag = null);
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
                    style: const TextStyle(color: Color(0xFFC8BDB7), fontSize: 13.5),
                  ),
                  Text(
                    formatDuration(dur),
                    style: const TextStyle(color: Color(0xFFC8BDB7), fontSize: 13.5),
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

// ─────────────────────────────────────────────────────────────────────────────
// Sheets & dialogs
// ─────────────────────────────────────────────────────────────────────────────

Future<T?> _sheet<T>(BuildContext context, WidgetBuilder builder,
    {bool scroll = false, Color? color}) {
  return showModalBottomSheet<T>(
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

Widget _sheetTile(AppPalette pal, IconData icon, String title, String subtitle,
    VoidCallback onTap) {
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
                  style: const TextStyle(color: Color(0xFFA6ADB2), fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
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
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'AlexLMP Settings',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
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
                  style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Row(
                  children: AppPalette.all.map((t) {
                    final selected = appState.themeName == t.name;
                    return Expanded(
                      child: SquishyGesture(
                        onTap: () => appState.setTheme(t.name),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: selected ? t.accent : pal.container,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            children: [
                              Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: selected ? t.onAccent : t.accent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                t.name.split(' ').first,
                                style: TextStyle(
                                  color: selected ? t.onAccent : Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Stop music on task clear'),
                  subtitle: const Text('Stops playback when swiped away from recents'),
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
              ],
            ),
          ),
        );
      },
    ),
  );
}

void showPlaybackSheet(BuildContext context) {
  _sheet(
    context,
    (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final pal = appState.palette;
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
                      'Playback',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
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
                        child: Text('Reset', style: TextStyle(color: pal.playerAccent)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Speed: ${appState.speed.toStringAsFixed(2)}x',
                    style: const TextStyle(color: Colors.white70)),
                Slider(
                  value: appState.speed,
                  min: 0.5,
                  max: 2.0,
                  divisions: 30,
                  activeColor: pal.playerAccent,
                  onChanged: (v) {
                    appState.setSpeed(v);
                    audioHandler.setSpeed(v);
                  },
                ),
                Text('Pitch: ${appState.pitch.toStringAsFixed(2)}x',
                    style: const TextStyle(color: Colors.white70)),
                Slider(
                  value: appState.pitch,
                  min: 0.5,
                  max: 1.5,
                  divisions: 20,
                  activeColor: pal.playerAccent,
                  onChanged: (v) {
                    appState.setPitch(v);
                    audioHandler.setPitch(v);
                  },
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
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
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
                            color: active ? pal.playerAccent : Colors.white,
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
                          child: const Icon(Icons.drag_handle_rounded, color: Colors.white54),
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

void showLyricsSheet(BuildContext context, TrackItem track) {
  final pal = appState.palette;
  _sheet(
    context,
    (ctx) => SizedBox(
      height: 260,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${track.title} — Lyrics',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: pal.playerAccent,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            const Expanded(
              child: Center(
                child: Text(
                  'No lyrics available for this local file.',
                  style: TextStyle(color: Colors.white60, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    color: pal.playerSurface,
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
          Text('Artist: ${track.artist}', style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 6),
          Text('Album: ${track.album}', style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 6),
          Text('File: ${track.filePath ?? track.source}',
              style: const TextStyle(color: Colors.white70)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text('Close', style: TextStyle(color: pal.playerAccent)),
        ),
      ],
    ),
  );
}

Widget _styleChips(String selected, ValueChanged<String> onSelect, AppPalette pal) {
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
        title: const Text('Edit Song Details', style: TextStyle(color: Colors.white)),
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
              const Text('Album art style',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
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
        title: const Text('Edit Playlist', style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Playlist Title',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 18),
              const Text('Cover style',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
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
              appState.setPlaylist(name.isEmpty ? appState.playlistName : name, style);
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
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final pal = appState.palette;
    final tracks = audioHandler.tracks;
    final q = _query.toLowerCase();
    final filtered = tracks.where((t) {
      return t.title.toLowerCase().contains(q) ||
          t.artist.toLowerCase().contains(q) ||
          t.album.toLowerCase().contains(q);
    }).toList();

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
                  hintText: 'Search songs & artists...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  prefixIcon: Icon(Icons.search, color: pal.accent),
                  filled: true,
                  fillColor: pal.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: filtered.isEmpty
                    ? const Center(
                        child: Text(
                          'No songs found.',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final t = filtered[i];
                          return TrackRow(
                            track: t,
                            palette: pal,
                            active: audioHandler.currentTrack?.id == t.id,
                            onTap: () {
                              final idx = tracks.indexOf(t);
                              Navigator.pop(context);
                              playAndOpen(widget.parentContext, idx);
                            },
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
}

// ─────────────────────────────────────────────────────────────────────────────
// Artwork
// ─────────────────────────────────────────────────────────────────────────────

final Map<String, Future<Uint8List?>> _artCache = {};

/// Fetches the real embedded / MediaStore album art (cached per track).
Future<Uint8List?> loadArt(TrackItem t) {
  return _artCache.putIfAbsent(t.id, () async {
    if (!Platform.isAndroid) return null;
    try {
      return await _mediaChannel.invokeMethod<Uint8List>('getArt', {
        'uri': t.source,
        'path': t.filePath ?? '',
      });
    } catch (_) {
      return null;
    }
  });
}

class CustomAlbumArtwork extends StatelessWidget {
  final TrackItem track;

  const CustomAlbumArtwork({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final placeholder = CustomPaint(
      painter: _ArtworkSymbolPainter(style: track.artStyle, colors: track.artColors),
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
              : SizedBox.expand(key: ValueKey('ph_${track.id}'), child: placeholder),
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
      canvas.drawCircle(center, s * 0.12, Paint()..color = const Color(0xFFFFB59C));
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
      canvas.drawCircle(Offset(center.dx - 15 * k, center.dy + 10 * k), 8 * k, note);
      canvas.drawCircle(Offset(center.dx + 15 * k, center.dy + 5 * k), 8 * k, note);
      canvas.drawLine(Offset(center.dx - 7 * k, center.dy + 10 * k),
          Offset(center.dx - 7 * k, center.dy - 15 * k), stem);
      canvas.drawLine(Offset(center.dx + 23 * k, center.dy + 5 * k),
          Offset(center.dx + 23 * k, center.dy - 20 * k), stem);
      canvas.drawLine(Offset(center.dx - 7 * k, center.dy - 15 * k),
          Offset(center.dx + 23 * k, center.dy - 20 * k), stem);
    } else if (style == 'equalizer_bars') {
      final bar = Paint()..strokeWidth = max(2.0, s * 0.045);
      const heights = [0.3, 0.6, 0.9, 0.5, 0.7, 0.4];
      double x = size.width * 0.2;
      for (int i = 0; i < heights.length; i++) {
        bar.color = i % 2 == 0 ? const Color(0xFF8CD0F0) : const Color(0xFFFFB59C);
        final h = size.height * 0.4 * heights[i];
        canvas.drawLine(Offset(x, center.dy + h), Offset(x, center.dy - h), bar);
        x += size.width * 0.12;
      }
    } else if (style == 'neon_vinyl') {
      final neon = Paint()
        ..color = const Color(0xFFF09CE2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(2.0, s * 0.02);
      canvas.drawCircle(center, s * 0.35, neon);
      canvas.drawCircle(center, s * 0.22, neon);
      canvas.drawCircle(center, s * 0.08, Paint()..color = const Color(0xFF9CF0C0));
    }
  }

  @override
  bool shouldRepaint(covariant _ArtworkSymbolPainter old) =>
      old.style != style || old.colors != colors;
}
