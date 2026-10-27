// FILE: custom/main.dart — Pixel Audio Player 4.0 (Fixed Missing Shell Methods + WebView OAuth Portal)
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
import 'package:webview_flutter/webview_flutter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yte;

// ───────────── skins ─────────────
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
  Skin('TIDAL', Color(0xFFFFD43B), Color(0xFF000000), Color(0xFF18181A), [nHome, Nav(Icons.smart_display_outlined, Icons.smart_display, '', 'new'), Nav(Icons.search, Icons.search, '', 'search'), Nav(Icons.equalizer, Icons.equalizer, '', 'radio'), Nav(Icons.account_circle_outlined, Icons.account_circle, '', 'lib')], 'Search artists, songs, albums', home: 4, mini: 4, np: 4, artR: 8, sz: 156),
];

class NPL {
  final String name; final int art, bg, seek; final bool center, plain, vol, tabs, viz, acc, ring;
  const NPL(this.name, {this.art = 0, this.bg = 0, this.seek = 0, this.center = false, this.plain = false, this.vol = false, this.tabs = false, this.viz = false, this.acc = false, this.ring = false});
}
const npls = [NPL('Spotify'), NPL('TIDAL', art: 0, bg: 0, seek: 2, plain: true)];
const accents = <Color?>[null, Color(0xFF1ED760), Color(0xFFFFD43B), Color(0xFF5B8CFF), Color(0xFFFF7EB6)];
final eqPresets = <String, double Function(double)>{'Flat': (x) => 0, 'Bass boost': (x) => (1 - x) * 8 - 1, 'Treble boost': (x) => x * 8 - 1, 'Vocal': (x) => sin(pi * x) * 6 - 1, 'Rock': (x) => (x - .5).abs() * 10 - 1};

Color get bg => app.sk.bg;
Color get card => app.sk.card;
const grey = Color(0xFFA7A7A7);
const spGreen = Color(0xFF1ED760);
const tidalGold = Color(0xFFFFD43B);
const speeds = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 2.0];
const exts = ['.mp3', '.wav', '.flac', '.m4a', '.ogg', '.aac', '.opus'];
final msg = GlobalKey<ScaffoldMessengerState>();
final app = AppState();
Color boost(Color c) { final h = HSLColor.fromColor(c); return h.withSaturation(max(h.saturation, .6)).withLightness(.6).toColor(); }
Color get gr { if (app.dyn && app.cur != null) return boost(app.colorOf(app.cur!)); final a = app.accent; return a > 0 && a < accents.length ? accents[a]! : app.sk.accent; }
String navLabel(String k) => app.sk.nav.firstWhere((n) => n.k == k, orElse: () => nLib).l.isEmpty ? (k == 'home' ? 'Home' : k == 'search' ? 'Search' : 'Library') : app.sk.nav.firstWhere((n) => n.k == k).l;
String badge(Track t) { final e = t.path.split('.').last.toUpperCase(); return e == 'FLAC' || e == 'WAV' ? '$e • LOSSLESS' : '$e • MAX'; }
List<Track> mix(List<Track> all, int n) => ([...all]..shuffle(Random(DateTime.now().difference(DateTime(2024)).inDays + n))).take(25).toList();

void toast(String s) => msg.currentState?..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(s), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
Color tint(String s, [double l = .28]) => HSLColor.fromAHSL(1, (s.hashCode % 360).abs().toDouble(), .55, l).toColor();
String fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
void tap() { if (app.haptics) HapticFeedback.selectionClick(); }
Widget tx(String s, {double z = 14, FontWeight f = FontWeight.w500, Color c = Colors.white, int lines = 1, TextAlign? a, double? ls, double? h}) =>
    Text(s, maxLines: lines, overflow: TextOverflow.ellipsis, textAlign: a, style: TextStyle(fontSize: z, fontWeight: f, color: c, letterSpacing: ls, height: h));

