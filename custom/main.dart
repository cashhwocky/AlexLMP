// FILE: custom/main.dart  (v3.0 – full Spotify-style rewrite)
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

const spGreen = Color(0xFF1DB954);
const accents = <String, Color>{
  'Green': spGreen,
  'Blue': Color(0xFF3B82F6),
  'Pink': Color(0xFFEC4899),
  'Orange': Color(0xFFF97316),
  'Purple': Color(0xFF8B5CF6),
  'Red': Color(0xFFEF4444),
};
const chan = MethodChannel('pixelaudio/meta');
const exts = ['.mp3', '.wav', '.flac', '.m4a', '.aac', '.ogg', '.opus'];
const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
enum Rep { off, all, one }

final msgKey = GlobalKey<ScaffoldMessengerState>();
final shellKey = GlobalKey<ScaffoldState>();
void toast(String m) => msgKey.currentState
  ?..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(
      content: Text(m),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2)));
void hap() {
  if (app.haptics) HapticFeedback.selectionClick();
}

String fmt(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

class Song {
  final String path;
  String title, artist, album;
  String? art;
  Song(this.path, this.title,
      [this.artist = 'Unknown artist', this.album = '', this.art]);
  Map<String, dynamic> toJson() =>
      {'t': title, 'a': artist, 'l': album, 'r': art};
}

class Pl {
  String name;
  List<String> songs;
  Pl(this.name, this.songs);
}

// ───────────────────────── audio handler ─────────────────────────
class Handler extends BaseAudioHandler with SeekHandler {
  final p = AudioPlayer();
  Handler() {
    p.playbackEventStream.listen((e) {
      playbackState.add(PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          p.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[p.processingState]!,
        playing: p.playing,
        updatePosition: p.position,
        bufferedPosition: p.bufferedPosition,
        speed: p.speed,
      ));
    });
  }
  @override
  Future<void> play() => p.play();
  @override
  Future<void> pause() => p.pause();
  @override
  Future<void> seek(Duration d) => p.seek(d);
  @override
  Future<void> skipToNext() => app.next();
  @override
  Future<void> skipToPrevious() => app.prev();
  @override
  Future<void> stop() async {
    await p.stop();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    if (app.stopOnClear) await stop();
  }
}

// ───────────────────────── app state ─────────────────────────
final app = AppState();

class AppState extends ChangeNotifier {
  late SharedPreferences sp;
  late Handler h;
  List<Song> songs = [];
  Map<String, Song> byPath = {};
  Map<String, dynamic> metaCache = {}, st = {}, plays = {};
  List<Song> queue = [];
  int idx = -1;
  Set<String> favs = {};
  List<Pl> pls = [];
  List<String> recents = [], dirs = [], extra = [];
  bool shuffle = false, scanning = false, sleepEnd = false;
  Rep rep = Rep.off;
  Timer? sleepT;
  DateTime? sleepAt;

  Song? get cur => idx >= 0 && idx < queue.length ? queue[idx] : null;
  T g<T>(String k, T d) => (st[k] as T?) ?? d;
  void s(String k, dynamic v) {
    st[k] = v;
    sp.setString('st', jsonEncode(st));
    notifyListeners();
  }

  int get modeIdx => g('mode', 2);
  bool get amoled => g('amoled', false);
  int get accent => g('accent', 0);
  String get swipe => g('swipe', 'skip');
  String get sort => g('sort', 'az');
  bool get showVol => g('vol', true);
  bool get resume => g('resume', true);
  bool get haptics => g('haptics', true);
  bool get skipSilence => g('silence', false);
  bool get stopOnClear => g('stop', false);
  double get speed => g('speed', 1.0);

  Future<void> init(Handler handler) async {
    h = handler;
    sp = await SharedPreferences.getInstance();
    st = Map<String, dynamic>.from(jsonDecode(sp.getString('st') ?? '{}'));
    metaCache =
        Map<String, dynamic>.from(jsonDecode(sp.getString('meta') ?? '{}'));
    plays = Map<String, dynamic>.from(jsonDecode(sp.getString('plays') ?? '{}'));
    favs = (sp.getStringList('favs') ?? []).toSet();
    recents = sp.getStringList('recents') ?? [];
    dirs = sp.getStringList('dirs') ??
        ['/storage/emulated/0/Music', '/storage/emulated/0/Download'];
    extra = sp.getStringList('extra') ?? [];
    pls = (jsonDecode(sp.getString('pls') ?? '[]') as List)
        .map((e) => Pl(e['n'] as String, List<String>.from(e['s'])))
        .toList();
    h.p.processingStateStream.listen((x) {
      if (x == ProcessingState.completed) _done();
    });
    h.p.playingStream.listen((pl) {
      if (!pl) _saveLast();
      notifyListeners();
    });
    h.p.durationStream.listen((d) {
      final m = h.mediaItem.value;
      if (m != null && d != null) h.mediaItem.add(m.copyWith(duration: d));
    });
    h.p.setSkipSilenceEnabled(skipSilence);
    scan().then((_) => _restore());
  }

  void save() {
    sp.setStringList('favs', favs.toList());
    sp.setStringList('recents', recents);
    sp.setStringList('dirs', dirs);
    sp.setStringList('extra', extra);
    sp.setString('plays', jsonEncode(plays));
    sp.setString('pls',
        jsonEncode([for (final p in pls) {'n': p.name, 's': p.songs}]));
    notifyListeners();
  }

