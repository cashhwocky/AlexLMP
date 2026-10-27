// FILE: custom/main.dart — Pixel Audio Player 4.0 (TIDAL & Spotify Only + Fixed Pitch + AudioSource Headers)
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

// ───────────── skins (TIDAL & Spotify only) ─────────────
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
];

class NPL {
  final String name; final int art, bg, seek; final bool center, plain, vol, tabs, viz, acc, ring;
  const NPL(this.name, {this.art = 0, this.bg = 0, this.seek = 0, this.center = false, this.plain = false, this.vol = false, this.tabs = false, this.viz = false, this.acc = false, this.ring = false});
}
const npls = [
  NPL('Spotify'),
  NPL('TIDAL', art: 0, bg: 0, seek: 2, plain: true),
];
const accents = <Color?>[null, Color(0xFF1ED760), Color(0xFFFFD43B), Color(0xFF5B8CFF), Color(0xFFFF7EB6)];
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
  int repeat = 0, accent = 0; double speed = 1, pitch = 1, vol = 1; DateTime? sleepAt; Timer? _sleep;
  int pbg = 0, sliderStyle = 0, tab0 = 0, pqi = 0, _errs = 0;
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
      await p.setAudioSource(
        AudioSource.uri(
          Uri.parse(path),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': '*/*',
            'Accept-Language': 'en-US,en;q=0.9',
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
          decoration: BoxDecoration(color: dom, borderRadius: BorderRadius.circular(8)),
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
                              Flexible(child: tx('${app.outName.isEmpty ? 'ALEXWIN11PRO' : app.outName} • Lossless', z: 11.5, c: spGreen, f: FontWeight.w600)),
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
                      icon: Icon(lk ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded, color: lk ? spGreen : Colors.white, size: 25),
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
    return const SizedBox();
  }
}

Color lift(Color c) => HSLColor.fromColor(c).withLightness(.34).withSaturation(.55).toColor();
int lyricIdx(List<(Duration, String)> l, Duration p) { var r = -1; for (var i = 0; i < l.length; i++) { if (l[i].$1 <= p) { r = i; } else { break; } } return r; }

class Seek extends StatefulWidget {
  final int sty; final bool acc; final bool showMaxBadge; final double? customThumbRadius, customTrackHeight;
  const Seek(this.sty, this.acc, {this.showMaxBadge = false, this.customThumbRadius, this.customTrackHeight, super.key});
  @override State<Seek> createState() => _SeekState();
}

class _SeekState extends State<Seek> {
  double? drag;
  @override
  Widget build(BuildContext c) => StreamBuilder<Duration>(stream: app.p.positionStream, builder: (_, sn) {
        final dur = app.p.duration ?? Duration.zero, pos = sn.data ?? Duration.zero;
        final mx = max(dur.inMilliseconds.toDouble(), 1.0), v = (drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, mx).toDouble();
        final s = widget.sty, a = widget.acc ? gr : Colors.white;
        final left = Duration(milliseconds: v.toInt());
        final th = widget.customTrackHeight ?? 3.5, tr = widget.customThumbRadius ?? 5.5;
        final bar = Stack(alignment: Alignment.center, children: [
          SliderTheme(
            data: SliderTheme.of(c).copyWith(
              trackHeight: th,
              activeTrackColor: a,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              thumbShape: tr <= 0 ? SliderComponentShape.noThumb : RoundSliderThumbShape(enabledThumbRadius: tr),
            ),
            child: Slider(value: v, max: mx, onChanged: (x) => setState(() => drag = x), onChangeEnd: (x) { app.p.seek(Duration(milliseconds: x.toInt())); setState(() => drag = null); }),
          ),
        ]);
        return Column(children: [
          SizedBox(height: 26, child: bar),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                tx(fmt(left), z: 12, c: const Color(0xFF9E9E9E), f: FontWeight.w600),
                if (widget.showMaxBadge)
                  GestureDetector(
                    onTap: () => sheet(c, (_) => const TuneSheet(), big: true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 3.5),
                      decoration: BoxDecoration(color: const Color(0xFF2B2210), borderRadius: BorderRadius.circular(6)),
                      child: const Text('MAX', style: TextStyle(color: tidalGold, fontSize: 10.5, fontWeight: FontWeight.w900)),
                    ),
                  ),
                tx(fmt(dur), z: 12, c: const Color(0xFF9E9E9E), f: FontWeight.w600),
              ],
            ),
          ),
        ]);
      });
}

class NowPlaying extends StatefulWidget { const NowPlaying({super.key}); @override State<NowPlaying> createState() => _NPState(); }
class _NPState extends State<NowPlaying> with SingleTickerProviderStateMixin {
  late final AnimationController spin = AnimationController(vsync: this, duration: const Duration(seconds: 14));
  StreamSubscription? _sub;
  @override
  void initState() {
    super.initState(); app.refreshOut();
    if (app.p.playing) spin.repeat();
    _sub = app.p.playingStream.listen((pl) { if (!mounted) return; if (pl) { spin.repeat(); } else { spin.stop(); } });
  }
  @override
  void dispose() { _sub?.cancel(); spin.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final t = app.cur;
        if (t == null) return const SizedBox();
        final lk = app.liked.contains(t.path), w = MediaQuery.of(c).size.width, artSize = w - 44;
        final col = app.colorOf(t);
        final topColor = HSLColor.fromColor(col).withLightness(.20).withSaturation(.65).toColor();

        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [topColor, Colors.black]))),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Column(
                    children: [
                      Row(children: [IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 32), onPressed: () => Navigator.pop(c)), const Spacer(), IconButton(icon: const Icon(Icons.more_vert), onPressed: () => trackMenu(c, t))]),
                      const Spacer(),
                      Art(t, artSize, r: 8),
                      const Spacer(),
                      Row(children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx(t.title, z: 22, f: FontWeight.w800), const SizedBox(height: 4), tx(t.artist, z: 15, c: grey)])),
                        IconButton(icon: Icon(lk ? Icons.favorite : Icons.favorite_border, color: lk ? tidalGold : Colors.white, size: 26), onPressed: () => app.like(t)),
                      ]),
                      const SizedBox(height: 14),
                      const Seek(2, false, showMaxBadge: true),
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(icon: Icon(CupertinoIcons.shuffle, color: app.shuffle ? Colors.white : grey, size: 24), onPressed: () => app.set(() => app.shuffle = !app.shuffle)),
                          IconButton(icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 44), onPressed: app.prev),
                          StreamBuilder<bool>(stream: app.p.playingStream, initialData: false, builder: (_, p) => GestureDetector(onTap: app.toggle, child: Icon(p.data! ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 64))),
                          IconButton(icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 44), onPressed: app.next),
                          IconButton(icon: Icon(app.repeat == 2 ? CupertinoIcons.repeat_1 : CupertinoIcons.repeat, color: app.repeat > 0 ? Colors.white : grey, size: 24), onPressed: () => app.set(() => app.repeat = (app.repeat + 1) % 3)),
                        ],
                      ),
                      const SizedBox(height: 30),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      });
}

// ───────────── HIGH-PRECISION STUDIO SPEED & PITCH ADJUSTER ─────────────
class TuneSheet extends StatelessWidget {
  const TuneSheet({super.key});
  @override
  Widget build(BuildContext c) => ListenableBuilder(
        listenable: app,
        builder: (_, __) {
          final st = app.semitones.clamp(-12.0, 12.0);
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [const Icon(Icons.tune_rounded, color: Colors.white, size: 22), const SizedBox(width: 10), tx('Speed & Pitch', z: 19, f: FontWeight.w800), const Spacer(), if (app.isTuned) TextButton.icon(onPressed: () => app.applyTunePreset(1.0, 1.0), icon: Icon(Icons.refresh_rounded, color: gr, size: 18), label: Text('Reset', style: TextStyle(color: gr, fontWeight: FontWeight.w800)))]),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [tx('Pitch Shift', z: 15.5, f: FontWeight.w800), const Spacer(), tx('${st.toStringAsFixed(1)} st • ${app.pitch.toStringAsFixed(2)}×', z: 12, c: gr, f: FontWeight.w800)]),
                        Slider(value: st, min: -12.0, max: 12.0, divisions: 240, activeColor: gr, onChanged: app.setSemitones),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [tx('Playback Speed', z: 15.5, f: FontWeight.w800), const Spacer(), tx('${app.speed.toStringAsFixed(2)}×', z: 12, c: gr, f: FontWeight.w800)]),
                        Slider(value: app.speed.clamp(0.5, 2.0), min: 0.5, max: 2.0, divisions: 150, activeColor: gr, onChanged: app.setSpeed),
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
            for (final b in ps.bands) Row(children: [
              SizedBox(width: 64, child: tx(b.centerFrequency >= 1000 ? '${(b.centerFrequency / 1000).toStringAsFixed(1)} kHz' : '${b.centerFrequency.round()} Hz', z: 12, c: grey)),
              Expanded(child: StreamBuilder<double>(stream: b.gainStream, initialData: b.gain, builder: (_, g) => Slider(min: ps.minDecibels, max: ps.maxDecibels, value: g.data!.clamp(ps.minDecibels, ps.maxDecibels).toDouble(), onChanged: b.setGain))),
            ]),
          ])));
        },
      ));
}

class LyricsPage extends StatelessWidget { const LyricsPage({super.key}); @override Widget build(BuildContext c) => const Scaffold(body: Center(child: Text('Lyrics'))); }
class QueueSheet extends StatelessWidget { const QueueSheet({super.key}); @override Widget build(BuildContext c) => const SizedBox(); }

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final all = app.sorted;
        if (all.isEmpty) return Scaffold(backgroundColor: bg, body: ListView(children: [head(c, 'Home'), emptyHome()]));
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            head(c, 'Home'),
            Padding(
              padding: const EdgeInsets.all(16),
              child: GestureDetector(
                onTap: () => app.shufflePlay(all),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(16)),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx('Your Library', z: 22, f: FontWeight.w800), tx('${all.length} tracks', c: grey)])),
                    Container(width: 50, height: 50, decoration: BoxDecoration(color: gr, shape: BoxShape.circle), child: const Icon(Icons.play_arrow, color: Colors.black)),
                  ]),
                ),
              ),
            ),
            for (var i = 0; i < all.length; i++) TTile(all[i], all, i),
          ],
        );
      });
}

Widget emptyHome() => Padding(padding: const EdgeInsets.all(40), child: Column(children: [
      Icon(Icons.library_music, size: 64, color: grey), const SizedBox(height: 12),
      tx('Search YouTube Music or scan local files', z: 18, f: FontWeight.w800, a: TextAlign.center), const SizedBox(height: 14),
      FilledButton(onPressed: app.scan, child: const Text('Scan local files')),
    ]));

class NewPage extends StatelessWidget { const NewPage({super.key}); @override Widget build(BuildContext c) => ListView(children: [head(c, 'Explore')]); }
class RadioPage extends StatelessWidget { const RadioPage({super.key}); @override Widget build(BuildContext c) => ListView(children: [head(c, 'Radio')]); }

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
    if (q.length < 2) { setState(() { ytRes = []; searchingYt = false; }); return; }
    setState(() => searchingYt = true);
    _deb = Timer(const Duration(milliseconds: 420), () async {
      final res = await app.searchYtMusic(q);
      if (mounted && ctl.text.trim() == q) { setState(() { ytRes = res; searchingYt = false; }); }
    });
  }

  @override
  void dispose() { _deb?.cancel(); ctl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final q = ctl.text.toLowerCase().trim();
        return Column(children: [
          head(c, 'Search'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: TextField(
              controller: ctl,
              onChanged: _onQueryChanged,
              decoration: InputDecoration(
                filled: true, fillColor: card,
                hintText: 'Search YouTube Music',
                prefixIcon: const Icon(Icons.search, color: grey),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (searchingYt) const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator())),
                for (final y in ytRes)
                  ListTile(
                    leading: Art(Track(y.art, y.title, y.artist, y.album, y.art, DateTime.now()), 48),
                    title: tx(y.title, f: FontWeight.w700),
                    subtitle: tx(y.artist, c: grey, z: 12.5),
                    trailing: const Icon(Icons.play_arrow_rounded, color: gr),
                    onTap: () => app.playYtSong(y),
                  ),
              ],
            ),
          ),
        ]);
      });
}

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final all = app.sorted;
        return Column(children: [
          head(c, 'Library', actions: [IconButton(icon: const Icon(Icons.add), onPressed: app.addFiles)]),
          Expanded(child: ListView(children: [for (var i = 0; i < all.length; i++) TTile(all[i], all, i)])),
        ]);
      });
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(backgroundColor: bg, title: const Text('Settings')),
        body: ListView(children: [
          srow('Rescan music files', icon: Icons.refresh, f: app.scan),
          srow('Clear cache', icon: Icons.cleaning_services, f: app.clearArt),
        ]),
      );
}

Widget srow(String t, {String? sub, VoidCallback? f, IconData? icon}) => ListTile(onTap: f, leading: icon == null ? null : Icon(icon, color: Colors.white), title: tx(t, z: 16), subtitle: sub == null ? null : tx(sub, c: grey, z: 13));

class StatsPage extends StatelessWidget {
  const StatsPage({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(appBar: AppBar(backgroundColor: bg, title: const Text('Stats')), body: const Center(child: Text('Listening Stats')));
}
