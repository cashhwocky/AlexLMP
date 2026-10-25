// FILE: custom/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Globals / constants
// ---------------------------------------------------------------------------

class PixelColor {
  final String name;
  final Color color;
  const PixelColor(this.name, this.color);
}

const List<PixelColor> seedOptions = [
  PixelColor('Indigo', Color(0xFF4B5C92)),
  PixelColor('Obsidian', Color(0xFF1C1C1E)),
  PixelColor('Porcelain', Color(0xFFF4F0EA)),
  PixelColor('Frost', Color(0xFFD6E4F0)),
  PixelColor('Lemongrass', Color(0xFFD8E698)),
  PixelColor('Peony', Color(0xFFF29CB6)),
  PixelColor('Jade', Color(0xFFA3C9A8)),
  PixelColor('Moonstone', Color(0xFF8FA3B0)),
];

const List<double> speedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
const List<String> audioExts = ['.mp3', '.wav', '.flac', '.m4a'];
const List<String> scanDirs = [
  '/storage/emulated/0/Music',
  '/storage/emulated/0/Download',
];

enum SortMode { az, recent }

enum RepeatMode { off, all, one }

final GlobalKey<ScaffoldMessengerState> messengerKey =
    GlobalKey<ScaffoldMessengerState>();

void toast(String message) {
  messengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
}