  void _saveLast() {
    if (cur == null) return;
    sp.setString('last', cur!.path);
    sp.setInt('lastPos', h.p.position.inSeconds);
  }

  Future<void> _restore() async {
    final p = sp.getString('last');
    if (!resume || p == null || cur != null || !byPath.containsKey(p)) return;
    queue = List.of(songs);
    idx = songs.indexOf(byPath[p]!);
    await _load(auto: false, at: Duration(seconds: sp.getInt('lastPos') ?? 0));
  }

  Future<void> perms() async {
    await [Permission.audio, Permission.storage, Permission.notification]
        .request();
  }

  Song _mk(String p) {
    final n = p.split('/').last, d = n.lastIndexOf('.');
    final c = metaCache[p];
    return Song(p, c?['t'] ?? (d > 0 ? n.substring(0, d) : n),
        c?['a'] ?? 'Unknown artist', c?['l'] ?? '', c?['r']);
  }

  Future<void> scan() async {
    scanning = true;
    notifyListeners();
    await perms();
    final found = <String>{...extra.where((p) => File(p).existsSync())};
    for (final d in dirs) {
      try {
        await for (final e
            in Directory(d).list(recursive: true, followLinks: false)) {
          final l = e.path.toLowerCase();
          if (e is File && exts.any(l.endsWith)) found.add(e.path);
        }
      } catch (_) {}
    }
    songs = found.map(_mk).toList();
    sortSongs();
    scanning = false;
    notifyListeners();
    _loadMeta();
  }

  void sortSongs() {
    String k(Song x) =>
        (sort == 'artist' ? '${x.artist} ${x.title}' : x.title).toLowerCase();
    songs.sort((a, b) => k(a).compareTo(k(b)));
    byPath = {for (final x in songs) x.path: x};
  }

  Future<void> _loadMeta() async {
    int n = 0;
    for (final x in songs) {
      if (metaCache.containsKey(x.path)) continue;
      try {
        final r = await chan.invokeMethod('read', {'path': x.path});
        if (r is Map) {
          final t = (r['title'] as String?)?.trim();
          final a = (r['artist'] as String?)?.trim();
          final l = (r['album'] as String?)?.trim();
          if (t != null && t.isNotEmpty) x.title = t;
          if (a != null && a.isNotEmpty) x.artist = a;
          if (l != null && l.isNotEmpty) x.album = l;
          final b = r['art'];
          if (b is Uint8List) {
            final dir = await chan.invokeMethod<String>('cacheDir');
            final f = File('$dir/a${x.path.hashCode}.jpg');
            if (!f.existsSync()) await f.writeAsBytes(b);
            x.art = f.path;
          }
        }
      } catch (_) {}
      metaCache[x.path] = x.toJson();
      if (++n % 15 == 0) notifyListeners();
    }
    sp.setString('meta', jsonEncode(metaCache));
    sortSongs();
    notifyListeners();
  }

  // playback
  Future<void> play(List<Song> list, int i) async {
    queue = List.of(list);
    idx = i;
    await _load();
  }

  Future<void> _load({bool auto = true, Duration? at}) async {
    final x = cur;
    if (x == null) return;
    notifyListeners();
    try {
      await h.p.setFilePath(x.path);
      h.mediaItem.add(MediaItem(
          id: x.path,
          title: x.title,
          artist: x.artist,
          album: x.album,
          artUri: x.art != null ? Uri.file(x.art!) : null));
      await h.p.setSpeed(speed);
      if (at != null) await h.p.seek(at);
      if (auto) {
        h.p.play();
        recents.remove(x.path);
        recents.insert(0, x.path);
        if (recents.length > 50) recents.removeLast();
        plays[x.path] = ((plays[x.path] as int?) ?? 0) + 1;
        save();
      }
    } catch (_) {
      toast('Cannot play ${x.title}');
    }
    notifyListeners();
  }

  void _done() {
    if (sleepEnd) {
      sleepEnd = false;
      h.p.pause();
      notifyListeners();
      return;
    }
    next(auto: true);
  }

  Future<void> next({bool auto = false}) async {
    if (queue.isEmpty) return;
    if (auto && rep == Rep.one) {
      await h.p.seek(Duration.zero);
      h.p.play();
      return;
    }
    int n;
    if (shuffle && queue.length > 1) {
      do {
        n = Random().nextInt(queue.length);
      } while (n == idx);
    } else {
      n = idx + 1;
      if (n >= queue.length) {
        if (rep == Rep.all || !auto) {
          n = 0;
        } else {
          await h.p.pause();
          await h.p.seek(Duration.zero);
          notifyListeners();
          return;
        }
      }
    }
    idx = n;
    await _load();
  }

  Future<void> prev() async {
    if (queue.isEmpty) return;
    if (h.p.position.inSeconds > 3) {
      await h.p.seek(Duration.zero);
      return;
    }
    idx = (idx - 1 + queue.length) % queue.length;
    await _load();
  }

  Future<void> closePlayer() async {
    _saveLast();
    await h.stop();
    queue = [];
    idx = -1;
    notifyListeners();
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    notifyListeners();
  }

  void cycleRep() {
    rep = Rep.values[(rep.index + 1) % 3];
    notifyListeners();
  }

  void setSpeed(double v) {
    h.p.setSpeed(v);
    s('speed', v);
  }

  void playNext(Song x) {
    if (cur == null) return play([x], 0);
    queue.insert(idx + 1, x);
    toast('Playing next');
    notifyListeners();
  }

