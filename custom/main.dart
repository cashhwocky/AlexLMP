// FILE: custom/main.dart — Pixel Audio Player 4.0 (Full Styles & Local Library Restored)
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
  Skin('Apple Music', Color(0xFFFA2D48), Color(0xFF000000), Color(0xFF1C1C1E), [nHome, Nav(Icons.grid_view, Icons.grid_view_rounded, 'New', 'new'), Nav(Icons.sensors, Icons.sensors, 'Radio', 'radio'), Nav(Icons.library_music_outlined, Icons.library_music, 'Library', 'lib'), nSearch], 'Artists, Songs, Lyrics, and More', title: 'Listen Now', head: 1, home: 1, mini: 1, np: 1, navAcc: true, artR: 10, sz: 164),
  Skin('YouTube Music', Color(0xFFFF0000), Color(0xFF030303), Color(0xFF212121), [nHome, Nav(Icons.smart_display_outlined, Icons.smart_display, 'Samples', 'radio'), Nav(Icons.explore_outlined, Icons.explore, 'Explore', 'new'), Nav(Icons.library_music_outlined, Icons.library_music, 'Library', 'lib')], 'Search songs, albums, artists', head: 2, home: 2, mini: 2, np: 2, artR: 4),
  Skin('Amazon Music', Color(0xFF25D1DA), Color(0xFF0F1923), Color(0xFF1B2733), [nHome, Nav(Icons.manage_search, Icons.manage_search, 'Find', 'search'), Nav(Icons.library_music_outlined, Icons.library_music, 'Library', 'lib')], 'Search', head: 1, home: 3, mini: 3, np: 3, navAcc: true, pill: true, artR: 4, sz: 156),
  Skin('TIDAL', Color(0xFFFFD43B), Color(0xFF000000), Color(0xFF18181A), [nHome, Nav(Icons.smart_display_outlined, Icons.smart_display, '', 'new'), Nav(Icons.search, Icons.search, '', 'search'), Nav(Icons.equalizer, Icons.equalizer, '', 'radio'), Nav(Icons.account_circle_outlined, Icons.account_circle, '', 'lib')], 'Search artists, songs, albums', home: 4, mini: 4, np: 4, artR: 8, sz: 156),
  Skin('SoundCloud', Color(0xFFFF5500), Color(0xFF111111), Color(0xFF222222), [nHome, Nav(Icons.dynamic_feed_outlined, Icons.dynamic_feed, 'Feed', 'new'), nSearch, Nav(Icons.library_music_outlined, Icons.library_music, 'Library', 'lib')], 'Search for artists, tracks, albums', home: 5, mini: 5, np: 5, navAcc: true, artR: 2),
  Skin('Deezer', Color(0xFFA238FF), Color(0xFF121216), Color(0xFF23232B), [nHome, nSearch, Nav(Icons.favorite_border, Icons.favorite, 'Favorites', 'lib'), Nav(Icons.all_inclusive, Icons.all_inclusive, 'Flow', 'radio')], 'Search for a song or artist', head: 1, home: 6, mini: 6, np: 6, navAcc: true, artR: 12),
];

class NPL {
  final String name; final int art, bg, seek; final bool center, plain, vol, tabs, viz, acc, ring;
  const NPL(this.name, {this.art = 0, this.bg = 0, this.seek = 0, this.center = false, this.plain = false, this.vol = false, this.tabs = false, this.viz = false, this.acc = false, this.ring = false});
}
const npls = [
  NPL('Spotify'),
  NPL('Apple Music', bg: 1, seek: 3, plain: true, vol: true),
  NPL('YouTube Music', seek: 2, tabs: true, acc: true),
  NPL('Amazon Music', bg: 1, center: true, acc: true, ring: true),
  NPL('TIDAL', art: 0, bg: 0, seek: 2, plain: true),
  NPL('SoundCloud', bg: 2, seek: 4, plain: true, acc: true),
  NPL('Deezer', center: true, acc: true, ring: true),
  NPL('Vinyl', art: 2, bg: 1, center: true, seek: 2),
  NPL('Fullscreen art', art: 3, bg: 4, seek: 3, center: true),
  NPL('Minimal', art: 5, bg: 4, seek: 2, center: true, plain: true),
  NPL('Visualizer', art: 4, bg: 3, center: true, viz: true, seek: 5, acc: true, ring: true),
];
const accents = <Color?>[null, Color(0xFF1ED760), Color(0xFFFFD43B), Color(0xFF5B8CFF), Color(0xFFFF7EB6), Color(0xFFFFB020), Color(0xFFFF4D5A), Color(0xFFB388FF), Color(0xFF00E5FF)];
final eqPresets = <String, double Function(double)>{'Flat': (x) => 0, 'Bass boost': (x) => (1 - x) * 8 - 1, 'Treble boost': (x) => x * 8 - 1, 'Vocal': (x) => sin(pi * x) * 6 - 1, 'Rock': (x) => (x - .5).abs() * 10 - 1};

