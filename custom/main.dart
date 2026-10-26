// FILE: custom/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:dynamic_color/dynamic_color.dart' show DynamicColorBuilder;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart'
    show
        CupertinoActivityIndicator,
        CupertinoIcons,
        CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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
enum UiStyle { material, ios, oneui, spotify }
enum IosVariant { amoled, glass }

enum PlayerStyle {
  materialYou,
  spotify,
  appleMusic,
  tidal,
  amazon,
  youtube,
  immersive,
  half,
  card,
  vinyl,
  equalizer,
  polaroid,
  neon,
  orb,
  minimal,
}

enum CtrlKind { tonal, plain, circle, materialYou }

const Map<PlayerStyle, String> playerLabels = {
  PlayerStyle.materialYou: 'Material You',
  PlayerStyle.spotify: 'Spotify',
  PlayerStyle.appleMusic: 'Apple Music',
  PlayerStyle.tidal: 'Tidal',
  PlayerStyle.amazon: 'Amazon Music',
  PlayerStyle.youtube: 'YouTube Music',
  PlayerStyle.immersive: 'Full screen',
  PlayerStyle.half: 'Half screen',
  PlayerStyle.card: 'Blur card',
  PlayerStyle.vinyl: 'Vinyl',
  PlayerStyle.equalizer: 'Equalizer',
  PlayerStyle.polaroid: 'Polaroid',
  PlayerStyle.neon: 'Neon glow',
  PlayerStyle.orb: 'Orb',
  PlayerStyle.minimal: 'Typography',
};

const Map<PlayerStyle, String> playerDescs = {
  PlayerStyle.materialYou:
      'Dark minimal layout with squishy pill controls and bottom segmented dock.',
  PlayerStyle.spotify:
      'Album-color gradient, left aligned title, save plus (+) button and white play button.',
  PlayerStyle.appleMusic:
      'Blurred artwork backdrop, big shadowed cover that shrinks when paused.',
  PlayerStyle.tidal:
      'Pure black minimalism with a square edge-to-edge cover and a hairline seek bar.',
  PlayerStyle.amazon:
      'Deep navy backdrop, rounded cover and a cyan accent.',
  PlayerStyle.youtube:
      'Black backdrop with a wide video-style cover and a red seek bar.',
  PlayerStyle.immersive: 'Artwork fills the whole screen.',
  PlayerStyle.half: 'Artwork covers the top half and fades into the controls.',
  PlayerStyle.card: 'Blurred artwork background with a large artwork card.',
  PlayerStyle.vinyl: 'A spinning vinyl record with your artwork on the label.',
  PlayerStyle.equalizer: 'Animated equalizer bars in your accent color.',
  PlayerStyle.polaroid: 'A tilted instant photo that swings with every swipe.',
  PlayerStyle.neon: 'Glowing artwork lit by the album color.',
  PlayerStyle.orb: 'Round artwork inside a glowing ring.',
  PlayerStyle.minimal: 'Typography first: a huge song title and a tiny cover.',
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
bool get isSpotify => app.uiStyle == UiStyle.spotify;
bool get glass => isIos && app.iosVariant == IosVariant.glass;
double get cardR => isIos ? 14 : (isOneUi ? 28 : (isSpotify ? 8 : 22));
double get artR => isIos ? 8 : (isOneUi ? 20 : (isSpotify ? 4 : 16));
double get listBottom => glass ? (app.current != null ? 210 : 120) : 20;

IconData ic(IconData material, IconData ios) => isIos ? ios : material;

RoundedRectangleBorder cardShape(double r) => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(r),
      side: glass
          ? BorderSide(color: Colors.white.withValues(alpha: 0.18))
          : BorderSide.none,
    );

Color shade(Color c, double l, {double sat = -1}) {
  final h = HSLColor.fromColor(c);
  final s = sat < 0 ? h.saturation.clamp(0.25, 0.9).toDouble() : sat;
  return h.withLightness(l.clamp(0.0, 1.0).toDouble()).withSaturation(s).toColor();
}

bool fileOk(String? p) {
  if (p == null || p.isEmpty || p.startsWith('http')) return false;
  try {
    return File(p).existsSync();
  } catch (_) {
    return false;
  }
}

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

class Track {
  final String path;
  final String title;
  final DateTime added;
  final String ext;
  final bool isStream;

  const Track(this.path, this.title, this.added, this.ext,
      {this.isStream = false});

  String get ytId => path.startsWith('yt:') ? path.substring(3).split('|')[0] : '';