  void addQueue(Song x) {
    if (cur == null) return play([x], 0);
    queue.add(x);
    toast('Added to queue');
    notifyListeners();
  }

  void setSleep(Duration? d, {bool end = false}) {
    sleepT?.cancel();
    sleepAt = null;
    sleepEnd = end;
    if (d != null) {
      sleepAt = DateTime.now().add(d);
      sleepT = Timer(d, () {
        h.p.pause();
        sleepAt = null;
        notifyListeners();
      });
    }
    toast(d != null ? 'Sleep timer: ${d.inMinutes} min' : (end ? 'Stops after this song' : 'Sleep timer off'));
    notifyListeners();
  }

  // library
  bool isFav(Song x) => favs.contains(x.path);
  void toggleFav(Song x) {
    hap();
    isFav(x) ? favs.remove(x.path) : favs.add(x.path);
    save();
  }

  List<Song> get liked =>
      songs.where((x) => favs.contains(x.path)).toList();
  List<Song> get recentSongs =>
      recents.map((p) => byPath[p]).whereType<Song>().toList();
  List<Song> get mostPlayed {
    final l = songs.where((x) => ((plays[x.path] as int?) ?? 0) > 0).toList();
    l.sort((a, b) => ((plays[b.path] as int?) ?? 0)
        .compareTo((plays[a.path] as int?) ?? 0));
    return l.take(15).toList();
  }

  Pl newPl(String name, [List<String> init = const []]) {
    final p = Pl(name.trim().isEmpty ? 'My playlist #${pls.length + 1}' : name.trim(), List.of(init));
    pls.add(p);
    save();
    return p;
  }

  void renamePl(Pl p, String n) {
    if (n.trim().isNotEmpty) p.name = n.trim();
    save();
  }

  void deletePl(Pl p) {
    pls.remove(p);
    save();
  }

  void addToPl(Pl p, Song x) {
    if (p.songs.contains(x.path)) return toast('Already in ${p.name}');
    p.songs.add(x.path);
    toast('Added to ${p.name}');
    save();
  }

  void movePl(Pl p, int o, int n) {
    p.songs.insert(n, p.songs.removeAt(o));
    save();
  }

  void removeFromPl(Pl p, int i) {
    p.songs.removeAt(i);
    save();
  }

  Future<void> pickFiles() async {
    final r = await FilePicker.platform
        .pickFiles(allowMultiple: true, type: FileType.audio);
    if (r == null) return;
    for (final f in r.files) {
      if (f.path != null && !extra.contains(f.path)) extra.add(f.path!);
    }
    save();
    scan();
  }

  Future<void> addFolder() async {
    final d = await FilePicker.platform.getDirectoryPath();
    if (d == null || dirs.contains(d)) return;
    dirs.add(d);
    save();
    scan();
  }
}

// ───────────────────────── entry ─────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final h = await AudioService.init(
    builder: () => Handler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.alexdesrosier.audio_player.channel',
      androidNotificationChannelName: 'Playback',
      androidNotificationOngoing: true,
    ),
  );
  await app.init(h);
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  ThemeData theme(Brightness b) {
    final d = b == Brightness.dark;
    final acc = accents.values.elementAt(app.accent);
    final bg = d ? (app.amoled ? Colors.black : const Color(0xFF121212)) : Colors.white;
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: ColorScheme.fromSeed(seedColor: acc, brightness: b)
          .copyWith(primary: acc, surface: bg),
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      appBarTheme: AppBarTheme(
          backgroundColor: bg, surfaceTintColor: Colors.transparent),
      navigationBarTheme: NavigationBarThemeData(
          backgroundColor: d ? Colors.black : Colors.white,
          indicatorColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          height: 62),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (_, __) => MaterialApp(
          title: 'Pixel Audio Player',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: msgKey,
          themeMode: ThemeMode.values[app.modeIdx],
          theme: theme(Brightness.light),
          darkTheme: theme(Brightness.dark),
          home: const Shell(),
        ),
      );
}

// ───────────────────────── shared widgets ─────────────────────────
class Art extends StatelessWidget {
  final String? path;
  final double size, r;
  const Art(this.path, this.size, {this.r = 4, super.key});
  @override
  Widget build(BuildContext context) {
    final ph = Container(
        width: size,
        height: size,
        color: const Color(0xFF282828),
        child: Icon(Icons.music_note, color: Colors.white38, size: size * .45));
    return ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: path == null
          ? ph
          : Image.file(File(path!),
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: (size * 3).toInt(),
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => ph),
    );
  }
}

Widget avatar(double r) => CircleAvatar(
    radius: r,
    backgroundColor: accents.values.elementAt(app.accent),
    child: Text('A',
        style: TextStyle(
            color: Colors.black, fontWeight: FontWeight.w800, fontSize: r)));

Future<T?> sheet<T>(BuildContext c, Widget Function(BuildContext) b) =>
    showModalBottomSheet<T>(
        context: c,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF282828),
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: b);

Future<String?> ask(BuildContext c, String title, [String init = '']) {
  final t = TextEditingController(text: init);
  return showDialog<String>(
    context: c,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(controller: t, autofocus: true, textCapitalization: TextCapitalization.sentences),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, t.text), child: const Text('Save')),
      ],
    ),
  );
}

