// FILE: custom/main.dart — Pixel Audio Player 4.0 (Bulletproof YouTube Music Streaming via Explode + Speed/Pitch + Replicas)
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
  Skin(
    'Spotify',
    Color(0xFF1ED760),
    Color(0xFF121212),
    Color(0xFF282828),
    [nHome, nSearch, nLib],
    'What do you want to play?',
    artR: 8,
    sz: 152,
  ),
  Skin(
    'Apple Music',
    Color(0xFFFA2D48),
    Color(0xFF000000),
    Color(0xFF1C1C1E),
    [nHome, Nav(Icons.grid_view, Icons.grid_view_rounded, 'New', 'new'), Nav(Icons.sensors, Icons.sensors, 'Radio', 'radio'), Nav(Icons.library_music_outlined, Icons.library_music, 'Library', 'lib'), nSearch],
    'Artists, Songs, Lyrics, and More',
    title: 'Listen Now',
    head: 1,
    home: 1,
    mini: 1,
    np: 1,
    navAcc: true,
    artR: 10,
    sz: 164,
  ),
  Skin(
    'YouTube Music',
    Color(0xFFFF0000),
    Color(0xFF030303),
    Color(0xFF212121),
    [nHome, Nav(Icons.smart_display_outlined, Icons.smart_display, 'Samples', 'radio'), Nav(Icons.explore_outlined, Icons.explore, 'Explore', 'new'), Nav(Icons.library_music_outlined, Icons.library_music, 'Library', 'lib')],
    'Search songs, albums, artists',
    head: 2,
    home: 2,
    mini: 2,
    np: 2,
    artR: 4,
  ),
  Skin(
    'Amazon Music',
    Color(0xFF25D1DA),
    Color(0xFF0F1923),
    Color(0xFF1B2733),
    [nHome, Nav(Icons.manage_search, Icons.manage_search, 'Find', 'search'), Nav(Icons.library_music_outlined, Icons.library_music, 'Library', 'lib')],
    'Search',
    head: 1,
    home: 3,
    mini: 3,
    np: 3,
    navAcc: true,
    pill: true,
    artR: 4,
    sz: 156,
  ),
  Skin(
    'TIDAL',
    Color(0xFFFFD43B),
    Color(0xFF000000),
    Color(0xFF18181A),
    [
      nHome,
      Nav(Icons.smart_display_outlined, Icons.smart_display, '', 'new'),
      Nav(Icons.search, Icons.search, '', 'search'),
      Nav(Icons.equalizer, Icons.equalizer, '', 'radio'),
      Nav(Icons.account_circle_outlined, Icons.account_circle, '', 'lib'),
    ],
    'Search artists, songs, albums',
    home: 4,
    mini: 4,
    np: 4,
    artR: 8,
    sz: 156,
  ),
  Skin(
    'SoundCloud',
    Color(0xFFFF5500),
    Color(0xFF111111),
    Color(0xFF222222),
    [nHome, Nav(Icons.dynamic_feed_outlined, Icons.dynamic_feed, 'Feed', 'new'), nSearch, Nav(Icons.library_music_outlined, Icons.library_music, 'Library', 'lib')],
    'Search for artists, tracks, albums',
    home: 5,
    mini: 5,
    np: 5,
    navAcc: true,
    artR: 2,
  ),
  Skin(
    'Deezer',
    Color(0xFFA238FF),
    Color(0xFF121216),
    Color(0xFF23232B),
    [nHome, nSearch, Nav(Icons.favorite_border, Icons.favorite, 'Favorites', 'lib'), Nav(Icons.all_inclusive, Icons.all_inclusive, 'Flow', 'radio')],
    'Search for a song or artist',
    head: 1,
    home: 6,
    mini: 6,
    np: 6,
    navAcc: true,
    artR: 12,
  ),
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

// ───────────── globals & helpers ─────────────
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
String navLabel(String k) {
  final l = app.sk.nav.firstWhere((n) => n.k == k, orElse: () => nLib).l;
  if (l.isNotEmpty) return l;
  return switch (k) { 'home' => 'Home', 'search' => 'Search', 'lib' => 'My Collection', 'new' => 'Explore', 'radio' => 'Mixes', _ => 'Library' };
}
String badge(Track t) { final e = t.path.split('.').last.toUpperCase(); return e == 'FLAC' || e == 'WAV' ? '$e • LOSSLESS' : '$e • MAX'; }
List<Track> mix(List<Track> all, int n) => ([...all]..shuffle(Random(DateTime.now().difference(DateTime(2024)).inDays + n))).take(25).toList();

void toast(String s) => msg.currentState
  ?..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(s), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
Color tint(String s, [double l = .28]) => HSLColor.fromAHSL(1, (s.hashCode % 360).abs().toDouble(), .55, l).toColor();
String fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
void tap() { if (app.haptics) HapticFeedback.selectionClick(); }
Widget tx(String s, {double z = 14, FontWeight f = FontWeight.w500, Color c = Colors.white, int lines = 1, TextAlign? a, double? ls, double? h}) =>
    Text(s, maxLines: lines, overflow: TextOverflow.ellipsis, textAlign: a, style: TextStyle(fontSize: z, fontWeight: f, color: c, letterSpacing: ls, height: h));

Widget explicitBadge() => Container(
      width: 15,
      height: 15,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: const Color(0xFF9E9E9E), borderRadius: BorderRadius.circular(3)),
      child: const Text('E', style: TextStyle(color: Color(0xFF121212), fontSize: 10, fontWeight: FontWeight.w900, height: 1.0)),
    );

// ───────────── models ─────────────
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

// ───────────── state ─────────────
class AppState extends ChangeNotifier {
  late SharedPreferences sp; late H h; String cache = '';
  AudioPlayer get p => h.p;
  List<Track> tracks = [], queue = []; int idx = -1;
  Set<String> liked = {}; Map<String, List<String>> lists = {}; List<String> recent = []; Map<String, int> plays = {};
  String name = 'Alex', swipe = 'skip', sort = 'recent', playCtx = 'Liked Songs'; String? avatar, ytAccountEmail;
  bool shuffle = false, haptics = true, showVol = false, resume = true, skipSilence = false, stopOnClear = false, scanning = false, libGrid = false;
  int repeat = 0, accent = 0; double speed = 1, vol = 1; DateTime? sleepAt; Timer? _sleep;
  int pbg = 0, sliderStyle = 0, tab0 = 0, pqi = 0, _errs = 0;
  bool dyn = false, lyricsCard = true, skipErr = true, normalize = false, slim = false, swipeArt = true, sleepEnd = false, linkPitch = false, loadingYt = false;
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
  String get tuneSummary {
    final st = semitones;
    final stStr = st.abs() < 0.05 ? '±0 st' : '${st > 0 ? '+' : ''}${st.toStringAsFixed(1)} st';
    return '${speed.toStringAsFixed(2)}× • $stStr';
  }

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
      if (queue.isEmpty) { idx = -1; } else { idx = pqi.clamp(0, queue.length - 1); try { await _loadPath(cur!.path); } catch (_) {} }
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
      name = d['name'] ?? name; avatar = d['avatar']; ytAccountEmail = d['ytEmail']; swipe = d['swipe'] ?? swipe; sort = d['sort'] ?? sort;
      haptics = d['haptics'] ?? true; showVol = d['showVol'] ?? false; resume = d['resume'] ?? true;
      skipSilence = d['skip'] ?? false; stopOnClear = d['stop'] ?? false; libGrid = d['grid'] ?? false;
      accent = d['accent'] ?? 0; shuffle = d['shuffle'] ?? false; repeat = d['repeat'] ?? 0;
      dirs = ((d['dirs'] ?? dirs) as List).cast<String>();
      dyn = d['dyn'] ?? false; pbg = d['pbg'] ?? 0; sliderStyle = d['sl'] ?? 0; lyricsCard = d['lc'] ?? true; skipErr = d['se'] ?? true; normalize = d['nm'] ?? false; slim = d['slim'] ?? false; swipeArt = d['sa'] ?? true; tab0 = d['tab0'] ?? 0;
      speed = (d['speed'] ?? 1.0).toDouble().clamp(0.25, 3.0);
      pitch = (d['pitch'] ?? 1.0).toDouble().clamp(0.25, 3.0);
      linkPitch = d['lp'] ?? false;
      pq = ((d['queue'] ?? []) as List).cast<String>(); pqi = d['qi'] ?? 0;
      skin = d['skin'] ?? 0; npStyle = d['nps'] ?? -1; artShape = d['shape'] ?? 0; glow = d['glow'] ?? true; spinArt = d['spin'] ?? true; viz = false; remain = false; dbl = true; badgeOn = false; fadeIn = false; miniProg = true; eqOn = false;
      playCtx = d['pctx'] ?? 'Liked Songs';
      tab = tab0;
    } catch (_) {}
  }

  void save() => sp.setString('d', jsonEncode({
        'tracks': tracks.map((t) => t.toJson()).toList(), 'liked': liked.toList(), 'lists': lists, 'recent': recent.take(50).toList(),
        'plays': plays, 'name': name, 'avatar': avatar, 'ytEmail': ytAccountEmail, 'swipe': swipe, 'sort': sort, 'haptics': haptics, 'showVol': showVol,
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

  // ── Bulletproof YouTube Music Search & Streaming via youtube_explode_dart ──
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
        final tr = Track(
          streamUrl,
          s.title,
          s.artist,
          s.album,
          s.art.isEmpty ? null : s.art,
          DateTime.now(),
        );
        final existingIdx = tracks.indexWhere((t) => t.path == streamUrl);
        if (existingIdx < 0) {
          tracks.insert(0, tr);
          save();
        }
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

  Future<void> _meta(Track t) async {
    if (t.path.startsWith('http')) return;
    try {
      final m = await ch.invokeMethod<Map>('read', {'path': t.path});
      if (m == null) return;
      final ti = m['title'] as String?; if (ti != null && ti.trim().isNotEmpty) t.title = ti;
      final ar = m['artist'] as String?; if (ar != null && ar.trim().isNotEmpty) t.artist = ar;
      final al = m['album'] as String?; if (al != null && al.trim().isNotEmpty) t.album = al;
      final b = m['art'];
      if (b is Uint8List && cache.isNotEmpty) {
        final f = File('$cache/art_${t.path.hashCode}.jpg');
        if (!f.existsSync()) await f.writeAsBytes(b);
        t.art = f.path;
      }
    } catch (_) {}
  }

  Future<void> scan() async {
    await [Permission.audio, Permission.storage, Permission.notification, Permission.bluetoothConnect].request();
    scanning = true; notifyListeners();
    final found = <String>{...tracks.where((t) => !t.path.startsWith('http') && !dirs.any((d) => t.path.startsWith(d)) && File(t.path).existsSync()).map((t) => t.path)};
    for (final d in dirs) {
      try {
        for (final e in Directory(d).listSync(recursive: true, followLinks: false)) {
          if (e is File && exts.any((x) => e.path.toLowerCase().endsWith(x))) found.add(e.path);
        }
      } catch (_) {}
    }
    final old = byPath;
    tracks = [for (final x in found) old[x] ?? Track.from(x), ...tracks.where((t) => t.path.startsWith('http'))];
    scanning = false; notifyListeners(); save();
    var n = 0;
    for (final t in tracks.where((t) => !t.path.startsWith('http') && t.art == null && t.artist == 'Unknown artist').toList()) { await _meta(t); if (++n % 8 == 0) notifyListeners(); }
    notifyListeners(); save();
  }

  Future<void> addFiles() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.audio);
    if (r == null) return;
    final old = byPath;
    for (final f in r.files.where((f) => f.path != null)) { if (!old.containsKey(f.path)) { final t = Track.from(f.path!); await _meta(t); tracks.add(t); } }
    set(() {});
  }

  Future<void> addFolder() async {
    final d = await FilePicker.platform.getDirectoryPath();
    if (d != null) { dirs = {...dirs, d}.toList(); save(); scan(); }
  }

  // ── playback ──
  Future<void> playAt(List<Track> q, int i, {String? ctx}) async {
    if (q.isEmpty) return;
    if (ctx != null && ctx.isNotEmpty) playCtx = ctx;
    queue = List.of(q);
    idx = i.clamp(0, queue.length - 1);
    await _load();
  }

  Future<void> shufflePlay(List<Track> q, {String? ctx}) async {
    if (q.isEmpty) return;
    shuffle = true;
    save();
    await playAt(q, Random().nextInt(q.length), ctx: ctx);
  }

  void _fade() { var k = 0; Timer.periodic(const Duration(milliseconds: 60), (t) { k++; p.setVolume(vol * k / 10); if (k >= 10) t.cancel(); }); }

  Future<void> _loadPath(String path) async {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      await p.setUrl(path);
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
      await p.setSpeed(speed); await p.setPitch(pitch); await p.setVolume(fadeIn ? 0 : vol); await p.setSkipSilenceEnabled(skipSilence);
      try { await h.enh.setEnabled(normalize); await h.enh.setTargetGain(3.0); await h.eq.setEnabled(eqOn); } catch (_) {}
      _errs = 0; p.play(); if (fadeIn) _fade();
    } catch (_) { toast('Cannot play ${t.title}'); if (skipErr && ++_errs < queue.length) { next(); return; } }
    recent..remove(t.path)..insert(0, t.path); plays[t.path] = (plays[t.path] ?? 0) + 1;
    sp.setString('last', t.path); save(); notifyListeners();
  }
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
  void playNext(Track t) { if (cur == null) { playAt([t], 0); return; } queue.insert(idx + 1, t); toast('Playing next'); notifyListeners(); }
  void enqueue(Track t) { if (cur == null) { playAt([t], 0); return; } queue.add(t); toast('Added to queue'); notifyListeners(); }
  void reorderQueue(int o, int n) { final c = cur; if (n > o) n--; queue.insert(n, queue.removeAt(o)); idx = queue.indexOf(c!); notifyListeners(); }

  void setSpeed(double s) {
    speed = s.clamp(0.25, 2.5).toDouble();
    p.setSpeed(speed);
    if (linkPitch) {
      pitch = speed;
      p.setPitch(pitch);
    }
    save();
    notifyListeners();
  }

  void setPitch(double v) {
    pitch = v.clamp(0.25, 2.5).toDouble();
    p.setPitch(pitch);
    if (linkPitch) {
      speed = pitch;
      p.setSpeed(speed);
    }
    save();
    notifyListeners();
  }

  void setSemitones(double st) {
    final ratio = pow(2.0, st.clamp(-12.0, 12.0) / 12.0).toDouble();
    setPitch(ratio);
  }

  void applyTunePreset(double spd, double ptch, {bool linked = false}) {
    linkPitch = linked;
    speed = spd.clamp(0.25, 2.5).toDouble();
    pitch = ptch.clamp(0.25, 2.5).toDouble();
    p.setSpeed(speed);
    p.setPitch(pitch);
    save();
    notifyListeners();
  }

  void setVol(double v) { vol = v; p.setVolume(v); notifyListeners(); }
  void setSleep(int? min) {
    _sleep?.cancel(); sleepAt = null;
    if (min != null) { sleepAt = DateTime.now().add(Duration(minutes: min)); _sleep = Timer(Duration(minutes: min), () { p.pause(); sleepAt = null; notifyListeners(); }); toast('Sleep timer: $min min'); }
    notifyListeners();
  }

  Color colorOf(Track t) {
    final c = _cols[t.path]; if (c != null) return c;
    if (t.art != null && !t.art!.startsWith('http') && _pend.add(t.path)) _dom(t);
    return tint(t.title, .32);
  }
  Future<void> _dom(Track t) async {
    try {
      final codec = await ui.instantiateImageCodec(await File(t.art!).readAsBytes(), targetWidth: 16, targetHeight: 16);
      final bd = await (await codec.getNextFrame()).image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) return;
      double r = 0, g = 0, b = 0, w = 0;
      for (var i = 0; i + 3 < bd.lengthInBytes; i += 4) { final R = bd.getUint8(i), G = bd.getUint8(i + 1), B = bd.getUint8(i + 2); final wt = 1 + (max(R, max(G, B)) - min(R, min(G, B))) / 32; r += R * wt; g += G * wt; b += B * wt; w += wt; }
      final h = HSLColor.fromColor(Color.fromARGB(255, (r / w).round(), (g / w).round(), (b / w).round()));
      _cols[t.path] = h.withLightness(h.lightness.clamp(.22, .46).toDouble()).withSaturation(max(h.saturation, .5).clamp(0.0, 1.0).toDouble()).toColor(); notifyListeners();
    } catch (_) {}
  }
  List<(Duration, String)> lyricsOf(Track t) => _lrc[t.path] ??= () {
        final out = <(Duration, String)>[];
        try {
          final f = File(t.path.replaceAll(RegExp(r'\.[^./]+$'), '.lrc'));
          if (!f.existsSync()) return out;
          final re = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]');
          for (final line in f.readAsLinesSync()) {
            final ms = re.allMatches(line).toList(); if (ms.isEmpty) continue;
            final text = line.replaceAll(re, '').trim();
            for (final m in ms) { out.add((Duration(milliseconds: ((int.parse(m[1]!) * 60 + double.parse(m[2]!)) * 1000).round()), text)); }
          }
          out.sort((a, b) => a.$1.compareTo(b.$1));
        } catch (_) {}
        return out;
      }();
  Future<void> backup() async { save(); await Clipboard.setData(ClipboardData(text: sp.getString('d') ?? '{}')); toast('Backup copied to clipboard'); }
  Future<void> restore() async {
    final d = await Clipboard.getData('text/plain');
    try { jsonDecode(d?.text ?? ''); sp.setString('d', d!.text!); load(); notifyListeners(); toast('Backup restored'); } catch (_) { toast('Clipboard has no valid backup'); }
  }

  // ── library ──
  void like(Track t) => set(() { if (!liked.remove(t.path)) liked.add(t.path); });
  bool createList(String n) { n = n.trim(); if (n.isEmpty || lists.containsKey(n)) return false; set(() => lists[n] = []); return true; }
  bool rename(String o, String n) { n = n.trim(); if (n.isEmpty || (n != o && lists.containsKey(n))) return false; set(() { final l = lists.remove(o)!; lists[n] = l; }); return true; }
  void deleteList(String n) => set(() => lists.remove(n));
  void toggleIn(String n, Track t) => set(() { final l = lists[n]!; if (!l.remove(t.path)) l.add(t.path); });
  void reorderList(String n, int o, int nw) => set(() { if (nw > o) nw--; final l = lists[n]!; l.insert(nw, l.removeAt(o)); });
  void clearHistory() => set(() { recent.clear(); plays.clear(); });
  void clearArt() { try { for (final f in Directory(cache).listSync()) { if (f.path.contains('art_')) f.deleteSync(); } } catch (_) {} for (final t in tracks) { t.art = null; } set(() {}); toast('Artwork cache cleared'); }
  void reset() { sp.remove('d'); name = 'Alex'; avatar = null; ytAccountEmail = null; swipe = 'skip'; accent = 0; skin = 0; tab = 0; npStyle = -1; artShape = 0; glow = true; spinArt = true; viz = false; remain = false; dbl = true; badgeOn = false; fadeIn = false; miniProg = true; eqOn = false; dyn = false; pbg = 0; sliderStyle = 0; lyricsCard = true; speed = 1; pitch = 1; linkPitch = false; slim = false; shuffle = false; repeat = 0; haptics = true; showVol = false; resume = true; stopOnClear = false; skipSilence = false; save(); notifyListeners(); toast('Settings reset'); }
}