  String get searchQuery {
    if (path.startsWith('sp:') || path.startsWith('yt:')) {
      final p = path.substring(3).split('|');
      final t = p.length > 1 ? p[1] : title;
      final a = p.length > 2 ? p[2] : '';
      return '$t $a'.trim();
    }
    return title;
  }

  factory Track.fromStream(String raw) {
    final isSp = raw.startsWith('sp:');
    final parts = raw.substring(3).split('|');
    final t = parts.length > 1 ? parts[1] : 'Stream Track';
    return Track(raw, t, DateTime.now(), isSp ? 'SPOTIFY' : 'STREAM',
        isStream: true);
  }

  factory Track.fromPath(String p) {
    if (p.startsWith('yt:') || p.startsWith('sp:')) {
      return Track.fromStream(p);
    }
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
  Future<void> play() async => player.play();
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
  Future<void> skipToNext() async => await onNext?.call();
  @override
  Future<void> skipToPrevious() async => await onPrev?.call();
  @override
  Future<void> onTaskRemoved() async {
    if (app.stopOnTaskClear) await stop();
  }
}

class AppState extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();
  final MethodChannel _channel = const MethodChannel('pixelaudio/meta');
  PlayerHandler? handler;
  SharedPreferences? _prefs;

  int seedIndex = 0;
  bool amoled = false;
  bool dynamicColor = true;
  ThemeMode themeMode = ThemeMode.system;
  UiStyle uiStyle = UiStyle.material;
  IosVariant iosVariant = IosVariant.amoled;
  PlayerStyle playerStyle = PlayerStyle.materialYou;
  bool showVolume = false;
  bool stopOnTaskClear = false;
  double volume = 1.0;

  String spClientId = '';
  String spClientSecret = '';
  String spAccessToken = '';
  String spUserId = '';
  String spDisplayName = '';

  List<Track> tracks = [];
  Set<String> favorites = {};
  Map<String, List<String>> playlists = {};
  Map<String, String> covers = {};
  Map<String, Map<String, String>> edits = {};
  Map<String, String> lyrics = {};
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
  Color? currentColor;

  Timer? sleepTimer;
  DateTime? sleepEnd;

  String outputName = 'This phone';
  String outputKind = 'phone';
  Timer? _outTimer;

  final Map<String, Future<TrackMeta>> _metaCache = {};
  final Map<String, TrackMeta> _metaDone = {};
  final Map<String, Color> _colorCache = {};
  String? _cacheDirPath;
  String? _filesDirPath;

  Track? get current =>
      (index >= 0 && index < queue.length) ? queue[index] : null;

  bool get spotifyConnected =>
      spAccessToken.isNotEmpty ||
      (spClientId.isNotEmpty && spClientSecret.isNotEmpty);

  ThemeMode get effectiveMode {
    if (uiStyle == UiStyle.spotify) return ThemeMode.dark;
    if (uiStyle == UiStyle.ios && iosVariant == IosVariant.amoled) {
      return ThemeMode.dark;
    }
    return themeMode;
  }