Color get bg => app.sk.bg;
Color get card => app.sk.card;
const grey = Color(0xFFA7A7A7);
const spGreen = Color(0xFF1ED760);
const exts = ['.mp3', '.wav', '.flac', '.m4a', '.ogg', '.aac', '.opus'];
final msg = GlobalKey<ScaffoldMessengerState>();
final app = AppState();
Color boost(Color c) { final h = HSLColor.fromColor(c); return h.withSaturation(max(h.saturation, .6)).withLightness(.6).toColor(); }
Color get gr { if (app.dyn && app.cur != null) return boost(app.colorOf(app.cur!)); final a = app.accent; return a > 0 && a < accents.length ? accents[a]! : app.sk.accent; }
String navLabel(String k) {
  final l = app.sk.nav.firstWhere((n) => n.k == k, orElse: () => nLib).l;
  if (l.isNotEmpty) return l;
  return switch (k) { 'home' => 'Home', 'search' => 'Search', 'lib' => 'My Collection', 'new' => 'Explore', 'radio' => 'Mixes', _ => 'Library' };
}
List<Track> mix(List<Track> all, int n) => ([...all]..shuffle(Random(DateTime.now().difference(DateTime(2024)).inDays + n))).take(25).toList();

void toast(String s) => msg.currentState?..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(s), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
Color tint(String s, [double l = .28]) => HSLColor.fromAHSL(1, (s.hashCode % 360).abs().toDouble(), .55, l).toColor();
String fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
void tap() { if (app.haptics) HapticFeedback.selectionClick(); }
Widget tx(String s, {double z = 14, FontWeight f = FontWeight.w500, Color c = Colors.white, int lines = 1, TextAlign? a, double? ls, double? h}) =>
    Text(s, maxLines: lines, overflow: TextOverflow.ellipsis, textAlign: a, style: TextStyle(fontSize: z, fontWeight: f, color: c, letterSpacing: ls, height: h));

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

class H extends BaseAudioHandler with SeekHandler {
  final enh = AndroidLoudnessEnhancer(), eq = AndroidEqualizer();
  late final AudioPlayer p = AudioPlayer(audioPipeline: AudioPipeline(androidAudioEffects: [enh, eq]));
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
  late SharedPreferences sp; late H h; String cache = '';
  AudioPlayer get p => h.p;
  List<Track> tracks = [], queue = []; int idx = -1;
  Set<String> liked = {}; Map<String, List<String>> lists = {}; List<String> recent = []; Map<String, int> plays = {};
  String name = 'Alex', swipe = 'skip', sort = 'recent', playCtx = 'Liked Songs'; String? avatar;
  bool shuffle = false, haptics = true, showVol = false, resume = true, skipSilence = false, stopOnClear = false, scanning = false, libGrid = false;
  int repeat = 0, accent = 0; double speed = 1, vol = 1;
  bool dyn = false, lyricsCard = true, skipErr = true, normalize = false, slim = false, swipeArt = true, linkPitch = false;
  double pitch = 1; List<String> pq = [];
  int skin = 0, npStyle = -1, artShape = 0, tab = 0; bool glow = true, spinArt = true, viz = false, remain = false, dbl = true, badgeOn = false, fadeIn = false, miniProg = true, eqOn = false;
  Duration? la, lb; String outName = 'ALEXWIN11PRO', outKind = 'phone';
  Skin get sk => skins[skin.clamp(0, skins.length - 1)];
  NPL get npl => npls[(npStyle >= 0 ? npStyle : sk.np).clamp(0, npls.length - 1)];
  final Map<String, Color> _cols = {}; final Set<String> _pend = {}; final Map<String, List<(Duration, String)>> _lrc = {};
  List<String> dirs = ['/storage/emulated/0/Music', '/storage/emulated/0/Download'];
  Track? get cur => idx >= 0 && idx < queue.length ? queue[idx] : null;
  Map<String, Track> get byPath => {for (final t in tracks) t.path: t};
  List<Track> get sorted => [...tracks]..sort(sort == 'az' ? (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()) : (a, b) => b.added.compareTo(a.added));
  List<Track> toTracks(Iterable<String> ps) { final m = byPath; return [for (final x in ps) if (m[x] != null) m[x]!]; }
  List<Track> get likedTracks => toTracks(liked);
  List<Track> get recentTracks => toTracks(recent);
  List<Track> get mostPlayed { final k = plays.keys.toList()..sort((a, b) => plays[b]!.compareTo(plays[a]!)); return toTracks(k.take(20)); }

