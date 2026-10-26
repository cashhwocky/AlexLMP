import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const green = Color(0xFF1DB954);
const bg = Color(0xFF121212);
const card = Color(0xFF282828);
const ch = MethodChannel('pixelaudio/meta');
final player = AudioPlayer();
final st = Store();

String fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

class Song {
  final int id, albumId, dur, added;
  final String title, artist, album, path;
  Song(Map m)
      : id = (m['id'] as num).toInt(),
        albumId = (m['albumId'] as num).toInt(),
        dur = (m['dur'] as num).toInt(),
        added = (m['added'] as num).toInt(),
        title = m['title'] as String,
        artist = (m['artist'] as String) == '<unknown>' ? 'Unknown artist' : m['artist'] as String,
        album = m['album'] as String,
        path = m['path'] as String;
}

class PL {
  String name;
  List<int> ids;
  PL(this.name, this.ids);
}

class Store extends ChangeNotifier {
  late SharedPreferences p;
  List<Song> all = [];
  Map<int, Song> byId = {};
  List<PL> pls = [];
  Set<int> liked = {};
  List<int> recents = [];
  Map<int, int> plays = {};
  String sw = 'skip', sort = 'title';
  int minSec = 30, loop = 0;
  bool resume = true, haptics = true, showArt = true, skipSil = false, confirmDel = true, shuffle = false;
  double speed = 1;
  bool perm = true, mini = false;
  int? cur;
  ConcatenatingAudioSource? q;
  Timer? sleepT;

  Future<void> init() async {
    p = await SharedPreferences.getInstance();
    pls = (jsonDecode(p.getString('pls') ?? '[]') as List)
        .map((e) => PL(e['n'] as String, List<int>.from(e['i'] as List)))
        .toList();
    liked = (p.getStringList('liked') ?? []).map(int.parse).toSet();
    recents = (p.getStringList('rec') ?? []).map(int.parse).toList();
    plays = (jsonDecode(p.getString('plays') ?? '{}') as Map)
        .map((k, v) => MapEntry(int.parse(k as String), (v as num).toInt()));
    sw = p.getString('sw') ?? 'skip';
    sort = p.getString('sort') ?? 'title';
    minSec = p.getInt('min') ?? 30;
    resume = p.getBool('resume') ?? true;
    haptics = p.getBool('hap') ?? true;
    showArt = p.getBool('art') ?? true;
    skipSil = p.getBool('sil') ?? false;
    confirmDel = p.getBool('cdel') ?? true;
    speed = p.getDouble('speed') ?? 1;
    shuffle = p.getBool('sh') ?? false;
    loop = p.getInt('lp') ?? 0;
    try {
      await player.setSpeed(speed);
      await player.setSkipSilenceEnabled(skipSil);
      await player.setShuffleModeEnabled(shuffle);
      await player.setLoopMode(LoopMode.values[loop]);
    } catch (_) {}
    player.shuffleModeEnabledStream.listen((v) {
      shuffle = v;
      p.setBool('sh', v);
    });
    player.loopModeStream.listen((v) {
      loop = v.index;
      p.setInt('lp', loop);
    });
    player.sequenceStateStream.listen((ss) {
      final t = ss?.currentSource?.tag;
      if (t is MediaItem) {
        final id = int.tryParse(t.id);
        if (id != null && id != cur) {
          cur = id;
          recents.remove(id);
          recents.insert(0, id);
          if (recents.length > 30) recents.removeLast();
          plays[id] = (plays[id] ?? 0) + 1;
          p.setInt('lid', id);
          p.setStringList('lq', player.sequence.map((e) => (e.tag as MediaItem).id).toList());
          upd();
        }
      }
    });
    await scan();
    if (resume && perm) {
      final lq = (p.getStringList('lq') ?? [])
          .map(int.parse)
          .where((e) => byId.containsKey(e))
          .map((e) => byId[e]!)
          .toList();
      if (lq.isNotEmpty) {
        final i = lq.indexWhere((x) => x.id == p.getInt('lid'));
        if (await load(lq, i < 0 ? 0 : i)) mini = true;
      }
    }
    notifyListeners();
  }

  Future<void> scan() async {
    final r = await [Permission.audio, Permission.storage, Permission.notification].request();
    perm = (r[Permission.audio]?.isGranted ?? false) || (r[Permission.storage]?.isGranted ?? false);
    if (perm) {
      final l = await ch.invokeMethod<List>('scan') ?? [];
      all = l.map((e) => Song(Map.from(e as Map))).toList();
      byId = {for (final x in all) x.id: x};
      for (final pl in pls) {
        pl.ids.removeWhere((id) => !byId.containsKey(id));
      }
      liked.removeWhere((id) => !byId.containsKey(id));
    }
    notifyListeners();
  }

