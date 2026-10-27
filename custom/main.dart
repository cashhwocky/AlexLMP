// FILE: custom/main.dart — Pixel Audio Player 4.0 (7 app skins, 11 player styles, mods)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  Skin('Spotify', Color(0xFF1ED760), Color(0xFF121212), Color(0xFF2A2A2A), [nHome, nSearch, nLib, Nav(Icons.add, Icons.add, 'Create', 'create')], 'What do you want to play?'),
  Skin('Apple Music', Color(0xFFFA2D48), Color(0xFF000000), Color(0xFF1C1C1E), [nHome, Nav(Icons.grid_view, Icons.grid_view_rounded, 'New', 'new'), Nav(Icons.sensors, Icons.sensors, 'Radio', 'radio'), Nav(Icons.library_music_outlined, Icons.library_music, 'Library', 'lib'), nSearch], 'Artists, Songs, Lyrics, and More', title: 'Listen Now', head: 1, home: 1, mini: 1, np: 1, navAcc: true, artR: 10, sz: 164),
  Skin('YouTube Music', Color(0xFFFF0000), Color(0xFF030303), Color(0xFF212121), [nHome, Nav(Icons.smart_display_outlined, Icons.smart_display, 'Samples', 'radio'), Nav(Icons.explore_outlined, Icons.explore, 'Explore', 'new'), Nav(Icons.library_music_outlined, Icons.library_music, 'Library', 'lib')], 'Search songs, albums, artists', head: 2, home: 2, mini: 2, np: 2, artR: 4),
  Skin('Amazon Music', Color(0xFF25D1DA), Color(0xFF0F1923), Color(0xFF1B2733), [nHome, Nav(Icons.manage_search, Icons.manage_search, 'Find', 'search'), Nav(Icons.library_music_outlined, Icons.library_music, 'Library', 'lib')], 'Search', head: 1, home: 3, mini: 3, np: 3, navAcc: true, pill: true, artR: 4, sz: 156),
  Skin('TIDAL', Color(0xFF00FFFF), Color(0xFF000000), Color(0xFF1A1A1A), [nHome, Nav(Icons.explore_outlined, Icons.explore, 'Explore', 'new'), nSearch, Nav(Icons.favorite_border, Icons.favorite, 'My Collection', 'lib')], 'Search artists, songs, albums', home: 4, mini: 4, np: 4, navAcc: true, artR: 0, sz: 150),
  Skin('SoundCloud', Color(0xFFFF5500), Color(0xFF111111), Color(0xFF222222), [nHome, Nav(Icons.dynamic_feed_outlined, Icons.dynamic_feed, 'Feed', 'new'), nSearch, Nav(Icons.library_music_outlined, Icons.library_music, 'Library', 'lib')], 'Search for artists, tracks, albums', home: 5, mini: 5, np: 5, navAcc: true, artR: 2),
  Skin('Deezer', Color(0xFFA238FF), Color(0xFF121216), Color(0xFF23232B), [nHome, nSearch, Nav(Icons.favorite_border, Icons.favorite, 'Favorites', 'lib'), Nav(Icons.all_inclusive, Icons.all_inclusive, 'Flow', 'radio')], 'Search for a song or artist', head: 1, home: 6, mini: 6, np: 6, navAcc: true, artR: 12),
];
// art: 0 padded, 1 flush, 2 vinyl, 3 fullscreen bg, 4 small, 5 none | bg: 0 gradient, 1 blur, 2 solid, 3 accent, 4 black | seek: 0 std, 1 wavy, 2 slim, 3 thick, 4 bars, 5 dots
class NPL {
  final String name; final int art, bg, seek; final bool center, plain, vol, tabs, viz, acc, ring;
  const NPL(this.name, {this.art = 0, this.bg = 0, this.seek = 0, this.center = false, this.plain = false, this.vol = false, this.tabs = false, this.viz = false, this.acc = false, this.ring = false});
}
const npls = [
  NPL('Spotify'),
  NPL('Apple Music', bg: 1, seek: 3, plain: true, vol: true),
  NPL('YouTube Music', seek: 2, tabs: true, acc: true),
  NPL('Amazon Music', bg: 1, center: true, acc: true, ring: true),
  NPL('TIDAL', art: 1, bg: 2, seek: 2, plain: true, acc: true),
  NPL('SoundCloud', bg: 2, seek: 4, plain: true, acc: true),
  NPL('Deezer', center: true, acc: true, ring: true),
  NPL('Vinyl', art: 2, bg: 1, center: true, seek: 2),
  NPL('Fullscreen art', art: 3, bg: 4, seek: 3, center: true),
  NPL('Minimal', art: 5, bg: 4, seek: 2, center: true, plain: true),
  NPL('Visualizer', art: 4, bg: 3, center: true, viz: true, seek: 5, acc: true, ring: true),
];
const accents = <Color?>[null, Color(0xFF1ED760), Color(0xFF5B8CFF), Color(0xFFFF7EB6), Color(0xFFFFB020), Color(0xFFFF4D5A), Color(0xFF7CE08A), Color(0xFFB388FF), Color(0xFF00E5FF)];
final eqPresets = <String, double Function(double)>{'Flat': (x) => 0, 'Bass boost': (x) => (1 - x) * 8 - 1, 'Treble boost': (x) => x * 8 - 1, 'Vocal': (x) => sin(pi * x) * 6 - 1, 'Rock': (x) => (x - .5).abs() * 10 - 1};

// ───────────── globals & helpers ─────────────
Color get bg => app.sk.bg;
Color get card => app.sk.card;
const grey = Color(0xFFA7A7A7);
const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
const exts = ['.mp3', '.wav', '.flac', '.m4a', '.ogg', '.aac', '.opus'];
final msg = GlobalKey<ScaffoldMessengerState>();
final app = AppState();
Color boost(Color c) { final h = HSLColor.fromColor(c); return h.withSaturation(max(h.saturation, .6)).withLightness(.6).toColor(); }
Color get gr { if (app.dyn && app.cur != null) return boost(app.colorOf(app.cur!)); final a = app.accent; return a > 0 && a < accents.length ? accents[a]! : app.sk.accent; }
String navLabel(String k) => app.sk.nav.firstWhere((n) => n.k == k, orElse: () => nLib).l;
String badge(Track t) { final e = t.path.split('.').last.toUpperCase(); return e == 'FLAC' || e == 'WAV' ? '$e • LOSSLESS' : e; }
List<Track> mix(List<Track> all, int n) => ([...all]..shuffle(Random(DateTime.now().difference(DateTime(2024)).inDays + n))).take(25).toList();