// ───────────── entry ─────────────
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
          theme: ThemeData(
            useMaterial3: true, brightness: Brightness.dark, scaffoldBackgroundColor: bg, canvasColor: card,
            colorScheme: ColorScheme.dark(primary: gr, surface: bg),
            sliderTheme: SliderThemeData(trackHeight: 4, activeTrackColor: Colors.white, inactiveTrackColor: Colors.white24, thumbColor: Colors.white, overlayShape: SliderComponentShape.noOverlay, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
          ),
          home: const Shell(),
        ),
      );
}

// ───────────── shared widgets ─────────────
class Art extends StatelessWidget {
  final Track? t; final double s; final double? r;
  const Art(this.t, this.s, {this.r, super.key});
  @override
  Widget build(BuildContext context) {
    final f = t?.art, ok = f != null && (f.startsWith('http') || File(f).existsSync()), rr = r ?? (s > 100 ? app.sk.artR : min(app.sk.artR, 6.0));
    final col = t != null ? app.colorOf(t!) : tint('music', .25);
    return ClipRRect(
      borderRadius: BorderRadius.circular(rr),
      child: Container(
        width: s, height: s,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [col, HSLColor.fromColor(col).withLightness(.14).toColor()],
          ),
        ),
        child: ok
            ? (f.startsWith('http')
                ? Image.network(f, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Icon(Icons.music_note_rounded, color: Colors.white70, size: s * .42))
                : Image.file(File(f), fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: s.isFinite ? (s * 3).toInt().clamp(120, 900) : 600))
            : Icon(Icons.music_note_rounded, color: Colors.white70, size: s * .42),
      ),
    );
  }
}

class CollageArt extends StatelessWidget {
  final List<Track> tracks;
  final double size;
  final double radius;
  const CollageArt(this.tracks, this.size, {this.radius = 6, super.key});

  @override
  Widget build(BuildContext context) {
    final withArt = tracks.where((t) => t.art != null && (t.art!.startsWith('http') || File(t.art!).existsSync())).take(4).toList();
    if (withArt.length < 4) {
      return Art(tracks.firstOrNull, size, r: radius);
    }
    final half = size / 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: Column(
          children: [
            Row(children: [Art(withArt[0], half, r: 0), Art(withArt[1], half, r: 0)]),
            Row(children: [Art(withArt[2], half, r: 0), Art(withArt[3], half, r: 0)]),
          ],
        ),
      ),
    );
  }
}

Widget avatar(double r, {bool dot = false}) {
  final has = app.avatar != null && File(app.avatar!).existsSync();
  final av = CircleAvatar(
    radius: r, backgroundColor: gr, backgroundImage: has ? FileImage(File(app.avatar!)) : null,
    child: has ? null : Text(app.name.isEmpty ? '?' : app.name[0].toUpperCase(), style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: r * .9)),
  );
  if (!dot) return av;
  return Stack(
    clipBehavior: Clip.none,
    children: [
      av,
      Positioned(
        top: -1,
        right: -1,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: const Color(0xFF639BFF),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black, width: 1.6),
          ),
        ),
      ),
    ],
  );
}

Widget head(BuildContext c, String title, {List<Widget> actions = const []}) {
  final h = app.sk.head;
  if (h == 1) return Padding(padding: const EdgeInsets.fromLTRB(16, 14, 8, 8), child: Row(children: [Expanded(child: tx(title, z: 32, f: FontWeight.w900)), ...actions, GestureDetector(onTap: () => openProfile(c), child: avatar(17)), const SizedBox(width: 8)]));
  if (h == 2) return Padding(padding: const EdgeInsets.fromLTRB(16, 12, 8, 8), child: Row(children: [Icon(Icons.play_circle_fill, color: gr, size: 30), const SizedBox(width: 8), tx('Music', z: 22, f: FontWeight.w800), const Spacer(), ...actions, GestureDetector(onTap: () => openProfile(c), child: avatar(16)), const SizedBox(width: 8)]));
  return Padding(padding: const EdgeInsets.fromLTRB(16, 12, 4, 8), child: Row(children: [GestureDetector(onTap: () => openProfile(c), child: avatar(16)), const SizedBox(width: 12), Expanded(child: tx(title, z: 24, f: FontWeight.w800)), ...actions]));
}

Future<String?> ask(BuildContext c, String title, [String init = '']) {
  final ctl = TextEditingController(text: init);
  return showDialog<String>(
    context: c,
    builder: (d) => AlertDialog(
      backgroundColor: const Color(0xFF282828), title: Text(title),
      content: TextField(controller: ctl, autofocus: true, decoration: InputDecoration(enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: grey)), focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: gr)))),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel', style: TextStyle(color: grey))), TextButton(onPressed: () => Navigator.pop(d, ctl.text), child: Text('Save', style: TextStyle(color: gr)))],
    ),
  );
}

void sheet(BuildContext c, Widget Function(BuildContext) b, {bool big = false}) => showModalBottomSheet(
      context: c, isScrollControlled: big, backgroundColor: const Color(0xFF282828),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))), builder: b);

Widget opt(IconData i, String t, VoidCallback f, {Color c = Colors.white}) => ListTile(leading: Icon(i, color: c), title: Text(t, style: TextStyle(color: c)), onTap: f);

Widget dd<T>(Map<T, String> o, T v, void Function(T) f, {Widget Function(T)? lead}) => Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4), padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(12)),
      child: DropdownButtonHideUnderline(child: DropdownButton<T>(
        isExpanded: true, value: v, dropdownColor: const Color(0xFF282828), icon: const Icon(Icons.arrow_drop_down),
        items: [for (final e in o.entries) DropdownMenuItem<T>(value: e.key, child: Row(children: [if (lead != null) ...[lead(e.key), const SizedBox(width: 10)], Text(e.value, style: const TextStyle(fontWeight: FontWeight.w700))]))],
        onChanged: (x) { if (x != null) { tap(); f(x); } },
      )),
    );

Widget skinDrop() => ListenableBuilder(listenable: app, builder: (_, __) => dd<int>({for (final (i, s) in skins.indexed) i: s.name}, app.skin, app.setSkin, lead: (i) => Container(width: 14, height: 14, decoration: BoxDecoration(color: skins[i].accent, shape: BoxShape.circle))));

// ── 3-DOT MENU ──
void trackMenu(BuildContext c, Track t, {String? inList}) => sheet(c, (s) => ListenableBuilder(
      listenable: app,
      builder: (_, __) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(leading: Art(t, 48), title: tx(t.title, f: FontWeight.w700), subtitle: tx(t.artist, c: grey, z: 13)),
              const Divider(color: Colors.white12),
              opt(
                app.liked.contains(t.path) ? Icons.check_circle : Icons.add_circle_outline,
                app.liked.contains(t.path) ? 'Remove from Liked Songs' : 'Add to Liked Songs',
                () { app.like(t); Navigator.pop(s); },
                c: app.liked.contains(t.path) ? gr : Colors.white,
              ),
              opt(
                Icons.tune_rounded,
                'Speed & pitch (${app.tuneSummary})',
                () {
                  Navigator.pop(s);
                  sheet(c, (_) => const TuneSheet(), big: true);
                },
                c: app.isTuned ? gr : Colors.white,
              ),
              opt(
                Icons.equalizer_rounded,
                app.eqOn ? 'Equalizer (On)' : 'Equalizer',
                () {
                  Navigator.pop(s);
                  sheet(c, (_) => const EqSheet(), big: true);
                },
                c: app.eqOn ? gr : Colors.white,
              ),
              opt(Icons.playlist_add, 'Add to playlist', () { Navigator.pop(s); pickList(c, t); }),
              opt(Icons.queue_music, 'Play next', () { app.playNext(t); Navigator.pop(s); }),
              opt(Icons.add_to_queue, 'Add to queue', () { app.enqueue(t); Navigator.pop(s); }),
              opt(Icons.info_outline, 'Song info', () { Navigator.pop(s); showTrackInfo(c, t); }),
              if (inList != null) opt(Icons.remove_circle_outline, 'Remove from this playlist', () { app.toggleIn(inList, t); Navigator.pop(s); }),
            ],
          ),
        ),
      ),
    ));

void showTrackInfo(BuildContext c, Track t) => sheet(c, (s) => SafeArea(child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Art(t, 56, r: 8), const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx(t.title, z: 18, f: FontWeight.w800), tx(t.artist, c: grey, z: 14), tx(t.album, c: Colors.white54, z: 12)]))]),
        const SizedBox(height: 16),
        const Divider(color: Colors.white12),
        const SizedBox(height: 8),
        tx('AUDIO QUALITY', z: 11, c: tidalGold, f: FontWeight.w800, ls: 1.1),
        const SizedBox(height: 4),
        tx('MAX • ${badge(t)} • 24-bit / 96 kHz', z: 14, f: FontWeight.w700),
        const SizedBox(height: 12),
        tx('FILE LOCATION', z: 11, c: grey, f: FontWeight.w800, ls: 1.1),
        const SizedBox(height: 4),
        tx(t.path, z: 12, c: Colors.white70, lines: 3),
        const SizedBox(height: 12),
      ]),
    )));

void pickList(BuildContext c, Track t) => sheet(c, (s) => ListenableBuilder(
      listenable: app,
      builder: (_, __) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        opt(Icons.add, 'New playlist', () async { Navigator.pop(s); final n = await ask(c, 'Playlist name'); if (n != null && app.createList(n)) app.toggleIn(n.trim(), t); }),
        for (final n in app.lists.keys) CheckboxListTile(activeColor: gr, title: Text(n), value: app.lists[n]!.contains(t.path), onChanged: (_) => app.toggleIn(n, t)),
      ])),
    ));

class TTile extends StatelessWidget {
  final Track t; final List<Track> list; final int i; final String? inList;
  const TTile(this.t, this.list, this.i, {this.inList, super.key});
  @override
  Widget build(BuildContext c) {
    final on = app.cur?.path == t.path;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16), leading: Art(t, 48),
      title: tx(t.title, c: on ? gr : Colors.white, f: FontWeight.w600), subtitle: tx(t.artist, c: grey, z: 13),
      trailing: IconButton(icon: const Icon(Icons.more_vert, color: grey), onPressed: () => trackMenu(c, t, inList: inList)),
      onTap: () { tap(); app.playAt(list, i, ctx: inList ?? 'Your Library'); },
    );
  }
}

// ───────────── customSpotifyLibraryIcon ─────────────
class SpotifyLibIcon extends StatelessWidget {
  final Color color;
  final bool active;
  const SpotifyLibIcon(this.color, {this.active = false, super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 26,
      height: 24,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(width: 3.2, height: 19, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1.5))),
          const SizedBox(width: 3),
          Container(width: 3.2, height: 19, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1.5))),
          const SizedBox(width: 3.5),
          Transform.rotate(
            angle: -0.22,
            child: Container(
              width: 3.5,
              height: 19,
              decoration: BoxDecoration(
                color: active ? color : Colors.transparent,
                border: Border.all(color: color, width: 2.2),
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────── shell / nav ─────────────
Widget page(String k) => switch (k) { 'home' => const HomePage(), 'search' => const SearchPage(), 'lib' => const LibraryPage(), 'new' => const NewPage(), 'radio' => const RadioPage(), _ => const SizedBox() };

class Shell extends StatelessWidget {
  const Shell({super.key});
  void create(BuildContext c) => sheet(c, (s) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        opt(Icons.queue_music, 'Playlist', () async {
          Navigator.pop(s);
          final n = await ask(c, 'Name your playlist', 'My playlist #${app.lists.length + 1}');
          if (n == null) return;
          if (app.createList(n)) { if (c.mounted) Navigator.push(c, MaterialPageRoute(builder: (_) => ListPage(n.trim(), () => app.toTracks(app.lists[n.trim()] ?? []), list: n.trim()))); }
          else { toast('Name is empty or already used'); }
        }),
        opt(Icons.audio_file, 'Add songs from device', () { Navigator.pop(s); app.addFiles(); }),
      ])));

  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final s = app.sk, t = app.tab.clamp(0, s.nav.length - 1);
        final isTidal = s.name == 'TIDAL';
        final isSpotify = s.name == 'Spotify';

        Widget item(int i) {
          final n = s.nav[i], on = t == i && n.k != 'create';
          final col = on ? (s.navAcc ? gr : Colors.white) : const Color(0xFF9E9E9E);
          final hideLbl = app.slim || isTidal || n.l.isEmpty;

          Widget iconWidget;
          if (isSpotify && n.k == 'lib') {
            iconWidget = SpotifyLibIcon(col, active: on);
          } else {
            iconWidget = Icon(on ? n.a : n.i, color: col, size: isTidal ? 27 : 26);
          }

          return Expanded(
            child: InkWell(
              onTap: () { tap(); n.k == 'create' ? create(c) : app.goTab(i); },
              child: SizedBox(
                height: hideLbl ? 52 : 58,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 3),
                      decoration: s.pill && on ? BoxDecoration(color: gr.withValues(alpha: .18), borderRadius: BorderRadius.circular(16)) : null,
                      child: iconWidget,
                    ),
                    if (!hideLbl) ...[
                      const SizedBox(height: 2),
                      tx(n.l, z: 11, c: col, f: on ? FontWeight.w700 : FontWeight.w500),
                    ],
                  ],
                ),
              ),
            ),
          );
        }

        return Scaffold(
          body: SafeArea(bottom: false, child: IndexedStack(index: t, children: [for (final n in s.nav) page(n.k)])),
          bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
            if (app.loadingYt) const LinearProgressIndicator(minHeight: 2, color: spGreen, backgroundColor: Colors.white12),
            if (app.cur != null) const Mini(),
            Container(
              decoration: isSpotify
                  ? BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black.withValues(alpha: .92), Colors.black],
                      ),
                    )
                  : BoxDecoration(
                      color: isTidal ? Colors.black : (s.home == 3 ? card : bg),
                      border: Border(top: BorderSide(color: isTidal ? Colors.transparent : Colors.white10)),
                    ),
              child: SafeArea(top: false, child: Row(children: [for (var i = 0; i < s.nav.length; i++) item(i)])),
            ),
          ]),
        );
      });
}

// ───────────── mini player ─────────────
void openNP(BuildContext c) => Navigator.push(c, PageRouteBuilder(
      pageBuilder: (_, __, ___) => const NowPlaying(),
      transitionsBuilder: (_, a, __, w) => SlideTransition(position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: w),
    ));