String fmt(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

class Track {
  final String path;
  final String title;
  final DateTime added;
  final String ext;

  const Track(this.path, this.title, this.added, this.ext);

  factory Track.fromPath(String p) {
    DateTime d;
    try {
      d = File(p).lastModifiedSync();
    } catch (_) {
      d = DateTime.fromMillisecondsSinceEpoch(0);
    }
    final name = p.split('/').last;
    final dot = name.lastIndexOf('.');
    return Track(
      p,
      dot > 0 ? name.substring(0, dot) : name,
      d,
      dot > 0 ? name.substring(dot + 1).toUpperCase() : '',
    );
  }
}

// ---------------------------------------------------------------------------
// App state
// ---------------------------------------------------------------------------

class AppState extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();
  SharedPreferences? _prefs;

  int seedIndex = 0;
  bool amoled = false;
  ThemeMode themeMode = ThemeMode.system;

  List<Track> tracks = [];
  Set<String> favorites = {};
  Map<String, List<String>> playlists = {};
  List<String> extraPaths = [];
  Set<String> _scanned = {};

  String query = '';
  SortMode sort = SortMode.az;
  bool scanning = false;

  List<Track> queue = [];
  int index = -1;
  bool shuffle = false;
  RepeatMode repeat = RepeatMode.off;
  double speed = 1.0;
  bool playing = false;
  bool _handling = false;

  Timer? sleepTimer;
  DateTime? sleepEnd;

  Track? get current =>
      (index >= 0 && index < queue.length) ? queue[index] : null;

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    seedIndex = (p.getInt('seed') ?? 0).clamp(0, seedOptions.length - 1).toInt();
    amoled = p.getBool('amoled') ?? false;
    themeMode =
        ThemeMode.values[(p.getInt('themeMode') ?? 0).clamp(0, 2).toInt()];
    sort = SortMode.values[(p.getInt('sort') ?? 0).clamp(0, 1).toInt()];
    favorites = (p.getStringList('favorites') ?? <String>[]).toSet();
    extraPaths = p.getStringList('extra') ?? <String>[];
    final pl = p.getString('playlists');
    if (pl != null) {
      try {
        final decoded = jsonDecode(pl) as Map;
        playlists = decoded.map(
            (k, v) => MapEntry(k as String, List<String>.from(v as List)));
      } catch (_) {
        playlists = {};
      }
    }

    player.playerStateStream.listen((s) {
      playing = s.playing;
      if (s.processingState == ProcessingState.completed) {
        _onCompleted();
      }
      notifyListeners();
    });

    _rebuildTracks();
    notifyListeners();
    scan();
  }

  // ----- persistence -------------------------------------------------------

  void _saveFavorites() =>
      _prefs?.setStringList('favorites', favorites.toList());
  void _savePlaylists() => _prefs?.setString('playlists', jsonEncode(playlists));
  void _saveExtra() => _prefs?.setStringList('extra', extraPaths);

  // ----- theme -------------------------------------------------------------

  void setSeed(int i) {
    seedIndex = i;
    _prefs?.setInt('seed', i);
    notifyListeners();
  }

  void setAmoled(bool v) {
    amoled = v;
    _prefs?.setBool('amoled', v);
    notifyListeners();
  }

  void setThemeMode(ThemeMode m) {
    themeMode = m;
    _prefs?.setInt('themeMode', m.index);
    notifyListeners();
  }

  // ----- library -----------------------------------------------------------

  void _rebuildTracks() {
    final paths = <String>{
      ..._scanned,
      ...extraPaths.where((p) {
        try {
          return File(p).existsSync();
        } catch (_) {
          return false;
        }
      }),
    };
    final old = {for (final t in tracks) t.path: t};
    tracks = [for (final p in paths) old[p] ?? Track.fromPath(p)];
  }

  bool _isAudio(String path) {
    final l = path.toLowerCase();
    return audioExts.any((e) => l.endsWith(e));
  }

  Future<void> _scanDir(String dirPath, Set<String> out) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return;
      await for (final e in dir
          .list(recursive: true, followLinks: false)
          .handleError((_) {})) {
        if (e is File && _isAudio(e.path)) {
          out.add(e.path);
        }
      }
    } catch (_) {}
  }

  Future<void> requestPermissions() async {
    try {
      await [Permission.audio, Permission.storage].request();
    } catch (_) {}
  }

  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    notifyListeners();
    try {
      await requestPermissions();
      final found = <String>{};
      for (final d in scanDirs) {
        await _scanDir(d, found);
      }
      _scanned = found;
      _rebuildTracks();
    } catch (_) {}
    scanning = false;
    notifyListeners();
  }

  Future<void> pickFiles() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['mp3', 'wav', 'flac', 'm4a'],
      );
      if (res == null) return;
      var added = 0;
      for (final f in res.files) {
        final p = f.path;
        if (p != null && _isAudio(p) && !extraPaths.contains(p)) {
          extraPaths.add(p);
          added++;
        }
      }
      _saveExtra();
      _rebuildTracks();
      notifyListeners();
      toast(added > 0 ? 'Added $added song(s)' : 'No new songs added');
    } catch (e) {
      toast('Could not pick files');
    }
  }

  Future<void> pickFolder() async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null) return;
      scanning = true;
      notifyListeners();
      final found = <String>{};
      await _scanDir(dir, found);
      var added = 0;
      for (final p in found) {
        if (!extraPaths.contains(p)) {
          extraPaths.add(p);
          added++;
        }
      }
      _saveExtra();
      _rebuildTracks();
      scanning = false;
      notifyListeners();
      toast(added > 0 ? 'Found $added new song(s)' : 'No new songs found');
    } catch (e) {
      scanning = false;
      notifyListeners();
      toast('Could not scan folder');
    }
  }

  void setQuery(String q) {
    query = q;
    notifyListeners();
  }

  void setSort(SortMode m) {
    sort = m;
    _prefs?.setInt('sort', m.index);
    notifyListeners();
  }

  List<Track> get visible {
    final q = query.trim().toLowerCase();
    final l = tracks
        .where((t) => q.isEmpty || t.title.toLowerCase().contains(q))
        .toList();
    if (sort == SortMode.az) {
      l.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    } else {
      l.sort((a, b) => b.added.compareTo(a.added));
    }
    return l;
  }

  List<Track> get favoriteTracks {
    final l = tracks.where((t) => favorites.contains(t.path)).toList();
    l.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return l;
  }

  // ----- favorites ---------------------------------------------------------

  void toggleFavorite(Track t) {
    if (!favorites.remove(t.path)) favorites.add(t.path);
    _saveFavorites();
    notifyListeners();
  }

  bool isFavorite(Track t) => favorites.contains(t.path);

  // ----- playlists ---------------------------------------------------------

  void createPlaylist(String name) {
    playlists.putIfAbsent(name, () => <String>[]);
    _savePlaylists();
    notifyListeners();
  }

  void deletePlaylist(String name) {
    playlists.remove(name);
    _savePlaylists();
    notifyListeners();
  }

  void addToPlaylist(String name, Track t) {
    final l = playlists.putIfAbsent(name, () => <String>[]);
    if (!l.contains(t.path)) l.add(t.path);
    _savePlaylists();
    notifyListeners();
  }

  void removeFromPlaylist(String name, Track t) {
    playlists[name]?.remove(t.path);
    _savePlaylists();
    notifyListeners();
  }

  List<Track> playlistTracks(String name) {
    final byPath = {for (final t in tracks) t.path: t};
    final paths = playlists[name] ?? const <String>[];
    return [
      for (final p in paths)
        if (byPath[p] != null) byPath[p]!
    ];
  }

  // ----- playback ----------------------------------------------------------

  Future<void> playQueue(List<Track> list, int i) async {
    if (list.isEmpty || i < 0 || i >= list.length) return;
    if (current?.path == list[i].path && queue.length == list.length) {
      togglePlay();
      return;
    }
    queue = List<Track>.of(list);
    await _playIndex(i);
  }

  Future<void> _playIndex(int i) async {
    if (i < 0 || i >= queue.length) return;
    index = i;
    notifyListeners();
    try {
      await player.setFilePath(queue[i].path);
      await player.setSpeed(speed);
      player.play();
    } catch (e) {
      toast('Cannot play "${queue[i].title}"');
    }
  }

  int _randomOther() {
    if (queue.length <= 1) return index;
    final r = Random();
    var n = index;
    while (n == index) {
      n = r.nextInt(queue.length);
    }
    return n;
  }

  Future<void> _onCompleted() async {
    if (_handling) return;
    _handling = true;
    try {
      if (queue.isEmpty) return;
      if (repeat == RepeatMode.one) {
        await player.seek(Duration.zero);
        player.play();
      } else if (shuffle && queue.length > 1) {
        await _playIndex(_randomOther());
      } else if (index < queue.length - 1) {
        await _playIndex(index + 1);
      } else if (repeat == RepeatMode.all) {
        await _playIndex(0);
      } else {
        await player.pause();
        await player.seek(Duration.zero);
      }
    } finally {
      _handling = false;
    }
  }

  void togglePlay() {
    if (current == null) return;
    if (player.playing) {
      player.pause();
    } else {
      if (player.processingState == ProcessingState.completed) {
        player.seek(Duration.zero);
      }
      player.play();
    }
  }

  Future<void> next() async {
    if (queue.isEmpty) return;
    if (shuffle && queue.length > 1) {
      await _playIndex(_randomOther());
    } else {
      await _playIndex((index + 1) % queue.length);
    }
  }

  Future<void> previous() async {
    if (queue.isEmpty) return;
    if (player.position.inSeconds > 3) {
      await player.seek(Duration.zero);
      return;
    }
    if (index > 0) {
      await _playIndex(index - 1);
    } else if (repeat == RepeatMode.all) {
      await _playIndex(queue.length - 1);
    } else {
      await player.seek(Duration.zero);
    }
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    notifyListeners();
  }

  void cycleRepeat() {
    repeat = RepeatMode.values[(repeat.index + 1) % 3];
    notifyListeners();
  }

  Future<void> setSpeed(double s) async {
    speed = s;
    try {
      await player.setSpeed(s);
    } catch (_) {}
    notifyListeners();
  }

  void setSleep(int minutes) {
    sleepTimer?.cancel();
    sleepTimer = null;
    sleepEnd = null;
    if (minutes > 0) {
      sleepEnd = DateTime.now().add(Duration(minutes: minutes));
      sleepTimer = Timer(Duration(minutes: minutes), () {
        player.pause();
        sleepTimer = null;
        sleepEnd = null;
        notifyListeners();
        toast('Sleep timer: playback paused');
      });
      toast('Sleep timer set for $minutes min');
    } else {
      toast('Sleep timer off');
    }
    notifyListeners();
  }
}