  List<Song> get songs {
    final l = all.where((x) => x.dur >= minSec * 1000).toList();
    int t(Song a, Song b) => a.title.toLowerCase().compareTo(b.title.toLowerCase());
    l.sort(switch (sort) {
      'artist' => (Song a, Song b) {
          final c = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
          return c != 0 ? c : t(a, b);
        },
      'recent' => (Song a, Song b) => b.added.compareTo(a.added),
      'plays' => (Song a, Song b) => (plays[b.id] ?? 0).compareTo(plays[a.id] ?? 0),
      _ => t,
    });
    return l;
  }

  List<Song> get likedSongs => liked.where(byId.containsKey).map((e) => byId[e]!).toList();

  void save() {
    p.setString('pls', jsonEncode(pls.map((e) => {'n': e.name, 'i': e.ids}).toList()));
    p.setStringList('liked', liked.map((e) => '$e').toList());
    p.setStringList('rec', recents.map((e) => '$e').toList());
    p.setString('plays', jsonEncode(plays.map((k, v) => MapEntry('$k', v))));
    p.setString('sw', sw);
    p.setString('sort', sort);
    p.setInt('min', minSec);
    p.setBool('resume', resume);
    p.setBool('hap', haptics);
    p.setBool('art', showArt);
    p.setBool('sil', skipSil);
    p.setBool('cdel', confirmDel);
    p.setDouble('speed', speed);
  }

  void upd() {
    save();
    notifyListeners();
  }

  void tap() {
    if (haptics) HapticFeedback.selectionClick();
  }

  void toggleLike(int id) {
    liked.contains(id) ? liked.remove(id) : liked.add(id);
    tap();
    upd();
  }

  AudioSource src(Song x) => AudioSource.uri(Uri.file(x.path),
      tag: MediaItem(
        id: '${x.id}',
        title: x.title,
        artist: x.artist,
        album: x.album,
        duration: Duration(milliseconds: x.dur),
        artUri: Uri.parse('content://media/external/audio/albumart/${x.albumId}'),
      ));

  Future<bool> load(List<Song> l, int i) async {
    try {
      q = ConcatenatingAudioSource(children: l.map(src).toList());
      await player.setAudioSource(q!, initialIndex: i);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> playQueue(List<Song> l, int i, {bool shuf = false}) async {
    if (l.isEmpty) return;
    if (!await load(l, i)) return;
    mini = true;
    if (shuf) {
      await player.setShuffleModeEnabled(true);
      await player.shuffle();
    }
    player.play();
    notifyListeners();
  }

  void playNext(Song s) {
    if (q == null || player.currentIndex == null) {
      playQueue([s], 0);
    } else {
      q!.insert(player.currentIndex! + 1, src(s));
    }
  }

  void addQueue(Song s) {
    if (q == null) {
      playQueue([s], 0);
    } else {
      q!.add(src(s));
    }
  }

  void setSleep(int min) {
    sleepT?.cancel();
    sleepT = null;
    if (min > 0) {
      sleepT = Timer(Duration(minutes: min), () {
        player.pause();
        sleepT = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.alexdesrosier.audio_player.audio',
    androidNotificationChannelName: 'Playback',
    androidNotificationOngoing: true,
  );
  await st.init();
  runApp(const App());
}

class W extends StatelessWidget {
  final Widget Function() b;
  const W(this.b, {super.key});
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: st, builder: (_, __) => b());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Music',
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: bg,
          colorScheme: const ColorScheme.dark(primary: green, surface: bg),
          appBarTheme: const AppBarTheme(backgroundColor: bg, elevation: 0, scrolledUnderElevation: 0),
          navigationBarTheme: NavigationBarThemeData(
            backgroundColor: const Color(0xF0000000),
            indicatorColor: Colors.transparent,
            labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
                fontSize: 11, color: s.contains(WidgetState.selected) ? Colors.white : Colors.white60)),
            iconTheme: WidgetStateProperty.resolveWith(
                (s) => IconThemeData(color: s.contains(WidgetState.selected) ? Colors.white : Colors.white60)),
          ),
          sliderTheme: const SliderThemeData(trackHeight: 4, thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6)),
        ),
        home: const Shell(),
      );
}

// ---------- shared widgets ----------
final _artCache = <int, Future<Uint8List?>>{};

class Art extends StatelessWidget {
  final Song? s;
  final double size, r;
  const Art(this.s, this.size, this.r, {super.key});
  @override
  Widget build(BuildContext c) {
    final ph = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(r)),
        child: Icon(Icons.music_note, color: Colors.white38, size: size * .45));
    if (s == null || !st.showArt) return ph;
    final k = s!.albumId > 0 ? s!.albumId : -s!.id;
    return FutureBuilder<Uint8List?>(
      future: _artCache.putIfAbsent(k, () => ch.invokeMethod<Uint8List>('art', {'path': s!.path})),
      builder: (_, snap) => snap.data == null
          ? ph
          : ClipRRect(
              borderRadius: BorderRadius.circular(r),
              child: Image.memory(snap.data!, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true)),
    );
  }
}