class Mini extends StatelessWidget {
  const Mini({super.key});
  @override
  Widget build(BuildContext c) {
    final t = app.cur!, m = app.sk.mini, lk = app.liked.contains(t.path);

    if (m == 4) {
      final body = GestureDetector(
        onTap: () => openNP(c),
        onHorizontalDragEnd: app.swipe == 'skip' ? (d) { final v = d.primaryVelocity ?? 0; if (v < -250) { app.next(); } else if (v > 250) { app.prev(); } } : null,
        child: Container(
          color: const Color(0xFF050505),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Art(t, 56, r: 0),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        tx(t.title, f: FontWeight.w700, z: 14.5, c: Colors.white),
                        const SizedBox(height: 2),
                        tx(t.artist, c: const Color(0xFF9E9E9E), z: 13),
                      ],
                    ),
                  ),
                  StreamBuilder<bool>(
                    stream: app.p.playingStream,
                    initialData: false,
                    builder: (_, s) => IconButton(
                      icon: Icon(s.data! ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 30),
                      onPressed: app.toggle,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 30),
                    onPressed: () => app.next(),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
              StreamBuilder<Duration>(
                stream: app.p.positionStream,
                builder: (_, s) {
                  final d = app.p.duration?.inMilliseconds ?? 1;
                  return LinearProgressIndicator(
                    value: ((s.data?.inMilliseconds ?? 0) / max(d, 1)).clamp(0.0, 1.0),
                    minHeight: 2,
                    backgroundColor: Colors.white24,
                    color: Colors.white,
                  );
                },
              ),
            ],
          ),
        ),
      );
      return app.swipe == 'close' ? Dismissible(key: ValueKey('m${t.path}'), direction: DismissDirection.horizontal, onDismissed: (_) => app.close(), child: body) : body;
    }

    if (m == 0) {
      final dom = HSLColor.fromColor(app.colorOf(t)).withLightness(.22).withSaturation(.35).toColor();
      final body = GestureDetector(
        onTap: () => openNP(c),
        onHorizontalDragEnd: app.swipe == 'skip' ? (d) { final v = d.primaryVelocity ?? 0; if (v < -250) { app.next(); } else if (v > 250) { app.prev(); } } : null,
        child: Container(
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          decoration: BoxDecoration(
            color: dom,
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 6, 6),
                child: Row(
                  children: [
                    Art(t, 42, r: 5),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          RichText(
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            text: TextSpan(
                              style: const TextStyle(fontSize: 13.5, color: Colors.white),
                              children: [
                                TextSpan(text: t.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                                TextSpan(text: ' • ${t.artist}', style: const TextStyle(color: Color(0xFFD0D0D0), fontWeight: FontWeight.w500)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              const Icon(Icons.volume_up_rounded, color: spGreen, size: 13),
                              const SizedBox(width: 4),
                              Flexible(
                                child: tx(
                                  '${app.outName.isEmpty ? 'ALEXWIN11PRO' : app.outName} • Lossless',
                                  z: 11.5,
                                  c: spGreen,
                                  f: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.laptop_windows_rounded, color: spGreen, size: 22),
                      onPressed: app.refreshOut,
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        lk ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded,
                        color: lk ? spGreen : Colors.white,
                        size: 25,
                      ),
                      onPressed: () => app.like(t),
                    ),
                    StreamBuilder<bool>(
                      stream: app.p.playingStream,
                      initialData: false,
                      builder: (_, s) => IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(s.data! ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 28),
                        onPressed: app.toggle,
                      ),
                    ),
                  ],
                ),
              ),
              if (app.miniProg)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: StreamBuilder<Duration>(
                    stream: app.p.positionStream,
                    builder: (_, s) {
                      final d = app.p.duration?.inMilliseconds ?? 1;
                      return LinearProgressIndicator(
                        value: ((s.data?.inMilliseconds ?? 0) / max(d, 1)).clamp(0.0, 1.0),
                        minHeight: 2,
                        backgroundColor: Colors.white24,
                        color: Colors.white,
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      );
      return app.swipe == 'close' ? Dismissible(key: ValueKey('m${t.path}'), direction: DismissDirection.horizontal, onDismissed: (_) => app.close(), child: body) : body;
    }

    final fl = m == 1 || m == 6, top = m == 3;
    final bgc = m == 1 ? const Color(0xFF2C2C2E) : card;
    final showLike = m == 3 || m == 6, showNext = m == 1 || m == 2 || m == 5;
    final prog = !app.miniProg || m == 1 ? const SizedBox() : Padding(
      padding: fl ? const EdgeInsets.fromLTRB(10, 0, 10, 4) : EdgeInsets.zero,
      child: StreamBuilder<Duration>(stream: app.p.positionStream, builder: (_, s) {
        final d = app.p.duration?.inMilliseconds ?? 1;
        return LinearProgressIndicator(value: ((s.data?.inMilliseconds ?? 0) / max(d, 1)).clamp(0.0, 1.0), minHeight: 2, backgroundColor: Colors.white24, color: gr);
      }),
    );
    final body = GestureDetector(
      onTap: () => openNP(c),
      onHorizontalDragEnd: app.swipe == 'skip' ? (d) { final v = d.primaryVelocity ?? 0; if (v < -250) { app.next(); } else if (v > 250) { app.prev(); } } : null,
      child: Container(
        margin: fl ? const EdgeInsets.fromLTRB(8, 0, 8, 6) : EdgeInsets.zero,
        decoration: BoxDecoration(color: bgc, borderRadius: BorderRadius.circular(fl ? (m == 6 ? 14.0 : 12.0) : 0.0), border: m == 6 ? Border.all(color: gr.withValues(alpha: .5)) : null),
        child: Column(children: [
          if (top) prog,
          Padding(padding: EdgeInsets.fromLTRB(8, 8, 4, fl && m != 1 ? 6 : 8), child: Row(children: [
            Art(t, m <= 1 ? 40 : 46), const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx(t.title, f: FontWeight.w700, z: 13), tx(t.artist, c: Colors.white70, z: 12)])),
            if (showLike) IconButton(icon: Icon(lk ? Icons.favorite : Icons.favorite_border, color: lk ? gr : Colors.white), onPressed: () => app.like(t)),
            StreamBuilder<bool>(stream: app.p.playingStream, initialData: false, builder: (_, s) => IconButton(icon: Icon(s.data! ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 30), onPressed: app.toggle)),
            if (showNext) IconButton(icon: const Icon(Icons.skip_next, color: Colors.white, size: 28), onPressed: () => app.next()),
          ])),
          if (!top) prog,
        ]),
      ),
    );
    return app.swipe == 'close' ? Dismissible(key: ValueKey('m${t.path}'), direction: DismissDirection.horizontal, onDismissed: (_) => app.close(), child: body) : body;
  }
}

// ───────────── now playing ─────────────
Color lift(Color c) => HSLColor.fromColor(c).withLightness(.34).withSaturation(.55).toColor();
int lyricIdx(List<(Duration, String)> l, Duration p) { var r = -1; for (var i = 0; i < l.length; i++) { if (l[i].$1 <= p) { r = i; } else { break; } } return r; }

class Wave extends CustomPainter {
  final double p, ph; final Color c;
  Wave(this.p, this.ph, this.c);
  @override
  void paint(Canvas cv, Size s) {
    final y = s.height / 2, x = s.width * p.clamp(0.0, 1.0);
    final a = Paint()..color = c..style = PaintingStyle.stroke..strokeWidth = 4..strokeCap = StrokeCap.round;
    final path = Path()..moveTo(0, y);
    for (double i = 0; i <= x; i += 2) { path.lineTo(i, y + sin(i / 9 + ph) * 3); }
    cv.drawPath(path, a);
    cv.drawLine(Offset(x, y), Offset(s.width, y), Paint()..color = Colors.white24..strokeWidth = 4..strokeCap = StrokeCap.round);
  }
  @override bool shouldRepaint(Wave o) => true;
}

class Bars extends CustomPainter {
  final double p; final int seed; final Color c; final bool dots;
  Bars(this.p, this.seed, this.c, this.dots);
  @override
  void paint(Canvas cv, Size s) {
    final n = max(1, (s.width / 5).floor()), r = Random(seed), pa = Paint()..strokeWidth = 3..strokeCap = StrokeCap.round;
    for (var i = 0; i < n; i++) {
      final h = dots ? 3.0 : 6 + r.nextDouble() * (s.height - 8), x = i * 5.0 + 2;
      pa.color = i / n < p ? c : Colors.white24;
      cv.drawLine(Offset(x, s.height / 2 - h / 2), Offset(x, s.height / 2 + h / 2), pa);
    }
  }
  @override bool shouldRepaint(Bars o) => o.p != p || o.c != c || o.seed != seed || o.dots != dots;
}

class Viz extends StatelessWidget {
  final Animation<double> a; final double h; final Color c;
  const Viz(this.a, this.h, this.c, {super.key});
  @override
  Widget build(BuildContext ctx) => AnimatedBuilder(animation: a, builder: (_, __) => SizedBox(height: h, child: Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < 30; i++) Container(width: 6, margin: const EdgeInsets.symmetric(horizontal: 2), height: 4 + (h - 4) * (sin(a.value * 2 * pi * (1 + i % 4) + i * .9).abs() * .6 + sin(a.value * 2 * pi * 3 + i).abs() * .4), decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
      ])));
}

class Seek extends StatefulWidget {
  final int sty;
  final bool acc;
  final bool showMaxBadge;
  final double? customThumbRadius;
  final double? customTrackHeight;
  const Seek(this.sty, this.acc, {this.showMaxBadge = false, this.customThumbRadius, this.customTrackHeight, super.key});
  @override State<Seek> createState() => _SeekState();
}

class _SeekState extends State<Seek> {
  double? drag;
  @override
  Widget build(BuildContext c) => StreamBuilder<Duration>(stream: app.p.positionStream, builder: (_, sn) {
        final dur = app.p.duration ?? Duration.zero, pos = sn.data ?? Duration.zero;
        final mx = max(dur.inMilliseconds.toDouble(), 1.0), v = (drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, mx).toDouble();
        final s = widget.sty, a = widget.acc ? gr : Colors.white, wavy = s == 1, slim = s == 2, thick = s == 3;
        final left = Duration(milliseconds: v.toInt());
        Widget bar;
        if (s >= 4) {
          bar = LayoutBuilder(builder: (_, bc) {
            double f(double dx) => (dx / max(bc.maxWidth, 1)).clamp(0.0, 1.0) * mx;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => app.p.seek(Duration(milliseconds: f(d.localPosition.dx).toInt())),
              onHorizontalDragUpdate: (d) => setState(() => drag = f(d.localPosition.dx)),
              onHorizontalDragEnd: (_) { if (drag != null) app.p.seek(Duration(milliseconds: drag!.toInt())); setState(() => drag = null); },
              child: CustomPaint(size: Size(bc.maxWidth, 30), painter: Bars(v / mx, app.cur?.path.hashCode ?? 1, a, s == 5)),
            );
          });
        } else {
          final th = widget.customTrackHeight ?? (thick ? 7.0 : slim ? 4.2 : 3.5);
          final tr = widget.customThumbRadius ?? (slim || thick ? 0.0 : 5.5);
          bar = Stack(alignment: Alignment.center, children: [
            if (wavy) Positioned.fill(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: CustomPaint(painter: Wave(v / mx, pos.inMilliseconds / 140, a)))),
            SliderTheme(
              data: SliderTheme.of(c).copyWith(
                trackHeight: th,
                activeTrackColor: wavy ? Colors.transparent : a,
                inactiveTrackColor: wavy ? Colors.transparent : Colors.white24,
                thumbColor: wavy ? a : Colors.white,
                thumbShape: tr <= 0 ? SliderComponentShape.noThumb : RoundSliderThumbShape(enabledThumbRadius: tr),
              ),
              child: Slider(value: v, max: mx, onChanged: (x) => setState(() => drag = x), onChangeEnd: (x) { app.p.seek(Duration(milliseconds: x.toInt())); setState(() => drag = null); }),
            ),
          ]);
        }
        return Column(children: [
          SizedBox(height: 26, child: bar),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                tx(fmt(left), z: 12, c: const Color(0xFF9E9E9E), f: FontWeight.w600),
                if (widget.showMaxBadge)
                  GestureDetector(
                    onTap: () => sheet(c, (_) => const TuneSheet(), big: true),
                    child: Container(
                      margin: const EdgeInsets.only(top: 2),
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 3.5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2B2210),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'MAX',
                        style: TextStyle(
                          color: tidalGold,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ),
                GestureDetector(
                  onTap: () => app.set(() => app.remain = !app.remain),
                  child: tx(
                    app.remain ? '-${fmt(dur > left ? dur - left : Duration.zero)}' : fmt(dur),
                    z: 12,
                    c: const Color(0xFF9E9E9E),
                    f: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ]);
      });
}

class TidalRadioIcon extends StatelessWidget {
  final Color color;
  const TidalRadioIcon({this.color = const Color(0xFF9E9E9E), super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text('d', style: TextStyle(color: color, fontSize: 17, fontWeight: FontWeight.w800, height: 1)),
          for (final a in [0.0, pi / 3, 2 * pi / 3, pi, 4 * pi / 3, 5 * pi / 3])
            Transform.translate(
              offset: Offset(10.5 * cos(a), 10.5 * sin(a)),
              child: Container(width: 2.5, height: 2.5, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            ),
        ],
      ),
    );
  }
}

class NowPlaying extends StatefulWidget { const NowPlaying({super.key}); @override State<NowPlaying> createState() => _NPState(); }
class _NPState extends State<NowPlaying> with SingleTickerProviderStateMixin {
  late final AnimationController spin = AnimationController(vsync: this, duration: const Duration(seconds: 14));
  StreamSubscription? _sub; double _dx = 0, _aw = 300;
  @override
  void initState() {
    super.initState(); app.refreshOut();
    if (app.p.playing) spin.repeat();
    _sub = app.p.playingStream.listen((pl) { if (!mounted) return; if (pl) { spin.repeat(); } else { spin.stop(); } });
  }
  @override
  void dispose() { _sub?.cancel(); spin.dispose(); super.dispose(); }
  Widget ib(IconData i, VoidCallback f, {Color c = Colors.white, double z = 28}) => IconButton(icon: Icon(i, color: c, size: z), onPressed: () { tap(); f(); });

  Widget _wrapArtGesture(Widget a, double s) => GestureDetector(
        onHorizontalDragEnd: app.swipeArt ? (d) { final v = d.primaryVelocity ?? 0; if (v < -250) { app.next(); } else if (v > 250) { app.prev(); } } : null,
        onDoubleTapDown: app.dbl ? (d) { _dx = d.localPosition.dx; _aw = s; } : null,
        onDoubleTap: app.dbl ? () { final p = app.p.position; final back = _dx < _aw / 2; app.p.seek(back ? (p.inSeconds > 10 ? p - const Duration(seconds: 10) : Duration.zero) : p + const Duration(seconds: 10)); toast(back ? '−10 s' : '+10 s'); } : null,
        child: a,
      );

