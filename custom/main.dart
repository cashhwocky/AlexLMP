import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

late final MyAudioHandler audioHandler;
final AppState appState = AppState();
final ValueNotifier<String?> appNotice = ValueNotifier<String?>(null);
final ValueNotifier<bool> scanning = ValueNotifier<bool>(false);
const MethodChannel _mediaChannel = MethodChannel('com.alexlmp.app/media');
const List<String> kArtStyles = ['vinyl_record', 'sound_wave', 'music_note_grid', 'equalizer_bars'];
const List<List<Color>> kArtPalettes = [
  [Color(0xFF3E1C0C), Color(0xFFD96B38), Color(0xFF1A0F0A)],
  [Color(0xFF42173B), Color(0xFFE0538A), Color(0xFF28193D)],
  [Color(0xFF062A4E), Color(0xFF1F7AE0), Color(0xFF0A2416)],
  [Color(0xFF1A3A2A), Color(0xFF9C27B0), Color(0xFF00BCD4)],
];
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.transparent),
  );
  await appState.load();
  try {
    audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.alexlmp.app.channel',
        androidNotificationChannelName: 'AlexLMP Playback',
        androidNotificationOngoing: true,
      ),
    );
  } catch (_) {
    audioHandler = MyAudioHandler();
  }
  runApp(const AlexLmpApp());
}
String formatDuration(Duration d) {
  final total = d.inSeconds;
  return '${(total ~/ 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
}
Future<String?> pickAndSaveGalleryImage() async {
  try {
    final res = await FilePicker.platform.pickFiles(type: FileType.image);
    if (res == null || res.files.isEmpty) return null;
    final srcPath = res.files.single.path;
    if (srcPath == null) return null;
    final dir = await getApplicationDocumentsDirectory();
    final dst = p.join(dir.path, 'pl_cover_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await File(srcPath).copy(dst);
    return dst;
  } catch (_) { return null; }
}
class Playlist {
  final String id;
  String name;
  String? cover;
  final List<String> trackIds;
  Playlist({required this.id, required this.name, this.cover, List<String>? trackIds}) : trackIds = trackIds ?? [];
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'cover': cover, 'tracks': trackIds};
  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: j['id'], name: j['name'], cover: j['cover'], trackIds: List<String>.from(j['tracks'] ?? []),
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
    required this.id, required this.title, required this.artist, required this.album,
    required this.durationSeconds, required this.artColors, required this.source,
    this.artStyle = 'vinyl_record', this.filePath,
  });
  Uri get playbackUri {
    if (filePath != null && filePath!.isNotEmpty && File(filePath!).existsSync()) return Uri.file(filePath!);
    return source.startsWith('content://') ? Uri.parse(source) : Uri.file(source);
  }
  MediaItem toMediaItem() => MediaItem(id: id, title: title, artist: artist, album: album, duration: Duration(seconds: durationSeconds));
}
class AppState extends ChangeNotifier {
  SharedPreferences? _prefs;
  Color seedColor = const Color(0xFFD0BCFF);
  bool useAmoled = true;
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
    linkSpeedAndPitch = _prefs?.getBool('link_speed_pitch') ?? false;
    speed = _prefs?.getDouble('speed') ?? 1.0;
    pitch = _prefs?.getDouble('pitch') ?? 1.0;
    liked.addAll(_prefs?.getStringList('liked') ?? []);
    deletedIds.addAll(_prefs?.getStringList('deleted') ?? []);
    try {
      final raw = jsonDecode(_prefs?.getString('playlists') ?? '[]') as List;
      playlists..clear()..addAll(raw.map((e) => Playlist.fromJson(Map<String, dynamic>.from(e))));
    } catch (_) {}
    try {
      _edits = Map<String, dynamic>.from(jsonDecode(_prefs?.getString('edits') ?? '{}'));
    } catch (_) {}
    notifyListeners();
  }
  void setSeedColor(Color c) { seedColor = c; _prefs?.setInt('seed_color', c.value); notifyListeners(); }
  void setAmoled(bool v) { useAmoled = v; _prefs?.setBool('use_amoled', v); notifyListeners(); }
  void setLinkSpeedAndPitch(bool v) { linkSpeedAndPitch = v; _prefs?.setBool('link_speed_pitch', v); notifyListeners(); }
  void setSpeed(double v) { speed = v.clamp(0.5, 2.0); _prefs?.setDouble('speed', speed); notifyListeners(); }
  void setPitch(double v) { pitch = v.clamp(0.5, 2.0); _prefs?.setDouble('pitch', pitch); notifyListeners(); }
  bool isDeleted(String id, [String? path]) => deletedIds.contains(id) || (path != null && deletedIds.contains(path));
  void markDeleted(TrackItem t) {
    deletedIds.add(t.id);
    if (t.filePath != null) deletedIds.add(t.filePath!);
    if (t.source.isNotEmpty) deletedIds.add(t.source);
    _prefs?.setStringList('deleted', deletedIds.toList());
    liked.remove(t.id);
    _prefs?.setStringList('liked', liked.toList());
    for (final pl in playlists) pl.trackIds.remove(t.id);
    _savePlaylists();
  }
  bool isLiked(String id) => liked.contains(id);
  void toggleLike(String id) {
    if (!liked.remove(id)) liked.add(id);
    _prefs?.setStringList('liked', liked.toList());
    notifyListeners();
  }
  Playlist? playlistById(String id) => playlists.where((p) => p.id == id).firstOrNull;
  void _savePlaylists() { _prefs?.setString('playlists', jsonEncode(playlists.map((p) => p.toJson()).toList())); notifyListeners(); }
  Playlist createPlaylist(String name, {String? cover}) {
    final pl = Playlist(id: 'pl_${DateTime.now().microsecondsSinceEpoch}', name: name.isEmpty ? 'New Playlist' : name, cover: cover);
    playlists.add(pl); _savePlaylists(); return pl;
  }
  void setPlaylistInfo(String id, String name, String? cover) {
    final pl = playlistById(id);
    if (pl != null) { pl.name = name.isEmpty ? pl.name : name; pl.cover = cover; _savePlaylists(); }
  }
  void deletePlaylist(String id) { playlists.removeWhere((p) => p.id == id); _savePlaylists(); }
  bool inPlaylist(String pid, String tid) => playlistById(pid)?.trackIds.contains(tid) ?? false;
  void togglePlaylistTrack(String pid, String tid) {
    final pl = playlistById(pid);
    if (pl != null) { if (!pl.trackIds.remove(tid)) pl.trackIds.add(tid); _savePlaylists(); }
  }
  void movePlaylistTrack(String pid, int from, int to) {
    final pl = playlistById(pid);
    if (pl != null) { final id = pl.trackIds.removeAt(from); pl.trackIds.insert(to.clamp(0, pl.trackIds.length), id); _savePlaylists(); }
  }
  void applyEdits(TrackItem t) {
    if (_edits[t.id] is Map) {
      final e = _edits[t.id];
      t.title = e['title'] ?? t.title; t.artist = e['artist'] ?? t.artist; t.artStyle = e['style'] ?? t.artStyle;
    }
  }
  void saveEdit(TrackItem t) {
    _edits[t.id] = {'title': t.title, 'artist': t.artist, 'style': t.artStyle};
    _prefs?.setString('edits', jsonEncode(_edits)); notifyListeners();
  }
}
class MyAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player = AudioPlayer(handleInterruptions: true, androidApplyAudioAttributes: true);
  List<TrackItem> tracks = [];
  int _index = 0;
  bool _shuffle = false;
  AudioServiceRepeatMode _repeat = AudioServiceRepeatMode.none;
  final ValueNotifier<int> currentIndex = ValueNotifier<int>(0);
  MyAudioHandler() { _init(); }
  int get index => _index;
  TrackItem? get currentTrack => (_index >= 0 && _index < tracks.length) ? tracks[_index] : null;
  TrackItem? trackById(String id) => tracks.where((t) => t.id == id).firstOrNull;
  Future<void> _init() async {
    try { await AudioSession.instance.then((s) => s.configure(const AudioSessionConfiguration.music())); } catch (_) {}
    try { await player.setSkipSilenceEnabled(false); } catch (_) {}
    player.playbackEventStream.map(_transformEvent).listen(playbackState.add, onError: (_, __) {});
    player.processingStateStream.listen((state) {
      if (state == ProcessingState.ready) _applySpeedAndPitch();
      else if (state == ProcessingState.completed) _onCompleted();
    });
    player.playingStream.listen((playing) { if (playing) _applySpeedAndPitch(); });
    player.durationStream.listen((d) {
      final item = mediaItem.value;
      if (d != null && item != null && d != item.duration) mediaItem.add(item.copyWith(duration: d));
    });
  }
  Future<void> _applySpeedAndPitch() async {
    try { await player.setSpeed(appState.speed); } catch (_) {}
    try { await player.setPitch(appState.pitch); } catch (_) {}
  }
  PlaybackState _transformEvent(PlaybackEvent event) => PlaybackState(
    controls: [MediaControl.skipToPrevious, player.playing ? MediaControl.pause : MediaControl.play, MediaControl.skipToNext],
    systemActions: const {MediaAction.seek},
    androidCompactActionIndices: const [0, 1, 2],
    processingState: const {
      ProcessingState.idle: AudioProcessingState.idle, ProcessingState.loading: AudioProcessingState.loading,
      ProcessingState.buffering: AudioProcessingState.buffering, ProcessingState.ready: AudioProcessingState.ready,
      ProcessingState.completed: AudioProcessingState.completed,
    }[player.processingState]!,
    playing: player.playing,
    updatePosition: player.position,
    speed: player.speed,
    queueIndex: _index,
    shuffleMode: _shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
    repeatMode: _repeat,
  );
  Future<void> setTracks(List<TrackItem> list) async {
    final cid = currentTrack?.id;
    tracks = list;
    if (list.isEmpty) return;
    final keep = list.indexWhere((t) => t.id == cid);
    if (keep >= 0) { _index = keep; currentIndex.value = keep; } else { await _load(0, play: false); }
  }
  Future<void> deleteTrackFromLibrary(TrackItem t) async {
    final removeIdx = tracks.indexWhere((x) => x.id == t.id);
    final wasCurrent = currentTrack?.id == t.id;
    appState.markDeleted(t);
    if (t.filePath != null && t.filePath!.isNotEmpty) { try { File(t.filePath!).deleteSync(); } catch (_) {} }
    if (removeIdx >= 0) {
      final wasPlaying = player.playing;
      tracks.removeAt(removeIdx);
      if (tracks.isEmpty) { _index = 0; currentIndex.value = 0; await player.stop(); mediaItem.add(null); }
      else if (wasCurrent) {
        if (_index >= tracks.length) _index = 0;
        currentIndex.value = _index; await _load(_index, play: wasPlaying);
      } else if (removeIdx < _index) { _index = math.max(0, _index - 1); currentIndex.value = _index; }
    }
  }
  void moveTrack(int o, int n) {
    final item = tracks.removeAt(o);
    tracks.insert(n, item);
    if (_index == o) _index = n;
    else if (o < _index && n >= _index) _index--;
    else if (o > _index && n <= _index) _index++;
    currentIndex.value = _index;
  }
  Future<void> _load(int i, {bool play = true}) async {
    if (i < 0 || i >= tracks.length) return;
    _index = i; currentIndex.value = i;
    final t = tracks[i];
    mediaItem.add(t.toMediaItem());
    try {
      try { await player.setAudioSource(AudioSource.uri(t.playbackUri)); } catch (_) {
        await player.setAudioSource(AudioSource.uri(t.source.startsWith('content://') ? Uri.parse(t.source) : Uri.file(t.source)));
      }
      await _applySpeedAndPitch();
      if (play) player.play();
    } catch (_) {}
  }
  Future<void> playIndex(int i) async {
    if (i == _index && player.processingState != ProcessingState.idle) { await _applySpeedAndPitch(); player.play(); return; }
    await _load(i, play: true);
  }
  Future<void> playTrackById(String id) async {
    final i = tracks.indexWhere((t) => t.id == id);
    if (i >= 0) await playIndex(i);
  }
  int? _nextIndex({required bool auto}) {
    if (tracks.isEmpty) return null;
    if (_shuffle && tracks.length > 1) { int n; do { n = math.Random().nextInt(tracks.length); } while (n == _index); return n; }
    final n = _index + 1;
    if (n < tracks.length) return n;
    if (_repeat == AudioServiceRepeatMode.all || !auto) return 0;
    return null;
  }
  Future<void> _onCompleted() async {
    if (_repeat == AudioServiceRepeatMode.one) { await player.seek(Duration.zero); player.play(); return; }
    final n = _nextIndex(auto: true);
    if (n == null) await _load(0, play: false); else await _load(n, play: true);
  }
  @override Future<void> play() async { if (tracks.isNotEmpty) { await _applySpeedAndPitch(); player.play(); } }
  @override Future<void> pause() => player.pause();
  @override Future<void> seek(Duration position) => player.seek(position);
  @override Future<void> skipToNext() async { final n = _nextIndex(auto: false); if (n != null) await _load(n, play: true); }
  @override Future<void> skipToPrevious() async {
    if (tracks.isEmpty) return;
    if (player.position.inSeconds > 3) { await player.seek(Duration.zero); return; }
    int prev = _shuffle ? math.Random().nextInt(tracks.length) : (_index - 1 + tracks.length) % tracks.length;
    await _load(prev, play: true);
  }
  @override Future<void> stop() async { await player.stop(); await super.stop(); }
  @override Future<void> setShuffleMode(AudioServiceShuffleMode s) async { _shuffle = s == AudioServiceShuffleMode.all; playbackState.add(playbackState.value.copyWith(shuffleMode: s)); }
  @override Future<void> setRepeatMode(AudioServiceRepeatMode r) async { _repeat = r; await player.setLoopMode(r == AudioServiceRepeatMode.one ? LoopMode.one : LoopMode.off); playbackState.add(playbackState.value.copyWith(repeatMode: r)); }
}
Future<void> scanDeviceAudio() async {
  if (!Platform.isAndroid || scanning.value) return;
  scanning.value = true;
  try {
    if (!(await Permission.audio.request().then((s) => s.isGranted || Permission.storage.request().then((s2) => s2.isGranted)))) return;
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
        id: id, title: title, artist: cleanText(m['artist'], 'Unknown Artist'), album: cleanText(m['album'], 'Local Audio'),
        durationSeconds: (m['durationSeconds'] as num?)?.toInt() ?? 0,
        artColors: kArtPalettes[i % kArtPalettes.length], artStyle: kArtStyles[i % kArtStyles.length],
        source: source, filePath: fp.isEmpty ? null : fp,
      );
      appState.applyEdits(t);
      scanned.add(t);
    }
    final existingLocal = audioHandler.tracks.where((t) => t.id.startsWith('local_') && !appState.isDeleted(t.id, t.filePath)).toList();
    await audioHandler.setTracks([...existingLocal, ...scanned]);
  } catch (_) {} finally { scanning.value = false; }
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
      id: id, title: p.basenameWithoutExtension(path), artist: 'Local File', album: 'Imported',
      durationSeconds: 0, artColors: kArtPalettes[i % kArtPalettes.length], artStyle: kArtStyles[i % kArtStyles.length],
      source: path, filePath: path,
    );
    added.add(t);
  }
  if (added.isNotEmpty) {
    await audioHandler.setTracks([...added, ...audioHandler.tracks]);
    await audioHandler.playIndex(0);
  }
}
final Map<String, Object?> _artCache = {};
Future<Uint8List?> loadArt(TrackItem t) {
  final ex = _artCache[t.id];
  if (ex is Future<Uint8List?>) return ex;
  final fut = _fetchArt(t); _artCache[t.id] = fut; return fut;
}
Future<Uint8List?> _fetchArt(TrackItem t) async {
  if (!Platform.isAndroid) return null;
  try {
    final res = await _mediaChannel.invokeMethod('getArt', {'uri': t.source, 'path': t.filePath ?? ''});
    return res is Uint8List ? res : null;
  } catch (_) { return null; }
}
class CustomAlbumArtwork extends StatelessWidget {
  final TrackItem track;
  const CustomAlbumArtwork({super.key, required this.track});
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: loadArt(track),
      builder: (ctx, snap) {
        final placeholder = CustomPaint(painter: _ArtPainter(track.artStyle, track.artColors), child: const SizedBox.expand());
        if (snap.data != null && snap.data!.isNotEmpty) {
          return Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_,__,___) => placeholder);
        }
        return placeholder;
      },
    );
  }
}
class _ArtPainter extends CustomPainter {
  final String style; final List<Color> colors;
  _ArtPainter(this.style, this.colors);
  @override void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = LinearGradient(colors: colors).createShader(rect));
    final center = Offset(size.width/2, size.height/2);
    final s = size.shortestSide;
    if (style == 'vinyl_record') {
      final g = Paint()..color = Colors.white12..style = PaintingStyle.stroke..strokeWidth = math.max(1, s*0.01);
      for(double r=s*0.15; r<s*0.45; r+=s*0.05) canvas.drawCircle(center, r, g);
      canvas.drawCircle(center, s*0.12, Paint()..color = Colors.white54);
      canvas.drawCircle(center, s*0.03, Paint()..color = Colors.black);
    } else {
      canvas.drawCircle(center, s*0.2, Paint()..color = Colors.white24);
    }
  }
  @override bool shouldRepaint(covariant _ArtPainter old) => old.style != style;
}
class AlexLmpApp extends StatelessWidget {
  const AlexLmpApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final cs = ColorScheme.fromSeed(seedColor: appState.seedColor, brightness: Brightness.dark);
        final bg = appState.useAmoled ? Colors.black : cs.surface;
        return MaterialApp(
          title: 'AlexLMP', debugShowCheckedModeBanner: false, themeMode: ThemeMode.dark,
          darkTheme: ThemeData(
            useMaterial3: true, colorScheme: cs.copyWith(surface: bg), scaffoldBackgroundColor: bg,
            sliderTheme: SliderThemeData(activeTrackColor: cs.primary, thumbColor: cs.primary),
          ),
          home: const MainScaffold(),
        );
      },
    );
  }
}
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});
  @override State<MainScaffold> createState() => _MainScaffoldState();
}
class _MainScaffoldState extends State<MainScaffold> {
  int _tab = 0;
  @override void initState() { super.initState(); scanDeviceAudio(); appNotice.addListener(_showNotice); }
  @override void dispose() { appNotice.removeListener(_showNotice); super.dispose(); }
  void _showNotice() {
    if (appNotice.value == null || !mounted) return;
    ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(appNotice.value!), behavior: SnackBarBehavior.floating));
    appNotice.value = null;
  }
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: audioHandler.currentIndex,
      builder: (ctx, _) {
        final track = audioHandler.currentTrack;
        return Scaffold(
          body: Stack(
            children: [
              IndexedStack(index: _tab, children: const [HomeTab(), LibraryTab()]),
              if (track != null)
                Positioned(left: 12, right: 12, bottom: 8, child: MiniPlayer(track: track)),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music_rounded), label: 'Library'),
            ],
          ),
        );
      },
    );
  }
}
void openPlayer(BuildContext context) {
  if (audioHandler.tracks.isEmpty) return;
  Navigator.push(context, MaterialPageRoute(builder: (_) => const NowPlayingScreen(), fullscreenDialog: true));
}
class HomeTab extends StatelessWidget {
  const HomeTab({super.key});
  @override
  Widget build(BuildContext context) {
    final tracks = audioHandler.tracks;
    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          title: const Text('Good Morning', style: TextStyle(fontWeight: FontWeight.bold)),
          actions: [IconButton(icon: const Icon(Icons.settings), onPressed: () => showSettingsSheet(context))],
        ),
        if (tracks.isEmpty)
          const SliverFillRemaining(child: Center(child: Text('No local songs found.')))
        else ...[
          SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: Text('All Songs', style: Theme.of(context).textTheme.titleLarge))),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => ListTile(
                leading: ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: tracks[i]))),
                title: Text(tracks[i].title, maxLines: 1), subtitle: Text(tracks[i].artist, maxLines: 1),
                trailing: IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showAddToPlaylistSheet(context, tracks[i])),
                onTap: () { audioHandler.playIndex(i); openPlayer(context); },
              ),
              childCount: tracks.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ]
      ],
    );
  }
}
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});
  @override State<LibraryTab> createState() => _LibraryTabState();
}
class _LibraryTabState extends State<LibraryTab> {
  int _filter = 0;
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) => CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('Library', style: TextStyle(fontWeight: FontWeight.bold)),
            actions: [
              IconButton(icon: const Icon(Icons.folder), onPressed: pickLocalFiles),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SegmentedButton<int>(
                segments: const [ButtonSegment(value: 0, label: Text('Playlists')), ButtonSegment(value: 1, label: Text('Artists'))],
                selected: {_filter}, onSelectionChanged: (s) => setState(() => _filter = s.first),
              ),
            ),
          ),
          if (_filter == 0) _buildPlaylists() else _buildArtists(),
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }
  Widget _buildPlaylists() {
    final pls = appState.playlists;
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (ctx, i) {
          if (i == 0) return ListTile(leading: const CircleAvatar(child: Icon(Icons.add_rounded)), title: const Text('Create New Playlist', style: TextStyle(fontWeight: FontWeight.bold)), onTap: () => showCreatePlaylistDialog(context));
          final pl = pls[i-1];
          return ListTile(
            leading: pl.cover != null ? ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(File(pl.cover!), width: 48, height: 48, fit: BoxFit.cover)) : const Icon(Icons.queue_music, size: 48),
            title: Text(pl.name), subtitle: Text('${pl.trackIds.length} songs'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlistId: pl.id))),
          );
        },
        childCount: pls.length + 1,
      ),
    );
  }
  Widget _buildArtists() {
    final map = <String, List<TrackItem>>{};
    for (final t in audioHandler.tracks) { map.putIfAbsent(t.artist, () => []).add(t); }
    final entries = map.entries.toList()..sort((a,b) => a.key.compareTo(b.key));
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (ctx, i) => ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person)),
          title: Text(entries[i].key), subtitle: Text('${entries[i].value.length} songs'),
        ),
        childCount: entries.length,
      ),
    );
  }
}
class MiniPlayer extends StatelessWidget {
  final TrackItem track;
  const MiniPlayer({super.key, required this.track});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => openPlayer(context),
      child: Container(
        height: 64, decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(32)),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            ClipOval(child: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: track))),
            const SizedBox(width: 12),
            Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(track.title, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(track.artist, maxLines: 1, style: const TextStyle(fontSize: 12)),
            ])),
            StreamBuilder<PlaybackState>(
              stream: audioHandler.playbackState,
              builder: (ctx, snap) {
                final playing = snap.data?.playing ?? false;
                return IconButton(icon: Icon(playing ? Icons.pause : Icons.play_arrow), onPressed: () => playing ? audioHandler.pause() : audioHandler.play());
              },
            ),
          ],
        ),
      ),
    );
  }
}
class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: audioHandler.currentIndex,
      builder: (ctx, _) {
        final track = audioHandler.currentTrack;
        if (track == null) return const Scaffold();
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent, elevation: 0,
            leading: IconButton(icon: const Icon(Icons.keyboard_arrow_down), onPressed: () => Navigator.pop(context)),
            actions: [IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showAddToPlaylistSheet(context, track))],
          ),
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                Expanded(child: Center(child: AspectRatio(aspectRatio: 1, child: ClipRRect(borderRadius: BorderRadius.circular(32), child: CustomAlbumArtwork(track: track))))),
                const SizedBox(height: 32),
                Text(track.title, maxLines: 1, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                Text(track.artist, maxLines: 1, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.grey)),
                const SizedBox(height: 24),
                StreamBuilder<Duration>(
                  stream: audioHandler.player.positionStream,
                  builder: (ctx, snap) {
                    final pos = snap.data ?? Duration.zero;
                    final dur = audioHandler.player.duration ?? Duration.zero;
                    return Column(
                      children: [
                        Slider(
                          value: pos.inMilliseconds.toDouble().clamp(0.0, math.max(1.0, dur.inMilliseconds.toDouble())),
                          max: math.max(1.0, dur.inMilliseconds.toDouble()),
                          onChanged: (v) => audioHandler.seek(Duration(milliseconds: v.toInt())),
                        ),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(formatDuration(pos)), Text(formatDuration(dur))]),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(iconSize: 48, icon: const Icon(Icons.skip_previous), onPressed: audioHandler.skipToPrevious),
                    StreamBuilder<bool>(
                      stream: audioHandler.player.playingStream,
                      builder: (ctx, snap) {
                        final playing = snap.data ?? false;
                        return FloatingActionButton.large(
                          onPressed: () => playing ? audioHandler.pause() : audioHandler.play(),
                          child: Icon(playing ? Icons.pause : Icons.play_arrow, size: 48),
                        );
                      }
                    ),
                    IconButton(iconSize: 48, icon: const Icon(Icons.skip_next), onPressed: audioHandler.skipToNext),
                  ],
                ),
                const SizedBox(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(icon: const Icon(Icons.tune), onPressed: () => showPlaybackSheet(context)),
                    IconButton(icon: const Icon(Icons.edit), onPressed: () => showEditTrackDialog(context, track)),
                  ],
                ),
                const SizedBox(height: 48),
              ],
            ),
          ),
        );
      },
    );
  }
}
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
          appBar: AppBar(title: Text(pl.name), actions: [IconButton(icon: const Icon(Icons.delete), onPressed: () { appState.deletePlaylist(pl.id); Navigator.pop(context); })]),
          body: ReorderableListView.builder(
            itemCount: tracks.length,
            onReorder: (o, n) { if (n > o) n -= 1; appState.movePlaylistTrack(pl.id, o, n); },
            itemBuilder: (ctx, i) {
              final t = tracks[i];
              return ListTile(
                key: ValueKey(t.id),
                leading: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: t)),
                title: Text(t.title), subtitle: Text(t.artist),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => appState.removeFromPlaylist(pl.id, t.id)), const Icon(Icons.drag_handle)]),
                onTap: () { audioHandler.playTrackById(t.id); openPlayer(context); },
              );
            },
          ),
        );
      }
    );
  }
}
void showAddToPlaylistSheet(BuildContext context, TrackItem track) {
  showModalBottomSheet(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('Add "${track.title}" to Playlist'),
              trailing: IconButton(icon: const Icon(Icons.add), onPressed: () => showCreatePlaylistDialog(context, initialTrackId: track.id)),
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
                    trailing: Icon(added ? Icons.check_circle : Icons.add_circle_outline, color: added ? Theme.of(context).colorScheme.primary : null),
                    onTap: () => appState.togglePlaylistTrack(pl.id, track.id),
                  );
                },
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text('Delete from Library', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
              onTap: () { Navigator.pop(ctx); audioHandler.deleteTrackFromLibrary(track); },
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
        title: const Text('New Playlist'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () async { final p = await pickAndSaveGalleryImage(); if (p != null) setState(() => coverPath = p); },
              child: Container(
                width: 100, height: 100, color: Colors.white12,
                child: coverPath != null ? Image.file(File(coverPath!), fit: BoxFit.cover) : const Icon(Icons.add_photo_alternate),
              ),
            ),
            const SizedBox(height: 16),
            TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Name')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            final pl = appState.createPlaylist(ctrl.text, cover: coverPath);
            if (initialTrackId != null) appState.addToPlaylist(pl.id, initialTrackId);
            Navigator.pop(ctx);
          }, child: const Text('Save')),
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
      title: const Text('Edit Info'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'Title')),
          TextField(controller: artistCtrl, decoration: const InputDecoration(labelText: 'Artist')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () { track.title = titleCtrl.text; track.artist = artistCtrl.text; appState.saveEdit(track); audioHandler.refreshMediaItem(); Navigator.pop(ctx); },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
void showPlaybackSheet(BuildContext context) {
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
              const Text('Speed & Pitch', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              SwitchListTile(
                title: const Text('Link Speed & Pitch (Vinyl Mode)'),
                value: appState.linkSpeedAndPitch,
                onChanged: (v) { appState.setLinkSpeedAndPitch(v); if (v) { appState.setSpeed(appState.pitch); audioHandler.setSpeed(appState.pitch); } },
              ),
              Row(children: [
                const Icon(Icons.speed), const SizedBox(width: 16),
                Expanded(child: Slider(value: appState.speed, min: 0.5, max: 2.0, divisions: 30, onChanged: (v) { appState.setSpeed(v); audioHandler.setSpeed(v); if (appState.linkSpeedAndPitch) { appState.setPitch(v); audioHandler.setPitch(v); } })),
                Text('${appState.speed.toStringAsFixed(2)}x'),
              ]),
              Row(children: [
                const Icon(Icons.graphic_eq), const SizedBox(width: 16),
                Expanded(child: Slider(value: appState.pitch, min: 0.5, max: 2.0, divisions: 60, onChanged: (v) { appState.setPitch(v); audioHandler.setPitch(v); if (appState.linkSpeedAndPitch) { appState.setSpeed(v); audioHandler.setSpeed(v); } })),
                Text('${appState.pitch.toStringAsFixed(2)}x'),
              ]),
              Wrap(
                spacing: 8,
                children: [-6, -3, -1, 0, 1, 3, 6].map((st) {
                  final tp = math.pow(2.0, st / 12.0).toDouble();
                  return ChoiceChip(
                    label: Text('$st st'), selected: (appState.pitch - tp).abs() < 0.02,
                    onSelected: (_) { appState.setPitch(tp); audioHandler.setPitch(tp); if (appState.linkSpeedAndPitch) { appState.setSpeed(tp); audioHandler.setSpeed(tp); } },
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
            const Text('Settings', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12, runSpacing: 12,
              children: [Colors.blue, Colors.red, Colors.green, Colors.purple, Colors.orange, const Color(0xFFD0BCFF)].map((c) => InkWell(
                onTap: () => appState.setSeedColor(c),
                child: CircleAvatar(backgroundColor: c, radius: 20, child: appState.seedColor.value == c.value ? const Icon(Icons.check, color: Colors.white) : null),
              )).toList(),
            ),
            const SizedBox(height: 16),
            SwitchListTile(title: const Text('Pure AMOLED Black Background'), value: appState.useAmoled, onChanged: appState.setAmoled),
            ListTile(leading: const Icon(Icons.refresh), title: const Text('Rescan Library'), onTap: () { Navigator.pop(ctx); scanDeviceAudio(); }),
          ],
        ),
      ),
    ),
  );
}