void toast(String s) => msg.currentState
  ?..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(s), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
Color tint(String s, [double l = .28]) => HSLColor.fromAHSL(1, (s.hashCode % 360).abs().toDouble(), .5, l).toColor();
String fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
void tap() { if (app.haptics) HapticFeedback.selectionClick(); }
Widget tx(String s, {double z = 14, FontWeight f = FontWeight.w500, Color c = Colors.white, int lines = 1, TextAlign? a}) =>
    Text(s, maxLines: lines, overflow: TextOverflow.ellipsis, textAlign: a, style: TextStyle(fontSize: z, fontWeight: f, color: c));

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
  String name = 'Alex', swipe = 'skip', sort = 'recent'; String? avatar;
  bool shuffle = false, haptics = true, showVol = true, resume = true, skipSilence = false, stopOnClear = false, scanning = false, libGrid = false;
  int repeat = 0, accent = 0; double speed = 1, vol = 1; DateTime? sleepAt; Timer? _sleep;
  int pbg = 0, sliderStyle = 0, tab0 = 0, pqi = 0, _errs = 0; bool dyn = false, lyricsCard = true, skipErr = true, normalize = false, slim = false, swipeArt = true, sleepEnd = false; double pitch = 1; List<String> pq = [];
  int skin = 0, npStyle = -1, artShape = 0, tab = 0; bool glow = true, spinArt = true, viz = false, remain = false, dbl = true, badgeOn = false, fadeIn = false, miniProg = true, eqOn = false;
  Duration? la, lb; String outName = '', outKind = 'phone';
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
    if (tracks.isEmpty) scan();
    if (resume && pq.isNotEmpty) {
      queue = toTracks(pq);
      if (queue.isEmpty) { idx = -1; } else { idx = pqi.clamp(0, queue.length - 1); try { await p.setFilePath(cur!.path); } catch (_) {} }
    }
  }

  void load() {
    try {
      final d = jsonDecode(sp.getString('d') ?? '{}') as Map<String, dynamic>;
      tracks = [for (final j in (d['tracks'] ?? []) as List) Track.fromJson(j)];
      liked = {...((d['liked'] ?? []) as List).cast<String>()};
      lists = {for (final e in ((d['lists'] ?? {}) as Map).entries) e.key as String: (e.value as List).cast<String>()};
      recent = ((d['recent'] ?? []) as List).cast<String>();
      plays = ((d['plays'] ?? {}) as Map).map((k, v) => MapEntry(k as String, v as int));
      name = d['name'] ?? name; avatar = d['avatar']; swipe = d['swipe'] ?? swipe; sort = d['sort'] ?? sort;
      haptics = d['haptics'] ?? true; showVol = d['showVol'] ?? true; resume = d['resume'] ?? true;
      skipSilence = d['skip'] ?? false; stopOnClear = d['stop'] ?? false; libGrid = d['grid'] ?? false;
      accent = d['accent'] ?? 0; shuffle = d['shuffle'] ?? false; repeat = d['repeat'] ?? 0;
      dirs = ((d['dirs'] ?? dirs) as List).cast<String>();
      dyn = d['dyn'] ?? false; pbg = d['pbg'] ?? 0; sliderStyle = d['sl'] ?? 0; lyricsCard = d['lc'] ?? true; skipErr = d['se'] ?? true; normalize = d['nm'] ?? false; slim = d['slim'] ?? false; swipeArt = d['sa'] ?? true; tab0 = d['tab0'] ?? 0; pitch = (d['pitch'] ?? 1.0).toDouble(); pq = ((d['queue'] ?? []) as List).cast<String>(); pqi = d['qi'] ?? 0;
      skin = d['skin'] ?? 0; npStyle = d['nps'] ?? -1; artShape = d['shape'] ?? 0; glow = d['glow'] ?? true; spinArt = d['spin'] ?? true; viz = d['viz'] ?? false; remain = d['remain'] ?? false; dbl = d['dbl'] ?? true; badgeOn = d['badge'] ?? false; fadeIn = d['fade'] ?? false; miniProg = d['mp'] ?? true; eqOn = d['eq'] ?? false;
      tab = tab0;
    } catch (_) {}
  }

  void save() => sp.setString('d', jsonEncode({
        'tracks': tracks.map((t) => t.toJson()).toList(), 'liked': liked.toList(), 'lists': lists, 'recent': recent.take(50).toList(),
        'plays': plays, 'name': name, 'avatar': avatar, 'swipe': swipe, 'sort': sort, 'haptics': haptics, 'showVol': showVol,
        'resume': resume, 'skip': skipSilence, 'stop': stopOnClear, 'grid': libGrid, 'accent': accent, 'shuffle': shuffle, 'repeat': repeat, 'dirs': dirs, 'dyn': dyn, 'pbg': pbg, 'sl': sliderStyle, 'lc': lyricsCard, 'se': skipErr, 'nm': normalize, 'slim': slim, 'sa': swipeArt, 'tab0': tab0, 'pitch': pitch, 'queue': queue.take(200).map((t) => t.path).toList(), 'qi': idx,
        'skin': skin, 'nps': npStyle, 'shape': artShape, 'glow': glow, 'spin': spinArt, 'viz': viz, 'remain': remain, 'dbl': dbl, 'badge': badgeOn, 'fade': fadeIn, 'mp': miniProg, 'eq': eqOn,
      }));
  void set(void Function() f) { f(); save(); notifyListeners(); }
  void setSkin(int i) => set(() { skin = i; tab = 0; });
  void goTab(int i) { tab = i; notifyListeners(); }

  Future<void> refreshOut() async {
    try { final m = await ch.invokeMethod<Map>('outputDevice'); if (m != null) { outName = '${m['name']}'; outKind = '${m['kind']}'; notifyListeners(); } } catch (_) {}
  }
  void abLoop() {
    if (la == null) { la = p.position; toast('Loop start set'); }
    else if (lb == null) { lb = p.position; if (lb! <= la!) { la = null; lb = null; toast('Loop cleared'); } else { toast('Looping A–B'); } }
    else { la = null; lb = null; toast('Loop cleared'); }
    notifyListeners();
  }

  Future<void> _meta(Track t) async {
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
    final found = <String>{...tracks.where((t) => !dirs.any((d) => t.path.startsWith(d)) && File(t.path).existsSync()).map((t) => t.path)};
    for (final d in dirs) {
      try {
        for (final e in Directory(d).listSync(recursive: true, followLinks: false)) {
          if (e is File && exts.any((x) => e.path.toLowerCase().endsWith(x))) found.add(e.path);
        }
      } catch (_) {}
    }
    final old = byPath;
    tracks = [for (final x in found) old[x] ?? Track.from(x)];
    scanning = false; notifyListeners(); save();
    var n = 0;
    for (final t in tracks.where((t) => t.art == null && t.artist == 'Unknown artist').toList()) { await _meta(t); if (++n % 8 == 0) notifyListeners(); }
    notifyListeners(); save();
    if (tracks.isEmpty) toast('No songs found. Use Add songs in Settings.');
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
  Future<void> playAt(List<Track> q, int i) async { queue = List.of(q); idx = i; await _load(); }
  Future<void> shufflePlay(List<Track> q) async { if (q.isEmpty) return; shuffle = true; save(); await playAt(q, Random().nextInt(q.length)); }
  void _fade() { var k = 0; Timer.periodic(const Duration(milliseconds: 60), (t) { k++; p.setVolume(vol * k / 10); if (k >= 10) t.cancel(); }); }
  Future<void> _load() async {
    final t = cur; if (t == null) return;
    la = null; lb = null; notifyListeners();
    try {
      await p.setFilePath(t.path);
      h.mediaItem.add(MediaItem(id: t.path, title: t.title, artist: t.artist, album: t.album, artUri: t.art != null ? Uri.file(t.art!) : null));
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
  void setSpeed(double s) { speed = s; p.setSpeed(s); notifyListeners(); }
  void setVol(double v) { vol = v; p.setVolume(v); notifyListeners(); }
  void setSleep(int? min) {
    _sleep?.cancel(); sleepAt = null;
    if (min != null) { sleepAt = DateTime.now().add(Duration(minutes: min)); _sleep = Timer(Duration(minutes: min), () { p.pause(); sleepAt = null; notifyListeners(); }); toast('Sleep timer: $min min'); }
    notifyListeners();
  }
  void setPitch(double v) { pitch = v; p.setPitch(v); save(); notifyListeners(); }
  Color colorOf(Track t) {
    final c = _cols[t.path]; if (c != null) return c;
    if (t.art != null && _pend.add(t.path)) _dom(t);
    return tint(t.title, .3);
  }
  Future<void> _dom(Track t) async {
    try {
      final codec = await ui.instantiateImageCodec(await File(t.art!).readAsBytes(), targetWidth: 16, targetHeight: 16);
      final bd = await (await codec.getNextFrame()).image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) return;
      double r = 0, g = 0, b = 0, w = 0;
      for (var i = 0; i + 3 < bd.lengthInBytes; i += 4) { final R = bd.getUint8(i), G = bd.getUint8(i + 1), B = bd.getUint8(i + 2); final wt = 1 + (max(R, max(G, B)) - min(R, min(G, B))) / 32; r += R * wt; g += G * wt; b += B * wt; w += wt; }
      final h = HSLColor.fromColor(Color.fromARGB(255, (r / w).round(), (g / w).round(), (b / w).round()));
      _cols[t.path] = h.withLightness(h.lightness.clamp(.18, .42).toDouble()).toColor(); notifyListeners();
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
  void reset() { sp.remove('d'); name = 'Alex'; avatar = null; swipe = 'skip'; accent = 0; skin = 0; tab = 0; npStyle = -1; artShape = 0; glow = true; spinArt = true; viz = false; remain = false; dbl = true; badgeOn = false; fadeIn = false; miniProg = true; eqOn = false; dyn = false; pbg = 0; sliderStyle = 0; lyricsCard = true; pitch = 1; slim = false; shuffle = false; repeat = 0; haptics = true; showVol = true; resume = true; stopOnClear = false; skipSilence = false; save(); notifyListeners(); toast('Settings reset'); }
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
    final f = t?.art, ok = f != null && File(f).existsSync(), rr = r ?? (s > 100 ? app.sk.artR : min(app.sk.artR, 6.0));
    return ClipRRect(
      borderRadius: BorderRadius.circular(rr),
      child: Container(
        width: s, height: s, color: tint(t?.title ?? 'x', .25),
        child: ok ? Image.file(File(f), fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: s.isFinite ? (s * 3).toInt().clamp(120, 900) : 600) : Icon(Icons.music_note, color: Colors.white54, size: s * .4),
      ),
    );
  }
}

Widget avatar(double r) {
  final has = app.avatar != null && File(app.avatar!).existsSync();
  return CircleAvatar(
    radius: r, backgroundColor: gr, backgroundImage: has ? FileImage(File(app.avatar!)) : null,
    child: has ? null : Text(app.name.isEmpty ? '?' : app.name[0].toUpperCase(), style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: r * .9)),
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))), builder: b);

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