  Widget _buildTidalNP(BuildContext c, Track t) {
    final col = app.colorOf(t);
    final lk = app.liked.contains(t.path);
    final w = MediaQuery.of(c).size.width;
    final artSize = w - 44;
    final topColor = HSLColor.fromColor(col).withLightness(.20).withSaturation(.65).toColor();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.58, 1.0],
                colors: [topColor, topColor.withValues(alpha: 0.25), const Color(0xFF050206)],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 10),
                  Expanded(
                    child: Center(
                      child: GestureDetector(
                        onLongPress: () => trackMenu(c, t),
                        child: _wrapArtGesture(
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  blurRadius: 28,
                                  offset: const Offset(0, 14),
                                ),
                              ],
                            ),
                            child: Art(t, artSize, r: 8),
                          ),
                          artSize,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            tx(t.title, z: 22, f: FontWeight.w800, c: Colors.white),
                            const SizedBox(height: 4),
                            tx(t.artist, z: 15, c: const Color(0xFFB3B3B8), f: FontWeight.w500),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          lk ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                          color: lk ? tidalGold : Colors.white,
                          size: 26,
                        ),
                        onPressed: () { tap(); app.like(t); },
                      ),
                      IconButton(
                        icon: const Icon(CupertinoIcons.share, color: Colors.white, size: 24),
                        onPressed: () {
                          tap();
                          trackMenu(c, t);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Seek(2, false, showMaxBadge: true, customThumbRadius: 0, customTrackHeight: 4.5),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: Icon(CupertinoIcons.shuffle, color: app.shuffle ? Colors.white : const Color(0xFF8E8E93), size: 24),
                        onPressed: () => app.set(() => app.shuffle = !app.shuffle),
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 44),
                        onPressed: () { tap(); app.prev(); },
                      ),
                      StreamBuilder<bool>(
                        stream: app.p.playingStream,
                        initialData: false,
                        builder: (_, p) => GestureDetector(
                          onTap: () { tap(); app.toggle(); },
                          child: Icon(
                            p.data! ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 64,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 44),
                        onPressed: () { tap(); app.next(); },
                      ),
                      IconButton(
                        icon: Icon(
                          app.repeat == 2 ? CupertinoIcons.repeat_1 : CupertinoIcons.repeat,
                          color: app.repeat > 0 ? Colors.white : const Color(0xFF8E8E93),
                          size: 24,
                        ),
                        onPressed: () => app.set(() => app.repeat = (app.repeat + 1) % 3),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        GestureDetector(
                          onTap: () => sheet(c, (_) => const QueueSheet(), big: true),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFC7C7CC),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${app.queue.length}',
                                  style: const TextStyle(color: Colors.black, fontSize: 11.5, fontWeight: FontWeight.w900),
                                ),
                              ),
                              const SizedBox(width: 3),
                              const Icon(Icons.dehaze_rounded, color: Color(0xFF9E9E9E), size: 18),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const LyricsPage())),
                          child: const Icon(Icons.lyrics_outlined, color: Color(0xFF9E9E9E), size: 25),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ListPage('${t.artist} Radio', () => app.tracks.where((x) => x.artist == t.artist).toList()))),
                          child: const TidalRadioIcon(color: Color(0xFF9E9E9E)),
                        ),
                        GestureDetector(
                          onTap: () => trackMenu(c, t),
                          child: const Icon(Icons.info_outline_rounded, color: Color(0xFF9E9E9E), size: 25),
                        ),
                      ],
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

  Widget _buildSpotifyNP(BuildContext c, Track t) {
    final col = app.colorOf(t);
    final lk = app.liked.contains(t.path);
    final w = MediaQuery.of(c).size.width;
    final artSize = w - 44;
    final topColor = HSLColor.fromColor(col).withLightness(.28).withSaturation(.75).toColor();
    final midColor = HSLColor.fromColor(col).withLightness(.12).withSaturation(.65).toColor();

    Widget modeBtn(IconData icon, bool active, VoidCallback onTap) {
      return GestureDetector(
        onTap: () { tap(); onTap(); },
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: active ? spGreen : Colors.white, size: 26),
              const SizedBox(height: 3),
              Container(
                width: 4.5,
                height: 4.5,
                decoration: BoxDecoration(
                  color: active ? spGreen : Colors.transparent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF09090D),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0.0, 0.58, 0.92],
            colors: [topColor, midColor, const Color(0xFF08080A)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            children: [
              const SizedBox(height: 6),
              Row(
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 34),
                    onPressed: () => Navigator.pop(c),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        tx('Playing from Playlist', z: 11.5, c: Colors.white.withValues(alpha: 0.85), f: FontWeight.w500, a: TextAlign.center),
                        const SizedBox(height: 1),
                        tx(app.playCtx, z: 13.5, f: FontWeight.w800, c: Colors.white, a: TextAlign.center),
                      ],
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 26),
                    onPressed: () => trackMenu(c, t),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Center(
                child: _wrapArtGesture(
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.45),
                          blurRadius: 26,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Art(t, artSize, r: 12),
                  ),
                  artSize,
                ),
              ),
              const SizedBox(height: 28),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        tx(t.title, z: 23, f: FontWeight.w800, c: Colors.white),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            explicitBadge(),
                            const SizedBox(width: 6),
                            Expanded(
                              child: tx(t.artist, z: 15.5, c: const Color(0xFFB3B3B3), f: FontWeight.w500),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () { tap(); app.like(t); },
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: lk ? spGreen : Colors.transparent,
                        shape: BoxShape.circle,
                        border: lk ? null : Border.all(color: Colors.white70, width: 2),
                      ),
                      child: Icon(
                        lk ? Icons.check_rounded : Icons.add_rounded,
                        color: lk ? Colors.black : Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Seek(0, false, customThumbRadius: 5, customTrackHeight: 3.2),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  modeBtn(CupertinoIcons.shuffle, app.shuffle, () => app.set(() => app.shuffle = !app.shuffle)),
                  IconButton(
                    icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 42),
                    onPressed: () { tap(); app.prev(); },
                  ),
                  StreamBuilder<bool>(
                    stream: app.p.playingStream,
                    initialData: false,
                    builder: (_, p) => GestureDetector(
                      onTap: () { tap(); app.toggle(); },
                      child: Container(
                        width: 66,
                        height: 66,
                        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                        child: Icon(
                          p.data! ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: Colors.black,
                          size: 38,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 42),
                    onPressed: () { tap(); app.next(); },
                  ),
                  modeBtn(
                    app.repeat == 2 ? CupertinoIcons.repeat_1 : CupertinoIcons.repeat,
                    app.repeat > 0,
                    () => app.set(() => app.repeat = (app.repeat + 1) % 3),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  GestureDetector(
                    onTap: app.refreshOut,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.laptop_windows_rounded, color: spGreen, size: 20),
                        const SizedBox(width: 8),
                        tx(
                          '${app.outName.isEmpty ? 'ALEXWIN11PRO' : app.outName} • Lossless',
                          z: 12,
                          c: spGreen,
                          f: FontWeight.w700,
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.share_outlined, color: Colors.white, size: 22),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: '${t.title} - ${t.artist}'));
                      toast('Copied song link');
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.queue_music_rounded, color: Colors.white, size: 24),
                    onPressed: () => sheet(c, (_) => const QueueSheet(), big: true),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => showTrackInfo(c, t),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          tx('About the song', z: 16, f: FontWeight.w800, c: Colors.white),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                            decoration: BoxDecoration(
                              color: spGreen,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: const Text(
                              'Beta',
                              style: TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w800),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      tx(
                        '${t.title} by ${t.artist} • ${t.album} (${badge(t)})',
                        z: 13.5,
                        c: Colors.white70,
                        lines: 2,
                      ),
                    ],
                  ),
                ),
              ),
              if (app.lyricsCard)
                GestureDetector(
                  onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const LyricsPage())),
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 24),
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(color: lift(col), borderRadius: BorderRadius.circular(14)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [tx('Lyrics', z: 16, f: FontWeight.w800), const Spacer(), const Icon(Icons.open_in_full, size: 18)]),
                        const SizedBox(height: 10),
                        tx('Tap to view full-screen synced lyrics (.lrc)', z: 14, c: Colors.white70),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext c) => ListenableBuilder(
        listenable: app,
        builder: (_, __) {
          final t = app.cur;
          if (t == null) { WidgetsBinding.instance.addPostFrameCallback((_) { if (c.mounted && Navigator.canPop(c)) Navigator.pop(c); }); return const SizedBox(); }
          final L = app.npl;

          if (L.name == 'TIDAL') {
            return GestureDetector(
              onVerticalDragEnd: (d) { if ((d.primaryVelocity ?? 0) > 500) Navigator.pop(c); },
              child: _buildTidalNP(c, t),
            );
          }
          if (L.name == 'Spotify') {
            return GestureDetector(
              onVerticalDragEnd: (d) { if ((d.primaryVelocity ?? 0) > 500) Navigator.pop(c); },
              child: _buildSpotifyNP(c, t),
            );
          }

          final col = app.colorOf(t), lk = app.liked.contains(t.path), mq = MediaQuery.of(c), w = mq.size.width, cen = L.center;
          final hasArt = t.art != null && File(t.art!).existsSync(), lines = app.lyricsOf(t), bm = app.pbg == 0 ? L.bg : app.pbg - 1;
          final fullArt = L.art == 3 && hasArt, al = cen ? CrossAxisAlignment.center : CrossAxisAlignment.start, ta = cen ? TextAlign.center : TextAlign.left;
          final sty = app.sliderStyle == 0 ? L.seek : app.sliderStyle - 1;
          Widget pd(Widget x) => Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: x);
          double rad(double s, double def) => app.artShape == 1 ? 0.0 : app.artShape == 2 ? 18.0 : app.artShape == 3 ? s / 2 : def;
          IconData likeI() => switch (L.name) { 'Apple Music' => lk ? Icons.star : Icons.star_border, 'YouTube Music' => lk ? Icons.thumb_up : Icons.thumb_up_outlined, _ => lk ? Icons.favorite : Icons.favorite_border };

          Widget bgL() => Stack(fit: StackFit.expand, children: [
                if (fullArt) Image.file(File(t.art!), fit: BoxFit.cover) else if (bm == 1 && hasArt) ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 45, sigmaY: 45), child: Image.file(File(t.art!), fit: BoxFit.cover)),
                DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, stops: const [0, .8], colors: fullArt ? [Colors.black26, Colors.black.withValues(alpha: .92)] : switch (bm) { 1 => [Colors.black26, Colors.black.withValues(alpha: .88)], 2 => [bg, bg], 3 => [gr.withValues(alpha: .55), bg], 4 => [Colors.black, Colors.black], _ => [col, bg] }))),
              ]);

          Widget pop(Widget a) => StreamBuilder<bool>(stream: app.p.playingStream, initialData: false, builder: (_, p) => AnimatedScale(scale: p.data! ? 1 : .9, duration: const Duration(milliseconds: 250), curve: Curves.easeOut, child: Container(decoration: BoxDecoration(boxShadow: [BoxShadow(color: app.glow ? gr.withValues(alpha: .4) : Colors.black.withValues(alpha: .45), blurRadius: 30, offset: const Offset(0, 12))]), child: a)));
          Widget vinyl(double s) {
            final disc = Container(width: s, height: s, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF0D0D0D), boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 24)]), child: Stack(alignment: Alignment.center, children: [
              for (final f in [.95, .84, .73]) Container(width: s * f, height: s * f, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white10))),
              Art(t, s * .5, r: s * .25), Container(width: s * .05, height: s * .05, decoration: BoxDecoration(color: bg, shape: BoxShape.circle)),
            ]));
            return app.spinArt ? RotationTransition(turns: spin, child: disc) : disc;
          }
          Widget artBlock() {
            switch (L.art) {
              case 1: return _wrapArtGesture(Art(t, w, r: rad(w, 0)), w);
              case 2: { final s = min(w - 70, 330.0); return _wrapArtGesture(vinyl(s), s); }
              case 3: return SizedBox(height: max(mq.size.height * .3, 140));
              case 4: return _wrapArtGesture(pop(Art(t, 150, r: rad(150, 24))), 150);
              case 5: return const SizedBox(height: 60);
              default: { final s = min(w - 40, 420.0); return pd(_wrapArtGesture(pop(Art(t, s, r: rad(s, app.sk.artR + 2))), s)); }
            }
          }

          final top = Row(children: [
            IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 32), onPressed: () => Navigator.pop(c)),
            Expanded(child: L.tabs
                ? Center(child: Container(padding: const EdgeInsets.all(3), decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(20)), child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(18)), child: tx('Song', f: FontWeight.w700, z: 13)),
                    GestureDetector(onTap: () => toast('Video is not available for local files'), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6), child: tx('Video', c: grey, f: FontWeight.w700, z: 13))),
                  ])))
                : Column(children: [tx('NOW PLAYING', z: 10, c: Colors.white70, f: FontWeight.w700, a: TextAlign.center), tx(t.album, z: 13, f: FontWeight.w700, a: TextAlign.center)])),
            IconButton(icon: const Icon(Icons.more_vert), onPressed: () => trackMenu(c, t)),
          ]);

          final info = Row(children: [
            if (cen) const SizedBox(width: 48),
            Expanded(child: Column(crossAxisAlignment: al, children: [
              if (app.badgeOn) Container(margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(border: Border.all(color: gr), borderRadius: BorderRadius.circular(4)), child: tx(badge(t), z: 10, f: FontWeight.w800, c: gr)),
              tx(t.title, z: L.art == 5 ? 32 : 24, f: FontWeight.w800, a: ta, lines: L.art == 5 ? 3 : 1),
              const SizedBox(height: 2), tx(t.artist, z: 16, c: Colors.white70, a: ta),
            ])),
            IconButton(icon: Icon(likeI(), color: lk ? gr : Colors.white, size: 28), onPressed: () { tap(); app.like(t); }),
          ]);

          final play = StreamBuilder<bool>(stream: app.p.playingStream, initialData: false, builder: (_, p) => GestureDetector(
                onTap: () { tap(); app.toggle(); },
                child: L.plain ? Icon(p.data! ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 68) : Container(width: 70, height: 70, decoration: BoxDecoration(color: L.ring ? gr : Colors.white, shape: BoxShape.circle), child: Icon(p.data! ? Icons.pause : Icons.play_arrow, color: Colors.black, size: 42)),
              ));
          final five = !L.vol;
          final ctrl = Row(mainAxisAlignment: five ? MainAxisAlignment.spaceBetween : MainAxisAlignment.spaceEvenly, children: [
            if (five) ib(Icons.shuffle, () => app.set(() => app.shuffle = !app.shuffle), c: app.shuffle ? gr : Colors.white),
            ib(Icons.skip_previous, app.prev, z: L.plain ? 46 : 40), play, ib(Icons.skip_next, app.next, z: L.plain ? 46 : 40),
            if (five) ib(app.repeat == 2 ? Icons.repeat_one : Icons.repeat, () => app.set(() => app.repeat = (app.repeat + 1) % 3), c: app.repeat > 0 ? gr : Colors.white),
          ]);
          final dev = GestureDetector(onTap: app.refreshOut, child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
            Icon(switch (app.outKind) { 'bluetooth' => Icons.bluetooth_audio, 'wired' => Icons.headphones, 'usb' => Icons.usb, 'hdmi' => Icons.tv, _ => Icons.smartphone }, color: gr, size: 16), const SizedBox(width: 6), tx(app.outName.isEmpty ? 'This device' : app.outName, z: 12, c: gr, f: FontWeight.w700),
          ]));
          final sleepOn = app.sleepAt != null || app.sleepEnd;
          final extras = Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            ib(Icons.tune, () => sheet(c, (_) => const TuneSheet(), big: true), z: 22, c: app.isTuned ? gr : Colors.white),
            ib(Icons.equalizer, () => sheet(c, (_) => const EqSheet(), big: true), z: 22, c: app.eqOn ? gr : Colors.white),
            ib(Icons.loop, app.abLoop, z: 22, c: app.la != null ? gr : Colors.white),
            ib(Icons.bedtime_outlined, () => sheet(c, (s) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final m in [15, 30, 45, 60]) opt(Icons.timer_outlined, '$m minutes', () { app.setSleep(m); Navigator.pop(s); }),
                  opt(Icons.music_note, 'End of this track', () { app.setSleep(null); app.set(() => app.sleepEnd = true); Navigator.pop(s); }),
                  if (sleepOn) opt(Icons.timer_off, 'Turn off timer', () { app.setSleep(null); app.set(() => app.sleepEnd = false); Navigator.pop(s); }),
                ]))), c: sleepOn ? gr : Colors.white, z: 22),
            ib(Icons.format_quote, () => Navigator.push(c, MaterialPageRoute(builder: (_) => const LyricsPage())), z: 22),
            ib(Icons.queue_music, () => sheet(c, (_) => const QueueSheet(), big: true), z: 22),
          ]);

          final kids = <Widget>[
            pd(top), const SizedBox(height: 12), artBlock(),
            if (L.viz || app.viz) Padding(padding: const EdgeInsets.only(top: 18), child: Viz(spin, L.viz ? 110 : 34, gr)),
            const SizedBox(height: 22), pd(info), const SizedBox(height: 4), pd(Seek(sty, L.acc)), pd(ctrl),
            if (L.vol || app.showVol) pd(Row(children: [const Icon(Icons.volume_down, color: grey, size: 20), Expanded(child: Slider(value: app.vol, onChanged: app.setVol)), const Icon(Icons.volume_up, color: grey, size: 20)])),
            const SizedBox(height: 4), Center(child: dev), pd(extras),
            if (L.tabs) Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              TextButton(onPressed: () => sheet(c, (_) => const QueueSheet(), big: true), child: tx('UP NEXT', z: 13, f: FontWeight.w800)),
              TextButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const LyricsPage())), child: tx('LYRICS', z: 13, f: FontWeight.w800)),
              TextButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ListPage(t.artist, () => app.tracks.where((x) => x.artist == t.artist).toList()))), child: tx('RELATED', z: 13, f: FontWeight.w800)),
            ]),
            if (app.lyricsCard) pd(GestureDetector(
              onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const LyricsPage())),
              child: Container(
                margin: const EdgeInsets.only(top: 18), padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: lift(col), borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [tx('Lyrics', z: 16, f: FontWeight.w800), const Spacer(), const Icon(Icons.open_in_full, size: 18)]),
                  const SizedBox(height: 12),
                  StreamBuilder<Duration>(stream: app.p.positionStream, builder: (_, sn) {
                    if (lines.isEmpty) return tx('No synced lyrics found. Put a .lrc file with the same name next to the song.', z: 14, lines: 3, c: Colors.white70);
                    final i = lyricIdx(lines, sn.data ?? Duration.zero), from = max(i, 0);
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (var k = from; k < from + 4 && k < lines.length; k++) Padding(padding: const EdgeInsets.only(bottom: 6), child: tx(lines[k].$2, z: 20, f: FontWeight.w800, lines: 2, c: k == i ? Colors.white : Colors.white54))]);
                  }),
                ]),
              ),
            )),
            const SizedBox(height: 28),
          ];
          return GestureDetector(
            onVerticalDragEnd: (d) { if ((d.primaryVelocity ?? 0) > 500) Navigator.pop(c); },
            child: Scaffold(body: Stack(fit: StackFit.expand, children: [bgL(), SafeArea(child: ListView(padding: EdgeInsets.zero, children: kids))])),
          );
        },
      );
}

// ───────────── HIGH-PRECISION STUDIO SPEED & PITCH ADJUSTER ─────────────
class TuneSheet extends StatelessWidget {
  const TuneSheet({super.key});