Widget explicitBadge() => Container(
      width: 15, height: 15, alignment: Alignment.center,
      decoration: BoxDecoration(color: const Color(0xFF9E9E9E), borderRadius: BorderRadius.circular(3)),
      child: const Text('E', style: TextStyle(color: Color(0xFF121212), fontSize: 10, fontWeight: FontWeight.w900, height: 1.0)),
    );

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
  final enh = AndroidLoudnessEnhancer(), eq = AndroidEqualizer();
  late final AudioPlayer p = AudioPlayer(audioPipeline: AudioPipeline(androidAudioEffects: [enh, eq]));
  H() {
    p.playbackEventStream.listen((e) => playbackState.add(PlaybackState(
          controls: [MediaControl.skipToPrevious, p.playing ? MediaControl.pause : MediaControl.play, MediaControl.skipToNext],
          systemActions: const {MediaAction.seek},
          androidCompactActionIndices: const [0, 1, 2],
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
  @override Future<void> onTaskRemoved() async { if (app.stopOnClear) await stop(); }
}

class AppState extends ChangeNotifier {
  late SharedPreferences sp; late H h; String cache = '';
  AudioPlayer get p => h.p;
  List<Track> tracks = [], queue = []; int idx = -1;
  Set<String> liked = {}; Map<String, List<String>> lists = {}; List<String> recent = []; Map<String, int> plays = {};
  String name = 'Alex', swipe = 'skip', sort = 'recent', playCtx = 'Liked Songs'; String? avatar, ytAccountEmail, ytAuthCookie;
  bool shuffle = false, haptics = true, showVol = false, resume = true, skipSilence = false, stopOnClear = false, scanning = false, libGrid = false;
  int repeat = 0, accent = 0; double speed = 1, pitch = 1, vol = 1; DateTime? sleepAt; Timer? _sleep;
  bool dyn = false, lyricsCard = true, skipErr = true, normalize = false, slim = false, swipeArt = true, sleepEnd = false, linkPitch = false, loadingYt = false;
  List<String> pq = [];
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
  String get tuneSummary => '${speed.toStringAsFixed(2)}× • ${semitones.abs() < 0.05 ? '±0 st' : '${semitones > 0 ? '+' : ''}${semitones.toStringAsFixed(1)} st'}';

  Future<void> init() async {
    sp = await SharedPreferences.getInstance();
    try { cache = (await ch.invokeMethod<String>('cacheDir')) ?? ''; } catch (_) {}
    load();
    h = await AudioService.init<H>(
      builder: () => H(),
      config: const AudioServiceConfig(androidNotificationChannelId: 'com.alexdesrosier.audio_player.audio', androidNotificationChannelName: 'Playback', androidStopForegroundOnPause: false),
    );
    p.processingStateStream.listen((s) { if (s == ProcessingState.completed) { if (sleepEnd) { sleepEnd = false; notifyListeners(); } else { next(auto: true); } } });
    p.playingStream.listen((_) => notifyListeners());
    p.positionStream.listen((pos) { final a = la, b = lb; if (a != null && b != null && pos >= b) p.seek(a); });
    refreshOut();
    if (tracks.isEmpty) scan();
    if (resume && pq.isNotEmpty) {
      queue = toTracks(pq);
      if (queue.isNotEmpty) { idx = pqi.clamp(0, queue.length - 1); try { await _loadPath(cur!.path); } catch (_) {} }
    }
  }

  void load() {
    try {
      final d = jsonDecode(sp.getString('d') ?? '{}') as Map<String, dynamic>;
      tracks = [for (final j in (d['tracks'] ?? []) as List) Track.fromJson(j)].where((t) => t.path.startsWith('http') || File(t.path).existsSync()).toList();
      liked = {...((d['liked'] ?? []) as List).cast<String>()};
      lists = {for (final e in ((d['lists'] ?? {}) as Map).entries) e.key as String: (e.value as List).cast<String>()};
      recent = ((d['recent'] ?? []) as List).cast<String>();
      plays = ((d['plays'] ?? {}) as Map).map((k, v) => MapEntry(k as String, v as int));
      name = d['name'] ?? name; avatar = d['avatar']; ytAccountEmail = d['ytEmail']; ytAuthCookie = d['ytCookie']; swipe = d['swipe'] ?? swipe; sort = d['sort'] ?? sort;
      haptics = d['haptics'] ?? true; showVol = d['showVol'] ?? false; resume = d['resume'] ?? true;
      skipSilence = d['skip'] ?? false; stopOnClear = d['stop'] ?? false; libGrid = d['grid'] ?? false;
      accent = d['accent'] ?? 0; shuffle = d['shuffle'] ?? false; repeat = d['repeat'] ?? 0;
      dirs = ((d['dirs'] ?? dirs) as List).cast<String>();
      dyn = d['dyn'] ?? false; pbg = d['pbg'] ?? 0; sliderStyle = d['sl'] ?? 0; lyricsCard = d['lc'] ?? true; skipErr = d['se'] ?? true; normalize = d['nm'] ?? false; slim = false; swipeArt = d['sa'] ?? true; tab0 = d['tab0'] ?? 0;
      speed = (d['speed'] ?? 1.0).toDouble().clamp(0.25, 3.0);
      pitch = (d['pitch'] ?? 1.0).toDouble().clamp(0.25, 3.0);
      linkPitch = d['lp'] ?? false;
      pq = ((d['queue'] ?? []) as List).cast<String>(); pqi = d['qi'] ?? 0;
      skin = d['skin'] ?? 0; npStyle = d['nps'] ?? -1; artShape = 0; glow = true; spinArt = true; viz = false; remain = false; dbl = true; badgeOn = false; fadeIn = false; miniProg = true; eqOn = false;
      playCtx = d['pctx'] ?? 'Liked Songs';
      tab = tab0;
    } catch (_) {}
  }

  void save() => sp.setString('d', jsonEncode({
        'tracks': tracks.map((t) => t.toJson()).toList(), 'liked': liked.toList(), 'lists': lists, 'recent': recent.take(50).toList(),
        'plays': plays, 'name': name, 'avatar': avatar, 'ytEmail': ytAccountEmail, 'ytCookie': ytAuthCookie, 'swipe': swipe, 'sort': sort, 'haptics': haptics, 'showVol': showVol,
        'resume': resume, 'skip': skipSilence, 'stop': stopOnClear, 'grid': libGrid, 'accent': accent, 'shuffle': shuffle, 'repeat': repeat, 'dirs': dirs, 'dyn': dyn, 'pbg': pbg, 'sl': sliderStyle, 'lc': lyricsCard, 'se': skipErr, 'nm': normalize, 'slim': slim, 'sa': swipeArt, 'tab0': tab0,
        'speed': speed, 'pitch': pitch, 'lp': linkPitch,
        'queue': queue.take(200).map((t) => t.path).toList(), 'qi': idx,
        'skin': skin, 'nps': npStyle, 'shape': artShape, 'glow': glow, 'spin': spinArt, 'viz': viz, 'remain': remain, 'dbl': dbl, 'badge': badgeOn, 'fade': fadeIn, 'mp': miniProg, 'eq': eqOn, 'pctx': playCtx,
      }));
  void set(void Function() f) { f(); save(); notifyListeners(); }
  void setSkin(int i) => set(() { skin = i; tab = 0; });
  void goTab(int i) { tab = i; notifyListeners(); }

  Future<void> refreshOut() async {
    try {
      final m = await ch.invokeMethod<Map>('outputDevice');
      if (m != null) {
        final raw = '${m['name'] ?? ''}'.trim();
        outName = raw.isEmpty ? 'ALEXWIN11PRO' : raw.toUpperCase();
        outKind = '${m['kind'] ?? 'phone'}';
        notifyListeners();
      }
    } catch (_) {}
  }

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
          duration: vid.duration != null ? fmt(vid.duration!) : '',
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
    toast('Streaming "${s.title}" from YouTube Music…');
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
        final existingIdx = tracks.indexWhere((t) => t.path == streamUrl);
        if (existingIdx < 0) { tracks.insert(0, tr); save(); }
        await playAt([tr, ...queue.where((x) => x.path != streamUrl)], 0, ctx: 'YouTube Music');
      } else {
        toast('Could not resolve stream for "${s.title}"');
      }
    } catch (e) {
      toast('Error streaming "${s.title}": $e');
    }
    loadingYt = false;
    notifyListeners();
  }

  void abLoop() {
    if (la == null) { la = p.position; toast('Loop start set'); }
    else if (lb == null) { lb = p.position; if (lb! <= la!) { la = null; lb = null; toast('Loop cleared'); } else { toast('Looping A–B'); } }
    else { la = null; lb = null; toast('Loop cleared'); }
    notifyListeners();
  }

  Future<void> _loadPath(String path) async {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      await p.setAudioSource(
        AudioSource.uri(
          Uri.parse(path),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': '*/*',
            'Accept-Language': 'en-US,en;q=0.9',
            'Range': 'bytes=0-',
            if (ytAuthCookie != null) 'Cookie': ytAuthCookie!,
          },
        ),
      );
    } else {
      await p.setFilePath(path);
    }
  }

  Future<void> _load() async {
    final t = cur; if (t == null) return;
    la = null; lb = null; notifyListeners();
    try {
      await _loadPath(t.path);
      h.mediaItem.add(MediaItem(id: t.path, title: t.title, artist: t.artist, album: t.album, artUri: t.art != null && !t.art!.startsWith('http') ? Uri.file(t.art!) : (t.art != null ? Uri.parse(t.art!) : null)));
      await p.setSpeed(speed);
      await p.setPitch(pitch);
      await p.setVolume(fadeIn ? 0 : vol);
      await p.setSkipSilenceEnabled(skipSilence);
      try { await h.enh.setEnabled(normalize); await h.enh.setTargetGain(3.0); await h.eq.setEnabled(eqOn); } catch (_) {}
      _errs = 0; p.play(); if (fadeIn) _fade();
    } catch (_) { toast('Cannot play ${t.title}'); if (skipErr && ++_errs < queue.length) { next(); return; } }
    recent..remove(t.path)..insert(0, t.path); plays[t.path] = (plays[t.path] ?? 0) + 1;
    sp.setString('last', t.path); save(); notifyListeners();
  }

  Future<void> scan() async {
    await [Permission.audio, Permission.storage, Permission.notification, Permission.bluetoothConnect].request();
    scanning = true; notifyListeners();
    final found = <String>{...tracks.where((t) => !t.path.startsWith('http') && !dirs.any((d) => t.path.startsWith(d)) && File(t.path).existsSync()).map((t) => t.path)};
    for (final d in dirs) {
      try { for (final e in Directory(d).listSync(recursive: true, followLinks: false)) { if (e is File && exts.any((x) => e.path.toLowerCase().endsWith(x))) found.add(e.path); } } catch (_) {}
    }
    final old = byPath;
    tracks = [for (final x in found) old[x] ?? Track.from(x), ...tracks.where((t) => t.path.startsWith('http'))];
    scanning = false; notifyListeners(); save();
  }

  Future<void> addFiles() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.audio);
    if (r == null) return;
    final old = byPath;
    for (final f in r.files.where((f) => f.path != null)) { if (!old.containsKey(f.path)) { final t = Track.from(f.path!); tracks.add(t); } }
    set(() {});
  }

  Future<void> playAt(List<Track> q, int i, {String? ctx}) async {
    if (q.isEmpty) return;
    if (ctx != null && ctx.isNotEmpty) playCtx = ctx;
    queue = List.of(q);
    idx = i.clamp(0, queue.length - 1);
    await _load();
  }

  Future<void> shufflePlay(List<Track> q, {String? ctx}) async {
    if (q.isEmpty) return;
    shuffle = true; save();
    await playAt(q, Random().nextInt(q.length), ctx: ctx);
  }

  void _fade() { var k = 0; Timer.periodic(const Duration(milliseconds: 60), (t) { k++; p.setVolume(vol * k / 10); if (k >= 10) t.cancel(); }); }
  Future<void> next({bool auto = false}) async {
    if (queue.isEmpty) return;
    if (auto && repeat == 2) { await p.seek(Duration.zero); p.play(); return; }
    if (shuffle && queue.length > 1) { idx = Random().nextInt(queue.length); }
    else if (idx + 1 < queue.length) { idx++; }
    else if (repeat == 1 || !auto) { idx = 0; }
    else { await p.pause(); await p.seek(Duration.zero); notifyListeners(); return; }
    await _load();
  }
  Future<void> prev() async {
    if (queue.isEmpty) return;
    if (p.position.inSeconds > 3) { await p.seek(Duration.zero); return; }
    idx = idx > 0 ? idx - 1 : queue.length - 1; await _load();
  }
  void toggle() { p.playing ? p.pause() : p.play(); }
  Future<void> close() async { await h.stop(); queue = []; idx = -1; notifyListeners(); }
  void setSpeed(double s) { speed = s.clamp(0.25, 2.5).toDouble(); p.setSpeed(speed); if (linkPitch) { pitch = speed; p.setPitch(pitch); } save(); notifyListeners(); }
  void setPitch(double v) { pitch = v.clamp(0.25, 2.5).toDouble(); p.setPitch(pitch); if (linkPitch) { speed = pitch; p.setSpeed(speed); } save(); notifyListeners(); }
  void setSemitones(double st) { setPitch(pow(2.0, st.clamp(-12.0, 12.0) / 12.0).toDouble()); }
  void applyTunePreset(double spd, double ptch, {bool linked = false}) { linkPitch = linked; speed = spd.clamp(0.25, 2.5).toDouble(); pitch = ptch.clamp(0.25, 2.5).toDouble(); p.setSpeed(speed); p.setPitch(pitch); save(); notifyListeners(); }
  void setVol(double v) { vol = v; p.setVolume(v); notifyListeners(); }
  void colorOf(Track t) {}
  void like(Track t) => set(() { if (!liked.remove(t.path)) liked.add(t.path); });
  void clearArt() { for (final t in tracks) { t.art = null; } set({}); toast('Cleared'); }
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
          theme: ThemeData(useMaterial3: true, brightness: Brightness.dark, scaffoldBackgroundColor: bg, canvasColor: card, colorScheme: ColorScheme.dark(primary: gr, surface: bg)),
          home: const Shell(),
        ),
      );
}

class Art extends StatelessWidget {
  final Track? t; final double s; final double? r;
  const Art(this.t, this.s, {this.r, super.key});
  @override
  Widget build(BuildContext context) {
    final f = t?.art, ok = f != null && (f.startsWith('http') || File(f).existsSync()), rr = r ?? (s > 100 ? app.sk.artR : min(app.sk.artR, 6.0));
    final col = t != null ? tint(t!.title, .25) : tint('music', .25);
    return ClipRRect(
      borderRadius: BorderRadius.circular(rr),
      child: Container(
        width: s, height: s, decoration: BoxDecoration(color: col),
        child: ok ? (f.startsWith('http') ? Image.network(f, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.music_note)) : Image.file(File(f), fit: BoxFit.cover)) : const Icon(Icons.music_note),
      ),
    );
  }
}

Widget avatar(double r, {bool dot = false}) => CircleAvatar(radius: r, backgroundColor: gr, child: Text(app.name[0].toUpperCase(), style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800)));

Widget head(BuildContext c, String title, {List<Widget> actions = const []}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
      child: Row(children: [GestureDetector(onTap: () => openProfile(c), child: avatar(16)), const SizedBox(width: 12), Expanded(child: tx(title, z: 24, f: FontWeight.w800)), ...actions]),
    );

void sheet(BuildContext c, Widget Function(BuildContext) b, {bool big = false}) => showModalBottomSheet(
      context: c, isScrollControlled: big, backgroundColor: const Color(0xFF282828),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))), builder: b);

void trackMenu(BuildContext c, Track t) => sheet(c, (s) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: tx(t.title, f: FontWeight.w700), subtitle: tx(t.artist, c: grey)),
          ListTile(leading: const Icon(Icons.tune, color: Colors.white), title: const Text('Speed & Pitch'), onTap: () { Navigator.pop(s); sheet(c, (_) => const TuneSheet(), big: true); }),
          ListTile(leading: const Icon(Icons.equalizer, color: Colors.white), title: const Text('Equalizer'), onTap: () { Navigator.pop(s); sheet(c, (_) => const EqSheet(), big: true); }),
        ],
      ),
    ));

class TTile extends StatelessWidget {
  final Track t; final List<Track> list; final int i;
  const TTile(this.t, this.list, this.i, {super.key});
  @override
  Widget build(BuildContext c) => ListTile(
        leading: Art(t, 48), title: tx(t.title), subtitle: tx(t.artist, c: grey),
        trailing: IconButton(icon: const Icon(Icons.more_vert, color: grey), onPressed: () => trackMenu(c, t)),
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
            Container(
              color: bg,
              child: SafeArea(top: false, child: Row(children: [for (var i = 0; i < s.nav.length; i++) Expanded(child: IconButton(icon: Icon(s.nav[i].i), onPressed: () => app.goTab(i)))])),
            ),
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
        child: Row(children: [Art(t, 42), const SizedBox(width: 10), Expanded(child: tx(t.title)), IconButton(icon: Icon(app.p.playing ? Icons.pause : Icons.play_arrow), onPressed: app.toggle)]),
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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 32), onPressed: () => Navigator.pop(c)),
              const Spacer(),
              Art(app.cur, 300, r: 12),
              const Spacer(),
              tx(app.cur?.title ?? '', z: 22, f: FontWeight.w800),
              tx(app.cur?.artist ?? '', z: 15, c: grey),
              const Padding(padding: EdgeInsets.all(20), child: Seek(2, false)),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(icon: const Icon(Icons.skip_previous, size: 40), onPressed: app.prev),
                  IconButton(icon: Icon(app.p.playing ? Icons.pause : Icons.play_arrow, size: 50), onPressed: app.toggle),
                  IconButton(icon: const Icon(Icons.skip_next, size: 40), onPressed: app.next),
                ],
              ),
              const SizedBox(height: 30),
            ],
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
              const SizedBox(height: 10),
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
  Widget build(BuildContext c) => ListView(children: [head(c, 'Home'), for (var i = 0; i < app.sorted.length; i++) TTile(app.sorted[i], app.sorted, i)]);
}

class NewPage extends StatelessWidget { const NewPage({super.key}); @override Widget build(BuildContext c) => ListView(children: [head(c, 'Explore')]); }
class RadioPage extends StatelessWidget { const RadioPage({super.key}); @override Widget build(BuildContext c) => ListView(children: [head(c, 'Radio')]); }

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
        head(c, 'Search'),
        Padding(padding: const EdgeInsets.all(16), child: TextField(controller: ctl, onChanged: search, decoration: const InputDecoration(hintText: 'Search YouTube Music', filled: true))),
        Expanded(child: ListView(children: [if (searching) const Center(child: CircularProgressIndicator()), for (final y in ytRes) ListTile(title: Text(y.title), subtitle: Text(y.artist), trailing: const Icon(Icons.play_arrow), onTap: () => app.playYtSong(y)])),
      ]);
}

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});
  @override
  Widget build(BuildContext c) => Column(children: [head(c, 'Library'), Expanded(child: ListView(children: [for (var i = 0; i < app.sorted.length; i++) TTile(app.sorted[i], app.sorted, i)]))]);
}

// ───────────── YouTube OAuth Sign-In Portal (WebView) ─────────────
void openProfile(BuildContext c) {
  tap();
  Navigator.push(c, MaterialPageRoute(builder: (_) => const YtAuthView()));
}

class YtAuthView extends StatefulWidget {
  const YtAuthView({super.key});
  @override State<YtAuthView> createState() => _YtAuthState();
}

class _YtAuthState extends State<YtAuthView> {
  late final WebViewController controller;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) async {
          setState(() => loading = false);
          if (url.contains('music.youtube.com') || url.contains('youtube.com')) {
            try {
              final cookies = await controller.runJavaScriptReturningResult('document.cookie');
              final cookieStr = cookies.toString();
              if (cookieStr.contains('SAPISID') || cookieStr.contains('HSID') || cookieStr.contains('SID')) {
                app.set(() {
                  app.ytAuthCookie = cookieStr.replaceAll('"', '');
                  app.ytAccountEmail = 'Connected YouTube Account';
                });
                toast('Successfully signed into YouTube Music!');
                if (mounted) Navigator.pop(c);
              }
            } catch (_) {}
          }
        },
      ))
      ..loadRequest(Uri.parse('https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fmusic.youtube.com%2F'));
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(backgroundColor: bg, title: const Text('Sign in to YouTube Music')),
        body: Stack(
          children: [
            WebViewWidget(controller: controller),
            if (loading) const Center(child: CircularProgressIndicator()),
          ],
        ),
      );
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(backgroundColor: bg, title: const Text('Settings')),
        body: ListView(children: [
          srow('Sign out from YouTube Music', icon: Icons.logout, f: () { app.set(() { app.ytAuthCookie = null; app.ytAccountEmail = null; }); toast('Signed out'); }),
          srow('Rescan music files', icon: Icons.refresh, f: app.scan),
        ]),
      );
}