Future<String?> ask(BuildContext c, String t, {String init = ''}) {
  final ctl = TextEditingController(text: init);
  return showDialog<String>(
    context: c,
    builder: (d) => AlertDialog(
      backgroundColor: card,
      title: Text(t),
      content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: 'Playlist name')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(d, ctl.text.trim()), child: const Text('Save')),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext c, String t) async =>
    await showDialog<bool>(
        context: c,
        builder: (d) => AlertDialog(backgroundColor: card, title: Text(t), actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('OK')),
            ])) ??
    false;

Future<T?> pick<T>(BuildContext c, String t, Map<T, String> o) => showDialog<T>(
      context: c,
      builder: (d) => SimpleDialog(
        backgroundColor: card,
        title: Text(t),
        children: o.entries.map((e) => SimpleDialogOption(onPressed: () => Navigator.pop(d, e.key), child: Text(e.value))).toList(),
      ),
    );

void msg(BuildContext c, String t) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 2)));

void addToPlaylist(BuildContext c, Song s) {
  showModalBottomSheet(
    context: c,
    backgroundColor: card,
    builder: (d) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('New playlist'),
          onTap: () async {
            Navigator.pop(d);
            final n = await ask(c, 'New playlist');
            if (n != null && n.isNotEmpty) {
              st.pls.add(PL(n, [s.id]));
              st.upd();
            }
          },
        ),
        for (final pl in st.pls)
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: Text(pl.name),
            subtitle: Text('${pl.ids.length} songs'),
            onTap: () {
              Navigator.pop(d);
              if (!pl.ids.contains(s.id)) pl.ids.add(s.id);
              st.upd();
              msg(c, 'Added to ${pl.name}');
            },
          ),
      ]),
    ),
  );
}

void songMenu(BuildContext c, Song s, {PL? from}) {
  final lk = st.liked.contains(s.id);
  showModalBottomSheet(
    context: c,
    backgroundColor: card,
    builder: (d) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: Art(s, 48, 4), title: Text(s.title, maxLines: 1), subtitle: Text(s.artist, maxLines: 1)),
        const Divider(height: 1),
        ListTile(
            leading: Icon(lk ? Icons.favorite : Icons.favorite_border, color: lk ? green : null),
            title: Text(lk ? 'Remove from Liked Songs' : 'Add to Liked Songs'),
            onTap: () {
              Navigator.pop(d);
              st.toggleLike(s.id);
            }),
        ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('Add to playlist'),
            onTap: () {
              Navigator.pop(d);
              addToPlaylist(c, s);
            }),
        ListTile(
            leading: const Icon(Icons.queue_play_next),
            title: const Text('Play next'),
            onTap: () {
              Navigator.pop(d);
              st.playNext(s);
              msg(c, 'Will play next');
            }),
        ListTile(
            leading: const Icon(Icons.queue_music),
            title: const Text('Add to queue'),
            onTap: () {
              Navigator.pop(d);
              st.addQueue(s);
              msg(c, 'Added to queue');
            }),
        if (from != null)
          ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('Remove from this playlist'),
              onTap: () {
                Navigator.pop(d);
                from.ids.remove(s.id);
                st.upd();
              }),
      ]),
    ),
  );
}

class SongTile extends StatelessWidget {
  final Song s;
  final List<Song> ctx;
  final int i;
  final PL? from;
  final int? handle;
  const SongTile(this.s, this.ctx, this.i, {super.key, this.from, this.handle});
  @override
  Widget build(BuildContext c) => W(() {
        final on = st.cur == s.id;
        return ListTile(
          leading: Art(s, 48, 4),
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: on ? green : Colors.white, fontWeight: FontWeight.w500)),
          subtitle: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: const Icon(Icons.more_vert, color: Colors.white60), onPressed: () => songMenu(c, s, from: from)),
            if (handle != null) ReorderableDragStartListener(index: handle!, child: const Icon(Icons.drag_handle, color: Colors.white60)),
          ]),
          onTap: () {
            st.tap();
            st.playQueue(ctx, i);
          },
        );
      });
}

class PlayRow extends StatelessWidget {
  final List<Song> l;
  const PlayRow(this.l, {super.key});
  @override
  Widget build(BuildContext c) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          Text('${l.length} songs', style: const TextStyle(color: Colors.white60)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.shuffle, color: green, size: 28), onPressed: () => st.playQueue(l, 0, shuf: true)),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () => st.playQueue(l, 0),
            child: const CircleAvatar(radius: 28, backgroundColor: green, child: Icon(Icons.play_arrow, color: Colors.black, size: 36)),
          ),
        ]),
      );
}