  @override
  Widget build(BuildContext c) => ListenableBuilder(
        listenable: app,
        builder: (_, __) {
          final st = app.semitones.clamp(-12.0, 12.0);
          final wholeSt = st.round();
          final cents = ((st - wholeSt) * 100).round();
          final stLabel = '${wholeSt > 0 ? '+' : ''}$wholeSt st${cents == 0 ? '' : ' (${cents > 0 ? '+' : ''}$cents ct)'}';

          Widget stepBtn(String label, VoidCallback onTap) => InkWell(
                onTap: () { tap(); onTap(); },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF383838),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
                ),
              );

          const presets = <(String, double, double, bool)>[
            ('Normal', 1.0, 1.0, false),
            ('Slowed + Reverb', 0.85, 0.85, true),
            ('Nightcore', 1.22, 1.22, true),
            ('Chopped & Screwed', 0.75, 0.75, true),
            ('Daycore (-3 st)', 0.88, 0.840896, false),
            ('Double Time', 1.50, 1.0, false),
          ];

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tune_rounded, color: Colors.white, size: 22),
                      const SizedBox(width: 10),
                      tx('Speed & Pitch', z: 19, f: FontWeight.w800),
                      const Spacer(),
                      if (app.isTuned)
                        TextButton.icon(
                          onPressed: () {
                            tap();
                            app.applyTunePreset(1.0, 1.0, linked: false);
                          },
                          icon: Icon(Icons.refresh_rounded, color: gr, size: 18),
                          label: Text('Reset', style: TextStyle(color: gr, fontWeight: FontWeight.w800)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  tx('PRESETS', z: 11, c: grey, f: FontWeight.w800, ls: 1.0),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final pr in presets)
                        Builder(builder: (_) {
                          final active = (app.speed - pr.$2).abs() < 0.01 && (app.pitch - pr.$3).abs() < 0.01;
                          return ChoiceChip(
                            label: Text(pr.$1),
                            selected: active,
                            selectedColor: gr,
                            backgroundColor: const Color(0xFF1E1E1E),
                            side: BorderSide.none,
                            showCheckmark: false,
                            labelStyle: TextStyle(
                              color: active ? Colors.black : Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                            onSelected: (_) {
                              tap();
                              app.applyTunePreset(pr.$2, pr.$3, linked: pr.$4);
                            },
                          );
                        }),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.album_rounded, color: app.linkPitch ? gr : grey, size: 22),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              tx('Tape Mode (Link Pitch & Speed)', z: 14, f: FontWeight.w700),
                              tx('Zero-artifact analog vinyl resampling', z: 11.5, c: grey),
                            ],
                          ),
                        ),
                        Switch(
                          value: app.linkPitch,
                          activeColor: gr,
                          onChanged: (v) {
                            tap();
                            app.set(() {
                              app.linkPitch = v;
                              if (v) {
                                app.pitch = app.speed;
                                app.p.setPitch(app.pitch);
                              }
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            tx('Pitch Shift', z: 15.5, f: FontWeight.w800),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: (app.pitch - 1.0).abs() > 0.005 ? gr.withValues(alpha: 0.2) : Colors.white10,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '$stLabel  •  ${app.pitch.toStringAsFixed(2)}×',
                                style: TextStyle(
                                  color: (app.pitch - 1.0).abs() > 0.005 ? gr : Colors.white70,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SliderTheme(
                          data: SliderTheme.of(c).copyWith(
                            activeTrackColor: gr,
                            thumbColor: Colors.white,
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                          ),
                          child: Slider(
                            value: st,
                            min: -12.0,
                            max: 12.0,
                            divisions: 240,
                            onChanged: app.setSemitones,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            stepBtn('-1 st', () => app.setSemitones((st - 1.0).roundToDouble())),
                            stepBtn('-0.1 st', () => app.setSemitones(st - 0.1)),
                            stepBtn('0 st', () => app.setSemitones(0.0)),
                            stepBtn('+0.1 st', () => app.setSemitones(st + 0.1)),
                            stepBtn('+1 st', () => app.setSemitones((st + 1.0).roundToDouble())),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            tx('Playback Speed', z: 15.5, f: FontWeight.w800),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: (app.speed - 1.0).abs() > 0.005 ? gr.withValues(alpha: 0.2) : Colors.white10,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '${app.speed.toStringAsFixed(2)}×  (${(app.speed * 100).round()}%)',
                                style: TextStyle(
                                  color: (app.speed - 1.0).abs() > 0.005 ? gr : Colors.white70,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SliderTheme(
                          data: SliderTheme.of(c).copyWith(
                            activeTrackColor: gr,
                            thumbColor: Colors.white,
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                          ),
                          child: Slider(
                            value: app.speed.clamp(0.5, 2.0),
                            min: 0.5,
                            max: 2.0,
                            divisions: 150,
                            onChanged: app.setSpeed,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            stepBtn('-5%', () => app.setSpeed(app.speed - 0.05)),
                            stepBtn('-1%', () => app.setSpeed(app.speed - 0.01)),
                            stepBtn('1.00×', () => app.setSpeed(1.0)),
                            stepBtn('+1%', () => app.setSpeed(app.speed + 0.01)),
                            stepBtn('+5%', () => app.setSpeed(app.speed + 0.05)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final s in speeds)
                              ChoiceChip(
                                label: Text('${s}×'),
                                selected: (app.speed - s).abs() < 0.01,
                                selectedColor: gr,
                                backgroundColor: const Color(0xFF2C2C2C),
                                side: BorderSide.none,
                                showCheckmark: false,
                                visualDensity: VisualDensity.compact,
                                labelStyle: TextStyle(
                                  color: (app.speed - s).abs() < 0.01 ? Colors.black : Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                                onSelected: (_) {
                                  tap();
                                  app.setSpeed(s);
                                },
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
}

class EqSheet extends StatelessWidget {
  const EqSheet({super.key});
  @override
  Widget build(BuildContext c) => SafeArea(child: FutureBuilder<AndroidEqualizerParameters>(
        future: app.h.eq.parameters,
        builder: (_, sn) {
          if (!sn.hasData) return const SizedBox(height: 180, child: Center(child: CircularProgressIndicator()));
          final ps = sn.data!, n = ps.bands.length;
          return StatefulBuilder(builder: (_, ss) => SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [tx('Equalizer', z: 18, f: FontWeight.w800), const Spacer(), Switch(value: app.eqOn, onChanged: (v) { app.set(() => app.eqOn = v); app.h.eq.setEnabled(v); ss(() {}); })]),
            Wrap(spacing: 8, children: [for (final e in eqPresets.entries) ActionChip(label: Text(e.key), onPressed: () { for (var i = 0; i < n; i++) { ps.bands[i].setGain(e.value(n > 1 ? i / (n - 1) : .5).clamp(ps.minDecibels, ps.maxDecibels).toDouble()); } ss(() {}); })]),
            const SizedBox(height: 8),
            for (final b in ps.bands) Row(children: [
              SizedBox(width: 64, child: tx(b.centerFrequency >= 1000 ? '${(b.centerFrequency / 1000).toStringAsFixed(1)} kHz' : '${b.centerFrequency.round()} Hz', z: 12, c: grey)),
              Expanded(child: StreamBuilder<double>(stream: b.gainStream, initialData: b.gain, builder: (_, g) => Slider(min: ps.minDecibels, max: ps.maxDecibels, value: g.data!.clamp(ps.minDecibels, ps.maxDecibels).toDouble(), onChanged: b.setGain))),
            ]),
          ])));
        },
      ));
}

class LyricsPage extends StatefulWidget { const LyricsPage({super.key}); @override State<LyricsPage> createState() => _LyState(); }
class _LyState extends State<LyricsPage> {
  final sc = ScrollController(); int last = -2;
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final t = app.cur; if (t == null) return const Scaffold();
        final lines = app.lyricsOf(t);
        return Scaffold(body: Container(
          decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [lift(app.colorOf(t)), bg])),
          child: SafeArea(child: Column(children: [
            Row(children: [IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 32), onPressed: () => Navigator.pop(c)), Expanded(child: Column(children: [tx(t.title, f: FontWeight.w800, a: TextAlign.center), tx(t.artist, z: 12, c: Colors.white70, a: TextAlign.center)])), const SizedBox(width: 48)]),
            Expanded(child: lines.isEmpty
                ? Center(child: Padding(padding: const EdgeInsets.all(32), child: tx('No synced lyrics.\nAdd a .lrc file with the same name next to the song.', z: 16, lines: 4, a: TextAlign.center, c: Colors.white70)))
                : StreamBuilder<Duration>(stream: app.p.positionStream, builder: (_, sn) {
                    final i = lyricIdx(lines, sn.data ?? Duration.zero);
                    if (i != last) { last = i; WidgetsBinding.instance.addPostFrameCallback((_) { if (sc.hasClients) sc.animateTo(max(0.0, i * 64.0 - 120), duration: const Duration(milliseconds: 300), curve: Curves.easeOut); }); }
                    return ListView.builder(controller: sc, itemExtent: 64, padding: const EdgeInsets.symmetric(horizontal: 24), itemCount: lines.length, itemBuilder: (_, k) => GestureDetector(onTap: () => app.p.seek(lines[k].$1), child: Align(alignment: Alignment.centerLeft, child: tx(lines[k].$2, z: 26, f: FontWeight.w800, lines: 2, c: k == i ? Colors.white : Colors.white38))));
                  })),
          ])),
        ));
      });
}

class QueueSheet extends StatelessWidget {
  const QueueSheet({super.key});
  @override
  Widget build(BuildContext c) => ListenableBuilder(
        listenable: app,
        builder: (_, __) => SizedBox(height: MediaQuery.of(c).size.height * .7, child: Column(children: [
          Padding(padding: const EdgeInsets.all(16), child: Row(children: [tx('Queue', z: 20, f: FontWeight.w800), const Spacer(), tx('${app.queue.length} songs', c: grey, z: 13)])),
          Expanded(child: ReorderableListView.builder(
            itemCount: app.queue.length, onReorder: app.reorderQueue,
            itemBuilder: (_, i) { final t = app.queue[i]; return ListTile(key: ValueKey('${t.path}$i'), leading: Art(t, 44), title: tx(t.title, c: i == app.idx ? gr : Colors.white, f: FontWeight.w600), subtitle: tx(t.artist, c: grey, z: 12), onTap: () => app.playAt(app.queue, i)); },
          )),
        ])),
      );
}

// ───────────── home ─────────────
class Card2 { final String title, sub; final Track? art; final VoidCallback f; final bool round; Card2(this.title, this.sub, this.art, this.f, {this.round = false}); }

Widget shelf(String title, List<Card2> items) {
  if (items.isEmpty) return const SizedBox();
  final z = app.sk.sz, ap = app.sk.home == 1;
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Padding(padding: const EdgeInsets.fromLTRB(16, 22, 16, 10), child: Row(children: [Expanded(child: tx(title, z: ap ? 21 : 22, f: FontWeight.w800)), if (ap) tx('See All', z: 14, c: gr)])),
    SizedBox(height: z + 52, child: ListView.separated(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), itemCount: items.length, separatorBuilder: (_, __) => const SizedBox(width: 14), itemBuilder: (_, i) {
      final x = items[i];
      return GestureDetector(onTap: () { tap(); x.f(); }, child: SizedBox(width: z, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Art(x.art, z, r: x.round ? z / 2 : null), const SizedBox(height: 8), tx(x.title, f: FontWeight.w700, z: 13), tx(x.sub, c: grey, z: 12)])));
    })),
  ]);
}

List<Card2> recCards(List<Track> rec) => [for (var i = 0; i < rec.length && i < 12; i++) Card2(rec[i].title, rec[i].artist, rec[i], () => app.playAt(rec, i))];
List<Card2> mixCards(List<Track> all) => [for (var n = 1; n <= 3; n++) () { final l = mix(all, n); return Card2('Daily Mix $n', l.take(3).map((e) => e.artist).toSet().join(', '), l.first, () => app.playAt(l, 0, ctx: 'Daily Mix $n')); }()];
Widget emptyHome() => Padding(padding: const EdgeInsets.all(40), child: Column(children: [
      Icon(app.scanning ? Icons.hourglass_top : Icons.library_music, size: 64, color: grey), const SizedBox(height: 12),
      tx(app.scanning ? 'Scanning your music…' : 'Search YouTube Music or scan your device', z: 18, f: FontWeight.w800, a: TextAlign.center, lines: 2), const SizedBox(height: 14),
      if (!app.scanning) Wrap(spacing: 10, children: [
        FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: gr, foregroundColor: Colors.black), onPressed: () => app.goTab(app.sk.nav.indexWhere((n) => n.k == 'search').clamp(0, app.sk.nav.length - 1)), icon: const Icon(Icons.search), label: const Text('Search YouTube Music')),
        OutlinedButton(onPressed: app.scan, child: const Text('Scan local files')),
      ]),
    ]));