class PlayBtn extends StatelessWidget {
  final double size;
  final bool circle;
  const PlayBtn(this.size, {this.circle = true, super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<bool>(
        stream: app.h.p.playingStream,
        initialData: app.h.p.playing,
        builder: (_, s) {
          final pl = s.data ?? false;
          return GestureDetector(
            onTap: () {
              hap();
              if (pl) {
                app.h.pause();
              } else {
                app.h.play();
              }
            },
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                  color: circle ? Colors.white : Colors.transparent,
                  shape: BoxShape.circle),
              child: Icon(pl ? Icons.pause : Icons.play_arrow,
                  color: circle ? Colors.black : Colors.white, size: size * .62),
            ),
          );
        },
      );
}

class SongTile extends StatelessWidget {
  final List<Song> list;
  final int i;
  final Widget? trailing;
  const SongTile(this.list, this.i, {this.trailing, super.key});
  @override
  Widget build(BuildContext context) {
    final x = list[i];
    final on = app.cur?.path == x.path;
    return ListTile(
      leading: Art(x.art, 48),
      title: Text(x.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontWeight: FontWeight.w600,
              color: on ? Theme.of(context).colorScheme.primary : null)),
      subtitle: Text(x.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing ??
          IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () => songMenu(context, x)),
      onTap: () {
        hap();
        app.play(list, i);
      },
    );
  }
}

void songMenu(BuildContext c, Song x) => sheet(
      c,
      (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: Art(x.art, 48),
              title: Text(x.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(x.artist)),
          const Divider(height: 1),
          ListTile(
              leading: Icon(app.isFav(x) ? Icons.check_circle : Icons.add_circle_outline),
              title: Text(app.isFav(x) ? 'Remove from Liked Songs' : 'Add to Liked Songs'),
              onTap: () {
                Navigator.pop(ctx);
                app.toggleFav(x);
              }),
          ListTile(
              leading: const Icon(Icons.playlist_play),
              title: const Text('Play next'),
              onTap: () {
                Navigator.pop(ctx);
                app.playNext(x);
              }),
          ListTile(
              leading: const Icon(Icons.queue_music),
              title: const Text('Add to queue'),
              onTap: () {
                Navigator.pop(ctx);
                app.addQueue(x);
              }),
          ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('Add to playlist'),
              onTap: () {
                Navigator.pop(ctx);
                pickPlaylist(c, x);
              }),
        ]),
      ),
    );

void pickPlaylist(BuildContext c, Song x) => sheet(
      c,
      (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * .6),
          child: ListView(shrinkWrap: true, children: [
            ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New playlist'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final n = await ask(c, 'New playlist');
                  if (n != null) app.addToPl(app.newPl(n), x);
                }),
            for (final p in app.pls)
              ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(p.name),
                  subtitle: Text('${p.songs.length} songs'),
                  onTap: () {
                    Navigator.pop(ctx);
                    app.addToPl(p, x);
                  }),
          ]),
        ),
      ),
    );

Widget sectionTitle(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 22, 16, 10),
    child: Text(t, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)));

Widget empty(IconData i, String t, String s) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 56, color: Colors.white38),
          const SizedBox(height: 14),
          Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(s, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
        ]),
      ),
    );

// ───────────────────────── shell ─────────────────────────
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (_, __) => Scaffold(
          key: shellKey,
          drawer: const ProfileDrawer(),
          body: SafeArea(
              bottom: false,
              child: IndexedStack(index: tab, children: const [HomePage(), SearchPage(), LibraryPage()])),
          bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
            const MiniPlayer(),
            NavigationBar(
              selectedIndex: tab,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              onDestinationSelected: (i) {
                hap();
                setState(() => tab = i);
              },
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_filled), label: 'Home'),
                NavigationDestination(icon: Icon(Icons.search), selectedIcon: Icon(Icons.search), label: 'Search'),
                NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Your Library'),
              ],
            ),
          ]),
        ),
      );
}

class ProfileDrawer extends StatelessWidget {
  const ProfileDrawer({super.key});
  Widget item(BuildContext c, IconData i, String t, VoidCallback f) => ListTile(
      leading: Icon(i),
      title: Text(t, style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: () {
        Navigator.pop(c);
        f();
      });
  @override
  Widget build(BuildContext c) => Drawer(
        backgroundColor: const Color(0xFF121212),
        child: SafeArea(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                avatar(28),
                const SizedBox(width: 14),
                const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Alex', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  Text('View profile', style: TextStyle(color: Colors.white60)),
                ]),
              ]),
            ),
            const Divider(height: 1),
            item(c, Icons.person_add_alt_1_outlined, 'Add account', () => toast('Add account')),
            item(c, Icons.bolt_outlined, "What's new", () => toast('v3.0: full redesign')),
            item(c, Icons.insights_outlined, 'Listening stats', () => stats(c)),
            item(c, Icons.history, 'Recents', () => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => SongListPage('Recents', app.recentSongs)))),
            item(c, Icons.bedtime_outlined, 'Sleep timer', () => sleepSheet(c)),
            item(c, Icons.settings_outlined, 'Settings and privacy', () => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => const SettingsPage()))),
          ]),
        ),
      );
  void stats(BuildContext c) {
    final total = app.plays.values.fold<int>(0, (a, b) => a + (b as int));
    final top = app.mostPlayed;
    showDialog<void>(
        context: c,
        builder: (_) => AlertDialog(
              title: const Text('Listening stats'),
              content: Text('${app.songs.length} songs\n${app.favs.length} liked\n${app.pls.length} playlists\n$total plays\nTop song: ${top.isEmpty ? "-" : top.first.title}'),
            ));
  }
}

