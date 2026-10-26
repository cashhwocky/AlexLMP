// FILE: custom/main.dart  — Pixel Audio Player 3.0 (Spotify-style rewrite)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ───────────── globals & helpers ─────────────
const ch = MethodChannel('pixelaudio/meta');
const bg = Color(0xFF121212);
const grey = Color(0xFFA7A7A7);
const accents = [Color(0xFF1ED760), Color(0xFF3B82F6), Color(0xFFEC4899), Color(0xFFF59E0B), Color(0xFFEF4444)];
const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
const exts = ['.mp3', '.wav', '.flac', '.m4a', '.ogg', '.aac', '.opus'];
final msg = GlobalKey<ScaffoldMessengerState>();
final app = AppState();
Color get gr => accents[app.accent];

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
  final p = AudioPlayer();
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
    p.processingStateStream.listen((s) { if (s == ProcessingState.completed) next(auto: true); });
    p.playingStream.listen((_) => notifyListeners());
    if (tracks.isEmpty) scan();
    final last = sp.getString('last');
    if (resume && last != null) {
      final t = byPath[last];
      if (t != null) { queue = [t]; idx = 0; try { await p.setFilePath(t.path); } catch (_) {} }
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
    } catch (_) {}
  }

  void save() => sp.setString('d', jsonEncode({
        'tracks': tracks.map((t) => t.toJson()).toList(), 'liked': liked.toList(), 'lists': lists, 'recent': recent.take(50).toList(),
        'plays': plays, 'name': name, 'avatar': avatar, 'swipe': swipe, 'sort': sort, 'haptics': haptics, 'showVol': showVol,
        'resume': resume, 'skip': skipSilence, 'stop': stopOnClear, 'grid': libGrid, 'accent': accent, 'shuffle': shuffle, 'repeat': repeat, 'dirs': dirs,
      }));
  void set(void Function() f) { f(); save(); notifyListeners(); }

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
  Future<void> _load() async {
    final t = cur; if (t == null) return;
    notifyListeners();
    try {
      await p.setFilePath(t.path);
      h.mediaItem.add(MediaItem(id: t.path, title: t.title, artist: t.artist, album: t.album, artUri: t.art != null ? Uri.file(t.art!) : null));
      await p.setSpeed(speed); await p.setVolume(vol); await p.setSkipSilenceEnabled(skipSilence);
      p.play();
    } catch (_) { toast('Cannot play ${t.title}'); }
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

  // ── library ──
  void like(Track t) => set(() { if (!liked.remove(t.path)) liked.add(t.path); });
  bool createList(String n) { n = n.trim(); if (n.isEmpty || lists.containsKey(n)) return false; set(() => lists[n] = []); return true; }
  bool rename(String o, String n) { n = n.trim(); if (n.isEmpty || (n != o && lists.containsKey(n))) return false; set(() { final l = lists.remove(o)!; lists[n] = l; }); return true; }
  void deleteList(String n) => set(() => lists.remove(n));
  void toggleIn(String n, Track t) => set(() { final l = lists[n]!; if (!l.remove(t.path)) l.add(t.path); });
  void reorderList(String n, int o, int nw) => set(() { if (nw > o) nw--; final l = lists[n]!; l.insert(nw, l.removeAt(o)); });
  void clearHistory() => set(() { recent.clear(); plays.clear(); });
  void clearArt() { try { for (final f in Directory(cache).listSync()) { if (f.path.contains('art_')) f.deleteSync(); } } catch (_) {} for (final t in tracks) { t.art = null; } set(() {}); toast('Artwork cache cleared'); }
  void reset() { sp.remove('d'); name = 'Alex'; avatar = null; swipe = 'skip'; accent = 0; shuffle = false; repeat = 0; haptics = true; showVol = true; resume = true; stopOnClear = false; skipSilence = false; save(); notifyListeners(); toast('Settings reset'); }
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
            useMaterial3: true, brightness: Brightness.dark, scaffoldBackgroundColor: bg,
            colorScheme: ColorScheme.dark(primary: gr, surface: bg),
            sliderTheme: SliderThemeData(trackHeight: 4, activeTrackColor: Colors.white, inactiveTrackColor: Colors.white24, thumbColor: Colors.white, overlayShape: SliderComponentShape.noOverlay, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
          ),
          home: const Shell(),
        ),
      );
}