  Map<String, String> _strMap(String? raw) {
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map;
      return decoded.map((k, v) => MapEntry(k as String, v as String));
    } catch (_) {
      return {};
    }
  }

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    seedIndex = (p.getInt('seed') ?? 0).clamp(0, seedOptions.length - 1).toInt();
    amoled = p.getBool('amoled') ?? false;
    dynamicColor = p.getBool('dynamic') ?? true;
    themeMode =
        ThemeMode.values[(p.getInt('themeMode') ?? 0).clamp(0, 2).toInt()];
    uiStyle = UiStyle.values[(p.getInt('uiStyle') ?? 0).clamp(0, 3).toInt()];
    iosVariant =
        IosVariant.values[(p.getInt('iosVariant') ?? 0).clamp(0, 1).toInt()];
    playerStyle = PlayerStyle.values[(p.getInt('pstyle') ?? 0)
        .clamp(0, PlayerStyle.values.length - 1)
        .toInt()];
    showVolume = p.getBool('showVolume') ?? false;
    stopOnTaskClear = p.getBool('stopOnClear') ?? false;
    volume = (p.getDouble('volume') ?? 1.0).clamp(0.0, 1.0).toDouble();
    sort = SortMode.values[(p.getInt('sort') ?? 0).clamp(0, 1).toInt()];
    favorites = (p.getStringList('favorites') ?? <String>[]).toSet();
    extraPaths = p.getStringList('extra') ?? <String>[];
    recent = p.getStringList('recent') ?? <String>[];

    spClientId = p.getString('spClientId') ?? '';
    spClientSecret = p.getString('spClientSecret') ?? '';
    spAccessToken = p.getString('spAccessToken') ?? '';
    spUserId = p.getString('spUserId') ?? '';
    spDisplayName = p.getString('spDisplayName') ?? '';

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
    covers = _strMap(p.getString('covers'));
    lyrics = _strMap(p.getString('lyrics'));
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

    try {
      await player.setVolume(volume);
    } catch (_) {}

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

  void _saveFavorites() =>
      _prefs?.setStringList('favorites', favorites.toList());
  void _savePlaylists() => _prefs?.setString('playlists', jsonEncode(playlists));
  void _saveCovers() => _prefs?.setString('covers', jsonEncode(covers));
  void _saveExtra() => _prefs?.setStringList('extra', extraPaths);
  void _saveEdits() => _prefs?.setString('edits', jsonEncode(edits));
  void _saveLyrics() => _prefs?.setString('lyrics', jsonEncode(lyrics));
  void _saveRecent() {
    _prefs?.setStringList('recent', recent);
    _prefs?.setString('counts', jsonEncode(counts));
  }

  void saveSpotifyCreds({
    required String clientId,
    required String clientSecret,
    required String token,
    required String userId,
    String displayName = '',
  }) {
    spClientId = clientId.trim();
    spClientSecret = clientSecret.trim();
    spAccessToken = token.trim();
    spUserId = userId.trim();
    if (displayName.isNotEmpty) spDisplayName = displayName;
    _prefs?.setString('spClientId', spClientId);
    _prefs?.setString('spClientSecret', spClientSecret);
    _prefs?.setString('spAccessToken', spAccessToken);
    _prefs?.setString('spUserId', spUserId);
    _prefs?.setString('spDisplayName', spDisplayName);
    notifyListeners();
  }

  void logoutSpotify() {
    spClientId = '';
    spClientSecret = '';
    spAccessToken = '';
    spUserId = '';
    spDisplayName = '';
    _prefs?.remove('spClientId');
    _prefs?.remove('spClientSecret');
    _prefs?.remove('spAccessToken');
    _prefs?.remove('spUserId');
    _prefs?.remove('spDisplayName');
    notifyListeners();
    toast('Disconnected from Spotify');
  }

  Future<String?> getValidSpotifyToken() async {
    if (spAccessToken.isNotEmpty && spClientId.isEmpty) {
      return spAccessToken;
    }
    if (spClientId.isNotEmpty && spClientSecret.isNotEmpty) {
      try {
        final creds = base64Encode(utf8.encode('$spClientId:$spClientSecret'));
        final res = await http.post(
          Uri.parse('https://accounts.spotify.com/api/token'),
          headers: {
            'Authorization': 'Basic $creds',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: 'grant_type=client_credentials',
        );
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map;
          final tok = data['access_token'] as String?;
          if (tok != null && tok.isNotEmpty) {
            spAccessToken = tok;
            _prefs?.setString('spAccessToken', tok);
            return tok;
          }
        }
      } catch (_) {}
    }
    return spAccessToken.isNotEmpty ? spAccessToken : null;
  }

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

  void setSeed(int i) {
    seedIndex = i;
    dynamicColor = false;
    _prefs?.setInt('seed', i);
    _prefs?.setBool('dynamic', false);
    notifyListeners();
  }

  void setDynamic(bool v) {
    dynamicColor = v;
    _prefs?.setBool('dynamic', v);
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

  void setIosVariant(IosVariant v) {
    iosVariant = v;
    _prefs?.setInt('iosVariant', v.index);
    notifyListeners();
  }

  void setPlayerStyle(PlayerStyle s) {
    playerStyle = s;
    _prefs?.setInt('pstyle', s.index);
    notifyListeners();
  }

  void setShowVolume(bool v) {
    showVolume = v;
    _prefs?.setBool('showVolume', v);
    notifyListeners();
  }

  void setStopOnTaskClear(bool v) {
    stopOnTaskClear = v;
    _prefs?.setBool('stopOnClear', v);
    notifyListeners();
  }

  void setVolume(double v) {
    volume = v.clamp(0.0, 1.0).toDouble();
    try {
      player.setVolume(volume);
    } catch (_) {}
    _prefs?.setDouble('volume', volume);
    notifyListeners();
  }

  String? lyricsFor(String path) {
    final l = lyrics[path];
    if (l == null || l.trim().isEmpty) return null;
    return l;
  }

  void setLyrics(String path, String text) {
    if (text.trim().isEmpty) {
      lyrics.remove(path);
    } else {
      lyrics[path] = text;
    }
    _saveLyrics();
    notifyListeners();
  }

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
  TrackMeta? metaNow(String path) => _metaDone[path];

  Future<TrackMeta> metaFor(String path) =>
      _metaCache.putIfAbsent(path, () => _loadMeta(path));

  Future<Color?> colorFor(String? path) async {
    if (path == null || path.isEmpty) return null;
    final cached = _colorCache[path];
    if (cached != null) return cached;
    try {
      Uint8List bytes;
      if (path.startsWith('http')) {
        final res = await http.get(Uri.parse(path)).timeout(const Duration(seconds: 4));
        if (res.statusCode != 200) return null;
        bytes = res.bodyBytes;
      } else {
        bytes = await File(path).readAsBytes();
      }
      final codec =
          await ui.instantiateImageCodec(bytes, targetWidth: 16, targetHeight: 16);
      final fr = await codec.getNextFrame();
      final data = await fr.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      fr.image.dispose();
      codec.dispose();
      if (data == null) return null;
      var r = 0, g = 0, b = 0, n = 0;
      for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
        if (data.getUint8(i + 3) < 200) continue;
        r += data.getUint8(i);
        g += data.getUint8(i + 1);
        b += data.getUint8(i + 2);
        n++;
      }
      if (n == 0) return null;
      final avg = Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
      final h = HSLColor.fromColor(avg);
      final col = h
          .withSaturation(max(h.saturation, 0.35).clamp(0.0, 1.0).toDouble())
          .toColor();
      _colorCache[path] = col;
      return col;
    } catch (_) {
      return null;
    }
  }

  Future<TrackMeta> _loadMeta(String path) async {
    String? title;
    String? artist;
    String? album;
    String? artPath;
    if (path.startsWith('yt:') || path.startsWith('sp:')) {
      final isSp = path.startsWith('sp:');
      final parts = path.substring(3).split('|');
      title = parts.length > 1 ? parts[1] : 'Track';
      artist = parts.length > 2 ? parts[2] : (isSp ? 'Spotify' : 'YouTube Music');
      album = isSp ? 'Spotify' : 'YouTube Music';
      artPath = parts.length > 3 && parts[3].isNotEmpty ? parts[3] : null;
    } else {
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
    }
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
        } else if (fileOk(ap) || ap.startsWith('http')) {
          artPath = ap;
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
    currentColor = await colorFor(m.art);
    _pushItem(c, m, player.duration);
  }

  void _pushItem(Track t, TrackMeta m, Duration? dur) {
    Uri? artUri;
    if (m.art != null && m.art!.isNotEmpty) {
      artUri = m.art!.startsWith('http')
          ? Uri.tryParse(m.art!)
          : Uri.file(m.art!);
    }
    handler?.mediaItem.add(MediaItem(
      id: t.path,
      title: m.title ?? listTitle(t),
      artist: m.artist,
      album: m.album,
      duration: dur,
      artUri: artUri,
    ));
  }

  Track addStreamTrack({
    required String prefix,
    required String id,
    required String title,
    required String artist,
    required String artUrl,
  }) {
    final safeTitle = title.replaceAll('|', ' ').trim();
    final safeArtist = artist.replaceAll('|', ' ').trim();
    final key = '$prefix:$id|$safeTitle|$safeArtist|$artUrl';
    if (!extraPaths.contains(key)) {
      extraPaths.add(key);
      _saveExtra();
      _rebuildTracks();
      notifyListeners();
    }
    return tracks.firstWhere((x) => x.path == key,
        orElse: () => Track.fromStream(key));
  }

  void _rebuildTracks() {
    final paths = <String>{
      ..._scanned,
      ...extraPaths.where((p) {
        if (p.startsWith('yt:') || p.startsWith('sp:')) return true;
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

  void toggleFavorite(Track t) {
    if (!favorites.remove(t.path)) {
      favorites.add(t.path);
      toast('Added to Liked Songs');
    } else {
      toast('Removed from Liked Songs');
    }
    _saveFavorites();
    notifyListeners();
  }

  bool isFavorite(Track t) => favorites.contains(t.path);

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
    if (cover != null && cover.isNotEmpty) {
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

  Future<String?> _resolveFallbackCdnUrl(String searchQuery) async {
    try {
      final uri = Uri.parse(
          'https://saavn.dev/api/search/songs?query=${Uri.encodeComponent(searchQuery)}&limit=3');
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map;
        final results = (data['data'] as Map?)?['results'] as List?;
        if (results != null && results.isNotEmpty) {
          final first = results.first as Map;
          final dlUrls = first['downloadUrl'] as List?;
          if (dlUrls != null && dlUrls.isNotEmpty) {
            final best = dlUrls.last as Map;
            final url = best['url'] as String?;
            if (url != null && url.startsWith('http')) return url;
          }
        }
      }
    } catch (_) {}

    try {
      final uri = Uri.parse(
          'https://itunes.apple.com/search?term=${Uri.encodeComponent(searchQuery)}&entity=song&limit=3');
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map;
        final results = data['results'] as List?;
        if (results != null && results.isNotEmpty) {
          for (final item in results) {
            if (item is Map) {
              final pUrl = item['previewUrl'] as String?;
              if (pUrl != null && pUrl.startsWith('http')) return pUrl;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<Duration?> _playStreamTrack(Track t) async {
    final dir = await _cacheDir();
    final safeHash = t.path.hashCode.toUnsigned(32).toString();
    final cachedFile = File('$dir/stream_$safeHash.m4a');
    if (await cachedFile.exists() && await cachedFile.length() > 12000) {
      return await player.setFilePath(cachedFile.path);
    }

    toast('Loading "${listTitle(t)}"...');

    final yt = YoutubeExplode();
    try {
      String videoId = t.ytId;
      if (videoId.isEmpty) {
        final searchRes = await yt.search
            .search('${t.searchQuery} audio')
            .timeout(const Duration(seconds: 6));
        if (searchRes.isNotEmpty) {
          videoId = searchRes.first.id.value;
        }
      }

      if (videoId.isNotEmpty) {
        StreamManifest manifest;
        try {
          manifest = await yt.videos.streamsClient
              .getManifest(
                videoId,
                ytClients: [
                  YoutubeApiClient.androidVr,
                  YoutubeApiClient.ios,
                ],
                requireWatchPage: false,
              )
              .timeout(const Duration(seconds: 7));
        } catch (_) {
          manifest = await yt.videos.streamsClient
              .getManifest(videoId, requireWatchPage: false)
              .timeout(const Duration(seconds: 7));
        }

        final mp4s = manifest.audioOnly
            .where((s) => s.container == StreamContainer.mp4)
            .toList();
        final StreamInfo info = mp4s.isNotEmpty
            ? mp4s.withHighestBitrate()
            : (manifest.audioOnly.isNotEmpty
                ? manifest.audioOnly.withHighestBitrate()
                : manifest.muxed.withHighestBitrate());

        try {
          final stream = yt.videos.streamsClient.get(info);
          final sink = cachedFile.openWrite();
          try {
            await for (final chunk in stream.timeout(const Duration(seconds: 10))) {
              sink.add(chunk);
            }
          } finally {
            await sink.close();
          }
          if (await cachedFile.exists() && await cachedFile.length() > 12000) {
            return await player.setFilePath(cachedFile.path);
          }
        } catch (_) {}

        try {
          return await player.setAudioSource(
            AudioSource.uri(
              info.url,
              headers: const {
                'User-Agent':
                    'com.google.android.apps.youtube.vr.oculus/1.56.21 (Linux; U; Android 12; en_US; Quest 2; Build/SQ3A.220605.009.A1) gzip',
              },
            ),
          );
        } catch (_) {}
      }
    } catch (_) {
    } finally {
      yt.close();
    }

    final cdnUrl = await _resolveFallbackCdnUrl(t.searchQuery);
    if (cdnUrl != null) {
      return await player.setUrl(cdnUrl);
    }

    throw Exception('All stream sources failed');
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
      if (t.isStream) {
        dur = await _playStreamTrack(t);
      } else {
        dur = await player.setFilePath(t.path);
      }
      await player.setSpeed(speed);
      player.play();
    } on PlayerInterruptedException catch (_) {
      return;
    } catch (e) {
      toast('Could not play "${listTitle(t)}"');
    }
    final m = await metaFuture;
    if (index != i || current?.path != t.path) return;
    currentMeta = m;
    _pushItem(t, m, dur ?? player.duration);
    notifyListeners();
    final col = await colorFor(m.art);
    if (index != i || current?.path != t.path) return;
    currentColor = col;
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

ColorScheme spotifyScheme() {
  return ColorScheme.fromSeed(
    seedColor: const Color(0xFF1DB954),
    brightness: Brightness.dark,
  ).copyWith(
    primary: const Color(0xFF1DB954),
    onPrimary: Colors.black,
    primaryContainer: const Color(0xFF282828),
    onPrimaryContainer: Colors.white,
    secondary: const Color(0xFF1DB954),
    onSecondary: Colors.black,
    secondaryContainer: const Color(0xFF2A2A2A),
    onSecondaryContainer: Colors.white,
    tertiaryContainer: const Color(0xFF333333),
    onTertiaryContainer: const Color(0xFFB3B3B3),
    surface: const Color(0xFF121212),
    onSurface: Colors.white,
    onSurfaceVariant: const Color(0xFFB3B3B3),
    outline: const Color(0xFF727272),
    outlineVariant: const Color(0xFF2A2A2A),
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: const Color(0xFF121212),
    surfaceContainer: const Color(0xFF181818),
    surfaceContainerHigh: const Color(0xFF242424),
    surfaceContainerHighest: const Color(0xFF2E2E2E),
  );
}

ColorScheme iosScheme(bool dark, bool isGlass) {
  var s = ColorScheme.fromSeed(
    seedColor: const Color(0xFF007AFF),
    brightness: dark ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF),
    onPrimary: Colors.white,
    primaryContainer: dark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
    onPrimaryContainer: dark ? const Color(0xFFAEAEB2) : const Color(0xFF636366),
    secondary: dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF),
    secondaryContainer: dark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
    onSecondaryContainer: dark ? Colors.white : Colors.black,
    tertiaryContainer: dark ? const Color(0xFF3A3A3C) : const Color(0xFFD1D1D6),
    onTertiaryContainer: dark ? const Color(0xFFAEAEB2) : const Color(0xFF636366),
    surface: dark ? Colors.black : const Color(0xFFF2F2F7),
    onSurface: dark ? Colors.white : Colors.black,
    onSurfaceVariant: dark ? const Color(0xFF98989D) : const Color(0xFF6C6C70),
    outline: dark ? const Color(0xFF48484A) : const Color(0xFFC7C7CC),
    outlineVariant: dark ? const Color(0xFF38383A) : const Color(0xFFD1D1D6),
    surfaceContainerLowest: dark ? Colors.black : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF111111) : Colors.white,
    surfaceContainer: dark ? const Color(0xFF1C1C1E) : Colors.white,
    surfaceContainerHigh: dark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
    surfaceContainerHighest:
        dark ? const Color(0xFF3A3A3C) : const Color(0xFFD1D1D6),
  );
  if (isGlass) {
    s = s.copyWith(
      surfaceContainerLowest: Colors.white.withValues(alpha: dark ? 0.05 : 0.4),
      surfaceContainerLow: Colors.white.withValues(alpha: dark ? 0.07 : 0.5),
      surfaceContainer: Colors.white.withValues(alpha: dark ? 0.1 : 0.62),
    );
  }
  return s;
}

ColorScheme oneUiScheme(bool dark) {
  return ColorScheme.fromSeed(
    seedColor: const Color(0xFF3E91FF),
    brightness: dark ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: dark ? const Color(0xFF6FB0FF) : const Color(0xFF3E91FF),
    onPrimary: dark ? Colors.black : Colors.white,
    primaryContainer: dark ? const Color(0xFF1E2F47) : const Color(0xFFD9E8FF),
    onPrimaryContainer: dark ? const Color(0xFFD9E8FF) : const Color(0xFF0B2A52),
    secondary: dark ? const Color(0xFF6FB0FF) : const Color(0xFF3E91FF),
    secondaryContainer: dark ? const Color(0xFF26364D) : const Color(0xFFDDE7F5),
    onSecondaryContainer: dark ? Colors.white : const Color(0xFF111827),
    tertiaryContainer: dark ? const Color(0xFF2A2F3A) : const Color(0xFFE6EAF2),
    onTertiaryContainer: dark ? const Color(0xFFC9D1E0) : const Color(0xFF3B4252),
    surface: dark ? Colors.black : const Color(0xFFF6F6F6),
    onSurface: dark ? const Color(0xFFF2F2F2) : const Color(0xFF111111),
    onSurfaceVariant: dark ? const Color(0xFF9A9A9F) : const Color(0xFF6B6B70),
    outline: dark ? const Color(0xFF55555A) : const Color(0xFFC4C4C9),
    outlineVariant: dark ? const Color(0xFF38383C) : const Color(0xFFDADADF),
    surfaceContainerLowest: dark ? Colors.black : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF0F0F10) : Colors.white,
    surfaceContainer: dark ? const Color(0xFF1B1B1D) : Colors.white,
    surfaceContainerHigh: dark ? const Color(0xFF242427) : const Color(0xFFEDEDF0),
    surfaceContainerHighest:
        dark ? const Color(0xFF2E2E32) : const Color(0xFFE2E2E6),
  );
}

ThemeData buildTheme(Brightness b, ColorScheme? dyn) {
  final dark = b == Brightness.dark;
  ColorScheme scheme;
  switch (app.uiStyle) {
    case UiStyle.spotify:
      scheme = spotifyScheme();
      break;
    case UiStyle.ios:
      scheme = iosScheme(dark, glass);
      break;
    case UiStyle.oneui:
      scheme = oneUiScheme(dark);
      break;
    case UiStyle.material:
      final seed = (app.dynamicColor && dyn != null)
          ? dyn.primary
          : seedOptions[app.seedIndex].color;
      scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
      break;
  }
  if (dark && app.amoled && (app.uiStyle == UiStyle.material || isOneUi)) {
    scheme = scheme.copyWith(
      surface: Colors.black,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xFF080808),
      surfaceContainer: const Color(0xFF0F0F0F),
      surfaceContainerHigh: const Color(0xFF151515),
      surfaceContainerHighest: const Color(0xFF1C1C1C),
    );
  }
  final bold = isSpotify ? FontWeight.w700 : FontWeight.w600;
  return ThemeData(
    useMaterial3: true,
    platform: isIos ? TargetPlatform.iOS : null,
    colorScheme: scheme,
    scaffoldBackgroundColor: glass ? Colors.transparent : scheme.surface,
    splashFactory: app.uiStyle == UiStyle.material
        ? InkSparkle.splashFactory
        : InkRipple.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: glass ? Colors.transparent : scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: isIos,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(isSpotify ? 6 : 16)),
    ),
    sliderTheme: isSpotify
        ? const SliderThemeData(
            trackHeight: 4,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
          )
        : null,
    textTheme: TextTheme(
      headlineMedium:
          const TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineSmall:
          const TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleLarge: TextStyle(fontWeight: bold),
      titleMedium: TextStyle(fontWeight: bold),
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
        return DynamicColorBuilder(
          builder: (lightDyn, darkDyn) {
            return MaterialApp(
              title: 'Pixel Audio Player',
              debugShowCheckedModeBanner: false,
              scaffoldMessengerKey: messengerKey,
              themeMode: app.effectiveMode,
              theme: buildTheme(Brightness.light, lightDyn),
              darkTheme: buildTheme(Brightness.dark, darkDyn),
              home: const HomeShell(),
            );
          },
        );
      },
    );
  }
}

class Pressable extends StatefulWidget {
  final Widget child;
  final double scale;
  final bool squish;
  const Pressable({
    super.key,
    required this.child,
    this.scale = 0.95,
    this.squish = false,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool down = false;
  Offset? start;

  void _set(bool v) {
    if (down != v && mounted) setState(() => down = v);
  }

  @override
  Widget build(BuildContext context) {
    final sx = down ? (widget.squish ? 1.07 : widget.scale) : 1.0;
    final sy = down ? (widget.squish ? 0.85 : widget.scale) : 1.0;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        start = e.position;
        _set(true);
      },
      onPointerMove: (e) {
        final s = start;
        if (s != null && (e.position - s).distance > 14) _set(false);
      },
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: TweenAnimationBuilder<Offset>(
        tween: Tween<Offset>(begin: const Offset(1, 1), end: Offset(sx, sy)),
        duration: Duration(milliseconds: down ? 85 : 260),
        curve: down ? Curves.easeOut : Curves.elasticOut,
        builder: (context, val, child) {
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(val.dx, val.dy, 1.0),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

class PIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;
  final Color? bg;
  final double size;
  final String? tooltip;
  const PIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.color,
    this.bg,
    this.size = 24,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      scale: 0.82,
      squish: true,
      child: IconButton(
        icon: Icon(icon),
        iconSize: size,
        color: color,
        tooltip: tooltip,
        onPressed: onTap,
        style: bg != null ? IconButton.styleFrom(backgroundColor: bg) : null,
      ),
    );
  }
}

class AppBackdrop extends StatelessWidget {
  final Widget child;
  const AppBackdrop({super.key, required this.child});

  Widget _blob(Color c) => Container(
        width: 340,
        height: 340,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [c.withValues(alpha: 0.5), c.withValues(alpha: 0.0)],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!glass) return child;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? const [Color(0xFF0B1026), Color(0xFF2A1450), Color(0xFF0A2A45)]
                  : const [Color(0xFFDDEBFF), Color(0xFFF1E3FF), Color(0xFFFFE6EE)],
            ),
          ),
        ),
        Positioned(
            top: -90,
            left: -70,
            child: _blob(dark ? const Color(0xFF3B82F6) : const Color(0xFF7DB5FF))),
        Positioned(
            bottom: 140,
            right: -100,
            child: _blob(dark ? const Color(0xFFEC4899) : const Color(0xFFFFA6C9))),
        child,
      ],
    );
  }
}