final AppState app = AppState();

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await app.init();
  runApp(const AudioApp());
}

ThemeData buildTheme(Brightness b) {
  var scheme = ColorScheme.fromSeed(
    seedColor: seedOptions[app.seedIndex].color,
    brightness: b,
  );
  if (b == Brightness.dark && app.amoled) {
    scheme = scheme.copyWith(
      surface: Colors.black,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xFF080808),
      surfaceContainer: const Color(0xFF0F0F0F),
      surfaceContainerHigh: const Color(0xFF151515),
      surfaceContainerHighest: const Color(0xFF1C1C1C),
    );
  }
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineSmall: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleLarge: TextStyle(fontWeight: FontWeight.w600),
      titleMedium: TextStyle(fontWeight: FontWeight.w600),
    ),
  );
}

class AudioApp extends StatelessWidget {
  const AudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        return MaterialApp(
          title: 'Pixel Audio Player',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: messengerKey,
          themeMode: app.themeMode,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          home: const HomeShell(),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Shell
// ---------------------------------------------------------------------------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    const pages = <Widget>[
      LibraryPage(),
      FavoritesPage(),
      PlaylistsPage(),
      SettingsPage(),
    ];
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Expanded(child: IndexedStack(index: tab, children: pages)),
                if (app.current != null) const MiniPlayer(),
              ],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.library_music_outlined),
                  selectedIcon: Icon(Icons.library_music),
                  label: 'Library'),
              NavigationDestination(
                  icon: Icon(Icons.favorite_border),
                  selectedIcon: Icon(Icons.favorite),
                  label: 'Favorites'),
              NavigationDestination(
                  icon: Icon(Icons.queue_music_outlined),
                  selectedIcon: Icon(Icons.queue_music),
                  label: 'Playlists'),
              NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'Settings'),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Shared helpers / widgets