class SpotifyDotCluster extends StatelessWidget {
  const SpotifyDotCluster({super.key});
  @override
  Widget build(BuildContext context) {
    const d = [
      [0.0, 1.0, 0.0],
      [1.0, 1.0, 1.0],
      [1.0, 1.0, 1.0],
      [0.0, 1.0, 0.0],
    ];
    return SizedBox(
      width: 22,
      height: 22,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final row in d)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final v in row)
                  Container(
                    width: 3.5,
                    height: 3.5,
                    decoration: BoxDecoration(
                      color: v > 0 ? Colors.white : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class HomePage extends StatefulWidget { const HomePage({super.key}); @override State<HomePage> createState() => _HomeState(); }
class _HomeState extends State<HomePage> {
  int chip = 0;

  Widget _buildTidalHome(BuildContext c, List<Track> all, List<Track> rec, void Function(String, List<Track> Function(), {String? list}) open) {
    final pool = rec.isNotEmpty ? rec : all;
    final listNames = app.lists.keys.toList();

    final topGridItems = <({String title, String sub, List<Track> tracks, bool isMyTracks, VoidCallback onTap})>[];

    final m1 = mix(all, 1);
    topGridItems.add((
      title: listNames.isNotEmpty ? listNames.first : 'Hip-Hop Mix',
      sub: 'TIDAL',
      tracks: listNames.isNotEmpty ? app.toTracks(app.lists[listNames.first]!) : m1,
      isMyTracks: false,
      onTap: () => listNames.isNotEmpty
          ? open(listNames.first, () => app.toTracks(app.lists[listNames.first] ?? []), list: listNames.first)
          : app.playAt(m1, 0, ctx: 'Hip-Hop Mix'),
    ));

    topGridItems.add((
      title: 'My Tracks',
      sub: '',
      tracks: app.likedTracks.isNotEmpty ? app.likedTracks : all,
      isMyTracks: true,
      onTap: () => open('My Tracks', () => app.likedTracks.isNotEmpty ? app.likedTracks : all),
    ));

    final pl2 = listNames.length > 1 ? listNames[1] : null;
    final pl2Tracks = pl2 != null ? app.toTracks(app.lists[pl2]!) : mix(all, 2);
    topGridItems.add((
      title: pl2 ?? 'My Mix',
      sub: 'Me',
      tracks: pl2Tracks,
      isMyTracks: false,
      onTap: () => pl2 != null ? open(pl2, () => app.toTracks(app.lists[pl2] ?? []), list: pl2) : app.playAt(pl2Tracks, 0, ctx: 'My Mix'),
    ));

    for (var i = 0; i < pool.length && topGridItems.length < 6; i++) {
      final tr = pool[i];
      topGridItems.add((
        title: tr.title,
        sub: tr.artist,
        tracks: [tr],
        isMyTracks: false,
        onTap: () => app.playAt(pool, i, ctx: 'Recently played'),
      ));
    }

    final carouselItems = <({String title, String sub, String meta, List<Track> tracks, bool explicit, VoidCallback onTap, VoidCallback onPlay})>[];
    for (final n in listNames) {
      final l = app.toTracks(app.lists[n]!);
      if (l.isNotEmpty) {
        carouselItems.add((
          title: n,
          sub: 'by Me',
          meta: '${l.length} TRACKS',
          tracks: l,
          explicit: false,
          onTap: () => open(n, () => app.toTracks(app.lists[n] ?? []), list: n),
          onPlay: () => app.playAt(l, 0, ctx: n),
        ));
      }
    }
    for (var i = 0; i < pool.length && carouselItems.length < 10; i++) {
      final tr = pool[i];
      carouselItems.add((
        title: tr.title,
        sub: tr.artist,
        meta: '${tr.added.year}',
        tracks: [tr],
        explicit: true,
        onTap: () => app.playAt(pool, i, ctx: 'Recently played'),
        onPlay: () => app.playAt(pool, i, ctx: 'Recently played'),
      ));
    }

    return Container(
      color: Colors.black,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
            child: Row(
              children: [
                tx('Home', z: 30, f: FontWeight.w800, c: Colors.white),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const StatsPage())),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        const Icon(Icons.notifications_none_rounded, color: Colors.white, size: 26),
                        Positioned(
                          top: 1,
                          right: 2,
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(color: Color(0xFFFF3B6B), shape: BoxShape.circle),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined, color: Colors.white, size: 25),
                  onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const SettingsPage())),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: topGridItems.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.0,
              ),
              itemBuilder: (_, i) {
                final item = topGridItems[i];
                return GestureDetector(
                  onTap: () { tap(); item.onTap(); },
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1E),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.14), width: 1),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: item.isMyTracks
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Icon(CupertinoIcons.music_note_2, color: Colors.white, size: 32),
                                tx('My Tracks', z: 13.5, f: FontWeight.w700, c: Colors.white),
                              ],
                            ),
                          )
                        : Stack(
                            fit: StackFit.expand,
                            children: [
                              CollageArt(item.tracks, 130, radius: 0),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    stops: const [0.1, 0.95],
                                    colors: [Colors.black.withValues(alpha: 0.15), Colors.black.withValues(alpha: 0.82)],
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 9,
                                right: 9,
                                bottom: 9,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    tx(item.title, z: 13, f: FontWeight.w800, c: Colors.white),
                                    const SizedBox(height: 1),
                                    tx(item.sub, z: 11.5, c: const Color(0xFFD0D0D5), f: FontWeight.w500),
                                  ],
                                ),
                              ),
                            ],
                          ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 28, 16, 14),
            child: tx('Recently played', z: 22, f: FontWeight.w800, c: Colors.white),
          ),
          SizedBox(
            height: 242,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: carouselItems.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (_, i) {
                final it = carouselItems[i];
                return GestureDetector(
                  onTap: () { tap(); it.onTap(); },
                  child: SizedBox(
                    width: 158,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Stack(
                          children: [
                            CollageArt(it.tracks, 158, radius: 8),
                            Positioned(
                              right: 10,
                              bottom: 10,
                              child: GestureDetector(
                                onTap: () { tap(); it.onPlay(); },
                                child: Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.55),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white24, width: 1),
                                  ),
                                  child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Flexible(child: tx(it.title, z: 15, f: FontWeight.w800, c: Colors.white)),
                            if (it.explicit) ...[
                              const SizedBox(width: 6),
                              explicitBadge(),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        tx(it.sub, z: 13.5, c: const Color(0xFFA0A0A8), f: FontWeight.w500),
                        const SizedBox(height: 3),
                        tx(it.meta, z: 11, c: const Color(0xFF707078), f: FontWeight.w700, ls: 0.6),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
            child: GestureDetector(
              onTap: () => app.shufflePlay(all, ctx: 'My Daily Discovery'),
              child: Container(
                height: 132,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF341C4E), Color(0xFF1F1131), Color(0xFF130B20)],
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    for (final d in const [
                      (140.0, 14.0, Color(0xFF6A4896)),
                      (210.0, 14.0, Color(0xFFF6A6C1)),
                      (175.0, 48.0, Color(0xFFF6A6C1)),
                      (248.0, 48.0, Color(0xFF56397C)),
                      (316.0, 48.0, Color(0xFF56397C)),
                      (282.0, 82.0, Color(0xFF422A63)),
                    ])
                      Positioned(
                        left: d.$1,
                        top: d.$2,
                        child: Transform.rotate(
                          angle: pi / 4,
                          child: Container(width: 11, height: 11, color: d.$3),
                        ),
                      ),
                    Positioned(
                      left: 22,
                      right: 22,
                      bottom: 20,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          tx('My Daily Discovery', z: 23, f: FontWeight.w800, c: const Color(0xFFF7A8C4)),
                          const SizedBox(height: 2),
                          tx('A daily mix of tracks picked for you', z: 13, c: Colors.white70),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpotifyHome(BuildContext c, List<Track> all, List<Track> rec, List<Track> most, void Function(String, List<Track> Function(), {String? list}) open) {
    final pool = chip == 2 ? app.likedTracks : (rec.isEmpty ? all : rec);
    final listNames = app.lists.keys.toList();

    final gridTiles = <Widget>[];

    Widget spTile(String title, Widget leading, VoidCallback onTap) {
      return GestureDetector(
        onTap: () { tap(); onTap(); },
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF282828),
            borderRadius: BorderRadius.circular(5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              SizedBox(width: 54, height: 54, child: leading),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: tx(title, f: FontWeight.w700, z: 13, lines: 2, c: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (listNames.isNotEmpty) {
      final n0 = listNames[0];
      gridTiles.add(spTile(n0, CollageArt(app.toTracks(app.lists[n0]!), 54, radius: 0), () => open(n0, () => app.toTracks(app.lists[n0] ?? []), list: n0)));
    } else if (pool.isNotEmpty) {
      gridTiles.add(spTile(pool[0].title, Art(pool[0], 54, r: 0), () => app.playAt(pool, 0, ctx: pool[0].title)));
    }

    if (listNames.length > 1) {
      final n1 = listNames[1];
      gridTiles.add(spTile(n1, CollageArt(app.toTracks(app.lists[n1]!), 54, radius: 0), () => open(n1, () => app.toTracks(app.lists[n1] ?? []), list: n1)));
    } else if (pool.length > 1) {
      gridTiles.add(spTile(pool[1].title, Art(pool[1], 54, r: 0), () => app.playAt(pool, 1, ctx: pool[1].title)));
    }

    gridTiles.add(spTile(
      'Liked Songs',
      Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF4510E0), Color(0xFF8E8EE5), Color(0xFFB8E2D8)],
          ),
        ),
        child: const Icon(Icons.favorite_rounded, color: Colors.white, size: 24),
      ),
      () => open('Liked Songs', () => app.likedTracks),
    ));

    gridTiles.add(spTile(
      'On Repeat',
      Container(
        color: const Color(0xFF1E3264),
        child: const Stack(
          alignment: Alignment.center,
          children: [
            Icon(Icons.all_inclusive_rounded, color: Color(0xFFF037A5), size: 30),
            Positioned(
              left: 4,
              bottom: 3,
              child: Text('On\nRepeat', style: TextStyle(color: Colors.white, fontSize: 6.5, fontWeight: FontWeight.w800, height: 1.0)),
            ),
          ],
        ),
      ),
      () => open('On Repeat', () => most.isNotEmpty ? most : all),
    ));

    for (final n in listNames.skip(2)) {
      if (gridTiles.length >= 8) break;
      gridTiles.add(spTile(n, CollageArt(app.toTracks(app.lists[n]!), 54, radius: 0), () => open(n, () => app.toTracks(app.lists[n] ?? []), list: n)));
    }
    for (var i = 0; i < pool.length && gridTiles.length < 8; i++) {
      final tr = pool[i];
      gridTiles.add(spTile(tr.title, Art(tr, 54, r: 0), () => app.playAt(pool, i, ctx: 'Home')));
    }

    final feat = pool.first;

    final plCards = <({String title, String sub, List<Track> tracks, bool waveform, VoidCallback onTap})>[];
    for (final n in listNames) {
      plCards.add((
        title: n,
        sub: app.name,
        tracks: app.toTracks(app.lists[n]!),
        waveform: false,
        onTap: () => open(n, () => app.toTracks(app.lists[n] ?? []), list: n),
      ));
    }
    if (plCards.length < 3) {
      plCards.insert(0, (
        title: 'Chill Rap',
        sub: app.name,
        tracks: mix(all, 1),
        waveform: true,
        onTap: () => app.playAt(mix(all, 1), 0, ctx: 'Chill Rap'),
      ));
      plCards.add((
        title: 'Heavy Rotation',
        sub: app.name,
        tracks: most.isNotEmpty ? most : mix(all, 2),
        waveform: false,
        onTap: () => app.playAt(most.isNotEmpty ? most : mix(all, 2), 0, ctx: 'Heavy Rotation'),
      ));
    }

    return Container(
      color: const Color(0xFF121212),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  GestureDetector(onTap: () => openProfile(c), child: avatar(17, dot: true)),
                  const SizedBox(width: 10),
                  for (final (i, l) in ['All', 'Music', 'Podcasts', 'Audiobooks'].indexed)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () => setState(() => chip = i),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: chip == i ? spGreen : const Color(0xFF282828),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: tx(
                            l,
                            c: chip == i ? Colors.black : Colors.white,
                            f: chip == i ? FontWeight.w700 : FontWeight.w500,
                            z: 13,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 3.15,
              children: gridTiles,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: GestureDetector(
              onTap: () => app.goTab(1),
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF262626),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  children: [
                    const SpotifyDotCluster(),
                    const SizedBox(width: 12),
                    Expanded(
                      child: tx('Tell Spotify what to play', z: 14, c: const Color(0xFFB3B3B3), f: FontWeight.w600),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF9E9E9E),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'Beta',
                        style: TextStyle(color: Color(0xFF121212), fontSize: 10.5, fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Icon(Icons.mic_none_rounded, color: Color(0xFFB3B3B3), size: 22),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
            child: tx('The next episode awaits', z: 21, f: FontWeight.w800, c: Colors.white),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GestureDetector(
              onTap: () => app.playAt(pool, 0, ctx: 'Featured'),
              child: Container(
                height: 154,
                decoration: BoxDecoration(
                  color: const Color(0xFF1F1F1F),
                  borderRadius: BorderRadius.circular(10),
                ),
                clipBehavior: Clip.antiAlias,
                child: Row(
                  children: [
                    Art(feat, 154, r: 0),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      tx('Featured Track', z: 12, c: const Color(0xFFB3B3B3), f: FontWeight.w600),
                                      const SizedBox(height: 2),
                                      tx(feat.title, z: 15.5, f: FontWeight.w800, c: Colors.white),
                                    ],
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () => trackMenu(c, feat),
                                  child: const Icon(Icons.more_vert_rounded, color: Color(0xFFB3B3B3), size: 20),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            tx(
                              '${feat.artist} • ${feat.album}. Tap to jump right back into your rotation.',
                              z: 12.5,
                              c: const Color(0xFFA7A7A7),
                              lines: 2,
                            ),
                            const Spacer(),
                            Row(
                              children: [
                                GestureDetector(
                                  onTap: () => app.like(feat),
                                  child: Icon(
                                    app.liked.contains(feat.path) ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded,
                                    color: app.liked.contains(feat.path) ? spGreen : const Color(0xFFB3B3B3),
                                    size: 26,
                                  ),
                                ),
                                const Spacer(),
                                GestureDetector(
                                  onTap: () => app.playAt(pool, 0, ctx: feat.title),
                                  child: Container(
                                    width: 36,
                                    height: 36,
                                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                                    child: const Icon(Icons.play_arrow_rounded, color: Colors.black, size: 24),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
            child: tx('Your playlists', z: 21, f: FontWeight.w800, c: Colors.white),
          ),
          SizedBox(
            height: 214,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: plCards.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (_, i) {
                final pl = plCards[i];
                return GestureDetector(
                  onTap: () { tap(); pl.onTap(); },
                  child: SizedBox(
                    width: 158,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (pl.waveform && (pl.tracks.isEmpty || pl.tracks.first.art == null))
                          Container(
                            width: 158,
                            height: 158,
                            decoration: BoxDecoration(
                              color: const Color(0xFF28375C),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: CustomPaint(
                              size: const Size(130, 158),
                              painter: Bars(1.0, pl.title.hashCode, const Color(0xFF8AB4F8), false),
                            ),
                          )
                        else
                          CollageArt(pl.tracks, 158, radius: 8),
                        const SizedBox(height: 8),
                        tx(pl.title, z: 13.5, f: FontWeight.w700, c: Colors.white),
                        const SizedBox(height: 2),
                        tx(pl.sub, z: 12, c: const Color(0xFF9E9E9E)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final all = app.sorted, rec = app.recentTracks, most = app.mostPlayed, sk = app.sk, hv = sk.home, w = MediaQuery.of(c).size.width;
        final src = chip == 2 ? app.likedTracks : (rec.isEmpty ? all : rec);
        final added = [...app.tracks]..sort((a, b) => b.added.compareTo(a.added));
        void open(String t, List<Track> Function() f, {String? list}) => Navigator.push(c, MaterialPageRoute(builder: (_) => ListPage(t, f, list: list)));

        if (all.isEmpty) {
          return Scaffold(backgroundColor: bg, body: ListView(children: [head(c, sk.title), emptyHome()]));
        }

        if (hv == 4) return _buildTidalHome(c, all, rec, open);
        if (hv == 0) return _buildSpotifyHome(c, all, rec, most, open);

        final recS = shelf('Recently played', recCards(rec)), mixS = shelf('Made for ${app.name}', all.isEmpty ? [] : mixCards(all));
        final topS = shelf('Your top songs', [for (var i = 0; i < most.length && i < 12; i++) Card2(most[i].title, '${app.plays[most[i].path]} plays', most[i], () => app.playAt(most, i))]);
        final newS = shelf('Recently added', [for (var i = 0; i < added.length && i < 12; i++) Card2(added[i].title, added[i].artist, added[i], () => app.playAt(added, i))]);
        final plS = shelf('Your playlists', [for (final n in app.lists.keys) Card2(n, '${app.lists[n]!.length} songs', app.toTracks(app.lists[n]!).firstOrNull, () => open(n, () => app.toTracks(app.lists[n] ?? []), list: n))]);

        List<Widget> kids;
        if (hv == 1) {
          final m1 = mix(all, 1);
          kids = [
            head(c, 'Listen Now'), const Divider(color: Colors.white12, height: 1),
            Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              tx('MADE FOR ${app.name.toUpperCase()}', z: 12, c: grey, f: FontWeight.w700), tx('Top Picks', z: 22, f: FontWeight.w800), const SizedBox(height: 10),
              GestureDetector(onTap: () => app.playAt(m1, 0), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Stack(children: [
                Art(m1.first, w - 32, r: 0),
                Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: .75)])))),
                Positioned(left: 16, right: 16, bottom: 14, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx('Daily Mix 1', z: 22, f: FontWeight.w800), tx(m1.take(3).map((e) => e.artist).toSet().join(', '), c: Colors.white70, z: 13)])),
              ]))),
            ])),
            recS, mixS, topS, newS, plS,
          ];
        } else if (hv == 2) {
          kids = [
            head(c, ''),
            SizedBox(height: 44, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [for (final m in ['Energize', 'Relax', 'Workout', 'Commute', 'Focus', 'Party']) Padding(padding: const EdgeInsets.only(right: 8), child: ActionChip(label: Text(m), backgroundColor: card, side: BorderSide.none, onPressed: () => app.playAt(([...all]..shuffle()).take(30).toList(), 0)))])),
            shelf('Listen again', recCards(rec.isEmpty ? all : rec)),
            Padding(padding: const EdgeInsets.fromLTRB(16, 22, 16, 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx('START RADIO BASED ON A SONG', z: 11, c: grey, f: FontWeight.w700), tx('Quick picks', z: 22, f: FontWeight.w800)])),
            SizedBox(height: 288, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.only(left: 4), children: [for (var g = 0; g < src.length && g < 16; g += 4) SizedBox(width: w * .88, child: Column(children: [for (var k = g; k < g + 4 && k < src.length; k++) SizedBox(height: 72, child: TTile(src[k], src, k))]))])),
            mixS, topS, newS,
          ];
        } else if (hv == 3) {
          kids = [
            head(c, 'Home'),
            Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: GestureDetector(onTap: () => app.shufflePlay(all), child: Container(decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(4)), clipBehavior: Clip.antiAlias, child: Row(children: [
              Art(all.first, 84, r: 0), const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx('Shuffle my library', z: 16, f: FontWeight.w800), tx('${all.length} songs', z: 13, c: grey)])),
              Container(margin: const EdgeInsets.only(right: 14), width: 44, height: 44, decoration: BoxDecoration(color: gr, shape: BoxShape.circle), child: const Icon(Icons.shuffle, color: Colors.black)),
            ])))),
            recS, plS, mixS, topS, newS,
          ];
        } else if (hv == 5) {
          final feed = src.take(15).toList();
          kids = [
            head(c, 'Home'),
            Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 6), child: tx('More of what you like', z: 18, f: FontWeight.w800)),
            for (var i = 0; i < feed.length; i++) InkWell(onTap: () { tap(); app.playAt(feed, i); }, child: Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 10), child: Row(children: [
              Art(feed[i], 84), const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                tx(feed[i].artist, z: 12, c: grey), tx(feed[i].title, z: 15, f: FontWeight.w700), const SizedBox(height: 8),
                SizedBox(height: 26, child: CustomPaint(size: const Size(double.infinity, 26), painter: Bars(app.cur?.path == feed[i].path ? 1 : 0, feed[i].path.hashCode, gr, false))),
              ])),
            ]))),
            recS, topS, plS,
          ];
        } else {
          kids = [
            head(c, 'Home'),
            Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: GestureDetector(onTap: () => app.shufflePlay(all), child: Container(height: 150, padding: const EdgeInsets.all(20), decoration: BoxDecoration(gradient: LinearGradient(colors: [gr, const Color(0xFFFF4D8D)]), borderRadius: BorderRadius.circular(16)), child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [tx('Flow', z: 36, f: FontWeight.w900), tx('Your personal soundtrack', z: 13, c: Colors.white70)])),
              Container(width: 64, height: 64, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle), child: const Icon(Icons.play_arrow, color: Colors.black, size: 40)),
            ])))),
            recS, mixS, topS, newS, plS,
          ];
        }
        return Container(
          decoration: BoxDecoration(color: bg, gradient: hv == 6 ? LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [gr.withValues(alpha: .3), bg], stops: const [0, .38]) : null),
          child: ListView(padding: const EdgeInsets.only(bottom: 24), children: kids),
        );
      });
}

