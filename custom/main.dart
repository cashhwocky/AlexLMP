// FILE: custom/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart'
    show
        CupertinoActivityIndicator,
        CupertinoIcons,
        CupertinoSlidingSegmentedControl,
        CupertinoTabBar;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Constants
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

enum UiStyle { material, ios, oneui }

enum NpStyle { immersive, half, card, vinyl, equalizer }

const Map<NpStyle, String> npLabels = {
  NpStyle.immersive: 'Full screen',
  NpStyle.half: 'Half screen',
  NpStyle.card: 'Card',
  NpStyle.vinyl: 'Vinyl',
  NpStyle.equalizer: 'Equalizer',
};

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

bool get isIos => app.uiStyle == UiStyle.ios;
bool get isOneUi => app.uiStyle == UiStyle.oneui;
double get cardR => isIos ? 14 : (isOneUi ? 28 : 22);
double get artR => isIos ? 8 : (isOneUi ? 20 : 16);

IconData outputIcon(String kind) {
  switch (kind) {
    case 'bluetooth':
      return Icons.bluetooth_audio;
    case 'wired':
      return Icons.headphones;
    case 'usb':
      return Icons.usb;
    case 'hdmi':
      return Icons.tv;
    default:
      return Icons.smartphone;
  }
}

// ---------------------------------------------------------------------------
// Models
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

class TrackMeta {
  final String? title;
  final String? artist;
  final String? album;
  final String? art;
  const TrackMeta({this.title, this.artist, this.album, this.art});
}

class NewPlaylist {
  final String name;
  final String? cover;
  const NewPlaylist(this.name, this.cover);
}

// ---------------------------------------------------------------------------
// Audio handler (lock screen / notification controls)
// ---------------------------------------------------------------------------

class PlayerHandler extends BaseAudioHandler with SeekHandler {
  PlayerHandler(this.player) {
    player.playbackEventStream.listen((_) => _broadcast(), onError: (Object e) {});
    player.playerStateStream.listen((_) => _broadcast());
  }

  final AudioPlayer player;
  Future<void> Function()? onNext;
  Future<void> Function()? onPrev;

  AudioProcessingState _map(ProcessingState s) {
    switch (s) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  void _broadcast() {
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: _map(player.processingState),
      playing: player.playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
    ));
  }

  @override
  Future<void> play() async {
    player.play();
  }

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    await onNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await onPrev?.call();
  }
}

// ---------------------------------------------------------------------------
// App state
// ---------------------------------------------------------------------------

