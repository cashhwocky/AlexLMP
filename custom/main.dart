// FILE: custom/main.dart — Pixel Audio Player 4.0 (Clean, Lightweight & Fully Functional)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yte;

const ch = MethodChannel('pixelaudio/meta');
class Nav { final IconData i, a; final String l, k; const Nav(this.i, this.a, this.l, this.k); }
class Skin {
  final String name, hint, title; final Color accent, bg, card; final List<Nav> nav;
  final int head, home, mini, np; final bool navAcc, pill; final double artR, sz;
  const Skin(this.name, this.accent, this.bg, this.card, this.nav, this.hint, {this.title = 'Home', this.head = 0, this.home = 0, this.mini = 0, this.np = 0, this.navAcc = false, this.pill = false, this.artR = 6, this.sz = 144});
}
const nHome = Nav(Icons.home_outlined, Icons.home_filled, 'Home', 'home');
const nSearch = Nav(Icons.search, Icons.search, 'Search', 'search');
const nLib = Nav(Icons.library_music_outlined, Icons.library_music, 'Your Library', 'lib');
const skins = [
  Skin('Spotify', Color(0xFF1ED760), Color(0xFF121212), Color(0xFF282828), [nHome, nSearch, nLib], 'What do you want to play?', artR: 8, sz: 152),
];

Color get bg => app.sk.bg;
Color get card => app.sk.card;
const grey = Color(0xFFA7A7A7);
const spGreen = Color(0xFF1ED760);
const exts = ['.mp3', '.wav', '.flac', '.m4a', '.ogg', '.aac', '.opus'];
final msg = GlobalKey<ScaffoldMessengerState>();
final app = AppState();
Color get gr => spGreen;

void toast(String s) => msg.currentState?..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(s), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
void tap() { if (app.haptics) HapticFeedback.selectionClick(); }
Widget tx(String s, {double z = 14, FontWeight f = FontWeight.w500, Color c = Colors.white, int lines = 1, TextAlign? a}) =>
    Text(s, maxLines: lines, overflow: TextOverflow.ellipsis, textAlign: a, style: TextStyle(fontSize: z, fontWeight: f, color: c));

class Track {
  final String path; String title, artist, album; String? art; final DateTime added;
  Track(this.path, this.title, this.artist, this.album, this.art, this.added);
  factory Track.from(String p) {
    DateTime d; try { d = File(p).lastModifiedSync(); } catch (_) { d = DateTime(2000); }
    final n = p.split('/').last; final i = n.lastIndexOf('.');
    return Track(p, i > 0 ? n.substring(0, i) : n, 'Unknown artist', 'Unknown album', null, d);
  }
  List toJson() => [path, title, artist, album, art, added.millisecondsSinceEpoch];
  factory Track.fromJson(List j) => Track(j[0], j[1], j[2], j[3], j[4], DateTime.fromMillisecondsSinceEpoch(j[5]));
}

class YtSong {
  final String videoId, title, artist, album, duration, art;
  const YtSong({required this.videoId, required this.title, required this.artist, required this.album, required this.duration, required this.art});
}

class H extends BaseAudioHandler with SeekHandler {
  final p = AudioPlayer();
  H() {
    p.playbackEventStream.listen((e) => playbackState.add(PlaybackState(
          controls: [MediaControl.skipToPrevious, p.playing ? MediaControl.pause : MediaControl.play, MediaControl.skipToNext],
          systemActions: const {MediaAction.seek},
          processingState: const {
            ProcessingState.idle: AudioProcessingState.idle,
            ProcessingState.loading: AudioProcessingState.loading,
            ProcessingState.buffering: AudioProcessingState.buffering,
            ProcessingState.ready: AudioProcessingState.ready,
            ProcessingState.completed: AudioProcessingState.completed,
          }[p.processingState]!,
          playing: p.playing, updatePosition: p.position, bufferedPosition: p.bufferedPosition, speed: p.speed,
        )));
  }
  @override Future<void> play() => p.play();
  @override Future<void> pause() => p.pause();
  @override Future<void> seek(Duration d) => p.seek(d);
  @override Future<void> skipToNext() => app.next();
  @override Future<void> skipToPrevious() => app.prev();
  @override Future<void> stop() async { await p.stop(); return super.stop(); }
}