void openSettings(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
  );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        const pages = <Widget>[
          HomePage(),
          LibraryPage(),
          FavoritesPage(),
          PlaylistsPage(),
        ];
        final content = IndexedStack(index: tab, children: pages);
        final nav = AppNavBar(index: tab, onTap: (i) => setState(() => tab = i));
        if (glass) {
          final dark = Theme.of(context).brightness == Brightness.dark;
          return AppBackdrop(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Stack(
                children: [
                  Positioned.fill(child: SafeArea(bottom: false, child: content)),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRect(
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                        child: ColoredBox(
                          color: (dark ? Colors.black : Colors.white)
                              .withValues(alpha: dark ? 0.35 : 0.45),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (app.current != null) const MiniPlayer(),
                              nav,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Expanded(child: content),
                if (app.current != null) const MiniPlayer(),
              ],
            ),
          ),
          bottomNavigationBar: nav,
        );
      },
    );
  }
}

class AppNavBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  const AppNavBar({super.key, required this.index, required this.onTap});

  static const labels = ['Home', 'Library', 'Favorites', 'Playlists'];

  List<List<IconData>> _icons() {
    if (isIos) {
      return [
        [CupertinoIcons.house, CupertinoIcons.house_fill],
        [CupertinoIcons.music_albums, CupertinoIcons.music_albums_fill],
        [CupertinoIcons.heart, CupertinoIcons.heart_fill],
        [CupertinoIcons.music_note_list, CupertinoIcons.music_note_list],
      ];
    }
    return [
      [Icons.home_outlined, Icons.home_filled],
      [Icons.library_music_outlined, Icons.library_music],
      [Icons.favorite_border, Icons.favorite],
      [Icons.queue_music_outlined, Icons.queue_music],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final icons = _icons();
    final h = isIos ? 54.0 : (isSpotify ? 62.0 : (isOneUi ? 74.0 : 80.0));

    Widget item(int i) {
      final sel = i == index;
      final icon = sel ? icons[i][1] : icons[i][0];
      Widget core;
      if (isIos || isSpotify) {
        final col = sel
            ? (isSpotify ? Colors.white : cs.primary)
            : (isSpotify ? const Color(0xFFB3B3B3) : cs.onSurfaceVariant);
        core = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              scale: sel ? 1.12 : 1.0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              child: Icon(icon, color: col, size: 26),
            ),
            const SizedBox(height: 3),
            Text(labels[i],
                style: TextStyle(
                    fontSize: isIos ? 10 : 11,
                    fontWeight: FontWeight.w500,
                    color: col)),
          ],
        );
      } else {
        final pill = isOneUi ? cs.primaryContainer : cs.secondaryContainer;
        final onPill =
            isOneUi ? cs.onPrimaryContainer : cs.onSecondaryContainer;
        core = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              width: 64,
              height: 32,
              decoration: BoxDecoration(
                color: sel ? pill : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon,
                  size: 24, color: sel ? onPill : cs.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(labels[i],
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                    color: sel ? cs.onSurface : cs.onSurfaceVariant)),
          ],
        );
      }
      return Expanded(
        child: Pressable(
          scale: 0.88,
          squish: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              onTap(i);
            },
            child: SizedBox(height: h, child: core),
          ),
        ),
      );
    }

    BoxDecoration deco;
    if (glass) {
      deco = BoxDecoration(
        border: Border(
            top: BorderSide(
                color: Colors.white.withValues(alpha: 0.18), width: 0.5)),
      );
    } else if (isSpotify) {
      deco = const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xE6121212), Color(0xFF000000)],
        ),
      );
    } else if (isIos) {
      deco = BoxDecoration(
        color: cs.surfaceContainer,
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
      );
    } else {
      deco = BoxDecoration(color: cs.surfaceContainer);
    }
    return DecoratedBox(
      decoration: deco,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: h,
          child: Row(children: [for (var i = 0; i < 4; i++) item(i)]),
        ),
      ),
    );
  }
}