// ---------- shell ----------
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  @override
  Widget build(BuildContext c) => W(() => Scaffold(
        body: SafeArea(
          bottom: false,
          child: !st.perm
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.library_music, size: 64, color: Colors.white38),
                  const SizedBox(height: 12),
                  const Text('Allow access to your music to get started'),
                  const SizedBox(height: 12),
                  FilledButton(style: FilledButton.styleFrom(backgroundColor: green, foregroundColor: Colors.black), onPressed: st.scan, child: const Text('Grant access')),
                  TextButton(onPressed: openAppSettings, child: const Text('Open settings')),
                ]))
              : IndexedStack(index: tab, children: const [HomeTab(), SearchTab(), LibraryTab()]),
        ),
        bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
          const Mini(),
          NavigationBar(
            height: 64,
            selectedIndex: tab,
            onDestinationSelected: (i) {
              st.tap();
              setState(() => tab = i);
            },
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
              NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Your Library'),
            ],
          ),
        ]),
      ));
}

// ---------- mini player ----------
class Mini extends StatelessWidget {
  const Mini({super.key});
  @override
  Widget build(BuildContext c) => W(() {
        if (!st.mini) return const SizedBox.shrink();
        return StreamBuilder<SequenceState?>(
          stream: player.sequenceStateStream,
          builder: (_, snap) {
            final t = snap.data?.currentSource?.tag;
            if (t is! MediaItem) return const SizedBox.shrink();
            final s = st.byId[int.tryParse(t.id)];
            final lk = s != null && st.liked.contains(s.id);
            return GestureDetector(
              onTap: () => Navigator.push(c, MaterialPageRoute(fullscreenDialog: true, builder: (_) => const NowPlaying())),
              onHorizontalDragEnd: (d) {
                final v = d.primaryVelocity ?? 0;
                if (v.abs() < 250 || st.sw == 'off') return;
                st.tap();
                if (st.sw == 'skip') {
                  v < 0 ? player.seekToNext() : player.seekToPrevious();
                } else {
                  player.stop();
                  st.mini = false;
                  st.notifyListeners();
                }
              },
              child: Container(
                margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                decoration: BoxDecoration(color: const Color(0xFF3A2E2E), borderRadius: BorderRadius.circular(8)),
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
                    child: Row(children: [
                      Art(s, 44, 4),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text(t.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      ])),
                      if (s != null) IconButton(icon: Icon(lk ? Icons.favorite : Icons.favorite_border, color: lk ? green : Colors.white), onPressed: () => st.toggleLike(s.id)),
                      StreamBuilder<bool>(
                        stream: player.playingStream,
                        builder: (_, ps) => IconButton(
                          icon: Icon((ps.data ?? false) ? Icons.pause : Icons.play_arrow, size: 30),
                          onPressed: () {
                            st.tap();
                            (ps.data ?? false) ? player.pause() : player.play();
                          },
                        ),
                      ),
                    ]),
                  ),
                  StreamBuilder<Duration>(
                    stream: player.positionStream,
                    builder: (_, ps) {
                      final d = (player.duration ?? t.duration ?? Duration.zero).inMilliseconds;
                      final v = d <= 0 ? 0.0 : ((ps.data ?? Duration.zero).inMilliseconds / d).clamp(0.0, 1.0);
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                        child: LinearProgressIndicator(value: v, minHeight: 2, color: Colors.white, backgroundColor: Colors.white24),
                      );
                    },
                  ),
                ]),
              ),
            );
          },
        );
      });
}