// ───────────────────────── pages ─────────────────────────
class Header extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  const Header(this.title, {this.actions = const [], super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
        child: Row(children: [
          GestureDetector(onTap: () => shellKey.currentState?.openDrawer(), child: avatar(17)),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
          ...actions,
        ]),
      );
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  Widget card(Song x, List<Song> l, int i) => GestureDetector(
        onTap: () {
          hap();
          app.play(l, i);
        },
        child: SizedBox(
          width: 140,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Art(x.art, 140),
            const SizedBox(height: 6),
            Text(x.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(x.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 12)),
          ]),
        ),
      );
  Widget row(List<Song> l) => SizedBox(
      height: 195,
      child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: l.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) => card(l[i], l, i)));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (c, _) {
          final hr = DateTime.now().hour;
          final greet = hr < 12 ? 'Good morning' : (hr < 18 ? 'Good afternoon' : 'Good evening');
          final rec = app.recentSongs;
          final grid = (rec.isNotEmpty ? rec : app.songs).take(6).toList();
          if (app.songs.isEmpty) {
            return Column(children: [
              Header(greet),
              Expanded(
                  child: app.scanning
                      ? const Center(child: CircularProgressIndicator())
                      : empty(Icons.library_music, 'No songs yet', 'Add songs or a folder in Settings, then rescan.')),
            ]);
          }
          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            Header(greet, actions: [
              IconButton(icon: const Icon(Icons.shuffle), tooltip: 'Shuffle all', onPressed: () {
                app.shuffle = true;
                final l = List.of(app.songs)..shuffle();
                app.play(l, 0);
              }),
              IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => const SettingsPage()))),
            ]),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: grid.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 8, crossAxisSpacing: 8, mainAxisExtent: 56),
                itemBuilder: (_, i) => GestureDetector(
                  onTap: () => app.play(grid, i),
                  child: Container(
                    decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(6)),
                    clipBehavior: Clip.antiAlias,
                    child: Row(children: [
                      Art(grid[i].art, 56, r: 0),
                      const SizedBox(width: 10),
                      Expanded(child: Text(grid[i].title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white))),
                    ]),
                  ),
                ),
              ),
            ),
            if (rec.isNotEmpty) ...[sectionTitle('Jump back in'), row(rec.take(12).toList())],
            if (app.mostPlayed.isNotEmpty) ...[sectionTitle('Most played'), row(app.mostPlayed)],
            if (app.liked.isNotEmpty) ...[sectionTitle('Liked songs'), row(app.liked.take(12).toList())],
            sectionTitle('All songs'),
            row(app.songs.take(20).toList()),
          ]);
        },
      );
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchState();
}

class _SearchState extends State<SearchPage> {
  String q = '';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (c, _) {
          final k = q.toLowerCase();
          final r = k.isEmpty ? <Song>[] : app.songs.where((x) => '${x.title} ${x.artist} ${x.album}'.toLowerCase().contains(k)).toList();
          return Column(children: [
            const Header('Search'),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                onChanged: (v) => setState(() => q = v),
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
                cursorColor: Colors.black,
                decoration: InputDecoration(
                  hintText: 'What do you want to play?',
                  hintStyle: const TextStyle(color: Colors.black54),
                  prefixIcon: const Icon(Icons.search, color: Colors.black),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                ),
              ),
            ),
            Expanded(
              child: k.isEmpty
                  ? empty(Icons.search, 'Play what you love', 'Search by song, artist or album.')
                  : r.isEmpty
                      ? empty(Icons.search_off, 'No results', 'Try a different word.')
                      : ListView.builder(itemCount: r.length, itemBuilder: (_, i) => SongTile(r, i)),
            ),
          ]);
        },
      );
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibState();
}

class _LibState extends State<LibraryPage> {
  int tab = 0;
  Future<void> create(BuildContext c) async {
    final n = await ask(c, 'Name your playlist');
    if (n != null) app.newPl(n);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (c, _) {
          const labels = ['Playlists', 'Liked', 'Songs'];
          Widget body;
          if (tab == 0) {
            body = ListView(children: [
              ListTile(
                leading: Container(width: 56, height: 56, decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF4500FF), Color(0xFF9AA0FF)]), borderRadius: BorderRadius.circular(4)), child: const Icon(Icons.favorite, color: Colors.white)),
                title: const Text('Liked Songs', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('Playlist • ${app.favs.length} songs'),
                onTap: () => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => SongListPage('Liked Songs', app.liked))),
              ),
              for (final p in app.pls)
                ListTile(
                  leading: Art(app.byPath[p.songs.isEmpty ? '' : p.songs.first]?.art, 56),
                  title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('Playlist • ${p.songs.length} songs'),
                  onTap: () => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => PlaylistPage(p))),
                ),
              if (app.pls.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Tap + to create your first playlist.', style: TextStyle(color: Colors.white60))),
            ]);
          } else {
            final l = tab == 1 ? app.liked : app.songs;
            body = l.isEmpty ? empty(Icons.favorite_border, 'Nothing here yet', 'Like songs with the + button.') : ListView.builder(itemCount: l.length, itemBuilder: (_, i) => SongTile(l, i));
          }
          return Column(children: [
            Header('Your Library', actions: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.sort),
                onSelected: (v) {
                  app.s('sort', v);
                  app.sortSongs();
                },
                itemBuilder: (_) => const [PopupMenuItem(value: 'az', child: Text('Title A–Z')), PopupMenuItem(value: 'artist', child: Text('Artist'))],
              ),
              IconButton(icon: const Icon(Icons.add), onPressed: () => create(c)),
            ]),
            SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                for (int i = 0; i < 3; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: ChoiceChip(label: Text(labels[i]), selected: tab == i, onSelected: (_) => setState(() => tab = i), showCheckmark: false),
                  ),
              ]),
            ),
            Expanded(child: body),
          ]);
        },
      );
}