// ---------------------------------------------------------------------------

Future<String?> askName(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const NameDialog(),
  );
}

class NameDialog extends StatefulWidget {
  const NameDialog({super.key});

  @override
  State<NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<NameDialog> {
  final TextEditingController c = TextEditingController();

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New playlist'),
      content: TextField(
        controller: c,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          hintText: 'Playlist name',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text('Create')),
      ],
    );
  }
}

Future<void> addToPlaylistSheet(BuildContext context, Track t) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New playlist'),
              onTap: () async {
                Navigator.pop(ctx);
                final n = await askName(context);
                if (n != null && n.trim().isNotEmpty) {
                  app.createPlaylist(n.trim());
                  app.addToPlaylist(n.trim(), t);
                  toast('Added to ${n.trim()}');
                }
              },
            ),
            for (final n in app.playlists.keys)
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(n),
                onTap: () {
                  app.addToPlaylist(n, t);
                  Navigator.pop(ctx);
                  toast('Added to $n');
                },
              ),
          ],
        ),
      );
    },
  );
}

void openNowPlaying(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height,
      child: const NowPlayingSheet(),
    ),
  );
}

class ArtBox extends StatelessWidget {
  final double size;
  final double radius;
  final bool active;
  const ArtBox(
      {super.key, required this.size, required this.radius, this.active = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cs.primaryContainer, cs.tertiaryContainer],
        ),
      ),
      child: Icon(
        active ? Icons.graphic_eq : Icons.music_note_rounded,
        size: size * 0.5,
        color: cs.onPrimaryContainer,
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;
  const EmptyState(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle,
      this.action});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, color: cs.outline),
            const SizedBox(height: 16),
            Text(title,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(subtitle,
                style: TextStyle(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

class TrackTile extends StatelessWidget {
  final Track track;
  final List<Track> queue;
  final int index;
  final String? playlist;
  const TrackTile(
      {super.key,
      required this.track,
      required this.queue,
      required this.index,
      this.playlist});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isCur = app.current?.path == track.path;
    final fav = app.isFavorite(track);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: isCur ? cs.secondaryContainer : cs.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => app.playQueue(queue, index),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Row(
            children: [
              ArtBox(size: 52, radius: 16, active: isCur && app.playing),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(track.ext.isEmpty ? 'Audio' : track.ext,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                    color: fav ? cs.primary : cs.onSurfaceVariant),
                onPressed: () => app.toggleFavorite(track),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (v) {
                  if (v == 'add') {
                    addToPlaylistSheet(context, track);
                  } else if (v == 'remove' && playlist != null) {
                    app.removeFromPlaylist(playlist!, track);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'add', child: Text('Add to playlist')),
                  if (playlist != null)
                    const PopupMenuItem(
                        value: 'remove', child: Text('Remove from playlist')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TrackList extends StatelessWidget {
  final List<Track> tracks;
  final String? playlist;
  final Future<void> Function()? onRefresh;
  const TrackList(
      {super.key, required this.tracks, this.playlist, this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final list = ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: tracks.length,
      itemBuilder: (_, i) => TrackTile(
        track: tracks[i],
        queue: tracks,
        index: i,
        playlist: playlist,
      ),
    );
    if (onRefresh == null) return list;
    return RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}

// ---------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final list = app.visible;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Library',
                        style: Theme.of(context).textTheme.headlineMedium),
                  ),
                  if (app.scanning)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.5)),
                    )
                  else
                    IconButton(
                      tooltip: 'Rescan storage',
                      icon: const Icon(Icons.refresh),
                      onPressed: app.scan,
                    ),
                  PopupMenuButton<String>(
                    tooltip: 'Add songs',
                    icon: const Icon(Icons.add_circle_outline),
                    onSelected: (v) {
                      if (v == 'files') app.pickFiles();
                      if (v == 'folder') app.pickFolder();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: 'files',
                          child: ListTile(
                              leading: Icon(Icons.audio_file),
                              title: Text('Add songs'))),
                      PopupMenuItem(
                          value: 'folder',
                          child: ListTile(
                              leading: Icon(Icons.folder_open),
                              title: Text('Scan folder'))),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                onChanged: app.setQuery,
                decoration: InputDecoration(
                  hintText: 'Search ${app.tracks.length} songs',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: cs.surfaceContainerHigh,
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('A-Z'),
                    selected: app.sort == SortMode.az,
                    onSelected: (_) => app.setSort(SortMode.az),
                  ),
                  ChoiceChip(
                    label: const Text('Recently Added'),
                    selected: app.sort == SortMode.recent,
                    onSelected: (_) => app.setSort(SortMode.recent),
                  ),
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? EmptyState(
                      icon: Icons.music_off_outlined,
                      title: app.tracks.isEmpty
                          ? 'No songs yet'
                          : 'No matches',
                      subtitle: app.tracks.isEmpty
                          ? 'Songs in your Music and Download folders appear automatically. You can also add songs or scan a folder.'
                          : 'Try a different search.',
                      action: app.tracks.isEmpty
                          ? Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              alignment: WrapAlignment.center,
                              children: [
                                FilledButton.icon(
                                  onPressed: app.pickFiles,
                                  icon: const Icon(Icons.audio_file),
                                  label: const Text('Add songs'),
                                ),
                                FilledButton.tonalIcon(
                                  onPressed: app.pickFolder,
                                  icon: const Icon(Icons.folder_open),
                                  label: const Text('Scan folder'),
                                ),
                              ],
                            )
                          : null,
                    )
                  : TrackList(tracks: list, onRefresh: app.scan),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Favorites
// ---------------------------------------------------------------------------

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final list = app.favoriteTracks;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Favorites',
                        style: Theme.of(context).textTheme.headlineMedium),
                  ),
                  if (list.isNotEmpty)
                    FilledButton.tonalIcon(
                      onPressed: () {
                        app.shuffle = true;
                        app.playQueue(list, Random().nextInt(list.length));
                      },
                      icon: const Icon(Icons.shuffle),
                      label: const Text('Shuffle'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? const EmptyState(
                      icon: Icons.favorite_border,
                      title: 'No favorites yet',
                      subtitle: 'Tap the heart on any song to save it here.',
                    )
                  : TrackList(tracks: list),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Playlists
// ---------------------------------------------------------------------------

class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final names = app.playlists.keys.toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Playlists',
                        style: Theme.of(context).textTheme.headlineMedium),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      final n = await askName(context);
                      if (n != null && n.trim().isNotEmpty) {
                        app.createPlaylist(n.trim());
                      }
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('New'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: names.isEmpty
                  ? const EmptyState(
                      icon: Icons.queue_music_outlined,
                      title: 'No playlists yet',
                      subtitle:
                          'Create a playlist, then add songs from the ⋮ menu on any track.',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      itemCount: names.length,
                      itemBuilder: (_, i) {
                        final n = names[i];
                        final count = app.playlistTracks(n).length;
                        return Card(
                          elevation: 0,
                          margin: const EdgeInsets.only(bottom: 8),
                          color: cs.surfaceContainer,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(22)),
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 6),
                            leading: Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: cs.tertiaryContainer,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Icon(Icons.queue_music,
                                  color: cs.onTertiaryContainer),
                            ),
                            title: Text(n,
                                style:
                                    Theme.of(context).textTheme.titleMedium),
                            subtitle: Text('$count song(s)'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                  builder: (_) => PlaylistPage(name: n)),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class PlaylistPage extends StatelessWidget {
  final String name;
  const PlaylistPage({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final list = app.playlistTracks(name);
        return Scaffold(
          appBar: AppBar(
            title: Text(name),
            actions: [
              IconButton(
                tooltip: 'Delete playlist',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Delete playlist?'),
                      content: Text('"$name" will be removed.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel')),
                        FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Delete')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    if (context.mounted) Navigator.pop(context);
                    app.deletePlaylist(name);
                  }
                },
              ),
            ],
          ),
          body: Column(
            children: [
              if (list.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => app.playQueue(list, 0),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play all'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () {
                            app.shuffle = true;
                            app.playQueue(list, Random().nextInt(list.length));
                          },
                          icon: const Icon(Icons.shuffle),
                          label: const Text('Shuffle'),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: list.isEmpty
                    ? const EmptyState(
                        icon: Icons.library_add_outlined,
                        title: 'Empty playlist',
                        subtitle:
                            'Use the ⋮ menu on any song in your Library to add it here.',
                      )
                    : TrackList(tracks: list, playlist: name),
              ),
            ],
          ),
          bottomNavigationBar:
              app.current == null ? null : const SafeArea(child: MiniPlayer()),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Mini player
// ---------------------------------------------------------------------------

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = app.current;
    if (t == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: GestureDetector(
        onTap: () => openNowPlaying(context),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -200) openNowPlaying(context);
        },
        child: Material(
          color: cs.primaryContainer,
          elevation: 3,
          shadowColor: Colors.black54,
          borderRadius: BorderRadius.circular(32),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
                child: Row(
                  children: [
                    ArtBox(size: 46, radius: 23, active: app.playing),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: cs.onPrimaryContainer)),
                          Text('Swipe up for Now Playing',
                              maxLines: 1,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onPrimaryContainer
                                      .withValues(alpha: 0.7))),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                          app.playing ? Icons.pause_circle : Icons.play_circle,
                          size: 38,
                          color: cs.onPrimaryContainer),
                      onPressed: app.togglePlay,
                    ),
                    IconButton(
                      icon: Icon(Icons.skip_next_rounded,
                          color: cs.onPrimaryContainer),
                      onPressed: app.next,
                    ),
                  ],
                ),
              ),
              StreamBuilder<Duration>(
                stream: app.player.positionStream,
                builder: (context, snap) {
                  final d = app.player.duration?.inMilliseconds ?? 0;
                  final p = snap.data?.inMilliseconds ?? 0;
                  final v = d > 0 ? (p / d).clamp(0.0, 1.0).toDouble() : 0.0;
                  return LinearProgressIndicator(
                    value: v,
                    minHeight: 3,
                    backgroundColor: Colors.transparent,
                    color: cs.primary,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Now playing
// ---------------------------------------------------------------------------

class NowPlayingSheet extends StatelessWidget {
  const NowPlayingSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final t = app.current;
        if (t == null) {
          return const Center(child: Text('Nothing playing'));
        }
        final fav = app.isFavorite(t);
        final sleepEnd = app.sleepEnd;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
          child: Column(
            children: [
              const SizedBox(height: 8),
              LayoutBuilder(builder: (context, c) {
                final w = min(c.maxWidth, 340.0);
                return ArtBox(size: w, radius: 44, active: app.playing);
              }),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 4),
                        Text('${t.ext} • Local file',
                            style: TextStyle(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  IconButton(
                    iconSize: 30,
                    icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                        color: fav ? cs.primary : cs.onSurfaceVariant),
                    onPressed: () => app.toggleFavorite(t),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const SeekBar(),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    iconSize: 28,
                    isSelected: app.shuffle,
                    style: app.shuffle
                        ? IconButton.styleFrom(
                            backgroundColor: cs.secondaryContainer)
                        : null,
                    icon: const Icon(Icons.shuffle),
                    onPressed: app.toggleShuffle,
                  ),
                  IconButton(
                    iconSize: 42,
                    icon: const Icon(Icons.skip_previous_rounded),
                    onPressed: app.previous,
                  ),
                  FilledButton(
                    onPressed: app.togglePlay,
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(22),
                    ),
                    child: Icon(
                        app.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 44),
                  ),
                  IconButton(
                    iconSize: 42,
                    icon: const Icon(Icons.skip_next_rounded),
                    onPressed: app.next,
                  ),
                  IconButton(
                    iconSize: 28,
                    style: app.repeat != RepeatMode.off
                        ? IconButton.styleFrom(
                            backgroundColor: cs.secondaryContainer)
                        : null,
                    icon: Icon(app.repeat == RepeatMode.one
                        ? Icons.repeat_one
                        : Icons.repeat),
                    onPressed: app.cycleRepeat,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Repeat: ${app.repeat == RepeatMode.off ? 'Off' : app.repeat == RepeatMode.all ? 'All' : 'One'}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  PopupMenuButton<double>(
                    tooltip: 'Playback speed',
                    onSelected: app.setSpeed,
                    itemBuilder: (_) => [
                      for (final s in speedOptions)
                        CheckedPopupMenuItem<double>(
                          value: s,
                          checked: s == app.speed,
                          child: Text('${s}x'),
                        ),
                    ],
                    child: Chip(
                      avatar: const Icon(Icons.speed, size: 18),
                      label: Text('${app.speed}x'),
                    ),
                  ),
                  PopupMenuButton<int>(
                    tooltip: 'Sleep timer',
                    onSelected: app.setSleep,
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 15, child: Text('15 minutes')),
                      const PopupMenuItem(value: 30, child: Text('30 minutes')),
                      const PopupMenuItem(value: 60, child: Text('60 minutes')),
                      const PopupMenuItem(value: 0, child: Text('Turn off')),
                    ],
                    child: Chip(
                      avatar: const Icon(Icons.bedtime_outlined, size: 18),
                      label: Text(sleepEnd == null
                          ? 'Sleep timer'
                          : 'Ends ${TimeOfDay.fromDateTime(sleepEnd).format(context)}'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class SeekBar extends StatefulWidget {
  const SeekBar({super.key});

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? drag;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: app.player.durationStream,
      builder: (context, ds) {
        final dur = ds.data ?? app.player.duration ?? Duration.zero;
        final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
        return StreamBuilder<Duration>(
          stream: app.player.positionStream,
          builder: (context, ps) {
            final pos = ps.data ?? Duration.zero;
            final value =
                (drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, maxMs).toDouble();
            return Column(
              children: [
                Slider(
                  min: 0,
                  max: maxMs,
                  value: value,
                  onChanged: (v) => setState(() => drag = v),
                  onChangeEnd: (v) {
                    app.player.seek(Duration(milliseconds: v.round()));
                    setState(() => drag = null);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(fmt(Duration(milliseconds: value.round()))),
                      Text(fmt(dur)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final tt = Theme.of(context).textTheme;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            // Creator hero card
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(32),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [cs.primaryContainer, cs.tertiaryContainer],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.developer_mode,
                            color: cs.onPrimary, size: 32),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Made by Alex Desrosier',
                                style: tt.headlineSmall?.copyWith(
                                    color: cs.onPrimaryContainer)),
                            const SizedBox(height: 4),
                            Text('Pixel Audio Player',
                                style: TextStyle(
                                    color: cs.onPrimaryContainer
                                        .withValues(alpha: 0.8))),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(
                        avatar: Icon(Icons.android, color: cs.onPrimary, size: 18),
                        label: Text('Custom AOSP ROM Build',
                            style: TextStyle(color: cs.onPrimary)),
                        backgroundColor: cs.primary,
                        side: BorderSide.none,
                      ),
                      Chip(
                        avatar: Icon(Icons.verified,
                            color: cs.onSecondaryContainer, size: 18),
                        label: const Text('Material You'),
                        backgroundColor: cs.secondaryContainer,
                        side: BorderSide.none,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            Text('Pixel 10 theme color', style: tt.titleLarge),
            const SizedBox(height: 4),
            Text('Applies instantly and is remembered.',
                style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 16,
              children: [
                for (int i = 0; i < seedOptions.length; i++)
                  _Swatch(index: i, selected: app.seedIndex == i),
              ],
            ),
            const SizedBox(height: 28),

            Text('Appearance', style: tt.titleLarge),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                      icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('Light'),
                      icon: Icon(Icons.light_mode)),
                  ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('Dark'),
                      icon: Icon(Icons.dark_mode)),
                ],
                selected: {app.themeMode},
                onSelectionChanged: (s) => app.setThemeMode(s.first),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              elevation: 0,
              color: cs.surfaceContainer,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22)),
              child: SwitchListTile(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22)),
                secondary: const Icon(Icons.contrast),
                title: const Text('Pure AMOLED Black'),
                subtitle: const Text('True #000000 background in dark mode'),
                value: app.amoled,
                onChanged: app.setAmoled,
              ),
            ),
            const SizedBox(height: 28),

            Text('Library', style: tt.titleLarge),
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              color: cs.surfaceContainer,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22)),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('Rescan Music & Download'),
                    subtitle: Text('${app.tracks.length} songs in library'),
                    onTap: app.scan,
                  ),
                  ListTile(
                    leading: const Icon(Icons.audio_file),
                    title: const Text('Add songs'),
                    onTap: app.pickFiles,
                  ),
                  ListTile(
                    leading: const Icon(Icons.folder_open),
                    title: const Text('Scan folder'),
                    onTap: app.pickFolder,
                  ),
                  ListTile(
                    leading: const Icon(Icons.security),
                    title: const Text('Grant audio permission'),
                    onTap: () async {
                      await app.requestPermissions();
                      app.scan();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Center(
              child: Text('Pixel Audio Player 1.0.0',
                  style: TextStyle(color: cs.outline)),
            ),
          ],
        );
      },
    );
  }
}

class _Swatch extends StatelessWidget {
  final int index;
  final bool selected;
  const _Swatch({required this.index, required this.selected});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final opt = seedOptions[index];
    final checkColor =
        ThemeData.estimateBrightnessForColor(opt.color) == Brightness.dark
            ? Colors.white
            : Colors.black;
    return GestureDetector(
      onTap: () => app.setSeed(index),
      child: SizedBox(
        width: 76,
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: opt.color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? cs.primary : cs.outlineVariant,
                  width: selected ? 4 : 1.5,
                ),
              ),
              child:
                  selected ? Icon(Icons.check, color: checkColor) : null,
            ),
            const SizedBox(height: 6),
            Text(opt.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
          ],
        ),
      ),
    );
  }
}