// ---------- now playing ----------
class NowPlaying extends StatelessWidget {
  const NowPlaying({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
        body: Container(
          decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF4A3B3B), bg], stops: [0, .75])),
          child: SafeArea(
            child: StreamBuilder<SequenceState?>(
              stream: player.sequenceStateStream,
              builder: (_, snap) {
                final t = snap.data?.currentSource?.tag;
                if (t is! MediaItem) return const SizedBox.shrink();
                final s = st.byId[int.tryParse(t.id)];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(children: [
                    Row(children: [
                      IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 32), onPressed: () => Navigator.pop(c)),
                      const Expanded(child: Text('PLAYING FROM YOUR LIBRARY', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, letterSpacing: 1, fontWeight: FontWeight.w600))),
                      IconButton(icon: const Icon(Icons.more_vert), onPressed: s == null ? null : () => songMenu(c, s)),
                    ]),
                    const Spacer(),
                    LayoutBuilder(builder: (_, bc) => Art(s, bc.maxWidth, 8)),
                    const Spacer(),
                    W(() {
                      final lk = s != null && st.liked.contains(s.id);
                      return Row(children: [
                        Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                          Text(t.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 16)),
                        ])),
                        if (s != null) IconButton(icon: Icon(lk ? Icons.favorite : Icons.favorite_border, color: lk ? green : Colors.white, size: 28), onPressed: () => st.toggleLike(s.id)),
                      ]);
                    }),
                    const Seek(),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      StreamBuilder<bool>(
                        stream: player.shuffleModeEnabledStream,
                        builder: (_, s) => IconButton(
                          icon: Icon(Icons.shuffle, color: (s.data ?? false) ? green : Colors.white),
                          onPressed: () async {
                            st.tap();
                            final on = !(s.data ?? false);
                            await player.setShuffleModeEnabled(on);
                            if (on) await player.shuffle();
                          },
                        ),
                      ),
                      IconButton(iconSize: 40, icon: const Icon(Icons.skip_previous), onPressed: () { st.tap(); player.seekToPrevious(); }),
                      StreamBuilder<bool>(
                        stream: player.playingStream,
                        builder: (_, ps) => GestureDetector(
                          onTap: () {
                            st.tap();
                            (ps.data ?? false) ? player.pause() : player.play();
                          },
                          child: CircleAvatar(radius: 34, backgroundColor: Colors.white, child: Icon((ps.data ?? false) ? Icons.pause : Icons.play_arrow, color: Colors.black, size: 42)),
                        ),
                      ),
                      IconButton(iconSize: 40, icon: const Icon(Icons.skip_next), onPressed: () { st.tap(); player.seekToNext(); }),
                      StreamBuilder<LoopMode>(
                        stream: player.loopModeStream,
                        builder: (_, l) {
                          final m = l.data ?? LoopMode.off;
                          return IconButton(
                            icon: Icon(m == LoopMode.one ? Icons.repeat_one : Icons.repeat, color: m == LoopMode.off ? Colors.white : green),
                            onPressed: () => player.setLoopMode(LoopMode.values[(m.index + 1) % 3]),
                          );
                        },
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      PopupMenuButton<double>(
                        icon: const Icon(Icons.speed),
                        color: card,
                        onSelected: (v) {
                          player.setSpeed(v);
                          st.speed = v;
                          st.upd();
                        },
                        itemBuilder: (_) => [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map((v) => PopupMenuItem(value: v, child: Text('${v}x'))).toList(),
                      ),
                      W(() => IconButton(
                            icon: Icon(Icons.bedtime_outlined, color: st.sleepT != null ? green : Colors.white),
                            onPressed: () => showModalBottomSheet(
                              context: c,
                              backgroundColor: card,
                              builder: (d) => SafeArea(
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  const ListTile(title: Text('Sleep timer', style: TextStyle(fontWeight: FontWeight.bold))),
                                  for (final m in [5, 15, 30, 45, 60])
                                    ListTile(title: Text('$m minutes'), onTap: () { st.setSleep(m); Navigator.pop(d); }),
                                  ListTile(title: const Text('Turn off'), onTap: () { st.setSleep(0); Navigator.pop(d); }),
                                ]),
                              ),
                            ),
                          )),
                      IconButton(icon: const Icon(Icons.queue_music), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const QueuePage()))),
                    ]),
                    const SizedBox(height: 8),
                  ]),
                );
              },
            ),
          ),
        ),
      );
}

class Seek extends StatefulWidget {
  const Seek({super.key});
  @override
  State<Seek> createState() => _SeekState();
}

class _SeekState extends State<Seek> {
  double? drag;
  @override
  Widget build(BuildContext c) => StreamBuilder<Duration>(
        stream: player.positionStream,
        builder: (_, s) {
          final pos = s.data ?? Duration.zero;
          final dur = player.duration ?? Duration.zero;
          final mx = dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
          final v = (drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, mx).toDouble();
          return Column(children: [
            SliderTheme(
              data: SliderTheme.of(c).copyWith(activeTrackColor: Colors.white, inactiveTrackColor: Colors.white24, thumbColor: Colors.white, overlayShape: SliderComponentShape.noOverlay),
              child: Slider(
                min: 0,
                max: mx,
                value: v,
                onChanged: (x) => setState(() => drag = x),
                onChangeEnd: (x) {
                  player.seek(Duration(milliseconds: x.round()));
                  setState(() => drag = null);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(fmt(Duration(milliseconds: v.round())), style: const TextStyle(fontSize: 12, color: Colors.white70)),
                Text(fmt(dur), style: const TextStyle(fontSize: 12, color: Colors.white70)),
              ]),
            ),
          ]);
        },
      );
}