class SongListPage extends StatelessWidget {
  final String title;
  final List<Song> list;
  const SongListPage(this.title, this.list, {super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (c, _) => Scaffold(
          appBar: AppBar(title: Text(title)),
          bottomNavigationBar: const MiniPlayer(),
          body: list.isEmpty
              ? empty(Icons.music_off, 'Nothing here', 'Songs you play or like will show up.')
              : ListView.builder(
                  itemCount: list.length + 1,
                  itemBuilder: (_, i) => i == 0 ? playRow(list) : SongTile(list, i - 1),
                ),
        ),
      );
}

Widget playRow(List<Song> l) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(children: [
        Text('${l.length} songs', style: const TextStyle(color: Colors.white60)),
        const Spacer(),
        IconButton(icon: const Icon(Icons.shuffle), onPressed: () {
          app.shuffle = true;
          app.play(List.of(l)..shuffle(), 0);
        }),
        GestureDetector(
          onTap: () => app.play(l, 0),
          child: Container(width: 52, height: 52, decoration: BoxDecoration(color: accents.values.elementAt(app.accent), shape: BoxShape.circle), child: const Icon(Icons.play_arrow, color: Colors.black, size: 32)),
        ),
      ]),
    );

class PlaylistPage extends StatelessWidget {
  final Pl pl;
  const PlaylistPage(this.pl, {super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (c, _) {
          if (!app.pls.contains(pl)) return const Scaffold();
          if (app.songs.isNotEmpty && !app.scanning) pl.songs.removeWhere((p) => !app.byPath.containsKey(p));
          final list = pl.songs.map((p) => app.byPath[p]).whereType<Song>().toList();
          return Scaffold(
            appBar: AppBar(title: Text(pl.name), actions: [
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'rename') {
                    final n = await ask(c, 'Rename playlist', pl.name);
                    if (n != null) app.renamePl(pl, n);
                  } else {
                    app.deletePl(pl);
                    if (c.mounted) Navigator.pop(c);
                  }
                },
                itemBuilder: (_) => const [PopupMenuItem(value: 'rename', child: Text('Rename playlist')), PopupMenuItem(value: 'delete', child: Text('Delete playlist'))],
              ),
            ]),
            bottomNavigationBar: const MiniPlayer(),
            body: list.isEmpty
                ? empty(Icons.queue_music, 'This playlist is empty', 'Use ⋮ on any song and choose Add to playlist.')
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    header: playRow(list),
                    itemCount: list.length,
                    onReorder: (o, n) {
                      if (n > o) n--;
                      app.movePl(pl, o, n);
                    },
                    itemBuilder: (_, i) => Container(
                      key: ValueKey('${pl.songs[i]}'),
                      color: Theme.of(c).scaffoldBackgroundColor,
                      child: SongTile(list, i,
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => app.removeFromPl(pl, i)),
                            ReorderableDragStartListener(index: i, child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle))),
                          ])),
                    ),
                  ),
          );
        },
      );
}

// ───────────────────────── mini player ─────────────────────────
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (c, _) {
          final x = app.cur;
          if (x == null) return const SizedBox.shrink();
          final body = GestureDetector(
            onTap: () => openPlayer(c),
            child: Container(
              height: 60,
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(8)),
              child: Column(children: [
                Expanded(
                  child: Row(children: [
                    const SizedBox(width: 8),
                    Art(x.art, 44),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(x.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                        Text(x.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 12)),
                      ]),
                    ),
                    IconButton(icon: Icon(app.isFav(x) ? Icons.check_circle : Icons.add_circle_outline, color: app.isFav(x) ? spGreen : Colors.white70), onPressed: () => app.toggleFav(x)),
                    PlayBtn(36, circle: false),
                    const SizedBox(width: 4),
                  ]),
                ),
                StreamBuilder<Duration>(
                  stream: app.h.p.positionStream,
                  builder: (_, s) {
                    final d = app.h.p.duration?.inMilliseconds ?? 0;
                    final v = d == 0 ? 0.0 : ((s.data?.inMilliseconds ?? 0) / d).clamp(0.0, 1.0);
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                      child: LinearProgressIndicator(value: v.toDouble(), minHeight: 2, backgroundColor: Colors.white24, color: Colors.white),
                    );
                  },
                ),
              ]),
            ),
          );
          if (app.swipe == 'off') return body;
          return Dismissible(
            key: const ValueKey('mini'),
            confirmDismiss: (d) async {
              if (app.swipe == 'skip') {
                hap();
                if (d == DismissDirection.startToEnd) {
                  app.prev();
                } else {
                  app.next();
                }
                return false;
              }
              return true;
            },
            onDismissed: (_) => app.closePlayer(),
            child: body,
          );
        },
      );
}

// ───────────────────────── full player ─────────────────────────
void openPlayer(BuildContext c) => Navigator.of(c).push(PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, __, ___) => const PlayerPage(),
      transitionsBuilder: (_, a, __, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child),
    ));