void trackMenu(BuildContext c, Track t, {String? inList}) => sheet(c, (s) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: Art(t, 48), title: tx(t.title, f: FontWeight.w700), subtitle: tx(t.artist, c: grey, z: 13)),
      const Divider(color: Colors.white12),
      opt(app.liked.contains(t.path) ? Icons.check_circle : Icons.add_circle_outline, app.liked.contains(t.path) ? 'Remove from Liked Songs' : 'Add to Liked Songs', () { app.like(t); Navigator.pop(s); }, c: app.liked.contains(t.path) ? gr : Colors.white),
      opt(Icons.playlist_add, 'Add to playlist', () { Navigator.pop(s); pickList(c, t); }),
      opt(Icons.queue_music, 'Play next', () { app.playNext(t); Navigator.pop(s); }),
      opt(Icons.add_to_queue, 'Add to queue', () { app.enqueue(t); Navigator.pop(s); }),
      if (inList != null) opt(Icons.remove_circle_outline, 'Remove from this playlist', () { app.toggleIn(inList, t); Navigator.pop(s); }),
    ])));

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
      onTap: () { tap(); app.playAt(list, i); },
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
        Widget item(int i) {
          final n = s.nav[i], on = t == i && n.k != 'create', col = on ? (s.navAcc ? gr : Colors.white) : grey;
          return Expanded(child: InkWell(onTap: () { tap(); n.k == 'create' ? create(c) : app.goTab(i); }, child: SizedBox(height: app.slim ? 48 : 58, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 3), decoration: s.pill && on ? BoxDecoration(color: gr.withOpacity(.18), borderRadius: BorderRadius.circular(16)) : null, child: Icon(on ? n.a : n.i, color: col, size: 26)),
            if (!app.slim) tx(n.l, z: 11, c: col),
          ]))));
        }
        return Scaffold(
          body: SafeArea(bottom: false, child: IndexedStack(index: t, children: [for (final n in s.nav) page(n.k)])),
          bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
            if (app.cur != null) const Mini(),
            Container(
              decoration: s.name == 'Spotify' ? BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withOpacity(.85), Colors.black])) : BoxDecoration(color: s.home == 3 ? card : bg, border: const Border(top: BorderSide(color: Colors.white10))),
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
    final t = app.cur!, m = app.sk.mini, lk = app.liked.contains(t.path), fl = m == 0 || m == 1 || m == 6, top = m == 3 || m == 4;
    final bgc = m == 0 ? app.colorOf(t) : m == 1 ? const Color(0xFF2C2C2E) : card;
    final showLike = m == 0 || m == 3 || m == 6, showNext = m == 1 || m == 2 || m == 4 || m == 5;
    final prog = !app.miniProg || m == 1 ? const SizedBox() : Padding(
      padding: fl ? const EdgeInsets.fromLTRB(10, 0, 10, 4) : EdgeInsets.zero,
      child: StreamBuilder<Duration>(stream: app.p.positionStream, builder: (_, s) {
        final d = app.p.duration?.inMilliseconds ?? 1;
        return LinearProgressIndicator(value: ((s.data?.inMilliseconds ?? 0) / max(d, 1)).clamp(0.0, 1.0), minHeight: 2, backgroundColor: Colors.white24, color: m == 0 ? Colors.white : gr);
      }),
    );
    final body = GestureDetector(
      onTap: () => openNP(c),
      onHorizontalDragEnd: app.swipe == 'skip' ? (d) { final v = d.primaryVelocity ?? 0; if (v < -250) { app.next(); } else if (v > 250) { app.prev(); } } : null,
      child: Container(
        margin: fl ? const EdgeInsets.fromLTRB(8, 0, 8, 6) : EdgeInsets.zero,
        decoration: BoxDecoration(color: bgc, borderRadius: BorderRadius.circular(fl ? (m == 6 ? 14.0 : m == 1 ? 12.0 : 8.0) : 0.0), border: m == 6 ? Border.all(color: gr.withOpacity(.5)) : null),
        child: Column(children: [
          if (top) prog,
          Padding(padding: EdgeInsets.fromLTRB(8, 8, 4, fl && m != 1 ? 6 : 8), child: Row(children: [
            Art(t, m <= 1 ? 40 : 46), const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx(t.title, f: FontWeight.w700, z: 13), tx(t.artist, c: Colors.white70, z: 12)])),
            if (showLike) IconButton(icon: Icon(app.sk.name == 'Spotify' ? (lk ? Icons.check_circle : Icons.add_circle_outline) : (lk ? Icons.favorite : Icons.favorite_border), color: lk ? gr : Colors.white), onPressed: () => app.like(t)),
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

class Seek extends StatefulWidget { final int sty; final bool acc; const Seek(this.sty, this.acc, {super.key}); @override State<Seek> createState() => _SeekState(); }
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
              child: CustomPaint(size: Size(bc.maxWidth, 34), painter: Bars(v / mx, app.cur?.path.hashCode ?? 1, a, s == 5)),
            );
          });
        } else {
          bar = Stack(alignment: Alignment.center, children: [
            if (wavy) Positioned.fill(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: CustomPaint(painter: Wave(v / mx, pos.inMilliseconds / 140, a)))),
            SliderTheme(
              data: SliderTheme.of(c).copyWith(trackHeight: thick ? 8 : slim ? 2 : 4, activeTrackColor: wavy ? Colors.transparent : a, inactiveTrackColor: wavy ? Colors.transparent : Colors.white24, thumbColor: wavy ? a : Colors.white, thumbShape: RoundSliderThumbShape(enabledThumbRadius: slim || thick ? 0 : 6)),
              child: Slider(value: v, max: mx, onChanged: (x) => setState(() => drag = x), onChangeEnd: (x) { app.p.seek(Duration(milliseconds: x.toInt())); setState(() => drag = null); }),
            ),
          ]);
        }
        return Column(children: [
          SizedBox(height: 34, child: bar),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            tx(fmt(left), z: 12, c: Colors.white70),
            GestureDetector(onTap: () => app.set(() => app.remain = !app.remain), child: tx(app.remain ? '-${fmt(dur > left ? dur - left : Duration.zero)}' : fmt(dur), z: 12, c: Colors.white70)),
          ])),
        ]);
      });
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

  @override
  Widget build(BuildContext c) => ListenableBuilder(
        listenable: app,
        builder: (_, __) {
          final t = app.cur;
          if (t == null) { WidgetsBinding.instance.addPostFrameCallback((_) { if (c.mounted && Navigator.canPop(c)) Navigator.pop(c); }); return const SizedBox(); }
          final L = app.npl, col = app.colorOf(t), lk = app.liked.contains(t.path), mq = MediaQuery.of(c), w = mq.size.width, cen = L.center;
          final hasArt = t.art != null && File(t.art!).existsSync(), lines = app.lyricsOf(t), bm = app.pbg == 0 ? L.bg : app.pbg - 1;
          final fullArt = L.art == 3 && hasArt, al = cen ? CrossAxisAlignment.center : CrossAxisAlignment.start, ta = cen ? TextAlign.center : TextAlign.left;
          final ac = L.acc ? gr : Colors.white, sty = app.sliderStyle == 0 ? L.seek : app.sliderStyle - 1;
          Widget pd(Widget x) => Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: x);
          double rad(double s, double def) => app.artShape == 1 ? 0.0 : app.artShape == 2 ? 18.0 : app.artShape == 3 ? s / 2 : def;
          IconData likeI() => switch (L.name) { 'Apple Music' => lk ? Icons.star : Icons.star_border, 'YouTube Music' => lk ? Icons.thumb_up : Icons.thumb_up_outlined, 'Spotify' => lk ? Icons.check_circle : Icons.add_circle_outline, _ => lk ? Icons.favorite : Icons.favorite_border };

          Widget bgL() => Stack(fit: StackFit.expand, children: [
                if (fullArt) Image.file(File(t.art!), fit: BoxFit.cover) else if (bm == 1 && hasArt) ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 45, sigmaY: 45), child: Image.file(File(t.art!), fit: BoxFit.cover)),
                DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, stops: const [0, .8], colors: fullArt ? [Colors.black26, Colors.black.withOpacity(.92)] : switch (bm) { 1 => [Colors.black26, Colors.black.withOpacity(.88)], 2 => [bg, bg], 3 => [gr.withOpacity(.55), bg], 4 => [Colors.black, Colors.black], _ => [col, bg] }))),
              ]);

          Widget wrapArt(Widget a, double s) => GestureDetector(
                onHorizontalDragEnd: app.swipeArt ? (d) { final v = d.primaryVelocity ?? 0; if (v < -250) { app.next(); } else if (v > 250) { app.prev(); } } : null,
                onDoubleTapDown: app.dbl ? (d) { _dx = d.localPosition.dx; _aw = s; } : null,
                onDoubleTap: app.dbl ? () { final p = app.p.position; final back = _dx < _aw / 2; app.p.seek(back ? (p.inSeconds > 10 ? p - const Duration(seconds: 10) : Duration.zero) : p + const Duration(seconds: 10)); toast(back ? '−10 s' : '+10 s'); } : null,
                child: a,
              );
          Widget pop(Widget a) => StreamBuilder<bool>(stream: app.p.playingStream, initialData: false, builder: (_, p) => AnimatedScale(scale: p.data! ? 1 : .9, duration: const Duration(milliseconds: 250), curve: Curves.easeOut, child: Container(decoration: BoxDecoration(boxShadow: [BoxShadow(color: app.glow ? gr.withOpacity(.4) : Colors.black.withOpacity(.45), blurRadius: 30, offset: const Offset(0, 12))]), child: a)));
          Widget vinyl(double s) {
            final disc = Container(width: s, height: s, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF0D0D0D), boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 24)]), child: Stack(alignment: Alignment.center, children: [
              for (final f in [.95, .84, .73]) Container(width: s * f, height: s * f, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white10))),
              Art(t, s * .5, r: s * .25), Container(width: s * .05, height: s * .05, decoration: BoxDecoration(color: bg, shape: BoxShape.circle)),
            ]));
            return app.spinArt ? RotationTransition(turns: spin, child: disc) : disc;
          }
          Widget artBlock() {
            switch (L.art) {
              case 1: return wrapArt(Art(t, w, r: rad(w, 0)), w);
              case 2: { final s = min(w - 70, 330.0); return wrapArt(vinyl(s), s); }
              case 3: return SizedBox(height: max(mq.size.height * .3, 140));
              case 4: return wrapArt(pop(Art(t, 150, r: rad(150, 24))), 150);
              case 5: return const SizedBox(height: 60);
              default: { final s = min(w - 40, 420.0); return pd(wrapArt(pop(Art(t, s, r: rad(s, app.sk.artR + 2))), s)); }
            }
          }

          final top = Row(children: [
            IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 32), onPressed: () => Navigator.pop(c)),
            Expanded(child: L.tabs
                ? Center(child: Container(padding: const EdgeInsets.all(3), decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(20)), child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(18)), child: tx('Song', f: FontWeight.w700, z: 13)),
                    GestureDetector(onTap: () => toast('Video is not available for local files'), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6), child: tx('Video', c: grey, f: FontWeight.w700, z: 13))),
                  ])))
                : Column(children: [tx(L.name == 'Spotify' ? 'PLAYING FROM YOUR LIBRARY' : 'NOW PLAYING', z: 10, c: Colors.white70, f: FontWeight.w700, a: TextAlign.center), tx(t.album, z: 13, f: FontWeight.w700, a: TextAlign.center)])),
            IconButton(icon: const Icon(Icons.more_vert), onPressed: () => trackMenu(c, t)),
          ]);

          final info = Row(children: [
            if (cen) const SizedBox(width: 48),
            Expanded(child: Column(crossAxisAlignment: al, children: [
              if (app.badgeOn || L.name == 'TIDAL') Container(margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(border: Border.all(color: gr), borderRadius: BorderRadius.circular(4)), child: tx(badge(t), z: 10, f: FontWeight.w800, c: gr)),
              tx(t.title, z: L.art == 5 ? 32 : 24, f: FontWeight.w800, a: ta, lines: L.art == 5 ? 3 : 1),
              const SizedBox(height: 2), tx(t.artist, z: 16, c: L.name == 'TIDAL' ? gr : Colors.white70, a: ta),
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
            ib(Icons.tune, () => sheet(c, (_) => const TuneSheet()), z: 22, c: app.speed != 1 || app.pitch != 1 ? gr : Colors.white),
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

class TuneSheet extends StatelessWidget {
  const TuneSheet({super.key});
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) => SafeArea(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [tx('Speed', z: 16, f: FontWeight.w800), const Spacer(), tx('${app.speed.toStringAsFixed(2)}x', c: grey)]),
        Slider(value: app.speed, min: .5, max: 2, divisions: 30, onChanged: app.setSpeed),
        Wrap(spacing: 8, children: [for (final s in speeds) ChoiceChip(label: Text('${s}x'), selected: app.speed == s, selectedColor: gr, labelStyle: TextStyle(color: app.speed == s ? Colors.black : Colors.white), onSelected: (_) => app.setSpeed(s))]),
        const SizedBox(height: 8),
        Row(children: [tx('Pitch', z: 16, f: FontWeight.w800), const Spacer(), tx('${app.pitch.toStringAsFixed(2)}x', c: grey)]),
        Slider(value: app.pitch, min: .5, max: 1.5, divisions: 20, onChanged: app.setPitch),
        TextButton(onPressed: () { app.setSpeed(1); app.setPitch(1); }, child: Text('Reset', style: TextStyle(color: gr))),
      ]))));
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
List<Card2> mixCards(List<Track> all) => [for (var n = 1; n <= 3; n++) () { final l = mix(all, n); return Card2('Daily Mix $n', l.take(3).map((e) => e.artist).toSet().join(', '), l.first, () => app.playAt(l, 0)); }()];
Widget emptyHome() => Padding(padding: const EdgeInsets.all(40), child: Column(children: [
      Icon(app.scanning ? Icons.hourglass_top : Icons.library_music, size: 64, color: grey), const SizedBox(height: 12),
      tx(app.scanning ? 'Scanning your music…' : 'No songs yet', z: 20, f: FontWeight.w800), const SizedBox(height: 12),
      if (!app.scanning) FilledButton(style: FilledButton.styleFrom(backgroundColor: gr, foregroundColor: Colors.black), onPressed: app.scan, child: const Text('Scan device')),
    ]));