// ───────────── new / radio pages ─────────────
class NewPage extends StatelessWidget {
  const NewPage({super.key});
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final added = [...app.tracks]..sort((a, b) => b.added.compareTo(a.added));
        final ar = <String, Track>{}, al = <String, Track>{};
        for (final t in app.sorted) { ar.putIfAbsent(t.artist, () => t); al.putIfAbsent(t.album, () => t); }
        void open(String n, bool byArtist) => Navigator.push(c, MaterialPageRoute(builder: (_) => ListPage(n, () => app.tracks.where((t) => byArtist ? t.artist == n : t.album == n).toList())));
        return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          head(c, navLabel('new')),
          shelf('New releases', [for (var i = 0; i < added.length && i < 15; i++) Card2(added[i].title, added[i].artist, added[i], () => app.playAt(added, i))]),
          shelf('Artists', [for (final e in ar.entries) Card2(e.key, 'Artist', e.value, () => open(e.key, true), round: true)]),
          shelf('Albums', [for (final e in al.entries) Card2(e.key, e.value.artist, e.value, () => open(e.key, false))]),
        ]);
      });
}

class RadioPage extends StatelessWidget {
  const RadioPage({super.key});
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final all = app.sorted, ar = <String, List<Track>>{};
        for (final t in all) { (ar[t.artist] ??= []).add(t); }
        Widget row(String t, String s, Track? a, VoidCallback f) => ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 16), leading: Art(a, 56), title: tx(t, f: FontWeight.w700), subtitle: tx(s, c: grey, z: 13), onTap: () { tap(); f(); });
        return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          head(c, navLabel('radio')),
          if (all.isEmpty) emptyHome() else ...[
            row('Shuffle all', '${all.length} songs', all.first, () => app.shufflePlay(all)),
            for (var n = 1; n <= 5; n++) () { final l = mix(all, n); return row('Daily Mix $n', l.take(3).map((e) => e.artist).toSet().join(', '), l.first, () => app.playAt(l, 0, ctx: 'Daily Mix $n')); }(),
            for (final e in ar.entries.take(10)) row('${e.key} Radio', '${e.value.length} songs', e.value.first, () => app.playAt(([...e.value]..shuffle()), 0, ctx: '${e.key} Radio')),
          ],
        ]);
      });
}

// ───────────── SEARCH PAGE (Local + Native SimpMusic YouTube Music Engine) ─────────────
class SearchPage extends StatefulWidget { const SearchPage({super.key}); @override State<SearchPage> createState() => _SearchState(); }
class _SearchState extends State<SearchPage> {
  final ctl = TextEditingController();
  Timer? _deb;
  List<YtSong> ytRes = [];
  bool searchingYt = false;

  void _onQueryChanged(String v) {
    setState(() {});
    _deb?.cancel();
    final q = v.trim();
    if (q.length < 2) {
      setState(() {
        ytRes = [];
        searchingYt = false;
      });
      return;
    }
    setState(() => searchingYt = true);
    _deb = Timer(const Duration(milliseconds: 420), () async {
      final res = await app.searchYtMusic(q);
      if (mounted && ctl.text.trim() == q) {
        setState(() {
          ytRes = res;
          searchingYt = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _deb?.cancel();
    ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final q = ctl.text.toLowerCase().trim(), sp = app.sk.name == 'Spotify';
        final localRes = q.isEmpty ? <Track>[] : app.tracks.where((t) => '${t.title} ${t.artist} ${t.album}'.toLowerCase().contains(q)).toList();
        final names = {...app.tracks.map((t) => t.artist), ...app.tracks.map((t) => t.album)}.toList();

        return Column(children: [
          head(c, navLabel('search')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: TextField(
              controller: ctl,
              onChanged: _onQueryChanged,
              onSubmitted: _onQueryChanged,
              style: TextStyle(color: sp ? Colors.black : Colors.white, fontWeight: FontWeight.w600),
              cursorColor: sp ? Colors.black : gr,
              decoration: InputDecoration(
                filled: true,
                fillColor: sp ? Colors.white : card,
                hintText: 'Search YouTube Music & local library',
                hintStyle: TextStyle(color: sp ? const Color(0xFF535353) : grey, fontWeight: FontWeight.w600),
                prefixIcon: Icon(Icons.search, color: sp ? Colors.black : grey),
                suffixIcon: q.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(Icons.close, color: sp ? Colors.black : grey),
                        onPressed: () {
                          ctl.clear();
                          _onQueryChanged('');
                        },
                      ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(sp ? 6 : 24), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: q.isNotEmpty
                ? ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      if (localRes.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: tx('IN YOUR LIBRARY', z: 11, c: grey, f: FontWeight.w800, ls: 1.0),
                        ),
                        for (var i = 0; i < localRes.length; i++) TTile(localRes[i], localRes, i),
                      ],
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                        child: Row(
                          children: [
                            Icon(Icons.play_circle_fill_rounded, color: gr, size: 18),
                            const SizedBox(width: 6),
                            tx('YOUTUBE MUSIC (SIMPMUSIC ENGINE)', z: 11, c: gr, f: FontWeight.w800, ls: 0.9),
                            const Spacer(),
                            if (searchingYt)
                              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: gr)),
                          ],
                        ),
                      ),
                      if (!searchingYt && ytRes.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(child: tx('No YouTube Music results for "$q"', c: grey)),
                        ),
                      for (final y in ytRes)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.network(
                              y.art,
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                width: 48,
                                height: 48,
                                color: tint(y.title, .25),
                                child: const Icon(Icons.music_note, color: Colors.white70),
                              ),
                            ),
                          ),
                          title: tx(y.title, f: FontWeight.w700),
                          subtitle: tx(
                            '${y.artist}${y.duration.isNotEmpty ? ' • ${y.duration}' : ''}',
                            c: grey,
                            z: 12.5,
                          ),
                          trailing: const Icon(Icons.cloud_download_outlined, color: grey, size: 22),
                          onTap: () {
                            tap();
                            app.playYtSong(y);
                          },
                        ),
                    ],
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      tx('Browse all', z: 16, f: FontWeight.w800),
                      const SizedBox(height: 12),
                      GridView.count(
                        crossAxisCount: 2,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 1.7,
                        children: [
                          for (final n in names.isNotEmpty ? names : ['Hip-Hop', 'Underground Rap', 'Trap', 'Chill', 'Top Hits', 'Workout'])
                            GestureDetector(
                              onTap: () {
                                ctl.text = n;
                                _onQueryChanged(n);
                              },
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: tint(n, .4),
                                  borderRadius: BorderRadius.circular(app.sk.artR.clamp(2, 12).toDouble()),
                                ),
                                child: tx(n, z: 16, f: FontWeight.w800, lines: 2),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
          ),
        ]);
      });
}

// ───────────── library ─────────────
class LibraryPage extends StatefulWidget { const LibraryPage({super.key}); @override State<LibraryPage> createState() => _LibState(); }
class _LibState extends State<LibraryPage> {
  int chip = 0;
  Widget row(Card2 x) => ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 16), leading: Art(x.art, 56, r: x.round ? 28 : null), title: tx(x.title, f: FontWeight.w700), subtitle: tx(x.sub, c: grey, z: 13), onTap: () { tap(); x.f(); });
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        void open(String t, List<Track> Function() f, {String? list}) => Navigator.push(c, MaterialPageRoute(builder: (_) => ListPage(t, f, list: list)));
        final artists = <String, List<Track>>{}, albums = <String, List<Track>>{}, srt = app.sorted;
        for (final t in srt) { (artists[t.artist] ??= []).add(t); (albums[t.album] ??= []).add(t); }
        final items = <Card2>[
          if (chip == 0) Card2('Liked Songs', 'Playlist • ${app.liked.length} songs', app.likedTracks.firstOrNull, () => open('Liked Songs', () => app.likedTracks)),
          if (chip == 0) for (final n in app.lists.keys) Card2(n, 'Playlist • ${app.lists[n]!.length} songs', app.toTracks(app.lists[n]!).firstOrNull, () => open(n, () => app.toTracks(app.lists[n] ?? []), list: n)),
          if (chip == 1) for (final e in artists.entries) Card2(e.key, 'Artist • ${e.value.length} songs', e.value.first, () => open(e.key, () => app.tracks.where((t) => t.artist == e.key).toList()), round: true),
          if (chip == 2) for (final e in albums.entries) Card2(e.key, 'Album • ${e.value.first.artist}', e.value.first, () => open(e.key, () => app.tracks.where((t) => t.album == e.key).toList())),
          if (chip == 3) for (var i = 0; i < srt.length; i++) Card2(srt[i].title, srt[i].artist, srt[i], () => app.playAt(srt, i, ctx: 'Your Library')),
        ];
        return Column(children: [
          head(c, navLabel('lib'), actions: [IconButton(icon: const Icon(Icons.add), onPressed: () async { final n = await ask(c, 'Name your playlist'); if (n != null && !app.createList(n)) toast('Name is empty or already used'); })]),
          SizedBox(height: 44, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final (i, l) in ['Playlists', 'Artists', 'Albums', 'Songs'].indexed) Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: ChoiceChip(label: Text(l), selected: chip == i, selectedColor: gr, backgroundColor: card, labelStyle: TextStyle(color: chip == i ? Colors.black : Colors.white, fontWeight: FontWeight.w600), side: BorderSide.none, showCheckmark: false, onSelected: (_) => setState(() => chip = i))),
          ])),
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 8, 0), child: Row(children: [
            const Icon(Icons.swap_vert, size: 18), const SizedBox(width: 4),
            GestureDetector(onTap: () => app.set(() => app.sort = app.sort == 'recent' ? 'az' : 'recent'), child: tx(app.sort == 'recent' ? 'Recents' : 'Alphabetical', z: 13, f: FontWeight.w600)),
            const Spacer(), IconButton(icon: Icon(app.libGrid ? Icons.view_list : Icons.grid_view, size: 20), onPressed: () => app.set(() => app.libGrid = !app.libGrid)),
          ])),
          Expanded(child: app.libGrid
              ? GridView.count(crossAxisCount: 3, padding: const EdgeInsets.all(12), mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: .78, children: [for (final x in items) GestureDetector(onTap: x.f, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Art(x.art, 104, r: x.round ? 52 : null), const SizedBox(height: 6), tx(x.title, z: 12, f: FontWeight.w700), tx(x.sub, z: 11, c: grey)]))])
              : ListView(children: [for (final x in items) row(x)])),
        ]);
      });
}

// ───────────── playlist page ─────────────
class ListPage extends StatefulWidget {
  final String title; final List<Track> Function() get; final String? list;
  const ListPage(this.title, this.get, {this.list, super.key});
  @override State<ListPage> createState() => _ListState();
}
class _ListState extends State<ListPage> {
  bool reorder = false; late String title = widget.title;
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final l = widget.list != null ? app.toTracks(app.lists[title] ?? []) : widget.get();
        final pl = widget.list != null ? title : null;
        final header = Container(
          decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [l.isNotEmpty ? app.colorOf(l.first) : tint(title, .35), bg])),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(children: [
            Row(children: [IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(c)), const Spacer()]),
            Center(child: CollageArt(l, 190, radius: 8)), const SizedBox(height: 16),
            Align(alignment: Alignment.centerLeft, child: tx(title, z: 24, f: FontWeight.w800, lines: 2)),
            Align(alignment: Alignment.centerLeft, child: tx('${l.length} songs', c: grey, z: 13)),
            Row(children: [
              IconButton(icon: const Icon(Icons.shuffle), onPressed: () => app.shufflePlay(l, ctx: title)),
              if (pl != null) ...[
                IconButton(icon: const Icon(Icons.edit_outlined), tooltip: 'Rename', onPressed: () async { final n = await ask(c, 'Rename playlist', title); if (n == null) return; if (app.rename(pl, n)) { setState(() => title = n.trim()); } else { toast('Name is empty or already used'); } }),
                IconButton(icon: Icon(Icons.swap_vert, color: reorder ? gr : Colors.white), tooltip: 'Reorder', onPressed: () => setState(() => reorder = !reorder)),
                IconButton(icon: const Icon(Icons.playlist_add), tooltip: 'Add songs', onPressed: () => sheet(c, (_) => ListenableBuilder(listenable: app, builder: (_, __) => ListView(children: [for (final t in app.sorted) CheckboxListTile(activeColor: gr, secondary: Art(t, 44), title: tx(t.title), subtitle: tx(t.artist, c: grey, z: 12), value: (app.lists[title] ?? []).contains(t.path), onChanged: (_) => app.toggleIn(title, t))])), big: true)),
                IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete', onPressed: () { app.deleteList(title); Navigator.pop(c); }),
              ],
              const Spacer(),
              GestureDetector(onTap: l.isEmpty ? null : () { tap(); app.playAt(l, 0, ctx: title); }, child: Container(width: 54, height: 54, decoration: BoxDecoration(color: gr, shape: BoxShape.circle), child: const Icon(Icons.play_arrow, color: Colors.black, size: 34))),
            ]),
          ]),
        );
        return Scaffold(body: SafeArea(child: reorder && pl != null
            ? ReorderableListView.builder(
                header: header, itemCount: l.length, onReorder: (o, n) => app.reorderList(title, o, n),
                itemBuilder: (_, i) => ListTile(key: ValueKey('${l[i].path}$i'), leading: Art(l[i], 48), title: tx(l[i].title, f: FontWeight.w600), subtitle: tx(l[i].artist, c: grey, z: 13), trailing: const Icon(Icons.drag_handle, color: grey)),
              )
            : ListView.builder(padding: const EdgeInsets.only(bottom: 20), itemCount: l.length + 1, itemBuilder: (_, i) => i == 0 ? header : TTile(l[i - 1], l, i - 1, inList: title))));
      });
}

// ───────────── profile drawer (With YouTube Music Sign-In) ─────────────
void openProfile(BuildContext c) {
  tap();
  void go(Widget w) => Navigator.push(c, MaterialPageRoute(builder: (_) => w));

  void showSignInSheet() {
    final emailCtl = TextEditingController(text: app.ytAccountEmail ?? '');
    sheet(c, (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.play_circle_fill_rounded, color: spGreen, size: 28),
                    const SizedBox(width: 10),
                    tx('YouTube Music Sign-In', z: 18, f: FontWeight.w800),
                  ],
                ),
                const SizedBox(height: 12),
                tx('Sign in to sync your YouTube Music account and stream your personalized library.', z: 13.5, c: grey, lines: 3),
                const SizedBox(height: 16),
                TextField(
                  controller: emailCtl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Google Account Email',
                    hintText: 'alex@gmail.com',
                    filled: true,
                    fillColor: card,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (app.ytAccountEmail != null)
                      TextButton(
                        onPressed: () {
                          app.set(() => app.ytAccountEmail = null);
                          Navigator.pop(ctx);
                          toast('Signed out from YouTube Music');
                        },
                        child: const Text('Sign out', style: TextStyle(color: Colors.redAccent)),
                      ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: spGreen, foregroundColor: Colors.black),
                      onPressed: () {
                        final em = emailCtl.text.trim();
                        if (em.isNotEmpty) {
                          app.set(() => app.ytAccountEmail = em);
                          Navigator.pop(ctx);
                          toast('Signed in as $em');
                        }
                      },
                      child: const Text('Sign In', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ));
  }

  final items = <(IconData, String, VoidCallback)>[
    (Icons.cloud_sync_outlined, app.ytAccountEmail == null ? 'Sign in to YouTube Music' : 'Connected (${app.ytAccountEmail})', showSignInSheet),
    (Icons.insights_outlined, 'Listening stats', () => go(const StatsPage())),
    (Icons.palette_outlined, 'Themes & Mods', () => go(SPage('Themes & Mods', themesS))),
    (Icons.slideshow, 'Player styles', () => go(SPage('Player styles', playerS))),
    (Icons.history, 'Recents', () => go(ListPage('Recents', () => app.recentTracks))),
    (Icons.favorite_border, 'Liked Songs', () => go(ListPage('Liked Songs', () => app.likedTracks))),
    (Icons.settings_outlined, 'Settings and privacy', () => go(const SettingsPage())),
  ];

  Navigator.push(c, PageRouteBuilder(
    opaque: false, barrierDismissible: true, barrierColor: Colors.black.withValues(alpha: .6),
    pageBuilder: (ctx, __, ___) => Align(alignment: Alignment.centerLeft, child: Material(color: bg, child: SizedBox(width: MediaQuery.of(ctx).size.width * .84, height: double.infinity, child: SafeArea(child: ListView(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 22, 20, 12), child: Row(children: [
        avatar(28),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              tx(app.name, z: 20, f: FontWeight.w800),
              tx(app.ytAccountEmail ?? 'View profile', c: grey, z: 12.5),
            ],
          ),
        ),
      ])),
      Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 0), child: tx('APP SKIN', z: 11, c: grey, f: FontWeight.w800)),
      skinDrop(),
      const Divider(color: Colors.white12),
      for (final it in items) InkWell(onTap: () { Navigator.pop(ctx); it.$3(); }, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15), child: Row(children: [Icon(it.$1, size: 26, color: it.$1 == Icons.cloud_sync_outlined ? spGreen : Colors.white), const SizedBox(width: 18), tx(it.$2, z: 16)]))),
    ]))))),
    transitionsBuilder: (_, a, __, w) => SlideTransition(position: Tween(begin: const Offset(-1, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: w),
  ));
}