class AppState extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();
  final MethodChannel _channel = const MethodChannel('pixelaudio/meta');
  PlayerHandler? handler;
  SharedPreferences? _prefs;

  int seedIndex = 0;
  bool amoled = false;
  ThemeMode themeMode = ThemeMode.system;
  UiStyle uiStyle = UiStyle.material;
  NpStyle npStyle = NpStyle.half;

  List<Track> tracks = [];
  Set<String> favorites = {};
  Map<String, List<String>> playlists = {};
  Map<String, String> covers = {};
  Map<String, Map<String, String>> edits = {};
  List<String> recent = [];
  Map<String, int> counts = {};
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
  TrackMeta? currentMeta;

  Timer? sleepTimer;
  DateTime? sleepEnd;

  String outputName = 'This phone';
  String outputKind = 'phone';
  Timer? _outTimer;

  final Map<String, Future<TrackMeta>> _metaCache = {};
  final Map<String, TrackMeta> _metaDone = {};
  String? _cacheDirPath;
  String? _filesDirPath;

  Track? get current =>
      (index >= 0 && index < queue.length) ? queue[index] : null;

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    seedIndex = (p.getInt('seed') ?? 0).clamp(0, seedOptions.length - 1).toInt();
    amoled = p.getBool('amoled') ?? false;
    themeMode =
        ThemeMode.values[(p.getInt('themeMode') ?? 0).clamp(0, 2).toInt()];
    uiStyle = UiStyle.values[(p.getInt('uiStyle') ?? 0).clamp(0, 2).toInt()];
    npStyle = NpStyle.values[(p.getInt('npStyle') ?? 1).clamp(0, 4).toInt()];
    sort = SortMode.values[(p.getInt('sort') ?? 0).clamp(0, 1).toInt()];
    favorites = (p.getStringList('favorites') ?? <String>[]).toSet();
    extraPaths = p.getStringList('extra') ?? <String>[];
    recent = p.getStringList('recent') ?? <String>[];
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
    final cv = p.getString('covers');
    if (cv != null) {
      try {
        final decoded = jsonDecode(cv) as Map;
        covers = decoded.map((k, v) => MapEntry(k as String, v as String));
      } catch (_) {
        covers = {};
      }
    }
    final ed = p.getString('edits');
    if (ed != null) {
      try {
        final decoded = jsonDecode(ed) as Map;
        edits = decoded.map((k, v) => MapEntry(
            k as String,
            (v as Map).map((a, b) => MapEntry(a as String, b as String))));
      } catch (_) {
        edits = {};
      }
    }
    final ct = p.getString('counts');
    if (ct != null) {
      try {
        final decoded = jsonDecode(ct) as Map;
        counts =
            decoded.map((k, v) => MapEntry(k as String, (v as num).toInt()));
      } catch (_) {
        counts = {};
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
    refreshOutput();
    _outTimer?.cancel();
    _outTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => refreshOutput());
    scan();
  }

  // ----- persistence -------------------------------------------------------

  void _saveFavorites() =>
      _prefs?.setStringList('favorites', favorites.toList());
  void _savePlaylists() => _prefs?.setString('playlists', jsonEncode(playlists));
  void _saveCovers() => _prefs?.setString('covers', jsonEncode(covers));
  void _saveExtra() => _prefs?.setStringList('extra', extraPaths);
  void _saveEdits() => _prefs?.setString('edits', jsonEncode(edits));
  void _saveRecent() {
    _prefs?.setStringList('recent', recent);
    _prefs?.setString('counts', jsonEncode(counts));
  }

  // ----- output device -----------------------------------------------------

  Future<void> refreshOutput() async {
    try {
      final res = await _channel.invokeMethod('outputDevice');
      if (res is Map) {
        final n = (res['name'] as String?)?.trim();
        final k = (res['kind'] as String?) ?? 'phone';
        final name = (n == null || n.isEmpty) ? 'This phone' : n;
        if (name != outputName || k != outputKind) {
          outputName = name;
          outputKind = k;
          notifyListeners();
        }
      }
    } catch (_) {}
  }

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

  void setUiStyle(UiStyle s) {
    uiStyle = s;
    _prefs?.setInt('uiStyle', s.index);
    notifyListeners();
  }

  void setNpStyle(NpStyle s) {
    npStyle = s;
    _prefs?.setInt('npStyle', s.index);
    notifyListeners();
  }

  // ----- metadata / artwork -----------------------------------------------

  Future<String> _cacheDir() async {
    final c = _cacheDirPath;
    if (c != null) return c;
    final r = await _channel.invokeMethod<String>('cacheDir');
    _cacheDirPath = r ?? Directory.systemTemp.path;
    return _cacheDirPath!;
  }

  Future<String> _filesDir() async {
    final c = _filesDirPath;
    if (c != null) return c;
    final r = await _channel.invokeMethod<String>('filesDir');
    _filesDirPath = r ?? Directory.systemTemp.path;
    return _filesDirPath!;
  }

  String listTitle(Track t) => edits[t.path]?['title'] ?? t.title;

  String nameOf(Track t, TrackMeta? m) => m?.title ?? listTitle(t);

  Future<TrackMeta> metaFor(String path) =>
      _metaCache.putIfAbsent(path, () => _loadMeta(path));

  Future<TrackMeta> _loadMeta(String path) async {
    String? title;
    String? artist;
    String? album;
    String? artPath;
    try {
      final res = await _channel.invokeMethod('read', {'path': path});
      if (res is Map) {
        String? clean(Object? v) {
          if (v is! String) return null;
          final s = v.trim();
          return s.isEmpty ? null : s;
        }

        title = clean(res['title']);
        artist = clean(res['artist']);
        album = clean(res['album']);
        final art = res['art'];
        if (art is Uint8List && art.isNotEmpty) {
          final dir = await _cacheDir();
          final f = File(
              '$dir/art_${path.hashCode.toUnsigned(32)}_${art.length}.img');
          if (!await f.exists()) {
            await f.writeAsBytes(art, flush: true);
          }
          artPath = f.path;
        }
      }
    } catch (_) {}
    final ov = edits[path];
    if (ov != null) {
      final t = ov['title'];
      if (t != null && t.isNotEmpty) title = t;
      final a = ov['artist'];
      if (a != null && a.isNotEmpty) artist = a;
      if (ov.containsKey('art')) {
        final ap = ov['art'] ?? '';
        if (ap.isEmpty) {
          artPath = null;
        } else {
          bool ok = false;
          try {
            ok = File(ap).existsSync();
          } catch (_) {}
          if (ok) artPath = ap;
        }
      }
    }
    final m = TrackMeta(title: title, artist: artist, album: album, art: artPath);
    _metaDone[path] = m;
    return m;
  }

  Future<String?> pickImageTo(String sub) async {
    try {
      try {
        await Permission.photos.request();
      } catch (_) {}
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1400,
        maxHeight: 1400,
        imageQuality: 90,
      );
      if (x == null) return null;
      final base = await _filesDir();
      final d = Directory('$base/$sub');
      await d.create(recursive: true);
      final dest = '${d.path}/img_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(x.path).copy(dest);
      return dest;
    } catch (e) {
      toast('Could not pick photo');
      return null;
    }
  }

  Future<String?> pickCoverImage() => pickImageTo('covers');

  Future<void> saveEdit(
    String path, {
    required String title,
    required String artist,
    String? art,
    bool artChanged = false,
  }) async {
    final e = Map<String, String>.from(edits[path] ?? <String, String>{});
    final tr = title.trim();
    if (tr.isEmpty) {
      e.remove('title');
    } else {
      e['title'] = tr;
    }
    final ar = artist.trim();
    if (ar.isEmpty) {
      e.remove('artist');
    } else {
      e['artist'] = ar;
    }
    if (artChanged) {
      e['art'] = art ?? '';
    }
    if (e.isEmpty) {
      edits.remove(path);
    } else {
      edits[path] = e;
    }
    _saveEdits();
    _metaCache.remove(path);
    _metaDone.remove(path);
    await _refreshCurrentIf(path);
    notifyListeners();
    toast('Song updated');
  }

  Future<void> resetEdit(String path) async {
    edits.remove(path);
    _saveEdits();
    _metaCache.remove(path);
    _metaDone.remove(path);
    await _refreshCurrentIf(path);
    notifyListeners();
    toast('Original info restored');
  }

  Future<void> _refreshCurrentIf(String path) async {
    final c = current;
    if (c == null || c.path != path) return;
    final m = await metaFor(path);
    currentMeta = m;
    _pushItem(c, m, player.duration);
  }

  void _pushItem(Track t, TrackMeta m, Duration? dur) {
    handler?.mediaItem.add(MediaItem(
      id: t.path,
      title: m.title ?? listTitle(t),
      artist: m.artist,
      album: m.album,
      duration: dur,
      artUri: m.art != null ? Uri.file(m.art!) : null,
    ));
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
      await [
        Permission.audio,
        Permission.storage,
        Permission.notification,
        Permission.bluetoothConnect,
      ].request();
    } catch (_) {}
    refreshOutput();
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
    final l = tracks.where((t) {
      if (q.isEmpty) return true;
      final m = _metaDone[t.path];
      return listTitle(t).toLowerCase().contains(q) ||
          (m?.title ?? '').toLowerCase().contains(q) ||
          (m?.artist ?? '').toLowerCase().contains(q);
    }).toList();
    if (sort == SortMode.az) {
      l.sort((a, b) =>
          listTitle(a).toLowerCase().compareTo(listTitle(b).toLowerCase()));
    } else {
      l.sort((a, b) => b.added.compareTo(a.added));
    }
    return l;
  }

  List<Track> get favoriteTracks {
    final l = tracks.where((t) => favorites.contains(t.path)).toList();
    l.sort((a, b) =>
        listTitle(a).toLowerCase().compareTo(listTitle(b).toLowerCase()));
    return l;
  }

  List<Track> get recentTracks {
    final byPath = {for (final t in tracks) t.path: t};
    final out = <Track>[];
    for (final p in recent) {
      final t = byPath[p];
      if (t != null) out.add(t);
      if (out.length >= 12) break;
    }
    return out;
  }

  List<Track> get mostPlayed {
    final l = tracks.where((t) => (counts[t.path] ?? 0) >= 2).toList();
    l.sort((a, b) => (counts[b.path] ?? 0).compareTo(counts[a.path] ?? 0));
    return l.length > 12 ? l.sublist(0, 12) : l;
  }

  // ----- favorites ---------------------------------------------------------

  void toggleFavorite(Track t) {
    if (!favorites.remove(t.path)) favorites.add(t.path);
    _saveFavorites();
    notifyListeners();
  }

  bool isFavorite(Track t) => favorites.contains(t.path);

  // ----- playlists ---------------------------------------------------------

  Future<void> setCover(String name) async {
    final p = await pickCoverImage();
    if (p == null) return;
    covers[name] = p;
    _saveCovers();
    notifyListeners();
  }

  void removeCover(String name) {
    covers.remove(name);
    _saveCovers();
    notifyListeners();
  }

  void createPlaylist(String name, {String? cover}) {
    playlists.putIfAbsent(name, () => <String>[]);
    if (cover != null) {
      covers[name] = cover;
      _saveCovers();
    }
    _savePlaylists();
    notifyListeners();
  }

  void deletePlaylist(String name) {
    playlists.remove(name);
    covers.remove(name);
    _savePlaylists();
    _saveCovers();
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

  // ----- queue -------------------------------------------------------------

  void moveQueue(int oldI, int newI) {
    if (oldI < 0 || oldI >= queue.length) return;
    if (newI < 0 || newI >= queue.length) return;
    final t = queue.removeAt(oldI);
    queue.insert(newI, t);
    if (index == oldI) {
      index = newI;
    } else if (oldI < index && newI >= index) {
      index--;
    } else if (oldI > index && newI <= index) {
      index++;
    }
    notifyListeners();
  }

  void removeFromQueue(int i) {
    if (i < 0 || i >= queue.length || i == index) return;
    queue.removeAt(i);
    if (i < index) index--;
    notifyListeners();
  }

  void playNext(Track t) {
    if (queue.isEmpty || current == null) {
      playQueue([t], 0, force: true);
      return;
    }
    if (current?.path == t.path) return;
    final existing = queue.indexWhere((x) => x.path == t.path);
    if (existing >= 0) {
      queue.removeAt(existing);
      if (existing < index) index--;
    }
    queue.insert(index + 1, t);
    toast('Playing next');
    notifyListeners();
  }

  void addToQueue(Track t) {
    if (queue.isEmpty || current == null) {
      playQueue([t], 0, force: true);
      return;
    }
    if (queue.any((x) => x.path == t.path)) {
      toast('Already in queue');
      return;
    }
    queue.add(t);
    toast('Added to queue');
    notifyListeners();
  }

  Future<void> jumpTo(int i) => _playIndex(i);

  // ----- playback ----------------------------------------------------------

  Future<void> playQueue(List<Track> list, int i, {bool force = false}) async {
    if (list.isEmpty || i < 0 || i >= list.length) return;
    if (!force &&
        current?.path == list[i].path &&
        queue.length == list.length) {
      togglePlay();
      return;
    }
    queue = List<Track>.of(list);
    await _playIndex(i);
  }

  Future<void> shufflePlay(List<Track> list) async {
    if (list.isEmpty) return;
    shuffle = true;
    queue = List<Track>.of(list);
    await _playIndex(Random().nextInt(list.length));
  }

  void _markPlayed(Track t) {
    recent.remove(t.path);
    recent.insert(0, t.path);
    if (recent.length > 30) recent.removeRange(30, recent.length);
    counts[t.path] = (counts[t.path] ?? 0) + 1;
    _saveRecent();
  }

  Future<void> _playIndex(int i) async {
    if (i < 0 || i >= queue.length) return;
    index = i;
    currentMeta = null;
    final t = queue[i];
    _markPlayed(t);
    notifyListeners();
    handler?.mediaItem.add(MediaItem(id: t.path, title: listTitle(t)));
    final metaFuture = metaFor(t.path);
    Duration? dur;
    try {
      dur = await player.setFilePath(t.path);
      await player.setSpeed(speed);
      player.play();
    } on PlayerInterruptedException catch (_) {
      return;
    } catch (e) {
      toast('Cannot play "${listTitle(t)}"');
    }
    final m = await metaFuture;
    if (index != i || current?.path != t.path) return;
    currentMeta = m;
    _pushItem(t, m, dur ?? player.duration);
    notifyListeners();
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
// Entry / theme
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final h = await AudioService.init(
      builder: () => PlayerHandler(app.player),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.alexdesrosier.audio_player.playback',
        androidNotificationChannelName: 'Audio playback',
        androidNotificationOngoing: true,
      ),
    );
    h.onNext = app.next;
    h.onPrev = app.previous;
    app.handler = h;
  } catch (_) {}
  await app.init();
  runApp(const AudioApp());
}