class HomePage extends StatefulWidget { const HomePage({super.key}); @override State<HomePage> createState() => _HomeState(); }
class _HomeState extends State<HomePage> {
  int chip = 0;
  Widget tile(String t, Track? a, VoidCallback f, {IconData? icon}) => GestureDetector(
        onTap: () { tap(); f(); },
        child: Container(decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(4)), clipBehavior: Clip.antiAlias, child: Row(children: [
          icon != null ? Container(width: 56, height: 56, decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF4510E0), Color(0xFF9B8DD8)])), child: Icon(icon, color: Colors.white)) : Art(a, 56, r: 0),
          const SizedBox(width: 10), Expanded(child: tx(t, f: FontWeight.w700, z: 13, lines: 2)), const SizedBox(width: 6),
        ])),
      );
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final all = app.sorted, rec = app.recentTracks, most = app.mostPlayed, sk = app.sk, hv = sk.home, w = MediaQuery.of(c).size.width, hr = DateTime.now().hour;
        final src = chip == 2 ? app.likedTracks : (rec.isEmpty ? all : rec);
        final added = [...app.tracks]..sort((a, b) => b.added.compareTo(a.added));
        void open(String t, List<Track> Function() f, {String? list}) => Navigator.push(c, MaterialPageRoute(builder: (_) => ListPage(t, f, list: list)));
        final recS = shelf('Recently played', recCards(rec)), mixS = shelf('Made for ${app.name}', all.isEmpty ? [] : mixCards(all));
        final topS = shelf('Your top songs', [for (var i = 0; i < most.length && i < 12; i++) Card2(most[i].title, '${app.plays[most[i].path]} plays', most[i], () => app.playAt(most, i))]);
        final newS = shelf('Recently added', [for (var i = 0; i < added.length && i < 12; i++) Card2(added[i].title, added[i].artist, added[i], () => app.playAt(added, i))]);
        final plS = shelf('Your playlists', [for (final n in app.lists.keys) Card2(n, '${app.lists[n]!.length} songs', app.toTracks(app.lists[n]!).firstOrNull, () => open(n, () => app.toTracks(app.lists[n] ?? []), list: n))]);
        final tc = app.cur != null ? app.colorOf(app.cur!) : (all.isNotEmpty ? app.colorOf(all.first) : bg);
        List<Widget> kids;
        if (all.isEmpty) {
          kids = [head(c, sk.title), emptyHome()];
        } else if (hv == 1) {
          final m1 = mix(all, 1);
          kids = [
            head(c, 'Listen Now'), const Divider(color: Colors.white12, height: 1),
            Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              tx('MADE FOR ${app.name.toUpperCase()}', z: 12, c: grey, f: FontWeight.w700), tx('Top Picks', z: 22, f: FontWeight.w800), const SizedBox(height: 10),
              GestureDetector(onTap: () => app.playAt(m1, 0), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Stack(children: [
                Art(m1.first, w - 32, r: 0),
                Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withOpacity(.75)])))),
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
        } else if (hv == 4) {
          final h0 = added.first, ha = h0.art;
          kids = [
            head(c, 'Home'),
            GestureDetector(onTap: () => app.playAt(added, 0), child: SizedBox(height: 300, child: Stack(fit: StackFit.expand, children: [
              ha != null && File(ha).existsSync() ? Image.file(File(ha), fit: BoxFit.cover) : Container(color: tint(h0.title, .3)),
              const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black45, Colors.transparent, Colors.black]))),
              Positioned(left: 16, right: 16, bottom: 16, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx('NEW IN YOUR LIBRARY', z: 11, c: gr, f: FontWeight.w800), const SizedBox(height: 4), tx(h0.title, z: 26, f: FontWeight.w900, lines: 2), tx(h0.artist, c: Colors.white70)])),
            ]))),
            recS, mixS, topS, newS, plS,
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
        } else if (hv == 6) {
          kids = [
            head(c, 'Home'),
            Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: GestureDetector(onTap: () => app.shufflePlay(all), child: Container(height: 150, padding: const EdgeInsets.all(20), decoration: BoxDecoration(gradient: LinearGradient(colors: [gr, const Color(0xFFFF4D8D)]), borderRadius: BorderRadius.circular(16)), child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [tx('Flow', z: 36, f: FontWeight.w900), tx('Your personal soundtrack', z: 13, c: Colors.white70)])),
              Container(width: 64, height: 64, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle), child: const Icon(Icons.play_arrow, color: Colors.black, size: 40)),
            ])))),
            recS, mixS, topS, newS, plS,
          ];
        } else {
          final shortcuts = <Widget>[
            tile('Liked Songs', null, () => open('Liked Songs', () => app.likedTracks), icon: Icons.favorite),
            for (final n in app.lists.keys.take(3)) tile(n, app.toTracks(app.lists[n]!).firstOrNull, () => open(n, () => app.toTracks(app.lists[n] ?? []), list: n)),
            for (var i = 0; i < src.length && i < 8; i++) tile(src[i].title, src[i], () => app.playAt(src, i)),
          ].take(8).toList();
          kids = [
            Padding(padding: const EdgeInsets.fromLTRB(16, 12, 8, 14), child: Row(children: [
              GestureDetector(onTap: () => openProfile(c), child: avatar(17)), const SizedBox(width: 12),
              for (final (i, l) in ['All', 'Music', 'Liked'].indexed) Padding(padding: const EdgeInsets.only(right: 8), child: GestureDetector(onTap: () => setState(() => chip = i), child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7), decoration: BoxDecoration(color: chip == i ? gr : card, borderRadius: BorderRadius.circular(20)), child: tx(l, c: chip == i ? Colors.black : Colors.white, f: FontWeight.w600, z: 13)))),
            ])),
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: tx(hr < 12 ? 'Good morning' : hr < 18 ? 'Good afternoon' : 'Good evening', z: 22, f: FontWeight.w800)),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: GridView.count(crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 3.1, children: shortcuts)),
            recS, mixS, topS, newS,
          ];
        }
        return Container(
          decoration: BoxDecoration(color: bg, gradient: hv == 0 || hv == 6 ? LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [hv == 0 ? tc.withOpacity(.6) : gr.withOpacity(.3), bg], stops: const [0, .38]) : null),
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
            for (var n = 1; n <= 5; n++) () { final l = mix(all, n); return row('Daily Mix $n', l.take(3).map((e) => e.artist).toSet().join(', '), l.first, () => app.playAt(l, 0)); }(),
            for (final e in ar.entries.take(10)) row('${e.key} Radio', '${e.value.length} songs', e.value.first, () => app.playAt(([...e.value]..shuffle()), 0)),
          ],
        ]);
      });
}