void sleepSheet(BuildContext c) => sheet(
      c,
      (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('Sleep timer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          for (final m in [5, 15, 30, 45, 60])
            ListTile(title: Text('$m minutes'), onTap: () {
              Navigator.pop(ctx);
              app.setSleep(Duration(minutes: m));
            }),
          ListTile(title: const Text('End of track'), onTap: () {
            Navigator.pop(ctx);
            app.setSleep(null, end: true);
          }),
          ListTile(title: const Text('Turn off'), onTap: () {
            Navigator.pop(ctx);
            app.setSleep(null);
          }),
        ]),
      ),
    );

void queueSheet(BuildContext c) => sheet(
      c,
      (ctx) => ListenableBuilder(
        listenable: app,
        builder: (_, __) => SizedBox(
          height: MediaQuery.of(c).size.height * .7,
          child: Column(children: [
            const Padding(padding: EdgeInsets.all(16), child: Text('Queue', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
            Expanded(
              child: ListView.builder(
                itemCount: app.queue.length,
                itemBuilder: (_, i) => SongTile(app.queue, i,
                    trailing: i == app.idx
                        ? const Icon(Icons.equalizer, color: spGreen)
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              app.queue.removeAt(i);
                              if (i < app.idx) app.idx--;
                              app.notifyListeners();
                            })),
              ),
            ),
          ]),
        ),
      ),
    );

class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (c, _) {
          final x = app.cur;
          if (x == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (c.mounted) Navigator.pop(c);
            });
            return const Scaffold();
          }
          final acc = accents.values.elementAt(app.accent);
          final on = acc;
          final w = MediaQuery.of(c).size.width - 56;
          Widget ico(IconData i, VoidCallback f, {Color? col, double s = 28}) =>
              IconButton(icon: Icon(i, size: s, color: col ?? Colors.white), onPressed: () { hap(); f(); });
          return Scaffold(
            body: Container(
              decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(Colors.black, acc, .45)!, const Color(0xFF121212)], stops: const [0, .75])),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(children: [
                    Row(children: [
                      IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 32, color: Colors.white), onPressed: () => Navigator.pop(c)),
                      const Expanded(child: Text('PLAYING FROM YOUR LIBRARY', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1))),
                      IconButton(icon: const Icon(Icons.more_vert, color: Colors.white), onPressed: () => songMenu(c, x)),
                    ]),
                    const Spacer(),
                    GestureDetector(
                      onHorizontalDragEnd: (d) {
                        final v = d.primaryVelocity ?? 0;
                        if (v < -200) app.next();
                        if (v > 200) app.prev();
                      },
                      child: Container(
                        decoration: BoxDecoration(boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .5), blurRadius: 30, offset: const Offset(0, 12))]),
                        child: Art(x.art, w, r: 8),
                      ),
                    ),
                    const Spacer(),
                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(x.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                          Text(x.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 15)),
                        ]),
                      ),
                      ico(app.isFav(x) ? Icons.check_circle : Icons.add_circle_outline, () => app.toggleFav(x), col: app.isFav(x) ? on : Colors.white),
                    ]),
                    const Seek(),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      ico(Icons.shuffle, app.toggleShuffle, col: app.shuffle ? on : Colors.white70, s: 24),
                      ico(Icons.skip_previous, app.prev, s: 38),
                      PlayBtn(68),
                      ico(Icons.skip_next, app.next, s: 38),
                      ico(app.rep == Rep.one ? Icons.repeat_one : Icons.repeat, app.cycleRep, col: app.rep == Rep.off ? Colors.white70 : on, s: 24),
                    ]),
                    const SizedBox(height: 8),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      TextButton(
                        onPressed: () => sheet(c, (ctx) => SafeArea(child: Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
                              for (final sp in speeds)
                                Padding(padding: const EdgeInsets.all(12), child: ChoiceChip(label: Text('${sp}x'), selected: app.speed == sp, onSelected: (_) { app.setSpeed(sp); Navigator.pop(ctx); })),
                            ]))),
                        child: Text('${app.speed}x', style: const TextStyle(color: Colors.white70)),
                      ),
                      ico(Icons.bedtime_outlined, () => sleepSheet(c), col: (app.sleepAt != null || app.sleepEnd) ? on : Colors.white70, s: 22),
                      ico(Icons.queue_music, () => queueSheet(c), col: Colors.white70, s: 24),
                    ]),
                    if (app.showVol)
                      StreamBuilder<double>(
                        stream: app.h.p.volumeStream,
                        initialData: app.h.p.volume,
                        builder: (_, s) => Row(children: [
                          const Icon(Icons.volume_down, color: Colors.white70, size: 20),
                          Expanded(child: Slider(value: (s.data ?? 1).clamp(0.0, 1.0), onChanged: app.h.p.setVolume, activeColor: Colors.white, inactiveColor: Colors.white24)),
                          const Icon(Icons.volume_up, color: Colors.white70, size: 20),
                        ]),
                      ),
                    const SizedBox(height: 8),
                  ]),
                ),
              ),
            ),
          );
        },
      );
}

class Seek extends StatefulWidget {
  const Seek({super.key});
  @override
  State<Seek> createState() => _SeekState();
}