class QueuePage extends StatelessWidget {
  const QueuePage({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Queue')),
        body: StreamBuilder<SequenceState?>(
          stream: player.sequenceStateStream,
          builder: (_, snap) {
            final seq = snap.data?.sequence ?? [];
            final ci = snap.data?.currentIndex;
            if (st.q == null) return const Center(child: Text('Nothing in queue'));
            return ReorderableListView.builder(
              itemCount: seq.length,
              onReorder: (o, n) {
                if (n > o) n--;
                st.q!.move(o, n);
              },
              itemBuilder: (_, i) {
                final t = seq[i].tag as MediaItem;
                return ListTile(
                  key: ValueKey('${t.id}_$i'),
                  leading: Art(st.byId[int.tryParse(t.id)], 44, 4),
                  title: Text(t.title, maxLines: 1, style: TextStyle(color: i == ci ? green : Colors.white)),
                  subtitle: Text(t.artist ?? '', maxLines: 1, style: const TextStyle(color: Colors.white60)),
                  onTap: () => player.seek(Duration.zero, index: i),
                  trailing: IconButton(icon: const Icon(Icons.close, color: Colors.white60), onPressed: () => st.q!.removeAt(i)),
                );
              },
            );
          },
        ),
      );
}

// ---------- tabs ----------
class HomeTab extends StatelessWidget {
  const HomeTab({super.key});
  @override
  Widget build(BuildContext c) => W(() {
        final h = DateTime.now().hour;
        final greet = h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
        final songs = st.songs;
        final rec = st.recents.where(st.byId.containsKey).map((e) => st.byId[e]!).toList();
        final top = (st.plays.entries.where((e) => st.byId.containsKey(e.key)).toList()..sort((a, b) => b.value.compareTo(a.value))).take(10).map((e) => st.byId[e.key]!).toList();
        Widget quick(String n, Widget lead, VoidCallback f) => GestureDetector(
              onTap: f,
              child: Container(
                decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(4)),
                clipBehavior: Clip.antiAlias,
                child: Row(children: [lead, const SizedBox(width: 10), Expanded(child: Text(n, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)))]),
              ),
            );
        return ListView(padding: const EdgeInsets.only(bottom: 16), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(children: [
              Expanded(child: Text(greet, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
              IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const SettingsPage()))),
            ]),
          ),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            childAspectRatio: 3.2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              quick('Liked Songs', Container(width: 56, height: 56, color: const Color(0xFF5038A0), child: const Icon(Icons.favorite, size: 24)),
                  () => Navigator.push(c, MaterialPageRoute(builder: (_) => SongListPage('Liked Songs', () => st.likedSongs)))),
              quick('Shuffle all', Container(width: 56, height: 56, color: green, child: const Icon(Icons.shuffle, color: Colors.black)), () => st.playQueue(songs, 0, shuf: true)),
              for (final pl in st.pls.take(6))
                quick(pl.name, Container(width: 56, height: 56, color: const Color(0xFF404040), child: const Icon(Icons.queue_music)),
                    () => Navigator.push(c, MaterialPageRoute(builder: (_) => PlaylistPage(pl)))),
            ],
          ),
          if (songs.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No music found. Pull settings → Rescan library.', textAlign: TextAlign.center))),
          if (rec.isNotEmpty) ...[
            const Padding(padding: EdgeInsets.fromLTRB(16, 24, 16, 8), child: Text('Recently played', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
            SizedBox(
              height: 190,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: rec.length,
                itemBuilder: (_, i) => GestureDetector(
                  onTap: () => st.playQueue(rec, i),
                  child: Container(
                    width: 140,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Art(rec[i], 140, 6),
                      const SizedBox(height: 6),
                      Text(rec[i].title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(rec[i].artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 12)),
                    ]),
                  ),
                ),
              ),
            ),
          ],
          if (top.isNotEmpty) ...[
            const Padding(padding: EdgeInsets.fromLTRB(16, 24, 16, 4), child: Text('Most played', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
            for (var i = 0; i < top.length; i++) SongTile(top[i], top, i),
          ],
        ]);
      });
}