// ───────────── search ─────────────
class SearchPage extends StatefulWidget { const SearchPage({super.key}); @override State<SearchPage> createState() => _SearchState(); }
class _SearchState extends State<SearchPage> {
  final ctl = TextEditingController();
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final q = ctl.text.toLowerCase().trim(), sp = app.sk.name == 'Spotify';
        final res = q.isEmpty ? <Track>[] : app.tracks.where((t) => '${t.title} ${t.artist} ${t.album}'.toLowerCase().contains(q)).toList();
        final names = {...app.tracks.map((t) => t.artist), ...app.tracks.map((t) => t.album)}.toList();
        return Column(children: [
          head(c, navLabel('search')),
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 10), child: TextField(controller: ctl, onChanged: (_) => setState(() {}), style: TextStyle(color: sp ? Colors.black : Colors.white, fontWeight: FontWeight.w600), cursorColor: sp ? Colors.black : gr, decoration: InputDecoration(filled: true, fillColor: sp ? Colors.white : card, hintText: app.sk.hint, hintStyle: TextStyle(color: sp ? const Color(0xFF535353) : grey, fontWeight: FontWeight.w600), prefixIcon: Icon(Icons.search, color: sp ? Colors.black : grey), suffixIcon: q.isEmpty ? null : IconButton(icon: Icon(Icons.close, color: sp ? Colors.black : grey), onPressed: () => setState(ctl.clear)), border: OutlineInputBorder(borderRadius: BorderRadius.circular(sp ? 6 : 24), borderSide: BorderSide.none)))),
          Expanded(child: q.isNotEmpty
              ? (res.isEmpty ? Center(child: tx('No results for "$q"', z: 16, f: FontWeight.w700)) : ListView.builder(itemCount: res.length, itemBuilder: (_, i) => TTile(res[i], res, i)))
              : ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
                  tx('Browse all', z: 16, f: FontWeight.w800), const SizedBox(height: 12),
                  GridView.count(crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.7, children: [
                    for (final n in names) GestureDetector(onTap: () => setState(() => ctl.text = n), child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: tint(n, .4), borderRadius: BorderRadius.circular(app.sk.artR.clamp(2, 12).toDouble())), child: tx(n, z: 16, f: FontWeight.w800, lines: 2))),
                  ]),
                ])),
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
          if (chip == 3) for (var i = 0; i < srt.length; i++) Card2(srt[i].title, srt[i].artist, srt[i], () => app.playAt(srt, i)),
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
            Center(child: Art(l.firstOrNull, 190, r: 6)), const SizedBox(height: 16),
            Align(alignment: Alignment.centerLeft, child: tx(title, z: 24, f: FontWeight.w800, lines: 2)),
            Align(alignment: Alignment.centerLeft, child: tx('${l.length} songs', c: grey, z: 13)),
            Row(children: [
              IconButton(icon: const Icon(Icons.shuffle), onPressed: () => app.shufflePlay(l)),
              if (pl != null) ...[
                IconButton(icon: const Icon(Icons.edit_outlined), tooltip: 'Rename', onPressed: () async { final n = await ask(c, 'Rename playlist', title); if (n == null) return; if (app.rename(pl, n)) { setState(() => title = n.trim()); } else { toast('Name is empty or already used'); } }),
                IconButton(icon: Icon(Icons.swap_vert, color: reorder ? gr : Colors.white), tooltip: 'Reorder', onPressed: () => setState(() => reorder = !reorder)),
                IconButton(icon: const Icon(Icons.playlist_add), tooltip: 'Add songs', onPressed: () => sheet(c, (_) => ListenableBuilder(listenable: app, builder: (_, __) => ListView(children: [for (final t in app.sorted) CheckboxListTile(activeColor: gr, secondary: Art(t, 44), title: tx(t.title), subtitle: tx(t.artist, c: grey, z: 12), value: (app.lists[title] ?? []).contains(t.path), onChanged: (_) => app.toggleIn(title, t))])), big: true)),
                IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete', onPressed: () { app.deleteList(title); Navigator.pop(c); }),
              ],
              const Spacer(),
              GestureDetector(onTap: l.isEmpty ? null : () { tap(); app.playAt(l, 0); }, child: Container(width: 54, height: 54, decoration: BoxDecoration(color: gr, shape: BoxShape.circle), child: const Icon(Icons.play_arrow, color: Colors.black, size: 34))),
            ]),
          ]),
        );
        return Scaffold(body: SafeArea(child: reorder && pl != null
            ? ReorderableListView.builder(
                header: header, itemCount: l.length, onReorder: (o, n) => app.reorderList(title, o, n),
                itemBuilder: (_, i) => ListTile(key: ValueKey('${l[i].path}$i'), leading: Art(l[i], 48), title: tx(l[i].title, f: FontWeight.w600), subtitle: tx(l[i].artist, c: grey, z: 13), trailing: const Icon(Icons.drag_handle, color: grey)),
              )
            : ListView.builder(padding: const EdgeInsets.only(bottom: 20), itemCount: l.length + 1, itemBuilder: (_, i) => i == 0 ? header : TTile(l[i - 1], l, i - 1, inList: pl))));
      });
}