  double get semitones => (12.0 * (log(pitch.clamp(0.25, 4.0)) / ln2));
  bool get isTuned => (speed - 1.0).abs() > 0.005 || (pitch - 1.0).abs() > 0.005;

  Future<void> init() async {
    sp = await SharedPreferences.getInstance();
    try { cache = (await ch.invokeMethod<String>('cacheDir')) ?? ''; } catch (_) {}
    load();
    h = await AudioService.init<H>(
      builder: () => H(),
      config: const AudioServiceConfig(androidNotificationChannelId: 'com.alexdesrosier.audio_player.audio', androidNotificationChannelName: 'Playback'),
    );
    p.processingStateStream.listen((s) { if (s == ProcessingState.completed) next(auto: true); });
    p.playingStream.listen((_) => notifyListeners());
    if (tracks.isEmpty) scan();
  }

  void load() {
    try {
      final d = jsonDecode(sp.getString('d') ?? '{}') as Map<String, dynamic>;
      tracks = [for (final j in (d['tracks'] ?? []) as List) Track.fromJson(j)].where((t) => File(t.path).existsSync()).toList();
      liked = {...((d['liked'] ?? []) as List).cast<String>()};
      lists = {for (final e in ((d['lists'] ?? {}) as Map).entries) e.key as String: (e.value as List).cast<String>()};
      recent = ((d['recent'] ?? []) as List).cast<String>();
      plays = ((d['plays'] ?? {}) as Map).map((k, v) => MapEntry(k as String, v as int));
      skin = d['skin'] ?? 0;
    } catch (_) {}
  }

  void save() => sp.setString('d', jsonEncode({'tracks': tracks.map((t) => t.toJson()).toList(), 'liked': liked.toList(), 'lists': lists, 'skin': skin}));
  void set(void Function() f) { f(); save(); notifyListeners(); }
  void setSkin(int i) => set(() { skin = i; tab = 0; });
  void goTab(int i) { tab = i; notifyListeners(); }

  Future<void> scan() async {
    await [Permission.audio, Permission.storage].request();
    scanning = true; notifyListeners();
    final found = <String>{...tracks.where((t) => File(t.path).existsSync()).map((t) => t.path)};
    for (final d in dirs) {
      try { for (final e in Directory(d).listSync(recursive: true, followLinks: false)) { if (e is File && exts.any((x) => e.path.toLowerCase().endsWith(x))) found.add(e.path); } } catch (_) {}
    }
    final old = byPath;
    tracks = [for (final x in found) old[x] ?? Track.from(x)];
    scanning = false; notifyListeners(); save();
  }

  Future<void> addFiles() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.audio);
    if (r == null) return;
    final old = byPath;
    for (final f in r.files.where((f) => f.path != null)) { if (!old.containsKey(f.path)) tracks.add(Track.from(f.path!)); }
    set(() {});
  }

  Future<void> playAt(List<Track> q, int i, {String? ctx}) async {
    if (q.isEmpty) return;
    queue = List.of(q); idx = i.clamp(0, queue.length - 1);
    await _load();
  }

  Future<void> shufflePlay(List<Track> q, {String? ctx}) async {
    if (q.isEmpty) return;
    shuffle = true; save();
    await playAt(q, Random().nextInt(q.length));
  }

  Future<void> _load() async {
    final t = cur; if (t == null) return;
    notifyListeners();
    try {
      await p.setFilePath(t.path);
      p.setSpeed(speed); p.setPitch(pitch); p.play();
    } catch (_) { toast('Cannot play ${t.title}'); }
    recent..remove(t.path)..insert(0, t.path); save(); notifyListeners();
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
  void setSpeed(double s) { speed = s.clamp(0.25, 2.5); p.setSpeed(speed); notifyListeners(); }
  void setPitch(double v) { pitch = v.clamp(0.25, 2.5); p.setPitch(pitch); notifyListeners(); }
  void setSemitones(double st) { setPitch(pow(2.0, st.clamp(-12.0, 12.0) / 12.0).toDouble()); }
  void like(Track t) => set(() { if (!liked.remove(t.path)) liked.add(t.path); });
  Color colorOf(Track t) => tint(t.title, .32);
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
  final Track? t; final double s; final double? r;
  const Art(this.t, this.s, {this.r, super.key});
  @override
  Widget build(BuildContext context) {
    final f = t?.art, ok = f != null && File(f).existsSync(), rr = r ?? (s > 100 ? app.sk.artR : 6.0);
    final col = t != null ? app.colorOf(t!) : tint('music', .25);
    return ClipRRect(
      borderRadius: BorderRadius.circular(rr),
      child: Container(width: s, height: s, decoration: BoxDecoration(color: col), child: ok ? Image.file(File(f), fit: BoxFit.cover) : const Icon(Icons.music_note, color: Colors.white70)),
    );
  }
}