class SearchTab extends StatefulWidget {
  const SearchTab({super.key});
  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  String q = '';
  @override
  Widget build(BuildContext c) => W(() {
        final r = q.isEmpty
            ? <Song>[]
            : st.all.where((s) => '${s.title} ${s.artist} ${s.album}'.toLowerCase().contains(q.toLowerCase())).toList();
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => q = v),
              style: const TextStyle(color: Colors.black),
              cursorColor: Colors.black,
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white,
                hintText: 'What do you want to listen to?',
                hintStyle: const TextStyle(color: Colors.black54),
                prefixIcon: const Icon(Icons.search, color: Colors.black),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: q.isEmpty
                ? const Center(child: Text('Search your songs, artists and albums', style: TextStyle(color: Colors.white60)))
                : r.isEmpty
                    ? const Center(child: Text('No results found'))
                    : ListView.builder(itemCount: r.length, itemBuilder: (_, i) => SongTile(r[i], r, i)),
          ),
        ]);
      });
}

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});
  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  String f = 'Playlists';
  @override
  Widget build(BuildContext c) => W(() {
        final songs = st.songs;
        Widget body;
        if (f == 'Songs') {
          body = ListView.builder(itemCount: songs.length + 1, itemBuilder: (_, i) => i == 0 ? PlayRow(songs) : SongTile(songs[i - 1], songs, i - 1));
        } else if (f == 'Playlists') {
          body = ListView(children: [
            ListTile(
              leading: Container(width: 56, height: 56, color: card, child: const Icon(Icons.add)),
              title: const Text('Create playlist'),
              onTap: () async {
                final n = await ask(c, 'New playlist');
                if (n != null && n.isNotEmpty) {
                  st.pls.add(PL(n, []));
                  st.upd();
                }
              },
            ),
            ListTile(
              leading: Container(width: 56, height: 56, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: const Color(0xFF5038A0)), child: const Icon(Icons.favorite)),
              title: const Text('Liked Songs'),
              subtitle: Text('Playlist • ${st.liked.length} songs'),
              onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => SongListPage('Liked Songs', () => st.likedSongs))),
            ),
            for (final pl in st.pls)
              ListTile(
                leading: Container(width: 56, height: 56, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), color: card), child: const Icon(Icons.queue_music)),
                title: Text(pl.name),
                subtitle: Text('Playlist • ${pl.ids.length} songs'),
                onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => PlaylistPage(pl))),
              ),
          ]);
        } else {
          final alb = f == 'Albums';
          final g = <String, List<Song>>{};
          for (final s in songs) {
            g.putIfAbsent(alb ? s.album : s.artist, () => []).add(s);
          }
          final keys = g.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          body = ListView.builder(
            itemCount: keys.length,
            itemBuilder: (_, i) => ListTile(
              leading: Art(g[keys[i]]!.first, 56, alb ? 4 : 28),
              title: Text(keys[i], maxLines: 1),
              subtitle: Text('${alb ? 'Album' : 'Artist'} • ${g[keys[i]]!.length} songs'),
              onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => SongListPage(keys[i], () => g[keys[i]]!))),
            ),
          );
        }
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(children: [
              const Expanded(child: Text('Your Library', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
              IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const SettingsPage()))),
            ]),
          ),
          SizedBox(
            height: 48,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (final x in ['Playlists', 'Songs', 'Albums', 'Artists'])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: ChoiceChip(
                    label: Text(x, style: TextStyle(color: f == x ? Colors.black : Colors.white)),
                    selected: f == x,
                    showCheckmark: false,
                    selectedColor: green,
                    backgroundColor: card,
                    side: BorderSide.none,
                    shape: const StadiumBorder(),
                    onSelected: (_) => setState(() => f = x),
                  ),
                ),
            ]),
          ),
          Expanded(child: body),
        ]);
      });
}

class SongListPage extends StatelessWidget {
  final String title;
  final List<Song> Function() get;
  const SongListPage(this.title, this.get, {super.key});
  @override
  Widget build(BuildContext c) => W(() {
        final l = get();
        return Scaffold(
          appBar: AppBar(title: Text(title)),
          body: l.isEmpty
              ? const Center(child: Text('Nothing here yet'))
              : ListView.builder(itemCount: l.length + 1, itemBuilder: (_, i) => i == 0 ? PlayRow(l) : SongTile(l[i - 1], l, i - 1)),
        );
      });
}

class PlaylistPage extends StatelessWidget {
  final PL pl;
  const PlaylistPage(this.pl, {super.key});