// ───────────── shared widgets ─────────────
class Art extends StatelessWidget {
  final Track? t; final double s, r;
  const Art(this.t, this.s, {this.r = 4, super.key});
  @override
  Widget build(BuildContext context) {
    final f = t?.art;
    final ok = f != null && File(f).existsSync();
    return ClipRRect(
      borderRadius: BorderRadius.circular(r),
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

Widget head(BuildContext c, String title, {List<Widget> actions = const []}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
      child: Row(children: [
        GestureDetector(onTap: () => openProfile(c), child: avatar(16)),
        const SizedBox(width: 12),
        Expanded(child: tx(title, z: 24, f: FontWeight.w800)),
        ...actions,
      ]),
    );

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
class Shell extends StatefulWidget { const Shell({super.key}); @override State<Shell> createState() => _ShellState(); }
class _ShellState extends State<Shell> {
  int tab = 0;
  Widget nav(IconData i, String l, int n, {VoidCallback? f}) {
    final on = tab == n && f == null;
    return Expanded(child: InkWell(onTap: () { tap(); f != null ? f() : setState(() => tab = n); }, child: SizedBox(height: 58, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(i, color: on ? Colors.white : grey, size: 26), const SizedBox(height: 3), tx(l, z: 11, c: on ? Colors.white : grey)]))));
  }
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
  Widget build(BuildContext c) => ListenableBuilder(
        listenable: app,
        builder: (_, __) => Scaffold(
          body: SafeArea(bottom: false, child: IndexedStack(index: tab, children: const [HomePage(), SearchPage(), LibraryPage()])),
          bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
            if (app.cur != null) const Mini(),
            Container(
              decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withOpacity(.85), Colors.black])),
              child: SafeArea(top: false, child: Row(children: [
                nav(tab == 0 ? Icons.home_filled : Icons.home_outlined, 'Home', 0),
                nav(Icons.search, 'Search', 1),
                nav(tab == 2 ? Icons.library_music : Icons.library_music_outlined, 'Your Library', 2),
                nav(Icons.add, 'Create', 3, f: () => create(c)),
              ])),
            ),
          ]),
        ),
      );
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
    final t = app.cur!;
    final lk = app.liked.contains(t.path);
    final body = GestureDetector(
      onTap: () => openNP(c),
      onHorizontalDragEnd: app.swipe == 'skip' ? (d) { final v = d.primaryVelocity ?? 0; if (v < -250) { app.next(); } else if (v > 250) { app.prev(); } } : null,
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
        decoration: BoxDecoration(color: tint(t.title, .3), borderRadius: BorderRadius.circular(8)),
        child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(8, 8, 4, 6), child: Row(children: [
            Art(t, 40), const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx(t.title, f: FontWeight.w700, z: 13), tx(t.artist, c: Colors.white70, z: 12)])),
            IconButton(icon: Icon(lk ? Icons.check_circle : Icons.add_circle_outline, color: lk ? gr : Colors.white), onPressed: () => app.like(t)),
            StreamBuilder<bool>(stream: app.p.playingStream, initialData: false, builder: (_, s) => IconButton(icon: Icon(s.data! ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 30), onPressed: app.toggle)),
          ])),
          StreamBuilder<Duration>(stream: app.p.positionStream, builder: (_, s) {
            final d = app.p.duration?.inMilliseconds ?? 1;
            return Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 4), child: LinearProgressIndicator(value: ((s.data?.inMilliseconds ?? 0) / max(d, 1)).clamp(0.0, 1.0), minHeight: 2, backgroundColor: Colors.white24, color: Colors.white));
          }),
        ]),
      ),
    );
    return app.swipe == 'close' ? Dismissible(key: ValueKey('m${t.path}'), direction: DismissDirection.horizontal, onDismissed: (_) => app.close(), child: body) : body;
  }
}