ThemeData buildTheme(Brightness b) {
  final ios = isIos;
  final oneui = isOneUi;
  final dark = b == Brightness.dark;
  ColorScheme scheme;
  if (ios) {
    scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF007AFF),
      brightness: b,
    ).copyWith(
      primary: dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF),
      onPrimary: Colors.white,
      primaryContainer: dark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
      onPrimaryContainer:
          dark ? const Color(0xFFAEAEB2) : const Color(0xFF636366),
      secondary: dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF),
      secondaryContainer:
          dark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
      onSecondaryContainer: dark ? Colors.white : Colors.black,
      tertiaryContainer: dark ? const Color(0xFF3A3A3C) : const Color(0xFFD1D1D6),
      onTertiaryContainer:
          dark ? const Color(0xFFAEAEB2) : const Color(0xFF636366),
      surface: dark ? Colors.black : const Color(0xFFF2F2F7),
      onSurface: dark ? Colors.white : Colors.black,
      onSurfaceVariant: dark ? const Color(0xFF98989D) : const Color(0xFF6C6C70),
      outline: dark ? const Color(0xFF48484A) : const Color(0xFFC7C7CC),
      outlineVariant: dark ? const Color(0xFF38383A) : const Color(0xFFD1D1D6),
      surfaceContainerLowest: dark ? Colors.black : Colors.white,
      surfaceContainerLow: dark ? const Color(0xFF111111) : Colors.white,
      surfaceContainer: dark ? const Color(0xFF1C1C1E) : Colors.white,
      surfaceContainerHigh:
          dark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
      surfaceContainerHighest:
          dark ? const Color(0xFF3A3A3C) : const Color(0xFFD1D1D6),
    );
  } else if (oneui) {
    scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3E91FF),
      brightness: b,
    ).copyWith(
      primary: dark ? const Color(0xFF6FB0FF) : const Color(0xFF3E91FF),
      onPrimary: dark ? Colors.black : Colors.white,
      primaryContainer: dark ? const Color(0xFF1E2F47) : const Color(0xFFD9E8FF),
      onPrimaryContainer:
          dark ? const Color(0xFFD9E8FF) : const Color(0xFF0B2A52),
      secondary: dark ? const Color(0xFF6FB0FF) : const Color(0xFF3E91FF),
      secondaryContainer:
          dark ? const Color(0xFF26364D) : const Color(0xFFDDE7F5),
      onSecondaryContainer: dark ? Colors.white : const Color(0xFF111827),
      tertiaryContainer: dark ? const Color(0xFF2A2F3A) : const Color(0xFFE6EAF2),
      onTertiaryContainer:
          dark ? const Color(0xFFC9D1E0) : const Color(0xFF3B4252),
      surface: dark ? Colors.black : const Color(0xFFF6F6F6),
      onSurface: dark ? const Color(0xFFF2F2F2) : const Color(0xFF111111),
      onSurfaceVariant: dark ? const Color(0xFF9A9A9F) : const Color(0xFF6B6B70),
      outline: dark ? const Color(0xFF55555A) : const Color(0xFFC4C4C9),
      outlineVariant: dark ? const Color(0xFF38383C) : const Color(0xFFDADADF),
      surfaceContainerLowest: dark ? Colors.black : Colors.white,
      surfaceContainerLow: dark ? const Color(0xFF0F0F10) : Colors.white,
      surfaceContainer: dark ? const Color(0xFF1B1B1D) : Colors.white,
      surfaceContainerHigh:
          dark ? const Color(0xFF242427) : const Color(0xFFEDEDF0),
      surfaceContainerHighest:
          dark ? const Color(0xFF2E2E32) : const Color(0xFFE2E2E6),
    );
  } else {
    scheme = ColorScheme.fromSeed(
      seedColor: seedOptions[app.seedIndex].color,
      brightness: b,
    );
  }
  if (dark && app.amoled) {
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
    platform: ios ? TargetPlatform.iOS : null,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: ios,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      height: oneui ? 72 : null,
      indicatorColor: oneui ? scheme.primaryContainer : null,
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
        final cs = Theme.of(context).colorScheme;
        final Widget bar = isIos
            ? CupertinoTabBar(
                currentIndex: tab,
                onTap: (i) => setState(() => tab = i),
                activeColor: cs.primary,
                inactiveColor: cs.onSurfaceVariant,
                backgroundColor: cs.surfaceContainer.withValues(alpha: 0.92),
                border: Border(
                    top: BorderSide(color: cs.outlineVariant, width: 0.5)),
                items: const [
                  BottomNavigationBarItem(
                      icon: Icon(CupertinoIcons.music_albums), label: 'Library'),
                  BottomNavigationBarItem(
                      icon: Icon(CupertinoIcons.heart),
                      activeIcon: Icon(CupertinoIcons.heart_fill),
                      label: 'Favorites'),
                  BottomNavigationBarItem(
                      icon: Icon(CupertinoIcons.music_note_list),
                      label: 'Playlists'),
                  BottomNavigationBarItem(
                      icon: Icon(CupertinoIcons.gear_alt),
                      activeIcon: Icon(CupertinoIcons.gear_alt_fill),
                      label: 'Settings'),
                ],
              )
            : NavigationBar(
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
              );
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
          bottomNavigationBar: bar,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Shared helpers / widgets
// ---------------------------------------------------------------------------

Widget pageHeader(BuildContext context, String title, List<Widget> actions) {
  final tt = Theme.of(context).textTheme;
  return Padding(
    padding: EdgeInsets.fromLTRB(20, isOneUi ? 48 : 16, 8, isOneUi ? 12 : 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: isOneUi
                ? tt.headlineLarge?.copyWith(fontWeight: FontWeight.w500)
                : tt.headlineMedium,
          ),
        ),
        ...actions,
      ],
    ),
  );
}