Widget head(BuildContext c, String title, {List<Widget> actions = const []}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
      child: Row(children: [Expanded(child: tx(title, z: 24, f: FontWeight.w800)), ...actions]),
    );

class TTile extends StatelessWidget {
  final Track t; final List<Track> list; final int i;
  const TTile(this.t, this.list, this.i, {super.key});
  @override
  Widget build(BuildContext c) => ListTile(
        leading: Art(t, 48), title: tx(t.title, f: FontWeight.w600), subtitle: tx(t.artist, c: grey, z: 12),
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
        final s = app.sk, t = app.tab.clamp(0, s.nav.length - 1);
        return Scaffold(
          body: SafeArea(bottom: false, child: IndexedStack(index: t, children: [for (final n in s.nav) page(n.k)])),
          bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
            if (app.cur != null) const Mini(),
            Row(children: [for (var i = 0; i < s.nav.length; i++) Expanded(child: InkWell(onTap: () => app.goTab(i), child: Padding(padding: const EdgeInsets.all(12), child: Icon(t == i ? s.nav[i].a : s.nav[i].i, color: t == i ? gr : grey))))]),
          ]),
        );
      });
}

Widget page(String k) => switch (k) { 'home' => const HomePage(), 'search' => const SearchPage(), 'lib' => const LibraryPage(), 'new' => const NewPage(), 'radio' => const RadioPage(), _ => const SizedBox() };

class Mini extends StatelessWidget {
  const Mini({super.key});
  @override
  Widget build(BuildContext c) {
    final t = app.cur!;
    return GestureDetector(
      onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const NowPlaying())),
      child: Container(
        color: card, padding: const EdgeInsets.all(8),
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
  Widget build(BuildContext c) {
    final all = app.sorted;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        head(c, 'Home'),
        if (all.isEmpty) Padding(padding: const EdgeInsets.all(40), child: Center(child: tx('No music found. Tap Library to add or scan files.', c: grey, a: TextAlign.center)))
        else for (var i = 0; i < all.length && i < 15; i++) TTile(all[i], all, i),
      ],
    );
  }
}

class NewPage extends StatelessWidget { const NewPage({super.key}); @override Widget build(BuildContext c) => ListView(children: [head(c, 'Explore')]); }
class RadioPage extends StatelessWidget { const RadioPage({super.key}); @override Widget build(BuildContext c) => ListView(children: [head(c, 'Radio')]); }

class SearchPage extends StatefulWidget { const SearchPage({super.key}); @override State<SearchPage> createState() => _SearchState(); }
class _SearchState extends State<SearchPage> {
  final ctl = TextEditingController();
  @override
  Widget build(BuildContext c) => Column(children: [
        head(c, 'Search'),
        Padding(padding: const EdgeInsets.all(16), child: TextField(controller: ctl, decoration: const InputDecoration(hintText: 'Search local library', filled: true))),
      ]);
}

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});
  @override
  Widget build(BuildContext c) {
    final all = app.sorted;
    return Column(children: [
      head(c, 'Library', actions: [IconButton(icon: const Icon(Icons.add), onPressed: app.addFiles)]),
      Expanded(
        child: all.isEmpty
            ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.folder_open, size: 64, color: grey),
                const SizedBox(height: 12),
                tx('No local files found', z: 18, f: FontWeight.w700),
                const SizedBox(height: 12),
                FilledButton.icon(onPressed: app.scan, icon: const Icon(Icons.refresh), label: const Text('Scan Device'))
              ]))
            : ListView(children: [for (var i = 0; i < all.length; i++) TTile(all[i], all, i)]),
      ),
    ]);
  }
}