// ───────────── now playing ─────────────
class NowPlaying extends StatefulWidget { const NowPlaying({super.key}); @override State<NowPlaying> createState() => _NPState(); }
class _NPState extends State<NowPlaying> {
  double? drag;
  Widget ib(IconData i, VoidCallback f, {Color c = Colors.white, double z = 28}) => IconButton(icon: Icon(i, color: c, size: z), onPressed: () { tap(); f(); });
  @override
  Widget build(BuildContext c) => ListenableBuilder(
        listenable: app,
        builder: (_, __) {
          final t = app.cur;
          if (t == null) { WidgetsBinding.instance.addPostFrameCallback((_) { if (c.mounted && Navigator.canPop(c)) Navigator.pop(c); }); return const SizedBox(); }
          final s = min(MediaQuery.of(c).size.width - 48, 380.0);
          final lk = app.liked.contains(t.path);
          return GestureDetector(
            onVerticalDragEnd: (d) { if ((d.primaryVelocity ?? 0) > 500) Navigator.pop(c); },
            child: Scaffold(
              body: Container(
                decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [tint(t.title, .38), bg], stops: const [0, .75])),
                child: SafeArea(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Column(children: [
                  Row(children: [
                    IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 32), onPressed: () => Navigator.pop(c)),
                    Expanded(child: Column(children: [tx('PLAYING FROM YOUR LIBRARY', z: 10, c: Colors.white70, f: FontWeight.w700, a: TextAlign.center), tx(t.album, z: 13, f: FontWeight.w700, a: TextAlign.center)])),
                    IconButton(icon: const Icon(Icons.more_vert), onPressed: () => trackMenu(c, t)),
                  ]),
                  const Spacer(),
                  GestureDetector(
                    onHorizontalDragEnd: (d) { final v = d.primaryVelocity ?? 0; if (v < -250) { app.next(); } else if (v > 250) { app.prev(); } },
                    child: StreamBuilder<bool>(stream: app.p.playingStream, initialData: false, builder: (_, p) => AnimatedScale(scale: p.data! ? 1 : .88, duration: const Duration(milliseconds: 250), child: Container(decoration: BoxDecoration(boxShadow: [BoxShadow(color: Colors.black.withOpacity(.5), blurRadius: 30)]), child: Art(t, s, r: 8)))),
                  ),
                  const Spacer(),
                  Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx(t.title, z: 22, f: FontWeight.w800), const SizedBox(height: 2), tx(t.artist, z: 16, c: Colors.white70)])),
                    IconButton(icon: Icon(lk ? Icons.check_circle : Icons.add_circle_outline, color: lk ? gr : Colors.white, size: 30), onPressed: () { tap(); app.like(t); }),
                  ]),
                  StreamBuilder<Duration>(stream: app.p.positionStream, builder: (_, sn) {
                    final dur = app.p.duration ?? Duration.zero; final pos = sn.data ?? Duration.zero;
                    final mx = max(dur.inMilliseconds.toDouble(), 1.0);
                    final v = (drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, mx);
                    return Column(children: [
                      Slider(value: v, max: mx, onChanged: (x) => setState(() => drag = x), onChangeEnd: (x) { app.p.seek(Duration(milliseconds: x.toInt())); setState(() => drag = null); }),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [tx(fmt(Duration(milliseconds: v.toInt())), z: 12, c: grey), tx(fmt(dur), z: 12, c: grey)]),
                    ]);
                  }),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    ib(Icons.shuffle, () => app.set(() => app.shuffle = !app.shuffle), c: app.shuffle ? gr : Colors.white),
                    ib(Icons.skip_previous, app.prev, z: 40),
                    StreamBuilder<bool>(stream: app.p.playingStream, initialData: false, builder: (_, p) => GestureDetector(onTap: () { tap(); app.toggle(); }, child: Container(width: 68, height: 68, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle), child: Icon(p.data! ? Icons.pause : Icons.play_arrow, color: Colors.black, size: 40)))),
                    ib(Icons.skip_next, app.next, z: 40),
                    ib(app.repeat == 2 ? Icons.repeat_one : Icons.repeat, () => app.set(() => app.repeat = (app.repeat + 1) % 3), c: app.repeat > 0 ? gr : Colors.white),
                  ]),
                  if (app.showVol) Row(children: [const Icon(Icons.volume_down, color: grey, size: 20), Expanded(child: Slider(value: app.vol, onChanged: app.setVol)), const Icon(Icons.volume_up, color: grey, size: 20)]),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    TextButton(onPressed: () => sheet(c, (s) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [for (final x in speeds) opt(x == app.speed ? Icons.check : Icons.speed, '${x}x', () { app.setSpeed(x); Navigator.pop(s); }, c: x == app.speed ? gr : Colors.white)]))), child: Text('${app.speed}x', style: const TextStyle(color: Colors.white))),
                    ib(Icons.bedtime_outlined, () => sheet(c, (s) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [for (final m in [15, 30, 45, 60]) opt(Icons.timer_outlined, '$m minutes', () { app.setSleep(m); Navigator.pop(s); }), if (app.sleepAt != null) opt(Icons.timer_off, 'Turn off timer', () { app.setSleep(null); Navigator.pop(s); })]))), c: app.sleepAt != null ? gr : Colors.white, z: 24),
                    ib(Icons.queue_music, () => sheet(c, (_) => const QueueSheet(), big: true), z: 24),
                  ]),
                ]))),
              ),
            ),
          );
        },
      );
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