Widget seg<T extends Object>(
    Map<T, String> options, T value, ValueChanged<T> onChanged) {
  if (isIos) {
    return SizedBox(
      width: double.infinity,
      child: CupertinoSlidingSegmentedControl<T>(
        groupValue: value,
        children: {
          for (final e in options.entries)
            e.key: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
              child: Text(e.value, style: const TextStyle(fontSize: 14)),
            ),
        },
        onValueChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
  return SizedBox(
    width: double.infinity,
    child: SegmentedButton<T>(
      showSelectedIcon: false,
      segments: [
        for (final e in options.entries)
          ButtonSegment<T>(value: e.key, label: Text(e.value)),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    ),
  );
}

Future<NewPlaylist?> askPlaylist(BuildContext context) {
  return showDialog<NewPlaylist>(
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
  String? cover;

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  Future<void> pick() async {
    final p = await app.pickCoverImage();
    if (p != null && mounted) setState(() => cover = p);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New playlist'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: pick,
              child: CoverBox(path: cover, size: 96, radius: isIos ? 14 : 28),
            ),
            TextButton.icon(
              onPressed: pick,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: Text(cover == null ? 'Add photo' : 'Change photo'),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: c,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Playlist name',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) =>
                  Navigator.pop(context, NewPlaylist(v.trim(), cover)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () =>
                Navigator.pop(context, NewPlaylist(c.text.trim(), cover)),
            child: const Text('Create')),
      ],
    );
  }
}

Future<void> editSongDialog(BuildContext context, Track t) async {
  final m = await app.metaFor(t.path);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => EditSongDialog(track: t, meta: m),
  );
}

class EditSongDialog extends StatefulWidget {
  final Track track;
  final TrackMeta meta;
  const EditSongDialog({super.key, required this.track, required this.meta});

  @override
  State<EditSongDialog> createState() => _EditSongDialogState();
}

class _EditSongDialogState extends State<EditSongDialog> {
  late final TextEditingController title =
      TextEditingController(text: widget.meta.title ?? widget.track.title);
  late final TextEditingController artist =
      TextEditingController(text: widget.meta.artist ?? '');
  String? art;
  bool artChanged = false;

  @override
  void initState() {
    super.initState();
    art = widget.meta.art;
  }

  @override
  void dispose() {
    title.dispose();
    artist.dispose();
    super.dispose();
  }

  Future<void> pick() async {
    final p = await app.pickImageTo('artwork');
    if (p != null && mounted) {
      setState(() {
        art = p;
        artChanged = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit song'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: pick,
              child: ArtBox(size: 120, radius: isIos ? 14 : 28, artPath: art),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: pick,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Artwork'),
                ),
                if (art != null)
                  TextButton(
                    onPressed: () => setState(() {
                      art = null;
                      artChanged = true;
                    }),
                    child: const Text('Remove'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: title,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: artist,
              decoration: const InputDecoration(
                labelText: 'Artist',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            app.resetEdit(widget.track.path);
            Navigator.pop(context);
          },
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            app.saveEdit(
              widget.track.path,
              title: title.text,
              artist: artist.text,
              art: art,
              artChanged: artChanged,
            );
            Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
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
                final n = await askPlaylist(context);
                if (n != null && n.name.isNotEmpty) {
                  app.createPlaylist(n.name, cover: n.cover);
                  app.addToPlaylist(n.name, t);
                  toast('Added to ${n.name}');
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
    useSafeArea: false,
    showDragHandle: false,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(isIos ? 14 : 28)),
    ),
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height,
      child: const NowPlayingSheet(),
    ),
  );
}

void openQueue(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.75,
      child: const QueueSheet(),
    ),
  );
}

void swipeSkip(DragEndDetails d) {
  final v = d.primaryVelocity ?? 0;
  if (v > 300) {
    HapticFeedback.lightImpact();
    app.previous();
  } else if (v < -300) {
    HapticFeedback.lightImpact();
    app.next();
  }
}

class ArtBox extends StatelessWidget {
  final double size;
  final double radius;
  final bool active;
  final String? artPath;
  const ArtBox({
    super.key,
    required this.size,
    required this.radius,
    this.active = false,
    this.artPath,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fallback = Container(
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
    final p = artPath;
    if (p == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.file(
        File(p),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: min(1200, (size * 2.5).round()),
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

class CoverBox extends StatelessWidget {
  final String? path;
  final double size;
  final double radius;
  const CoverBox(
      {super.key, required this.path, required this.size, required this.radius});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(Icons.queue_music,
          size: size * 0.45, color: cs.onTertiaryContainer),
    );
    final p = path;
    if (p == null) return fallback;
    bool exists = false;
    try {
      exists = File(p).existsSync();
    } catch (_) {}
    if (!exists) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.file(
        File(p),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: min(900, (size * 2.5).round()),
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

class PlayButton extends StatelessWidget {
  final double size;
  final bool playing;
  final VoidCallback onTap;
  final Color bg;
  final Color fg;
  final bool morph;
  const PlayButton({
    super.key,
    required this.size,
    required this.playing,
    required this.onTap,
    required this.bg,
    required this.fg,
    this.morph = true,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(
              (morph && playing) ? size * 0.32 : size / 2),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            key: ValueKey<bool>(playing),
            color: fg,
            size: size * 0.52,
          ),
        ),
      ),
    );
  }
}

class VinylDisc extends StatefulWidget {
  final double size;
  final bool playing;
  final String? artPath;
  const VinylDisc(
      {super.key, required this.size, required this.playing, this.artPath});

  @override
  State<VinylDisc> createState() => _VinylDiscState();
}

class _VinylDiscState extends State<VinylDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController c =
      AnimationController(vsync: this, duration: const Duration(seconds: 10));

  @override
  void initState() {
    super.initState();
    if (widget.playing) c.repeat();
  }

  @override
  void didUpdateWidget(covariant VinylDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !c.isAnimating) {
      c.repeat();
    } else if (!widget.playing && c.isAnimating) {
      c.stop();
    }
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return RotationTransition(
      turns: c,
      child: Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF101010),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 30,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            for (final f in const [0.94, 0.84, 0.74, 0.64])
              Container(
                width: s * f,
                height: s * f,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white12, width: 1),
                ),
              ),
            ArtBox(
              size: s * 0.46,
              radius: s * 0.23,
              artPath: widget.artPath,
              active: widget.playing,
            ),
            Container(
              width: s * 0.07,
              height: s * 0.07,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF101010),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class EqBars extends StatefulWidget {
  final bool playing;
  final Color color;
  final double height;
  const EqBars(
      {super.key,
      required this.playing,
      required this.color,
      required this.height});

  @override
  State<EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<EqBars> with SingleTickerProviderStateMixin {
  late final AnimationController c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void initState() {
    super.initState();
    if (widget.playing) c.repeat();
  }

  @override
  void didUpdateWidget(covariant EqBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !c.isAnimating) {
      c.repeat();
    } else if (!widget.playing && c.isAnimating) {
      c.stop();
    }
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        const n = 21;
        return SizedBox(
          height: widget.height,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List<Widget>.generate(n, (i) {
              final phase = c.value * 2 * pi * (1 + (i % 4)) + i * 0.7;
              final v = 0.18 + 0.82 * ((sin(phase) + 1) / 2);
              return Container(
                width: 8,
                height: widget.height * v,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.45 + 0.55 * v),
                  borderRadius: BorderRadius.circular(6),
                ),
              );
            }),
          ),
        );
      },
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
    final Color bg = isCur
        ? (isIos
            ? cs.primary.withValues(alpha: 0.14)
            : (isOneUi ? cs.primaryContainer : cs.secondaryContainer))
        : cs.surfaceContainer;
    return Card(
      elevation: 0,
      margin: EdgeInsets.only(bottom: isIos ? 6 : 8),
      color: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardR)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => app.playQueue(queue, index),
        child: FutureBuilder<TrackMeta>(
          future: app.metaFor(track.path),
          builder: (context, snap) {
            final m = snap.data;
            final sub = m?.artist ?? (track.ext.isEmpty ? 'Audio' : track.ext);
            return Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(
                children: [
                  ArtBox(
                    size: 52,
                    radius: artR,
                    active: isCur && app.playing,
                    artPath: m?.art,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(app.listTitle(track),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 2),
                        Text(sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                        isIos
                            ? (fav
                                ? CupertinoIcons.heart_fill
                                : CupertinoIcons.heart)
                            : (fav ? Icons.favorite : Icons.favorite_border),
                        color: fav ? cs.primary : cs.onSurfaceVariant),
                    onPressed: () => app.toggleFavorite(track),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (v) {
                      if (v == 'next') {
                        app.playNext(track);
                      } else if (v == 'queue') {
                        app.addToQueue(track);
                      } else if (v == 'add') {
                        addToPlaylistSheet(context, track);
                      } else if (v == 'edit') {
                        editSongDialog(context, track);
                      } else if (v == 'remove' && playlist != null) {
                        app.removeFromPlaylist(playlist!, track);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                          value: 'next', child: Text('Play next')),
                      const PopupMenuItem(
                          value: 'queue', child: Text('Add to queue')),
                      const PopupMenuItem(
                          value: 'add', child: Text('Add to playlist')),
                      const PopupMenuItem(
                          value: 'edit', child: Text('Edit title & artwork')),
                      if (playlist != null)
                        const PopupMenuItem(
                            value: 'remove',
                            child: Text('Remove from playlist')),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class TrackList extends StatelessWidget {
  final List<Track> tracks;
  final String? playlist;
  final Future<void> Function()? onRefresh;
  final Widget? header;
  const TrackList(
      {super.key,
      required this.tracks,
      this.playlist,
      this.onRefresh,
      this.header});

  @override
  Widget build(BuildContext context) {
    final off = header == null ? 0 : 1;
    final list = ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: tracks.length + off,
      itemBuilder: (_, i) {
        if (off == 1 && i == 0) return header!;
        final j = i - off;
        return TrackTile(
          track: tracks[j],
          queue: tracks,
          index: j,
          playlist: playlist,
        );
      },
    );
    if (onRefresh == null) return list;
    return RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}

class TrackRow extends StatelessWidget {
  final String title;
  final List<Track> tracks;
  const TrackRow({super.key, required this.title, required this.tracks});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 0, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        SizedBox(
          height: 156,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: tracks.length,
            itemBuilder: (_, i) {
              final t = tracks[i];
              return GestureDetector(
                onTap: () => app.playQueue(tracks, i, force: true),
                child: SizedBox(
                  width: 118,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FutureBuilder<TrackMeta>(
                          future: app.metaFor(t.path),
                          builder: (c, s) => ArtBox(
                            size: 108,
                            radius: artR + 4,
                            artPath: s.data?.art,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(app.listTitle(t),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------

Widget libraryHeader(BuildContext context, List<Track> list) {
  final recent = app.recentTracks;
  final most = app.mostPlayed;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => app.shufflePlay(list),
                icon: const Icon(Icons.shuffle),
                label: const Text('Shuffle play'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => app.playQueue(list, 0, force: true),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play all'),
              ),
            ),
          ],
        ),
      ),
      if (recent.isNotEmpty) TrackRow(title: 'Recently played', tracks: recent),
      if (most.isNotEmpty) TrackRow(title: 'Most played', tracks: most),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 0, 8),
        child: Text('All songs', style: Theme.of(context).textTheme.titleLarge),
      ),
    ],
  );
}

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final list = app.visible;
        final showHeader = app.query.trim().isEmpty && list.isNotEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            pageHeader(context, 'Library', [
              if (app.scanning)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: isIos
                        ? const CupertinoActivityIndicator()
                        : const CircularProgressIndicator(strokeWidth: 2.5),
                  ),
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
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                onChanged: app.setQuery,
                decoration: InputDecoration(
                  hintText: 'Search ${app.tracks.length} songs',
                  prefixIcon:
                      Icon(isIos ? CupertinoIcons.search : Icons.search),
                  filled: true,
                  fillColor: cs.surfaceContainerHigh,
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(isIos ? 12 : 28),
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
                      title: app.tracks.isEmpty ? 'No songs yet' : 'No matches',
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
                  : TrackList(
                      tracks: list,
                      onRefresh: app.scan,
                      header: showHeader ? libraryHeader(context, list) : null,
                    ),
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
            pageHeader(context, 'Favorites', [
              if (list.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: FilledButton.tonalIcon(
                    onPressed: () => app.shufflePlay(list),
                    icon: const Icon(Icons.shuffle),
                    label: const Text('Shuffle'),
                  ),
                ),
            ]),
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
            pageHeader(context, 'Playlists', [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton.tonalIcon(
                  onPressed: () async {
                    final n = await askPlaylist(context);
                    if (n != null && n.name.isNotEmpty) {
                      app.createPlaylist(n.name, cover: n.cover);
                    }
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('New'),
                ),
              ),
            ]),
            Expanded(
              child: names.isEmpty
                  ? const EmptyState(
                      icon: Icons.queue_music_outlined,
                      title: 'No playlists yet',
                      subtitle:
                          'Create a playlist with a cover photo, then add songs from the ⋮ menu on any track.',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      itemCount: names.length,
                      itemBuilder: (_, i) {
                        final n = names[i];
                        final count = app.playlistTracks(n).length;
                        final hasCover = app.covers[n] != null;
                        return Card(
                          elevation: 0,
                          margin: const EdgeInsets.only(bottom: 8),
                          color: cs.surfaceContainer,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(cardR)),
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 6),
                            leading: CoverBox(
                                path: app.covers[n], size: 52, radius: artR),
                            title: Text(n,
                                style: Theme.of(context).textTheme.titleMedium),
                            subtitle: Text('$count song(s)'),
                            trailing: PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert),
                              onSelected: (v) {
                                if (v == 'photo') app.setCover(n);
                                if (v == 'removephoto') app.removeCover(n);
                                if (v == 'delete') app.deletePlaylist(n);
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                    value: 'photo',
                                    child: Text(hasCover
                                        ? 'Change photo'
                                        : 'Add photo')),
                                if (hasCover)
                                  const PopupMenuItem(
                                      value: 'removephoto',
                                      child: Text('Remove photo')),
                                const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete playlist')),
                              ],
                            ),
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
        final cs = Theme.of(context).colorScheme;
        final list = app.playlistTracks(name);
        return Scaffold(
          appBar: AppBar(
            title: Text(name),
            actions: [
              IconButton(
                tooltip: 'Set cover photo',
                icon: const Icon(Icons.add_photo_alternate_outlined),
                onPressed: () => app.setCover(name),
              ),
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
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 12),
                child: GestureDetector(
                  onTap: () => app.setCover(name),
                  onLongPress: () => app.removeCover(name),
                  child: Stack(
                    children: [
                      CoverBox(
                          path: app.covers[name],
                          size: 140,
                          radius: isIos ? 16 : 36),
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: CircleAvatar(
                          radius: 17,
                          backgroundColor: cs.primary,
                          child: Icon(Icons.add_a_photo,
                              size: 17, color: cs.onPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (list.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () =>
                              app.playQueue(list, 0, force: true),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play all'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () => app.shufflePlay(list),
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
    final meta = app.currentMeta;
    final ios = isIos;
    final bg = (ios || isOneUi) ? cs.surfaceContainerHigh : cs.primaryContainer;
    final fg = (ios || isOneUi) ? cs.onSurface : cs.onPrimaryContainer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: GestureDetector(
        onTap: () => openNowPlaying(context),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -200) openNowPlaying(context);
        },
        onHorizontalDragEnd: swipeSkip,
        child: Material(
          color: bg,
          elevation: ios ? 0 : 3,
          shadowColor: Colors.black54,
          borderRadius: BorderRadius.circular(ios ? 14 : 32),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
                child: Row(
                  children: [
                    ArtBox(
                      size: 46,
                      radius: ios ? 8 : 14,
                      active: app.playing,
                      artPath: meta?.art,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(app.nameOf(t, meta),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontWeight: FontWeight.w600, color: fg)),
                          Text(
                              '${meta?.artist ?? 'Swipe to skip'} • ${app.outputName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: fg.withValues(alpha: 0.7))),
                        ],
                      ),
                    ),
                    if (ios)
                      IconButton(
                        iconSize: 28,
                        icon: Icon(
                            app.playing
                                ? CupertinoIcons.pause_fill
                                : CupertinoIcons.play_fill,
                            color: fg),
                        onPressed: app.togglePlay,
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: PlayButton(
                          size: 46,
                          playing: app.playing,
                          onTap: app.togglePlay,
                          bg: cs.primary,
                          fg: cs.onPrimary,
                          morph: !isOneUi,
                        ),
                      ),
                    IconButton(
                      icon: Icon(
                          ios
                              ? CupertinoIcons.forward_fill
                              : Icons.skip_next_rounded,
                          color: fg),
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
// Queue sheet
// ---------------------------------------------------------------------------

class QueueSheet extends StatelessWidget {
  const QueueSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final q = app.queue;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Up next',
                        style: Theme.of(context).textTheme.titleLarge),
                  ),
                  Text('${q.length} songs'),
                ],
              ),
            ),
            Expanded(
              child: q.isEmpty
                  ? const EmptyState(
                      icon: Icons.queue_music_outlined,
                      title: 'Queue is empty',
                      subtitle: 'Play a song or use "Add to queue" from the ⋮ menu.',
                    )
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: q.length,
                      onReorder: (o, n) {
                        if (n > o) n -= 1;
                        app.moveQueue(o, n);
                      },
                      itemBuilder: (_, i) {
                        final t = q[i];
                        final cur = i == app.index;
                        return ListTile(
                          key: ValueKey(t.path),
                          selected: cur,
                          leading: FutureBuilder<TrackMeta>(
                            future: app.metaFor(t.path),
                            builder: (c, s) => ArtBox(
                              size: 44,
                              radius: 12,
                              artPath: s.data?.art,
                              active: cur && app.playing,
                            ),
                          ),
                          title: Text(app.listTitle(t),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(cur ? 'Now playing' : t.ext),
                          onTap: () => app.jumpTo(i),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!cur)
                                IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () => app.removeFromQueue(i),
                                ),
                              ReorderableDragStartListener(
                                index: i,
                                child: const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(Icons.drag_handle),
                                ),
                              ),
                            ],
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

// ---------------------------------------------------------------------------
// Now playing
// ---------------------------------------------------------------------------

class NowPlayingSheet extends StatelessWidget {
  const NowPlayingSheet({super.key});

  Widget _art(String p, {int w = 1080}) => Image.file(
        File(p),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: w,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );

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
        final meta = app.currentMeta;
        final artPath = meta?.art;
        bool hasArt = false;
        if (artPath != null) {
          try {
            hasArt = File(artPath).existsSync();
          } catch (_) {}
        }
        final style = app.npStyle;
        final h = MediaQuery.of(context).size.height;
        final light = hasArt &&
            (style == NpStyle.immersive ||
                style == NpStyle.card ||
                style == NpStyle.vinyl);
        final fg = light ? Colors.white : cs.onSurface;
        final fgDim = light ? Colors.white70 : cs.onSurfaceVariant;
        final fav = app.isFavorite(t);
        final sleepEnd = app.sleepEnd;
        final title = app.nameOf(t, meta);
        final parts = <String>[];
        if (meta?.artist != null) parts.add(meta!.artist!);
        if (meta?.album != null) parts.add(meta!.album!);
        final sub = parts.isEmpty ? '${t.ext} • Local file' : parts.join(' • ');

        Widget background;
        if (!hasArt || style == NpStyle.equalizer) {
          background = DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [cs.primaryContainer, cs.surface],
              ),
            ),
          );
        } else if (style == NpStyle.immersive) {
          background = Stack(
            fit: StackFit.expand,
            children: [
              _art(artPath!),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x66000000),
                      Color(0x00000000),
                      Color(0xE6000000)
                    ],
                    stops: [0.0, 0.35, 0.85],
                  ),
                ),
              ),
            ],
          );
        } else if (style == NpStyle.half) {
          background = Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: cs.surface),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: h * 0.54,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _art(artPath!),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, cs.surface],
                          stops: const [0.55, 1.0],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        } else {
          background = ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _art(artPath!, w: 400),
                BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                  child: Container(color: Colors.black.withValues(alpha: 0.5)),
                ),
              ],
            ),
          );
        }

        Widget center;
        if (style == NpStyle.equalizer) {
          center = Center(
            child: LayoutBuilder(builder: (context, box) {
              final bh = min(180.0, box.maxHeight * 0.7);
              return EqBars(
                  playing: app.playing,
                  color: cs.primary,
                  height: bh < 40 ? 40 : bh);
            }),
          );
        } else if (style == NpStyle.vinyl) {
          center = Center(
            child: LayoutBuilder(builder: (context, box) {
              final s = min(box.maxWidth, box.maxHeight)
                  .clamp(120.0, 380.0)
                  .toDouble();
              return VinylDisc(
                size: s,
                playing: app.playing,
                artPath: hasArt ? artPath : null,
              );
            }),
          );
        } else if (style == NpStyle.card || !hasArt) {
          center = Center(
            child: LayoutBuilder(builder: (context, box) {
              final s = min(box.maxWidth, box.maxHeight)
                  .clamp(120.0, 420.0)
                  .toDouble();
              final r = isIos ? 14.0 : (isOneUi ? 32.0 : 40.0);
              return Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(r),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 30,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: ArtBox(
                  size: s,
                  radius: r,
                  active: app.playing,
                  artPath: hasArt ? artPath : null,
                ),
              );
            }),
          );
        } else {
          center = const SizedBox.shrink();
        }

        Widget pill(IconData icon, String label, VoidCallback onTap) {
          return ActionChip(
            avatar: Icon(icon, size: 18, color: fg),
            label: Text(label, style: TextStyle(color: fg)),
            onPressed: onTap,
            backgroundColor:
                light ? Colors.white.withValues(alpha: 0.18) : null,
            side: light ? BorderSide.none : null,
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: swipeSkip,
          child: Stack(
            children: [
              Positioned.fill(child: background),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 52,
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                  isIos
                                      ? CupertinoIcons.chevron_down
                                      : Icons.keyboard_arrow_down_rounded,
                                  color: fg),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text('PLAYING ON',
                                      style: TextStyle(
                                          color: fgDim,
                                          fontSize: 10,
                                          letterSpacing: 1.2,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 2),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(outputIcon(app.outputKind),
                                          size: 14,
                                          color:
                                              light ? Colors.white : cs.primary),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(app.outputName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                color: fg,
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13)),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.queue_music, color: fg),
                              onPressed: () => openQueue(context),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 350),
                          child: KeyedSubtree(
                            key: ValueKey<String>(
                                '${style.index}|${t.path}|${artPath ?? ''}|$hasArt'),
                            child: center,
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(color: fg)),
                                const SizedBox(height: 4),
                                Text(sub,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: fgDim)),
                              ],
                            ),
                          ),
                          IconButton(
                            iconSize: 28,
                            icon: Icon(
                                isIos
                                    ? (fav
                                        ? CupertinoIcons.heart_fill
                                        : CupertinoIcons.heart)
                                    : (fav
                                        ? Icons.favorite
                                        : Icons.favorite_border),
                                color: fav
                                    ? (light ? Colors.white : cs.primary)
                                    : fgDim),
                            onPressed: () => app.toggleFavorite(t),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SeekBar(color: fg),
                      const SizedBox(height: 4),
                      NpControls(fg: fg),
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
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
                                avatar: Icon(Icons.speed, size: 18, color: fg),
                                label: Text('${app.speed}x',
                                    style: TextStyle(color: fg)),
                                backgroundColor: light
                                    ? Colors.white.withValues(alpha: 0.18)
                                    : null,
                                side: light ? BorderSide.none : null,
                              ),
                            ),
                            const SizedBox(width: 8),
                            PopupMenuButton<int>(
                              tooltip: 'Sleep timer',
                              onSelected: app.setSleep,
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 15, child: Text('15 minutes')),
                                PopupMenuItem(
                                    value: 30, child: Text('30 minutes')),
                                PopupMenuItem(
                                    value: 60, child: Text('60 minutes')),
                                PopupMenuItem(value: 0, child: Text('Turn off')),
                              ],
                              child: Chip(
                                avatar: Icon(Icons.bedtime_outlined,
                                    size: 18, color: fg),
                                label: Text(
                                    sleepEnd == null
                                        ? 'Sleep timer'
                                        : 'Ends ${TimeOfDay.fromDateTime(sleepEnd).format(context)}',
                                    style: TextStyle(color: fg)),
                                backgroundColor: light
                                    ? Colors.white.withValues(alpha: 0.18)
                                    : null,
                                side: light ? BorderSide.none : null,
                              ),
                            ),
                            const SizedBox(width: 8),
                            pill(Icons.queue_music, 'Queue',
                                () => openQueue(context)),
                            const SizedBox(width: 8),
                            pill(Icons.edit_outlined, 'Edit',
                                () => editSongDialog(context, t)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class NpControls extends StatelessWidget {
  final Color fg;
  const NpControls({super.key, required this.fg});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final light = fg == Colors.white;
    final selBg =
        light ? Colors.white.withValues(alpha: 0.25) : cs.secondaryContainer;

    Widget toggle(IconData icon, bool selected, VoidCallback onTap) {
      return IconButton(
        iconSize: 24,
        style: selected ? IconButton.styleFrom(backgroundColor: selBg) : null,
        icon: Icon(icon, color: fg),
        onPressed: onTap,
      );
    }

    final repeatIcon = isIos
        ? (app.repeat == RepeatMode.one
            ? CupertinoIcons.repeat_1
            : CupertinoIcons.repeat)
        : (app.repeat == RepeatMode.one ? Icons.repeat_one : Icons.repeat);
    final shuffleIcon = isIos ? CupertinoIcons.shuffle : Icons.shuffle;

    if (isIos) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          toggle(shuffleIcon, app.shuffle, app.toggleShuffle),
          IconButton(
            iconSize: 40,
            icon: Icon(CupertinoIcons.backward_fill, color: fg),
            onPressed: app.previous,
          ),
          IconButton(
            iconSize: 64,
            icon: Icon(
                app.playing
                    ? CupertinoIcons.pause_fill
                    : CupertinoIcons.play_fill,
                color: fg),
            onPressed: app.togglePlay,
          ),
          IconButton(
            iconSize: 40,
            icon: Icon(CupertinoIcons.forward_fill, color: fg),
            onPressed: app.next,
          ),
          toggle(repeatIcon, app.repeat != RepeatMode.off, app.cycleRepeat),
        ],
      );
    }

    final playBg = light ? Colors.white : cs.primary;
    final playFg = light ? Colors.black : cs.onPrimary;
    final skipBg =
        light ? Colors.white.withValues(alpha: 0.2) : cs.secondaryContainer;
    final skipFg = light ? Colors.white : cs.onSecondaryContainer;
    final skipR = isOneUi ? 30.0 : 22.0;

    Widget skip(IconData icon, VoidCallback onTap) {
      return Material(
        color: skipBg,
        borderRadius: BorderRadius.circular(skipR),
        child: InkWell(
          borderRadius: BorderRadius.circular(skipR),
          onTap: onTap,
          child: SizedBox(
            width: 60,
            height: 60,
            child: Icon(icon, color: skipFg, size: 32),
          ),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        toggle(shuffleIcon, app.shuffle, app.toggleShuffle),
        skip(Icons.skip_previous_rounded, app.previous),
        PlayButton(
          size: 84,
          playing: app.playing,
          onTap: app.togglePlay,
          bg: playBg,
          fg: playFg,
          morph: !isOneUi,
        ),
        skip(Icons.skip_next_rounded, app.next),
        toggle(repeatIcon, app.repeat != RepeatMode.off, app.cycleRepeat),
      ],
    );
  }
}