class AppState extends ChangeNotifier {
  late SharedPreferences sp; late H h;
  AudioPlayer get p => h.p;
  List<Track> tracks = [], queue = []; int idx = -1;
  Set<String> liked = {}; List<String> recent = [];
  bool shuffle = false, haptics = true, resume = true, loadingYt = false;
  int repeat = 0, tab = 0;
  double speed = 1.0, pitch = 1.0, vol = 1.0;
  List<String> pq = [];

  Skin get sk => skins[0];
  Track? get cur => idx >= 0 && idx < queue.length ? queue[idx] : null;
  Map<String, Track> get byPath => {for (final t in tracks) t.path: t};
  List<Track> get sorted => [...tracks];

  double get semitones => (12.0 * (log(pitch.clamp(0.25, 4.0)) / ln2));
  bool get isTuned => (speed - 1.0).abs() > 0.005 || (pitch - 1.0).abs() > 0.005;

  Future<void> init() async {
    sp = await SharedPreferences.getInstance();
    h = await AudioService.init<H>(
      builder: () => H(),
      config: const AudioServiceConfig(androidNotificationChannelId: 'com.alexdesrosier.audio_player.audio', androidNotificationChannelName: 'Playback'),
    );
    p.processingStateStream.listen((s) { if (s == ProcessingState.completed) next(auto: true); });
    p.playingStream.listen((_) => notifyListeners());
    if (tracks.isEmpty) scan();
  }

  void set(void Function() f) { f(); notifyListeners(); }
  void goTab(int i) { tab = i; notifyListeners(); }

  Future<List<YtSong>> searchYtMusic(String query) async {
    if (query.trim().isEmpty) return [];
    final yt = yte.YoutubeExplode();
    try {
      final results = await yt.search.search(query);
      final list = <YtSong>[];
      for (final vid in results.whereType<yte.Video>()) {
        list.add(YtSong(
          videoId: vid.id.value,
          title: vid.title,
          artist: vid.author,
          album: 'YouTube Music',
          duration: vid.duration != null ? '${vid.duration!.inMinutes}:${(vid.duration!.inSeconds % 60).toString().padLeft(2, '0')}' : '',
          art: vid.thumbnails.highResUrl,
        ));
      }
      return list;
    } catch (_) {
      return [];
    } finally {
      yt.close();
    }
  }

  Future<void> playYtSong(YtSong s) async {
    if (loadingYt) return;
    loadingYt = true;
    notifyListeners();
    toast('Streaming "${s.title}"…');
    try {
      final yt = yte.YoutubeExplode();
      String? streamUrl;
      try {
        final manifest = await yt.videos.streamsClient.getManifest(s.videoId);
        final audio = manifest.audioOnly.withHighestBitrate();
        streamUrl = audio.url.toString();
      } finally {
        yt.close();
      }

      if (streamUrl != null && streamUrl.isNotEmpty) {
        final tr = Track(streamUrl, s.title, s.artist, s.album, s.art.isEmpty ? null : s.art, DateTime.now());
        await playAt([tr], 0, ctx: 'YouTube Music');
      } else {
        toast('Could not resolve stream');
      }
    } catch (e) {
      toast('Error: $e');
    }
    loadingYt = false;
    notifyListeners();
  }