Widget shelf(String title, List<Card2> items) => items.isEmpty ? const SizedBox() : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 22, 16, 10), child: tx(title, z: 22, f: FontWeight.w800)),
      SizedBox(height: 196, child: ListView.separated(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), itemCount: items.length, separatorBuilder: (_, __) => const SizedBox(width: 14), itemBuilder: (_, i) {
        final x = items[i];
        return GestureDetector(onTap: () { tap(); x.f(); }, child: SizedBox(width: 144, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Art(x.art, 144, r: x.round ? 72 : 6), const SizedBox(height: 8), tx(x.title, f: FontWeight.w700, z: 13), tx(x.sub, c: grey, z: 12)])));
      })),
    ]);

class HomePage extends StatefulWidget { const HomePage({super.key}); @override State<HomePage> createState() => _HomeState(); }
class _HomeState extends State<HomePage> {
  int chip = 0;
  Widget tile(String t, Track? a, VoidCallback f, {IconData? icon}) => GestureDetector(
        onTap: () { tap(); f(); },
        child: Container(decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(4)), clipBehavior: Clip.antiAlias, child: Row(children: [
          icon != null ? Container(width: 56, height: 56, decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF4510E0), Color(0xFF9B8DD8)])), child: Icon(icon, color: Colors.white)) : Art(a, 56, r: 0),
          const SizedBox(width: 10), Expanded(child: tx(t, f: FontWeight.w700, z: 13, lines: 2)), const SizedBox(width: 6),
        ])),
      );
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        final all = app.sorted, rec = app.recentTracks, most = app.mostPlayed;
        final src = chip == 2 ? app.likedTracks : (rec.isEmpty ? all : rec);
        final added = [...app.tracks]..sort((a, b) => b.added.compareTo(a.added));
        final day = DateTime.now().difference(DateTime(2024)).inDays;
        final hr = DateTime.now().hour;
        void open(String t, List<Track> Function() f, {String? list}) => Navigator.push(c, MaterialPageRoute(builder: (_) => ListPage(t, f, list: list)));
        final shortcuts = <Widget>[
          tile('Liked Songs', null, () => open('Liked Songs', () => app.likedTracks), icon: Icons.favorite),
          for (final n in app.lists.keys.take(3)) tile(n, app.toTracks(app.lists[n]!).firstOrNull, () => open(n, () => app.toTracks(app.lists[n] ?? []), list: n)),
          for (var i = 0; i < src.length && i < 8; i++) tile(src[i].title, src[i], () => app.playAt(src, i)),
        ].take(8).toList();
        return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 12, 8, 14), child: Row(children: [
            GestureDetector(onTap: () => openProfile(c), child: avatar(17)), const SizedBox(width: 12),
            for (final (i, l) in ['All', 'Music', 'Liked'].indexed) Padding(padding: const EdgeInsets.only(right: 8), child: GestureDetector(onTap: () => setState(() => chip = i), child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7), decoration: BoxDecoration(color: chip == i ? gr : const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(20)), child: tx(l, c: chip == i ? Colors.black : Colors.white, f: FontWeight.w600, z: 13)))),
          ])),
          if (all.isEmpty) Padding(padding: const EdgeInsets.all(40), child: Column(children: [
            Icon(app.scanning ? Icons.hourglass_top : Icons.library_music, size: 64, color: grey), const SizedBox(height: 12),
            tx(app.scanning ? 'Scanning your music…' : 'No songs yet', z: 20, f: FontWeight.w800), const SizedBox(height: 12),
            if (!app.scanning) FilledButton(style: FilledButton.styleFrom(backgroundColor: gr, foregroundColor: Colors.black), onPressed: app.scan, child: const Text('Scan device')),
          ])) else ...[
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: tx(hr < 12 ? 'Good morning' : hr < 18 ? 'Good afternoon' : 'Good evening', z: 22, f: FontWeight.w800)),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: GridView.count(crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 3.1, children: shortcuts)),
            shelf('Recently played', [for (var i = 0; i < rec.length && i < 12; i++) Card2(rec[i].title, rec[i].artist, rec[i], () => app.playAt(rec, i))]),
            shelf('Made for ${app.name}', [for (var n = 1; n <= 3; n++) () { final l = ([...all]..shuffle(Random(day + n))).take(25).toList(); return Card2('Daily Mix $n', l.take(3).map((e) => e.artist).toSet().join(', '), l.first, () => app.playAt(l, 0)); }()]),
            shelf('Your top songs', [for (var i = 0; i < most.length && i < 12; i++) Card2(most[i].title, '${app.plays[most[i].path]} plays', most[i], () => app.playAt(most, i))]),
            shelf('Recently added', [for (var i = 0; i < added.length && i < 12; i++) Card2(added[i].title, added[i].artist, added[i], () => app.playAt(added, i))]),
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
        final q = ctl.text.toLowerCase().trim();
        final res = q.isEmpty ? <Track>[] : app.tracks.where((t) => '${t.title} ${t.artist} ${t.album}'.toLowerCase().contains(q)).toList();
        final names = {...app.tracks.map((t) => t.artist), ...app.tracks.map((t) => t.album)}.toList();
        return Column(children: [
          head(c, 'Search'),
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 10), child: TextField(controller: ctl, onChanged: (_) => setState(() {}), style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600), cursorColor: Colors.black, decoration: InputDecoration(filled: true, fillColor: Colors.white, hintText: 'What do you want to play?', hintStyle: const TextStyle(color: Color(0xFF535353), fontWeight: FontWeight.w600), prefixIcon: const Icon(Icons.search, color: Colors.black), suffixIcon: q.isEmpty ? null : IconButton(icon: const Icon(Icons.close, color: Colors.black), onPressed: () => setState(ctl.clear)), border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none)))),
          Expanded(child: q.isNotEmpty
              ? (res.isEmpty ? Center(child: tx('No results for "$q"', z: 16, f: FontWeight.w700)) : ListView.builder(itemCount: res.length, itemBuilder: (_, i) => TTile(res[i], res, i)))
              : ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
                  tx('Browse all', z: 16, f: FontWeight.w800), const SizedBox(height: 12),
                  GridView.count(crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.7, children: [
                    for (final n in names) GestureDetector(onTap: () => setState(() => ctl.text = n), child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: tint(n, .4), borderRadius: BorderRadius.circular(6)), child: tx(n, z: 16, f: FontWeight.w800, lines: 2))),
                  ]),
                ])),
        ]);
      });
}