// ───────────── profile drawer ─────────────
void openProfile(BuildContext c) {
  tap();
  void go(Widget w) => Navigator.push(c, MaterialPageRoute(builder: (_) => w));
  final items = <(IconData, String, VoidCallback)>[
    (Icons.insights_outlined, 'Listening stats', () => go(const StatsPage())),
    (Icons.palette_outlined, 'Themes & Mods', () => go(SPage('Themes & Mods', themesS))),
    (Icons.slideshow, 'Player styles', () => go(SPage('Player styles', playerS))),
    (Icons.history, 'Recents', () => go(ListPage('Recents', () => app.recentTracks))),
    (Icons.favorite_border, 'Liked Songs', () => go(ListPage('Liked Songs', () => app.likedTracks))),
    (Icons.settings_outlined, 'Settings and privacy', () => go(const SettingsPage())),
  ];
  Navigator.push(c, PageRouteBuilder(
    opaque: false, barrierDismissible: true, barrierColor: Colors.black.withOpacity(.6),
    pageBuilder: (ctx, __, ___) => Align(alignment: Alignment.centerLeft, child: Material(color: bg, child: SizedBox(width: MediaQuery.of(ctx).size.width * .84, height: double.infinity, child: SafeArea(child: ListView(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 22, 20, 12), child: Row(children: [avatar(28), const SizedBox(width: 16), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx(app.name, z: 20, f: FontWeight.w800), tx('View profile', c: grey)])])),
      Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 0), child: tx('APP SKIN', z: 11, c: grey, f: FontWeight.w800)),
      skinDrop(),
      const Divider(color: Colors.white12),
      for (final it in items) InkWell(onTap: () { Navigator.pop(ctx); it.$3(); }, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15), child: Row(children: [Icon(it.$1, size: 26), const SizedBox(width: 18), tx(it.$2, z: 16)]))),
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
      srow('Equalizer', sub: app.eqOn ? 'On' : 'Off', icon: Icons.equalizer, f: () => sheet(c, (_) => const EqSheet(), big: true)),
      srow('A–B loop', sub: app.la == null ? 'Tap to set loop start' : app.lb == null ? 'Tap to set loop end' : 'Looping • tap to clear', icon: Icons.loop, f: app.abLoop),
      sw('Fade in on play', 'Volume ramps up when a song starts', app.fadeIn, (v) => app.set(() => app.fadeIn = v)),
      sw('Shuffle', 'Play queues in random order', app.shuffle, (v) => app.set(() => app.shuffle = v)),
      srow('Repeat', sub: ['Off', 'Repeat all', 'Repeat one'][app.repeat], icon: Icons.repeat, f: () => app.set(() => app.repeat = (app.repeat + 1) % 3)),
      srow('Speed & pitch', sub: '${app.speed.toStringAsFixed(2)}x speed • ${app.pitch.toStringAsFixed(2)}x pitch', icon: Icons.tune, f: () => sheet(c, (_) => const TuneSheet())),
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
      srow('Pixel Audio Player', sub: 'Version 4.0.0'),
      srow('Skins', sub: skins.map((s) => s.name).join(', '), icon: Icons.palette_outlined),
      srow('Player styles', sub: npls.map((s) => s.name).join(', '), icon: Icons.slideshow),
      srow('Mods included', sub: 'Equalizer, A–B loop, fade in, visualizer, waveform seek bar, vinyl mode, double-tap seek, accent colors, dynamic accent, synced lyrics (.lrc), pitch, loudness boost, persistent queue, backups and stats.', icon: Icons.extension_outlined),
    ];

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext c) {
    final cats = <(IconData, String, String, List<Widget> Function(BuildContext))>[
      (Icons.person_outline, 'Account', 'Name and profile picture', accountS),
      (Icons.palette_outlined, 'Themes & Mods', 'App skin, accent, layout', themesS),
      (Icons.slideshow, 'Player styles', '11 players, backgrounds, progress bars', playerS),
      (Icons.play_circle_outline, 'Playback', 'Equalizer, A–B loop, speed, sleep timer', playbackS),
      (Icons.library_music_outlined, 'Your library', 'Scan folders and add songs', libraryS),
      (Icons.insights_outlined, 'Listening stats', 'Top songs and artists', (_) => const []),
      (Icons.storage_outlined, 'Backup & storage', 'Backup, restore and clear data', dataS),
      (Icons.info_outline, 'About', 'Version and included mods', aboutS),
    ];
    return ListenableBuilder(listenable: app, builder: (_, __) => Scaffold(
          appBar: AppBar(backgroundColor: bg, surfaceTintColor: Colors.transparent, centerTitle: true, title: const Text('Settings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
          body: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: Row(children: [avatar(30), const SizedBox(width: 14), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx(app.name, z: 20, f: FontWeight.w800), tx('View profile', c: grey)])])),
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