class _SeekState extends State<Seek> {
  double? d;
  @override
  Widget build(BuildContext context) => StreamBuilder<Duration?>(
        stream: app.h.p.durationStream,
        initialData: app.h.p.duration,
        builder: (_, ds) {
          final dur = ds.data ?? Duration.zero;
          return StreamBuilder<Duration>(
            stream: app.h.p.positionStream,
            builder: (_, ps) {
              final mx = max(dur.inMilliseconds.toDouble(), 1.0);
              final v = (d ?? (ps.data?.inMilliseconds ?? 0).toDouble()).clamp(0.0, mx).toDouble();
              return Column(children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), activeTrackColor: Colors.white, inactiveTrackColor: Colors.white24, thumbColor: Colors.white),
                  child: Slider(
                    value: v,
                    max: mx,
                    onChanged: (x) => setState(() => d = x),
                    onChangeEnd: (x) {
                      app.h.p.seek(Duration(milliseconds: x.toInt()));
                      setState(() => d = null);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(fmt(Duration(milliseconds: v.toInt())), style: const TextStyle(color: Colors.white60, fontSize: 12)),
                    Text(fmt(dur), style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  ]),
                ),
              ]);
            },
          );
        },
      );
}

// ───────────────────────── settings ─────────────────────────
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  Widget head(String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 26, 16, 6), child: Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)));
  Widget sw(String t, String sub, bool v, String k, {ValueChanged<bool>? extra}) => SwitchListTile(
        title: Text(t),
        subtitle: Text(sub, style: const TextStyle(color: Colors.white60, fontSize: 13)),
        value: v,
        onChanged: (x) {
          app.s(k, x);
          extra?.call(x);
        },
      );
  Widget seg<T extends Object>(Map<T, String> o, T v, ValueChanged<T> f) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<T>(
          showSelectedIcon: false,
          segments: [for (final e in o.entries) ButtonSegment<T>(value: e.key, label: Text(e.value))],
          selected: {v},
          onSelectionChanged: (s) => f(s.first),
        ),
      ));
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (c, _) => Scaffold(
          appBar: AppBar(title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.w800)), centerTitle: true),
          bottomNavigationBar: const MiniPlayer(),
          body: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
            head('Appearance'),
            seg<int>({0: 'System', 1: 'Light', 2: 'Dark'}, app.modeIdx, (v) => app.s('mode', v)),
            sw('Pure black (AMOLED)', 'True black background in dark mode', app.amoled, 'amoled'),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(spacing: 12, runSpacing: 12, children: [
                for (int i = 0; i < accents.length; i++)
                  GestureDetector(
                    onTap: () => app.s('accent', i),
                    child: CircleAvatar(radius: 20, backgroundColor: accents.values.elementAt(i), child: app.accent == i ? const Icon(Icons.check, color: Colors.black) : null),
                  ),
              ]),
            ),
            head('Mini player'),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('What happens when you swipe the mini player', style: TextStyle(color: Colors.white60, fontSize: 13))),
            seg<String>({'skip': 'Skip song', 'close': 'Close & stop', 'off': 'Off'}, app.swipe, (v) => app.s('swipe', v)),
            head('Playback'),
            sw('Resume last session', 'Reopen the last song and position on launch', app.resume, 'resume'),
            sw('Skip silence', 'Skip quiet gaps in songs', app.skipSilence, 'silence', extra: app.h.p.setSkipSilenceEnabled),
            sw('Volume slider in player', 'Show a volume slider on the player screen', app.showVol, 'vol'),
            sw('Stop playback on task clear', 'Stop music when the app is swiped away', app.stopOnClear, 'stop'),
            sw('Haptic feedback', 'Vibrate lightly on taps', app.haptics, 'haptics'),
            ListTile(
              title: const Text('Default speed'),
              trailing: DropdownButton<double>(
                value: app.speed,
                underline: const SizedBox(),
                items: [for (final s in speeds) DropdownMenuItem(value: s, child: Text('${s}x'))],
                onChanged: (v) => app.setSpeed(v ?? 1.0),
              ),
            ),
            head('Library'),
            ListTile(leading: const Icon(Icons.refresh), title: const Text('Rescan library'), subtitle: Text(app.scanning ? 'Scanning…' : '${app.songs.length} songs'), onTap: app.scan),
            ListTile(leading: const Icon(Icons.audio_file), title: const Text('Add songs'), onTap: app.pickFiles),
            ListTile(leading: const Icon(Icons.create_new_folder_outlined), title: const Text('Add music folder'), onTap: app.addFolder),
            for (final d in app.dirs)
              ListTile(
                dense: true,
                leading: const Icon(Icons.folder_outlined),
                title: Text(d, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(icon: const Icon(Icons.close), onPressed: () {
                  app.dirs.remove(d);
                  app.save();
                  app.scan();
                }),
              ),
            ListTile(leading: const Icon(Icons.security), title: const Text('Grant permissions'), onTap: () async {
              await app.perms();
              app.scan();
            }),
            head('Data'),
            ListTile(leading: const Icon(Icons.history), title: const Text('Clear listening history'), onTap: () {
              app.recents.clear();
              app.plays.clear();
              app.save();
              toast('History cleared');
            }),
            ListTile(leading: const Icon(Icons.favorite_border), title: const Text('Clear liked songs'), onTap: () {
              app.favs.clear();
              app.save();
              toast('Liked songs cleared');
            }),
            ListTile(leading: const Icon(Icons.restore), title: const Text('Reset all settings'), onTap: () {
              app.st = {};
              app.s('reset', true);
              toast('Settings reset');
            }),
            head('About'),
            const ListTile(title: Text('Pixel Audio Player'), subtitle: Text('Version 3.0.0')),
          ]),
        ),
      );
}