  Future<void> _loadPath(String path) async {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      await p.setAudioSource(
        AudioSource.uri(
          Uri.parse(path),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Range': 'bytes=0-',
          },
        ),
      );
    } else {
      await p.setFilePath(path);
    }
  }

  Future<void> _load() async {
    final t = cur; if (t == null) return;
    notifyListeners();
    try {
      await _loadPath(t.path);
      await p.setSpeed(speed);
      await p.setPitch(pitch);
      p.play();
    } catch (_) {
      toast('Cannot play ${t.title}');
    }
    notifyListeners();
  }

  Future<void> next({bool auto = false}) async {
    if (queue.isEmpty) return;
    if (idx + 1 < queue.length) { idx++; } else { idx = 0; }
    await _load();
  }

  Future<void> prev() async {
    if (queue.isEmpty) return;
    idx = idx > 0 ? idx - 1 : queue.length - 1;
    await _load();
  }

  void toggle() { p.playing ? p.pause() : p.play(); }

  Future<void> scan() async {
    await [Permission.audio, Permission.storage].request();
    scanning = true; notifyListeners();
    final found = <String>{};
    for (final d in ['/storage/emulated/0/Music', '/storage/emulated/0/Download']) {
      try { for (final e in Directory(d).listSync(recursive: true, followLinks: false)) { if (e is File && exts.any((x) => e.path.toLowerCase().endsWith(x))) found.add(e.path); } } catch (_) {}
    }
    tracks = [for (final x in found) Track.from(x)];
    scanning = false; notifyListeners();
  }

  Future<void> addFiles() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.audio);
    if (r == null) return;
    for (final f in r.files.where((f) => f.path != null)) { tracks.add(Track.from(f.path!)); }
    notifyListeners();
  }

  Future<void> playAt(List<Track> q, int i, {String? ctx}) async {
    if (q.isEmpty) return;
    queue = List.of(q);
    idx = i.clamp(0, queue.length - 1);
    await _load();
  }

  void shufflePlay(List<Track> q, {String? ctx}) {
    if (q.isEmpty) return;
    shuffle = true;
    playAt(q, Random().nextInt(q.length));
  }

  void setSpeed(double s) { speed = s.clamp(0.25, 2.5); p.setSpeed(speed); notifyListeners(); }
  void setPitch(double v) { pitch = v.clamp(0.25, 2.5); p.setPitch(pitch); notifyListeners(); }
  void setSemitones(double st) { setPitch(pow(2.0, st.clamp(-12.0, 12.0) / 12.0).toDouble()); }
  void applyTunePreset(double spd, double ptch) { speed = spd; pitch = ptch; p.setSpeed(speed); p.setPitch(pitch); notifyListeners(); }
  void like(Track t) => set(() { if (!liked.remove(t.path)) liked.add(t.path); });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await app.init();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (_, __) => MaterialApp(
          title: 'Pixel Audio Player', debugShowCheckedModeBanner: false, scaffoldMessengerKey: msg,
          theme: ThemeData(useMaterial3: true, brightness: Brightness.dark, scaffoldBackgroundColor: bg, canvasColor: card),
          home: const Shell(),
        ),
      );
}

class Art extends StatelessWidget {
  final Track? t; final double s;
  const Art(this.t, this.s, {super.key});
  @override
  Widget build(BuildContext context) {
    final f = t?.art, ok = f != null && (f.startsWith('http') || File(f).existsSync());
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: s, height: s, color: const Color(0xFF282828),
        child: ok ? (f.startsWith('http') ? Image.network(f, fit: BoxFit.cover) : Image.file(File(f), fit: BoxFit.cover)) : const Icon(Icons.music_note, color: grey),
      ),
    );
  }
}

Widget tx(String s, {double z = 14, FontWeight f = FontWeight.w500, Color c = Colors.white, int lines = 1}) =>
    Text(s, maxLines: lines, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: z, fontWeight: f, color: c));

class TTile extends StatelessWidget {
  final Track t; final List<Track> list; final int i;
  const TTile(this.t, this.list, this.i, {super.key});
  @override
  Widget build(BuildContext c) => ListTile(
        leading: Art(t, 48), title: tx(t.title), subtitle: tx(t.artist, c: grey, z: 12),
        trailing: IconButton(icon: const Icon(Icons.more_vert, color: grey), onPressed: () => sheet(c, (_) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(leading: const Icon(Icons.tune), title: const Text('Speed & Pitch'), onTap: () { Navigator.pop(c); sheet(c, (_) => const TuneSheet(), big: true); }),
          ]),
        ))),
        onTap: () { tap(); app.playAt(list, i); },
      );
}

class Shell extends StatelessWidget {
  const Shell({super.key});
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final t = app.tab.clamp(0, 2);
        return Scaffold(
          body: SafeArea(bottom: false, child: IndexedStack(index: t, children: const [HomePage(), SearchPage(), LibraryPage()])),
          bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
            if (app.cur != null) const Mini(),
            BottomNavigationBar(
              currentIndex: t, backgroundColor: bg, selectedItemColor: spGreen, unselectedItemColor: grey,
              onTap: app.goTab,
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
                BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
                BottomNavigationBarItem(icon: Icon(Icons.library_music), label: 'Library'),
              ],
            ),
          ]),
        );
      });
}

class Mini extends StatelessWidget {
  const Mini({super.key});
  @override
  Widget build(BuildContext c) {
    final t = app.cur!;
    return GestureDetector(
      onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const NowPlaying())),
      child: Container(
        color: card, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [Art(t, 42), const SizedBox(width: 10), Expanded(child: tx(t.title, f: FontWeight.w700)), IconButton(icon: Icon(app.p.playing ? Icons.pause : Icons.play_arrow), onPressed: app.toggle)]),
      ),
    );
  }
}