// ───────────── library ─────────────
class LibraryPage extends StatefulWidget { const LibraryPage({super.key}); @override State<LibraryPage> createState() => _LibState(); }
class _LibState extends State<LibraryPage> {
  int chip = 0;
  Widget row(Card2 x) => ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 16), leading: Art(x.art, 56, r: x.round ? 28 : 4), title: tx(x.title, f: FontWeight.w700), subtitle: tx(x.sub, c: grey, z: 13), onTap: () { tap(); x.f(); });
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) {
        void open(String t, List<Track> Function() f, {String? list}) => Navigator.push(c, MaterialPageRoute(builder: (_) => ListPage(t, f, list: list)));
        final artists = <String, List<Track>>{}, albums = <String, List<Track>>{};
        final srt = app.sorted;
        for (final t in srt) { (artists[t.artist] ??= []).add(t); (albums[t.album] ??= []).add(t); }
        final items = <Card2>[
          if (chip == 0) Card2('Liked Songs', 'Playlist • ${app.liked.length} songs', app.likedTracks.firstOrNull, () => open('Liked Songs', () => app.likedTracks)),
          if (chip == 0) for (final n in app.lists.keys) Card2(n, 'Playlist • ${app.lists[n]!.length} songs', app.toTracks(app.lists[n]!).firstOrNull, () => open(n, () => app.toTracks(app.lists[n] ?? []), list: n)),
          if (chip == 1) for (final e in artists.entries) Card2(e.key, 'Artist • ${e.value.length} songs', e.value.first, () => open(e.key, () => app.tracks.where((t) => t.artist == e.key).toList()), round: true),
          if (chip == 2) for (final e in albums.entries) Card2(e.key, 'Album • ${e.value.first.artist}', e.value.first, () => open(e.key, () => app.tracks.where((t) => t.album == e.key).toList())),
          if (chip == 3) for (var i = 0; i < srt.length; i++) Card2(srt[i].title, srt[i].artist, srt[i], () => app.playAt(srt, i)),
        ];
        return Column(children: [
          head(c, 'Your Library', actions: [IconButton(icon: const Icon(Icons.add), onPressed: () async { final n = await ask(c, 'Name your playlist'); if (n != null && !app.createList(n)) toast('Name is empty or already used'); })]),
          SizedBox(height: 44, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final (i, l) in ['Playlists', 'Artists', 'Albums', 'Songs'].indexed) Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: ChoiceChip(label: Text(l), selected: chip == i, selectedColor: gr, backgroundColor: const Color(0xFF2A2A2A), labelStyle: TextStyle(color: chip == i ? Colors.black : Colors.white, fontWeight: FontWeight.w600), side: BorderSide.none, showCheckmark: false, onSelected: (_) => setState(() => chip = i))),
          ])),
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 8, 0), child: Row(children: [
            const Icon(Icons.swap_vert, size: 18), const SizedBox(width: 4),
            GestureDetector(onTap: () => app.set(() => app.sort = app.sort == 'recent' ? 'az' : 'recent'), child: tx(app.sort == 'recent' ? 'Recents' : 'Alphabetical', z: 13, f: FontWeight.w600)),
            const Spacer(), IconButton(icon: Icon(app.libGrid ? Icons.view_list : Icons.grid_view, size: 20), onPressed: () => app.set(() => app.libGrid = !app.libGrid)),
          ])),
          Expanded(child: app.libGrid
              ? GridView.count(crossAxisCount: 3, padding: const EdgeInsets.all(12), mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: .78, children: [for (final x in items) GestureDetector(onTap: x.f, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Art(x.art, 104, r: x.round ? 52 : 4), const SizedBox(height: 6), tx(x.title, z: 12, f: FontWeight.w700), tx(x.sub, z: 11, c: grey)]))])
              : ListView(children: [for (final x in items) row(x)])),
        ]);
      });
}