class SeekBar extends StatefulWidget {
  final Color? color;
  const SeekBar({super.key, this.color});

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? drag;

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    return StreamBuilder<Duration?>(
      stream: app.player.durationStream,
      builder: (context, ds) {
        final dur = ds.data ?? app.player.duration ?? Duration.zero;
        final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
        return StreamBuilder<Duration>(
          stream: app.player.positionStream,
          builder: (context, ps) {
            final pos = ps.data ?? Duration.zero;
            final value = (drag ?? pos.inMilliseconds.toDouble())
                .clamp(0.0, maxMs)
                .toDouble();
            var theme = SliderTheme.of(context);
            if (c != null) {
              theme = theme.copyWith(
                activeTrackColor: c,
                inactiveTrackColor: c.withValues(alpha: 0.25),
                thumbColor: c,
                overlayColor: c.withValues(alpha: 0.12),
              );
            }
            if (isIos) {
              theme = theme.copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              );
            }
            return Column(
              children: [
                SliderTheme(
                  data: theme,
                  child: Slider(
                    min: 0,
                    max: maxMs,
                    value: value,
                    onChanged: (v) => setState(() => drag = v),
                    onChangeEnd: (v) {
                      app.player.seek(Duration(milliseconds: v.round()));
                      setState(() => drag = null);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(fmt(Duration(milliseconds: value.round())),
                          style: TextStyle(color: c)),
                      Text(fmt(dur), style: TextStyle(color: c)),
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
        final styleLabel =
            isIos ? 'iOS Style' : (isOneUi ? 'One UI' : 'Material You');
        return ListView(
          padding: EdgeInsets.fromLTRB(16, isOneUi ? 48 : 16, 16, 24),
          children: [
            if (isOneUi)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 0, 20),
                child: Text('Settings',
                    style: tt.headlineLarge
                        ?.copyWith(fontWeight: FontWeight.w500)),
              ),
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(isIos ? 20 : 32),
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
                                style: tt.headlineSmall
                                    ?.copyWith(color: cs.onPrimaryContainer)),
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
                        avatar:
                            Icon(Icons.android, color: cs.onPrimary, size: 18),
                        label: Text('Custom AOSP ROM Build',
                            style: TextStyle(color: cs.onPrimary)),
                        backgroundColor: cs.primary,
                        side: BorderSide.none,
                      ),
                      Chip(
                        avatar: Icon(Icons.verified,
                            color: cs.onSecondaryContainer, size: 18),
                        label: Text(styleLabel),
                        backgroundColor: cs.secondaryContainer,
                        side: BorderSide.none,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            Text('Interface style', style: tt.titleLarge),
            const SizedBox(height: 4),
            Text('Switches the whole app look instantly.',
                style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 12),
            seg<UiStyle>(
              {
                UiStyle.material: 'Material You',
                UiStyle.ios: 'iOS',
                UiStyle.oneui: 'One UI',
              },
              app.uiStyle,
              app.setUiStyle,
            ),
            const SizedBox(height: 28),

            if (app.uiStyle == UiStyle.material) ...[
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
            ] else ...[
              Text('Accent color', style: tt.titleLarge),
              const SizedBox(height: 4),
              Text(
                  isIos
                      ? 'iOS style uses system blue. Pixel 10 colors apply in Material You style.'
                      : 'One UI style uses its own blue accent. Pixel 10 colors apply in Material You style.',
                  style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 28),
            ],

            Text('Appearance', style: tt.titleLarge),
            const SizedBox(height: 12),
            seg<ThemeMode>(
              {
                ThemeMode.system: 'System',
                ThemeMode.light: 'Light',
                ThemeMode.dark: 'Dark',
              },
              app.themeMode,
              app.setThemeMode,
            ),
            const SizedBox(height: 8),
            Card(
              elevation: 0,
              color: cs.surfaceContainer,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(cardR)),
              child: SwitchListTile.adaptive(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(cardR)),
                secondary: const Icon(Icons.contrast),
                title: const Text('Pure AMOLED Black'),
                subtitle: const Text('True #000000 background in dark mode'),
                value: app.amoled,
                onChanged: app.setAmoled,
              ),
            ),
            const SizedBox(height: 28),

            Text('Player style', style: tt.titleLarge),
            const SizedBox(height: 4),
            Text('Album artwork is used when a song has it. Swipe left or right on the player to skip.',
                style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in NpStyle.values)
                  ChoiceChip(
                    label: Text(npLabels[s] ?? ''),
                    selected: app.npStyle == s,
                    onSelected: (_) => app.setNpStyle(s),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              app.npStyle == NpStyle.immersive
                  ? 'Artwork fills the whole screen.'
                  : app.npStyle == NpStyle.half
                      ? 'Artwork covers the top half and fades into the controls.'
                      : app.npStyle == NpStyle.card
                          ? 'Blurred artwork background with a large artwork card.'
                          : app.npStyle == NpStyle.vinyl
                              ? 'A spinning vinyl record with your artwork on the label.'
                              : 'Animated equalizer bars in your theme color.',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 28),

            Text('Library', style: tt.titleLarge),
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              color: cs.surfaceContainer,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(cardR)),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(outputIcon(app.outputKind)),
                    title: const Text('Playing on'),
                    subtitle: Text(app.outputName),
                    onTap: () async {
                      await app.requestPermissions();
                      app.refreshOutput();
                    },
                  ),
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
                    title: const Text('Grant audio, notification & Bluetooth permission'),
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
              child: Text('Pixel Audio Player 1.2.0',
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
              child: selected ? Icon(Icons.check, color: checkColor) : null,
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