class NowPlaying extends StatelessWidget {
  const NowPlaying({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Row(children: [IconButton(icon: const Icon(Icons.keyboard_arrow_down), onPressed: () => Navigator.pop(c)), const Spacer()]),
                const Spacer(),
                Art(app.cur, 300),
                const Spacer(),
                Align(alignment: Alignment.centerLeft, child: tx(app.cur?.title ?? '', z: 22, f: FontWeight.w800)),
                Align(alignment: Alignment.centerLeft, child: tx(app.cur?.artist ?? '', z: 15, c: grey)),
                const SizedBox(height: 20),
                StreamBuilder<Duration>(
                  stream: app.p.positionStream,
                  builder: (_, sn) {
                    final pos = sn.data ?? Duration.zero;
                    final dur = app.p.duration ?? Duration.zero;
                    return Slider(value: pos.inMilliseconds.toDouble(), max: max(dur.inMilliseconds.toDouble(), 1.0), onChanged: (v) => app.p.seek(Duration(milliseconds: v.toInt())));
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(icon: const Icon(Icons.skip_previous, size: 40), onPressed: app.prev),
                    IconButton(icon: Icon(app.p.playing ? Icons.pause : Icons.play_arrow, size: 50), onPressed: app.toggle),
                    IconButton(icon: const Icon(Icons.skip_next, size: 40), onPressed: app.next),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      );
}

class TuneSheet extends StatelessWidget {
  const TuneSheet({super.key});
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tx('Speed & Pitch', z: 18, f: FontWeight.w800),
              const SizedBox(height: 16),
              Row(children: [const Text('Pitch (st):'), Expanded(child: Slider(value: app.semitones, min: -12, max: 12, divisions: 24, onChanged: app.setSemitones))]),
              Row(children: [const Text('Speed:'), Expanded(child: Slider(value: app.speed, min: 0.5, max: 2.0, divisions: 30, onChanged: app.setSpeed))]),
            ],
          ),
        ),
      ));
}

class EqSheet extends StatelessWidget {
  const EqSheet({super.key});
  @override
  Widget build(BuildContext c) => const SafeArea(child: Padding(padding: EdgeInsets.all(20), child: Text('Equalizer')));
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext c) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          tx('Home', z: 26, f: FontWeight.w800),
          const SizedBox(height: 16),
          for (var i = 0; i < app.sorted.length && i < 15; i++) TTile(app.sorted[i], app.sorted, i),
        ],
      );
}

class NewPage extends StatelessWidget { const NewPage({super.key}); @override Widget build(BuildContext c) => const SizedBox(); }
class RadioPage extends StatelessWidget { const RadioPage({super.key}); @override Widget build(BuildContext c) => const SizedBox(); }

class SearchPage extends StatefulWidget { const SearchPage({super.key}); @override State<SearchPage> createState() => _SearchState(); }
class _SearchState extends State<SearchPage> {
  final ctl = TextEditingController();
  Timer? _deb; List<YtSong> ytRes = []; bool searching = false;

  void search(String q) {
    _deb?.cancel();
    if (q.trim().length < 2) { setState(() => ytRes = []); return; }
    setState(() => searching = true);
    _deb = Timer(const Duration(milliseconds: 400), () async {
      ytRes = await app.searchYtMusic(q);
      if (mounted) setState(() => searching = false);
    });
  }

  @override
  Widget build(BuildContext c) => Column(children: [
        Padding(padding: const EdgeInsets.all(16), child: TextField(controller: ctl, onChanged: search, decoration: const InputDecoration(hintText: 'Search YouTube Music', filled: true))),
        Expanded(child: ListView(children: [if (searching) const Center(child: CircularProgressIndicator()), for (final y in ytRes) ListTile(title: Text(y.title), subtitle: Text(y.artist), trailing: const Icon(Icons.play_arrow), onTap: () => app.playYtSong(y)])),
      ]);
}

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});
  @override
  Widget build(BuildContext c) => Column(children: [
        Padding(padding: const EdgeInsets.all(16), child: Row(children: [tx('Library', z: 24, f: FontWeight.w800), const Spacer(), IconButton(icon: const Icon(Icons.add), onPressed: app.addFiles)])),
        Expanded(child: ListView(children: [for (var i = 0; i < app.sorted.length; i++) TTile(app.sorted[i], app.sorted, i)])),
      ]);
}