// ───────────── playlist / list page (reorder + rename) ─────────────
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
          decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [tint(title, .35), bg])),
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

// ───────────── profile drawer + settings ─────────────
void openProfile(BuildContext c) {
  tap();
  void go(Widget w) => Navigator.push(c, MaterialPageRoute(builder: (_) => w));
  final items = <(IconData, String, VoidCallback)>[
    (Icons.insights_outlined, 'Your listening stats', () => toast('${app.tracks.length} songs • ${app.plays.values.fold(0, (a, b) => a + b)} plays')),
    (Icons.history, 'Recents', () => go(ListPage('Recents', () => app.recentTracks))),
    (Icons.favorite_border, 'Liked Songs', () => go(ListPage('Liked Songs', () => app.likedTracks))),
    (Icons.settings_outlined, 'Settings and privacy', () => go(const SettingsPage())),
  ];
  Navigator.push(c, PageRouteBuilder(
    opaque: false, barrierDismissible: true, barrierColor: Colors.black.withOpacity(.6),
    pageBuilder: (ctx, __, ___) => Align(alignment: Alignment.centerLeft, child: Material(color: bg, child: SizedBox(width: MediaQuery.of(ctx).size.width * .84, height: double.infinity, child: SafeArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 22, 20, 18), child: Row(children: [avatar(28), const SizedBox(width: 16), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [tx(app.name, z: 20, f: FontWeight.w800), tx('View profile', c: grey)])])),
      const Divider(color: Colors.white12),
      for (final it in items) InkWell(onTap: () { Navigator.pop(ctx); it.$3(); }, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15), child: Row(children: [Icon(it.$1, size: 26), const SizedBox(width: 18), tx(it.$2, z: 16)]))),
    ]))))),
    transitionsBuilder: (_, a, __, w) => SlideTransition(position: Tween(begin: const Offset(-1, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: w),
  ));
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  Widget sec(String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 26, 16, 6), child: tx(t, z: 16, f: FontWeight.w800));
  Widget row(String t, {String? sub, VoidCallback? f, Widget? trail}) => ListTile(onTap: f, title: tx(t, z: 16, lines: 2), subtitle: sub == null ? null : tx(sub, c: grey, z: 13, lines: 2), trailing: trail);
  Widget sw(String t, String sub, bool v, ValueChanged<bool> f) => row(t, sub: sub, f: () => f(!v), trail: Switch(value: v, onChanged: f, thumbColor: const WidgetStatePropertyAll(Colors.black), trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? gr : const Color(0xFF727272)), trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent)));
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: app, builder: (_, __) => Scaffold(
        appBar: AppBar(backgroundColor: bg, surfaceTintColor: Colors.transparent, centerTitle: true, title: const Text('Settings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
        body: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
          sec('Account'),
          row(app.name, sub: 'Tap to change your name', f: () async { final n = await ask(c, 'Your name', app.name); if (n != null && n.trim().isNotEmpty) app.set(() => app.name = n.trim()); }, trail: avatar(18)),
          row('Profile picture', sub: 'Choose from your gallery', f: () async { final r = await FilePicker.platform.pickFiles(type: FileType.image); final p = r?.files.single.path; if (p != null) app.set(() => app.avatar = p); }),
          if (app.avatar != null) row('Remove profile picture', f: () => app.set(() => app.avatar = null)),
          sec('Playback'),
          row('Mini player swipe', sub: {'skip': 'Swipe to skip songs', 'close': 'Swipe to close and stop the song', 'off': 'Swipe does nothing'}[app.swipe], f: () => showDialog(context: c, builder: (d) => SimpleDialog(backgroundColor: const Color(0xFF282828), title: const Text('Mini player swipe'), children: [for (final e in {'skip': 'Skip songs', 'close': 'Close & stop', 'off': 'Off'}.entries) RadioListTile<String>(activeColor: gr, title: Text(e.value), value: e.key, groupValue: app.swipe, onChanged: (v) { app.set(() => app.swipe = v!); Navigator.pop(d); })]))),
          sw('Shuffle', 'Play queues in random order', app.shuffle, (v) => app.set(() => app.shuffle = v)),
          row('Repeat', sub: ['Off', 'Repeat all', 'Repeat one'][app.repeat], f: () => app.set(() => app.repeat = (app.repeat + 1) % 3)),
          row('Playback speed', sub: '${app.speed}x', f: () => app.setSpeed(speeds[(speeds.indexOf(app.speed) + 1) % speeds.length])),
          sw('Skip silence', 'Skip quiet parts of tracks', app.skipSilence, (v) { app.set(() => app.skipSilence = v); app.p.setSkipSilenceEnabled(v); }),
          sw('Volume slider in player', 'Show volume control in Now Playing', app.showVol, (v) => app.set(() => app.showVol = v)),
          sw('Resume last song', 'Load your last song when the app opens', app.resume, (v) => app.set(() => app.resume = v)),
          sw('Stop playback on task clear', 'Stop music when you swipe the app away', app.stopOnClear, (v) => app.set(() => app.stopOnClear = v)),
          row('Sleep timer', sub: app.sleepAt == null ? 'Off (tap for 30 min)' : 'Pauses at ${TimeOfDay.fromDateTime(app.sleepAt!).format(c)}', f: () => app.setSleep(app.sleepAt == null ? 30 : null)),
          sec('Display'),
          row('Accent color', trail: Row(mainAxisSize: MainAxisSize.min, children: [for (final (i, a) in accents.indexed) GestureDetector(onTap: () => app.set(() => app.accent = i), child: Container(margin: const EdgeInsets.only(left: 8), width: 26, height: 26, decoration: BoxDecoration(color: a, shape: BoxShape.circle, border: app.accent == i ? Border.all(color: Colors.white, width: 2.5) : null)))])),
          row('Library sort', sub: app.sort == 'recent' ? 'Recently added' : 'A to Z', f: () => app.set(() => app.sort = app.sort == 'recent' ? 'az' : 'recent')),
          sw('Grid library view', 'Show your library as a grid', app.libGrid, (v) => app.set(() => app.libGrid = v)),
          sw('Haptic feedback', 'Vibrate on taps', app.haptics, (v) => app.set(() => app.haptics = v)),
          sec('Your library'),
          row('Rescan device', sub: '${app.tracks.length} songs${app.scanning ? ' • scanning…' : ''}', f: app.scan),
          row('Add songs', f: app.addFiles),
          row('Scan a folder', sub: '${app.dirs.length} folders scanned', f: app.addFolder),
          row('Permissions', sub: 'Audio, notifications and Bluetooth', f: () => openAppSettings()),
          sec('Storage & privacy'),
          row('Clear listening history', f: app.clearHistory),
          row('Clear artwork cache', f: app.clearArt),
          row('Reset all settings', f: app.reset),
          sec('About'),
          row('Pixel Audio Player', sub: 'Version 3.0.0'),
        ]),
      ));
}