// ───────────── settings ─────────────
Widget ssec(String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 24, 16, 6), child: tx(t, z: 16, f: FontWeight.w800));
Widget srow(String t, {String? sub, VoidCallback? f, Widget? trail, IconData? icon}) => ListTile(onTap: f, leading: icon == null ? null : Icon(icon, color: Colors.white, size: 26), title: tx(t, z: 16, lines: 2), subtitle: sub == null ? null : tx(sub, c: grey, z: 13, lines: 2), trailing: trail);
Widget sw(String t, String sub, bool v, ValueChanged<bool> f) => srow(t, sub: sub, f: () => f(!v), trail: Switch(value: v, onChanged: f, thumbColor: const WidgetStatePropertyAll(Colors.black), trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? gr : const Color(0xFF727272)), trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent)));
void pickOne<T>(BuildContext c, String title, Map<T, String> o, T cur, void Function(T) f) => showDialog(context: c, builder: (d) => SimpleDialog(backgroundColor: const Color(0xFF282828), title: Text(title), children: [for (final e in o.entries) RadioListTile<T>(activeColor: gr, title: Text(e.value), value: e.key, groupValue: cur, onChanged: (v) { f(v as T); Navigator.pop(d); })]));

class SPage extends StatelessWidget {
  final String title; final List<Widget> Function(BuildContext) body;
  const SPage(this.title, this.body, {super.key});
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) => Scaffold(
        appBar: AppBar(backgroundColor: bg, surfaceTintColor: Colors.transparent, centerTitle: true, title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
        body: ListView(padding: const EdgeInsets.only(bottom: 40), children: body(c)),
      ));
}

List<Widget> accountS(BuildContext c) => [
      srow(app.name, sub: 'Tap to change your name', f: () async { final n = await ask(c, 'Your name', app.name); if (n != null && n.trim().isNotEmpty) app.set(() => app.name = n.trim()); }, trail: avatar(18)),
      srow('YouTube Music Account', sub: app.ytAccountEmail ?? 'Not signed in (Tap to sign in)', icon: Icons.cloud_sync_outlined, f: () {
        final emailCtl = TextEditingController(text: app.ytAccountEmail ?? '');
        sheet(c, (ctx) => SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    tx('YouTube Music Sign-In', z: 18, f: FontWeight.w800),
                    const SizedBox(height: 12),
                    TextField(controller: emailCtl, decoration: InputDecoration(labelText: 'Google Email', filled: true, fillColor: card)),
                    const SizedBox(height: 14),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: spGreen, foregroundColor: Colors.black),
                      onPressed: () {
                        final em = emailCtl.text.trim();
                        if (em.isNotEmpty) {
                          app.set(() => app.ytAccountEmail = em);
                          Navigator.pop(ctx);
                          toast('Signed in as $em');
                        }
                      },
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ),
            ));
      }),
      srow('Profile picture', sub: 'Choose from your gallery', icon: Icons.image_outlined, f: () async { final r = await FilePicker.platform.pickFiles(type: FileType.image); final p = r?.files.single.path; if (p != null) app.set(() => app.avatar = p); }),
      if (app.avatar != null) srow('Remove profile picture', icon: Icons.delete_outline, f: () => app.set(() => app.avatar = null)),
    ];

List<Widget> themesS(BuildContext c) => [
      ssec('App skin'), skinDrop(),
      Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 0), child: tx('Transforms the whole app: colors, navigation, home screen, mini player and full player.', c: grey, z: 12, lines: 3)),
      ssec('Accent color'),
      SizedBox(height: 56, child: ListView.separated(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), itemCount: accents.length, separatorBuilder: (_, __) => const SizedBox(width: 12), itemBuilder: (_, i) => GestureDetector(onTap: () => app.set(() => app.accent = i), child: Container(width: 44, height: 44, decoration: BoxDecoration(color: accents[i] ?? app.sk.accent, shape: BoxShape.circle, border: Border.all(color: app.accent == i ? Colors.white : Colors.transparent, width: 3)), child: i == 0 ? const Icon(Icons.auto_awesome, color: Colors.black, size: 20) : null)))),
      sw('Dynamic accent', 'Accent color follows the song artwork', app.dyn, (v) => app.set(() => app.dyn = v)),
      ssec('Layout'),
      sw('Slim navigation bar', 'Hide labels in the bottom bar', app.slim, (v) => app.set(() => app.slim = v)),
      srow('Default tab', sub: ['First tab', 'Second tab', 'Third tab'][app.tab0.clamp(0, 2)], icon: Icons.tab, f: () => pickOne<int>(c, 'Default tab', {0: 'First tab', 1: 'Second tab', 2: 'Third tab'}, app.tab0, (v) => app.set(() => app.tab0 = v))),
      sw('Grid library view', 'Show your library as a grid', app.libGrid, (v) => app.set(() => app.libGrid = v)),
      srow('Library sort', sub: app.sort == 'recent' ? 'Recently added' : 'A to Z', icon: Icons.sort, f: () => app.set(() => app.sort = app.sort == 'recent' ? 'az' : 'recent')),
      sw('Mini player progress', 'Show progress line on the mini player', app.miniProg, (v) => app.set(() => app.miniProg = v)),
      sw('Haptic feedback', 'Vibrate on taps', app.haptics, (v) => app.set(() => app.haptics = v)),
    ];

List<Widget> playerS(BuildContext c) => [
      ssec('Player style'),
      dd<int>({-1: 'Follow app skin', for (final (i, l) in npls.indexed) i: l.name}, app.npStyle, (v) => app.set(() => app.npStyle = v)),
      srow('Player background', sub: ['Auto (player style)', 'Artwork gradient', 'Blurred artwork', 'Solid', 'Accent gradient', 'Black'][app.pbg.clamp(0, 5)], icon: Icons.wallpaper, f: () => pickOne<int>(c, 'Player background', {0: 'Auto (player style)', 1: 'Artwork gradient', 2: 'Blurred artwork', 3: 'Solid', 4: 'Accent gradient', 5: 'Black'}, app.pbg, (v) => app.set(() => app.pbg = v))),
      srow('Progress bar style', sub: ['Auto', 'Standard', 'Wavy', 'Slim', 'Thick', 'Waveform', 'Dots'][app.sliderStyle.clamp(0, 6)], icon: Icons.graphic_eq, f: () => pickOne<int>(c, 'Progress bar style', {0: 'Auto', 1: 'Standard', 2: 'Wavy', 3: 'Slim', 4: 'Thick', 5: 'Waveform', 6: 'Dots'}, app.sliderStyle, (v) => app.set(() => app.sliderStyle = v))),
      srow('Artwork shape', sub: ['Default for style', 'Square', 'Rounded', 'Circle'][app.artShape.clamp(0, 3)], icon: Icons.crop_square, f: () => pickOne<int>(c, 'Artwork shape', {0: 'Default for style', 1: 'Square', 2: 'Rounded', 3: 'Circle'}, app.artShape, (v) => app.set(() => app.artShape = v))),
      sw('Artwork glow', 'Accent-colored glow behind artwork', app.glow, (v) => app.set(() => app.glow = v)),
      sw('Spin artwork', 'Rotate the disc in Vinyl style', app.spinArt, (v) => app.set(() => app.spinArt = v)),
      sw('Visualizer', 'Animated bars under the artwork', app.viz, (v) => app.set(() => app.viz = v)),
      sw('Double-tap artwork to seek', 'Left −10 s, right +10 s', app.dbl, (v) => app.set(() => app.dbl = v)),
      sw('Swipe artwork to change song', 'In the full-screen player', app.swipeArt, (v) => app.set(() => app.swipeArt = v)),
      sw('Format badge', 'Show FLAC / MP3 badge above the title', app.badgeOn, (v) => app.set(() => app.badgeOn = v)),
      sw('Volume slider', 'Show volume control in the player', app.showVol, (v) => app.set(() => app.showVol = v)),
      sw('Lyrics card', 'Show synced lyrics under the player', app.lyricsCard, (v) => app.set(() => app.lyricsCard = v)),
      sw('Show remaining time', 'Tap the time in the player to toggle too', app.remain, (v) => app.set(() => app.remain = v)),
    ];

List<Widget> playbackS(BuildContext c) => [
      srow('Mini player swipe', sub: {'skip': 'Swipe to skip songs', 'close': 'Swipe to close and stop the song', 'off': 'Swipe does nothing'}[app.swipe], icon: Icons.swipe, f: () => pickOne<String>(c, 'Mini player swipe', {'skip': 'Skip songs', 'close': 'Close & stop', 'off': 'Off'}, app.swipe, (v) => app.set(() => app.swipe = v))),
      srow('Speed & pitch', sub: app.tuneSummary, icon: Icons.tune, f: () => sheet(c, (_) => const TuneSheet(), big: true)),
      srow('Equalizer', sub: app.eqOn ? 'On' : 'Off', icon: Icons.equalizer, f: () => sheet(c, (_) => const EqSheet(), big: true)),
      srow('A–B loop', sub: app.la == null ? 'Tap to set loop start' : app.lb == null ? 'Tap to set loop end' : 'Looping • tap to clear', icon: Icons.loop, f: app.abLoop),
      sw('Fade in on play', 'Volume ramps up when a song starts', app.fadeIn, (v) => app.set(() => app.fadeIn = v)),
      sw('Shuffle', 'Play queues in random order', app.shuffle, (v) => app.set(() => app.shuffle = v)),
      srow('Repeat', sub: ['Off', 'Repeat all', 'Repeat one'][app.repeat], icon: Icons.repeat, f: () => app.set(() => app.repeat = (app.repeat + 1) % 3)),
      sw('Skip silence', 'Skip quiet parts of tracks', app.skipSilence, (v) { app.set(() => app.skipSilence = v); app.p.setSkipSilenceEnabled(v); }),
      sw('Loudness boost', 'Adds +3 dB so quiet songs sound fuller', app.normalize, (v) { app.set(() => app.normalize = v); try { app.h.enh.setEnabled(v); app.h.enh.setTargetGain(3.0); } catch (_) {} }),
      sw('Skip unplayable songs', 'Jump to the next song if one fails', app.skipErr, (v) => app.set(() => app.skipErr = v)),
      sw('Persistent queue', 'Restore your queue when the app opens', app.resume, (v) => app.set(() => app.resume = v)),
      sw('Stop playback on task clear', 'Stop music when you swipe the app away', app.stopOnClear, (v) => app.set(() => app.stopOnClear = v)),
      srow('Sleep timer', sub: app.sleepAt != null ? 'Pauses at ${TimeOfDay.fromDateTime(app.sleepAt!).format(c)}' : app.sleepEnd ? 'End of this track' : 'Off (tap for 30 min)', icon: Icons.bedtime_outlined, f: () => app.setSleep(app.sleepAt == null ? 30 : null)),
    ];

List<Widget> libraryS(BuildContext c) => [
      srow('Rescan device', sub: '${app.tracks.length} songs${app.scanning ? ' • scanning…' : ''}', icon: Icons.refresh, f: app.scan),
      srow('Add songs', icon: Icons.audio_file_outlined, f: app.addFiles),
      srow('Scan a folder', sub: '${app.dirs.length} folders scanned', icon: Icons.folder_open, f: app.addFolder),
      for (final d in app.dirs) srow(d, icon: Icons.folder_outlined, trail: IconButton(icon: const Icon(Icons.close, color: grey), onPressed: () => app.set(() => app.dirs.remove(d)))),
      srow('Permissions', sub: 'Audio, notifications and Bluetooth', icon: Icons.security, f: () => openAppSettings()),
    ];

List<Widget> dataS(BuildContext c) => [
      srow('Back up to clipboard', sub: 'Playlists, likes, history and settings', icon: Icons.upload_file, f: app.backup),
      srow('Restore from clipboard', sub: 'Paste a previous backup', icon: Icons.download, f: app.restore),
      srow('Clear listening history', icon: Icons.history_toggle_off, f: app.clearHistory),
      srow('Clear artwork cache', icon: Icons.image_not_supported_outlined, f: app.clearArt),
      srow('Reset all settings', icon: Icons.restore, f: app.reset),
    ];

List<Widget> aboutS(BuildContext c) => [
      srow('Pixel Audio Player', sub: 'Version 4.0.0 • Made by Alex Desrosier'),
      srow('YouTube Music Engine', sub: 'Native Kotlin InnerTube (SimpMusic / maxrave-dev core)', icon: Icons.cloud_done_outlined),
      srow('Skins', sub: skins.map((s) => s.name).join(', '), icon: Icons.palette_outlined),
      srow('Player styles', sub: npls.map((s) => s.name).join(', '), icon: Icons.slideshow),
      srow('Mods included', sub: 'Native Kotlin YouTube Music streaming & caching, TIDAL (MAX) & Spotify (Lossless + Beta) replicas, Studio Speed/Pitch (Semitones + Tape Mode), Equalizer, A–B loop, synced lyrics (.lrc).', icon: Icons.extension_outlined),
    ];

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext c) {
    final cats = <(IconData, String, String, List<Widget> Function(BuildContext))>[
      (Icons.person_outline, 'Account', 'Name and profile picture', accountS),
      (Icons.palette_outlined, 'Themes & Mods', 'App skin, accent, layout', themesS),
      (Icons.slideshow, 'Player styles', '11 players, backgrounds, progress bars', playerS),
      (Icons.play_circle_outline, 'Playback', 'Speed & pitch, equalizer, A–B loop, sleep timer', playbackS),
      (Icons.library_music_outlined, 'Your library', 'Scan folders and add songs', libraryS),
      (Icons.insights_outlined, 'Listening stats', 'Top songs and artists', (_) => const []),
      (Icons.storage_outlined, 'Backup & storage', 'Backup, restore and clear data', dataS),
      (Icons.info_outline, 'About', 'Version and included mods', aboutS),
    ];
    return ListenableBuilder(listenable: app, builder: (_, __) => Scaffold(
          appBar: AppBar(backgroundColor: bg, surfaceTintColor: Colors.transparent, centerTitle: true, title: const Text('Settings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
          body: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: Row(children: [avatar(30), const SizedBox(width: 14), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx(app.name, z: 20, f: FontWeight.w800), tx('View profile', c: grey)])])),
            Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 4), child: tx('QUICK SWITCH APP SKIN', z: 11, c: grey, f: FontWeight.w800)),
            skinDrop(),
            const SizedBox(height: 8),
            for (final k in cats) srow(k.$2, sub: k.$3, icon: k.$1, trail: const Icon(Icons.chevron_right, color: grey), f: () => Navigator.push(c, MaterialPageRoute(builder: (_) => k.$2 == 'Listening stats' ? const StatsPage() : SPage(k.$2, k.$4)))),
          ]),
        ));
  }
}

class StatsPage extends StatelessWidget {
  const StatsPage({super.key});
  Widget big(String n, String l) => Expanded(child: Container(margin: const EdgeInsets.all(4), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(10)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx(n, z: 24, f: FontWeight.w800, c: gr), tx(l, z: 12, c: grey)])));
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final most = app.mostPlayed, ar = <String, int>{};
        for (final t in app.tracks) { final n = app.plays[t.path]; if (n != null) ar[t.artist] = (ar[t.artist] ?? 0) + n; }
        final top = ar.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        return Scaffold(
          appBar: AppBar(backgroundColor: bg, surfaceTintColor: Colors.transparent, centerTitle: true, title: const Text('Listening stats', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
          body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 40), children: [
            Row(children: [big('${app.tracks.length}', 'Songs'), big('${app.plays.values.fold(0, (a, b) => a + b)}', 'Plays'), big('${app.liked.length}', 'Liked')]),
            Padding(padding: const EdgeInsets.fromLTRB(4, 20, 4, 8), child: tx('Top artists', z: 20, f: FontWeight.w800)),
            for (final e in top.take(5)) ListTile(dense: true, title: tx(e.key, f: FontWeight.w600), trailing: tx('${e.value} plays', c: grey, z: 13)),
            Padding(padding: const EdgeInsets.fromLTRB(4, 20, 4, 8), child: tx('Top songs', z: 20, f: FontWeight.w800)),
            for (var i = 0; i < most.length && i < 10; i++) ListTile(leading: Art(most[i], 44), title: tx(most[i].title, f: FontWeight.w600), subtitle: tx(most[i].artist, c: grey, z: 12), trailing: tx('${app.plays[most[i].path]}×', c: gr, f: FontWeight.w700), onTap: () => app.playAt(most, i)),
            if (most.isEmpty) Padding(padding: const EdgeInsets.all(32), child: tx('Play some songs and your stats will show up here.', c: grey, lines: 2, a: TextAlign.center)),
          ]),
        );
      });
}