  void addSongs(BuildContext c) {
    showModalBottomSheet(
      context: c,
      isScrollControlled: true,
      backgroundColor: card,
      builder: (_) => StatefulBuilder(
        builder: (ctx, set) => SizedBox(
          height: MediaQuery.of(c).size.height * .8,
          child: Column(children: [
            const ListTile(title: Text('Add songs', style: TextStyle(fontWeight: FontWeight.bold))),
            Expanded(
              child: ListView(children: [
                for (final s in st.songs)
                  CheckboxListTile(
                    activeColor: green,
                    secondary: Art(s, 44, 4),
                    title: Text(s.title, maxLines: 1),
                    subtitle: Text(s.artist, maxLines: 1),
                    value: pl.ids.contains(s.id),
                    onChanged: (v) {
                      v == true ? pl.ids.add(s.id) : pl.ids.remove(s.id);
                      st.upd();
                      set(() {});
                    },
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext c) => W(() {
        if (!st.pls.contains(pl)) return const Scaffold();
        final l = pl.ids.where(st.byId.containsKey).map((e) => st.byId[e]!).toList();
        return Scaffold(
          appBar: AppBar(title: Text(pl.name), actions: [
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () async {
                final n = await ask(c, 'Rename playlist', init: pl.name);
                if (n != null && n.isNotEmpty) {
                  pl.name = n;
                  st.upd();
                }
              },
            ),
            IconButton(icon: const Icon(Icons.playlist_add), onPressed: () => addSongs(c)),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (!st.confirmDel || await confirm(c, 'Delete "${pl.name}"?')) {
                  st.pls.remove(pl);
                  st.upd();
                  if (c.mounted) Navigator.pop(c);
                }
              },
            ),
          ]),
          body: Column(children: [
            PlayRow(l),
            if (l.length > 1) const Padding(padding: EdgeInsets.only(bottom: 4), child: Text('Hold the ≡ handle to reorder', style: TextStyle(color: Colors.white38, fontSize: 12))),
            Expanded(
              child: l.isEmpty
                  ? Center(child: TextButton(onPressed: () => addSongs(c), child: const Text('Add songs', style: TextStyle(color: green, fontSize: 18))))
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: l.length,
                      onReorder: (o, n) {
                        if (n > o) n--;
                        final x = pl.ids.removeAt(o);
                        pl.ids.insert(n, x);
                        st.upd();
                      },
                      itemBuilder: (_, i) => Container(key: ValueKey('${l[i].id}_$i'), child: SongTile(l[i], l, i, from: pl, handle: i)),
                    ),
            ),
          ]),
        );
      });
}

// ---------- settings ----------
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  Widget h(String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 4), child: Text(t, style: const TextStyle(color: green, fontWeight: FontWeight.bold)));
  Widget sw(String t, String sub, bool v, void Function(bool) f) =>
      SwitchListTile(activeColor: green, title: Text(t), subtitle: Text(sub), value: v, onChanged: (x) { f(x); st.upd(); });

  @override
  Widget build(BuildContext c) => W(() => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(children: [
          h('MINI PLAYER'),
          ListTile(
            title: const Text('Swipe gesture'),
            subtitle: Text({'skip': 'Swipe to skip songs', 'close': 'Swipe to close & stop', 'off': 'Disabled'}[st.sw]!),
            onTap: () async {
              final v = await pick<String>(c, 'Mini player swipe', {'skip': 'Swipe to skip songs', 'close': 'Swipe to close & stop music', 'off': 'Disabled'});
              if (v != null) { st.sw = v; st.upd(); }
            },
          ),
          h('PLAYBACK'),
          ListTile(
            title: const Text('Default playback speed'),
            subtitle: Text('${st.speed}x'),
            onTap: () async {
              final v = await pick<double>(c, 'Speed', {for (final x in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]) x: '${x}x'});
              if (v != null) { st.speed = v; player.setSpeed(v); st.upd(); }
            },
          ),
          sw('Skip silence', 'Skip quiet gaps in tracks', st.skipSil, (v) { st.skipSil = v; player.setSkipSilenceEnabled(v); }),
          sw('Resume last queue', 'Restore your last song when the app opens', st.resume, (v) => st.resume = v),
          h('LIBRARY'),
          ListTile(
            title: const Text('Sort songs by'),
            subtitle: Text({'title': 'Title', 'artist': 'Artist', 'recent': 'Recently added', 'plays': 'Most played'}[st.sort]!),
            onTap: () async {
              final v = await pick<String>(c, 'Sort by', {'title': 'Title', 'artist': 'Artist', 'recent': 'Recently added', 'plays': 'Most played'});
              if (v != null) { st.sort = v; st.upd(); }
            },
          ),
          ListTile(
            title: const Text('Hide short tracks'),
            subtitle: Text(st.minSec == 0 ? 'Show everything' : 'Shorter than ${st.minSec} seconds'),
            onTap: () async {
              final v = await pick<int>(c, 'Hide tracks shorter than', {0: 'Show everything', 15: '15 seconds', 30: '30 seconds', 60: '1 minute', 120: '2 minutes'});
              if (v != null) { st.minSec = v; st.upd(); }
            },
          ),
          ListTile(
            title: const Text('Rescan library'),
            subtitle: Text('${st.all.length} songs found'),
            onTap: () async { await st.scan(); if (c.mounted) msg(c, 'Found ${st.all.length} songs'); },
          ),
          h('APPEARANCE & FEEL'),
          sw('Show album art', 'Turn off to save memory', st.showArt, (v) => st.showArt = v),
          sw('Haptic feedback', 'Vibrate lightly on taps', st.haptics, (v) => st.haptics = v),
          sw('Confirm playlist delete', 'Ask before deleting a playlist', st.confirmDel, (v) => st.confirmDel = v),
          h('DATA'),
          ListTile(
            title: const Text('Clear listening history'),
            onTap: () async {
              if (await confirm(c, 'Clear recents and play counts?')) { st.recents.clear(); st.plays.clear(); st.upd(); }
            },
          ),
          ListTile(
            title: const Text('Reset all settings'),
            onTap: () async {
              if (await confirm(c, 'Reset settings to default?')) {
                st.sw = 'skip'; st.sort = 'title'; st.minSec = 30; st.resume = true; st.haptics = true;
                st.showArt = true; st.skipSil = false; st.confirmDel = true; st.speed = 1;
                player.setSpeed(1); player.setSkipSilenceEnabled(false);
                st.upd();
              }
            },
          ),
          const ListTile(title: Text('Version'), subtitle: Text('3.0.0')),
        ]),
      ));
}
