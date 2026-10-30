import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as ytd;

// ─────────────────────────────────────────────────────────────────────────────
// Globals
// ─────────────────────────────────────────────────────────────────────────────

late final MyAudioHandler audioHandler;
final AppState appState = AppState();
final ValueNotifier<String?> appNotice = ValueNotifier<String?>(null);
final ValueNotifier<bool> scanning = ValueNotifier<bool>(false);
final ValueNotifier<double?> downloadProgress = ValueNotifier<double?>(null);
final ValueNotifier<String?> downloadStatus = ValueNotifier<String?>(null);
bool _cancelCurrentDownload = false;
HttpServer? _wifiServer;
final ValueNotifier<String?> wifiServerUrl = ValueNotifier<String?>(null);
const MethodChannel _mediaChannel = MethodChannel('com.alexlmp.app/media');

const List<String> kArtStyles = [
  'vinyl_record',
  'sound_wave',
  'music_note_grid',
  'equalizer_bars',
  'neon_vinyl',
];

class ColorStopSet {
  final List<Color> colors;
  const ColorStopSet(this.colors);
}

const List<ColorStopSet> kArtPalettes = [
  ColorStopSet([Color(0xFF3E1C0C), Color(0xFFD96B38), Color(0xFF1A0F0A)]),
  ColorStopSet([Color(0xFF42173B), Color(0xFFE0538A), Color(0xFF28193D)]),
  ColorStopSet([Color(0xFF062A4E), Color(0xFF1F7AE0), Color(0xFF0A2416)]),
  ColorStopSet([Color(0xFF1A3A2A), Color(0xFF9C27B0), Color(0xFF00BCD4)]),
  ColorStopSet([Color(0xFF4A1E0D), Color(0xFFE66833), Color(0xFF1B110E)]),
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  await appState.load();

  try {
    audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.alexlmp.app.channel.audio',
        androidNotificationChannelName: 'AlexLMP Music Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (_) {
    audioHandler = MyAudioHandler();
  }

  runApp(const AlexLmpApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// Core Utils
// ─────────────────────────────────────────────────────────────────────────────

String cleanText(dynamic v, String fallback) {
  final s = v?.toString().trim() ?? '';
  if (s.isEmpty || s == '<unknown>') return fallback;
  return s;
}

String formatDuration(Duration d) {
  final total = d.inSeconds;
  final mins = (total ~/ 60).toString().padLeft(2, '0');
  final secs = (total % 60).toString().padLeft(2, '0');
  return '$mins:$secs';
}

Future<T?> withHardTimeout<T>(Future<T?> future, int seconds) async {
  try {
    return await Future.any<T?>([
      future,
      Future<T?>.delayed(Duration(seconds: seconds), () => null),
    ]);
  } catch (_) {
    return null;
  }
}

Future<String?> pickAndSaveGalleryImage() async {
  try {
    final res = await FilePicker.platform.pickFiles(type: FileType.image);
    if (res == null || res.files.isEmpty) return null;
    final srcPath = res.files.single.path;
    if (srcPath == null) return null;
    final dir = await getApplicationDocumentsDirectory();
    final ext = p.extension(srcPath).isEmpty ? '.jpg' : p.extension(srcPath);
    final dst = p.join(
      dir.path,
      'pl_cover_${DateTime.now().microsecondsSinceEpoch}$ext',
    );
    await File(srcPath).copy(dst);
    return dst;
  } catch (_) {
    return null;
  }
}

Future<Directory> _getMusicDownloadsDir() async {
  final docDir = await getApplicationDocumentsDirectory();
  final d = Directory(p.join(docDir.path, 'alexlmp_downloads'));
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

Future<List<TrackItem>> loadSavedDownloads() async {
  final list = <TrackItem>[];
  try {
    final d = await _getMusicDownloadsDir();
    final files = d
        .listSync()
        .whereType<File>()
        .where((f) {
          final ext = p.extension(f.path).toLowerCase();
          return const ['.mp3', '.m4a', '.flac', '.wav', '.ogg', '.aac', '.opus']
              .contains(ext);
        })
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final id = 'dl_${f.path.hashCode}';
      if (appState.isDeleted(id, f.path)) continue;
      final base = p.basenameWithoutExtension(f.path);
      String title = base;
      String artist = 'Downloaded Track';
      if (base.contains(' - ')) {
        final parts = base.split(' - ');
        artist = parts.first.trim();
        title = parts.sublist(1).join(' - ').trim();
      }
      final t = TrackItem(
        id: id,
        title: title,
        artist: artist,
        album: 'AlexLMP Downloads',
        durationSeconds: 0,
        artColors: kArtPalettes[i % kArtPalettes.length].colors,
        artStyle: kArtStyles[i % kArtStyles.length],
        source: f.path,
        filePath: f.path,
      );
      appState.applyEdits(t);
      list.add(t);
    }
  } catch (_) {}
  return list;
}

// ─────────────────────────────────────────────────────────────────────────────
// Wi-Fi Server
// ─────────────────────────────────────────────────────────────────────────────

Future<void> toggleWifiDropServer() async {
  if (_wifiServer != null) {
    await _wifiServer!.close(force: true);
    _wifiServer = null;
    wifiServerUrl.value = null;
    return;
  }
  try {
    String localIp = '127.0.0.1';
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback && addr.address.startsWith('192.168.')) {
          localIp = addr.address;
          break;
        } else if (!addr.isLoopback) {
          localIp = addr.address;
        }
      }
    }

    final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
    _wifiServer = server;
    wifiServerUrl.value = 'http://$localIp:8080';

    server.listen((HttpRequest req) async {
      try {
        if (req.method == 'GET') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('''
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AlexLMP Wi-Fi Drop</title>
<style>
  body { background:#000000; color:#fff; font-family:sans-serif; text-align:center; padding:40px 20px; }
  .box { max-width:480px; margin:0 auto; background:#1C1B1F; border:2px dashed #D0BCFF; border-radius:24px; padding:40px 20px; }
  h1 { color:#D0BCFF; margin-top:0; }
  input[type=file] { margin:20px 0; color:#fff; }
  button { background:#D0BCFF; color:#381E72; border:none; padding:14px 28px; border-radius:24px; font-weight:bold; font-size:16px; cursor:pointer; }
  #status { margin-top:20px; color:#9cf0c0; font-weight:bold; }
</style>
</head>
<body>
  <div class="box">
    <h1>AlexLMP Wi-Fi Drop</h1>
    <p>Select MP3, FLAC, WAV, or M4A files from your PC or phone to send straight into AlexLMP.</p>
    <input type="file" id="files" multiple accept="audio/*,.mp3,.flac,.wav,.m4a,.ogg,.opus"><br>
    <button onclick="upload()">Send to AlexLMP</button>
    <div id="status"></div>
  </div>
  <script>
    async function upload() {
      const input = document.getElementById('files');
      const status = document.getElementById('status');
      if (!input.files.length) { status.innerText = 'Pick at least one audio file!'; return; }
      for (let i = 0; i < input.files.length; i++) {
        const f = input.files[i];
        status.innerText = 'Sending ' + (i+1) + '/' + input.files.length + ': ' + f.name + '...';
        await fetch('/upload?name=' + encodeURIComponent(f.name), { method: 'POST', body: f });
      }
      status.innerText = 'All songs sent to AlexLMP!';
      input.value = '';
    }
  </script>
</body>
</html>
''');
          await req.response.close();
        } else if (req.method == 'POST' && req.uri.path == '/upload') {
          final rawName = req.uri.queryParameters['name'] ?? 'Track.mp3';
          final safeName = rawName
              .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
              .trim();
          final dir = await _getMusicDownloadsDir();
          final savePath = p.join(dir.path, safeName);
          final outFile = File(savePath);
          final sink = outFile.openWrite();
          await for (final chunk in req) {
            sink.add(chunk);
          }
          await sink.flush();
          await sink.close();

          final base = p.basenameWithoutExtension(safeName);
          String title = base;
          String artist = 'Wi-Fi Drop';
          if (base.contains(' - ')) {
            final parts = base.split(' - ');
            artist = parts.first.trim();
            title = parts.sublist(1).join(' - ').trim();
          }
          final id = 'dl_${savePath.hashCode}';
          appState.unmarkDeleted(id, savePath);
          final newTrack = TrackItem(
            id: id,
            title: title,
            artist: artist,
            album: 'AlexLMP Wi-Fi Drop',
            durationSeconds: 0,
            artColors: kArtPalettes[
                    audioHandler.tracks.length % kArtPalettes.length]
                .colors,
            artStyle: kArtStyles[audioHandler.tracks.length % kArtStyles.length],
            source: savePath,
            filePath: savePath,
          );
          await audioHandler.addTracks([newTrack], playFirst: true);
          appNotice.value = 'Received "$title" over Wi-Fi!';

          req.response.statusCode = 200;
          req.response.write('OK');
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      } catch (_) {
        try {
          await req.response.close();
        } catch (_) {}
      }
    });
  } catch (e) {
    appNotice.value = 'Could not start Wi-Fi server: $e';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Audio Downloader (YouTube Explode & Direct HTTP)
// ─────────────────────────────────────────────────────────────────────────────

Future<bool> _downloadBinaryStreamToLibrary({
  required HttpClient client,
  required String downloadUrl,
  required String title,
  required String artist,
  required String ext,
}) async {
  try {
    downloadStatus.value = 'Downloading "$title"…';
    final uri = Uri.parse(downloadUrl);
    final req = await client.getUrl(uri);
    req.headers.set('User-Agent', 'Mozilla/5.0');
    final resp = await req.close().timeout(const Duration(seconds: 15));

    if (resp.statusCode < 200 || resp.statusCode >= 400) {
      return false;
    }

    var safeName = '$artist - $title'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safeName.isEmpty) {
      safeName = 'Track_${DateTime.now().millisecondsSinceEpoch}';
    }

    final dir = await _getMusicDownloadsDir();
    final savePath = p.join(dir.path, '$safeName$ext');
    final outFile = File(savePath);
    final sink = outFile.openWrite();

    final totalBytes = resp.contentLength;
    int received = 0;

    await for (final chunk in resp.timeout(const Duration(seconds: 20))) {
      if (_cancelCurrentDownload) {
        await sink.close();
        try { outFile.deleteSync(); } catch (_) {}
        return false;
      }
      sink.add(chunk);
      received += chunk.length;
      if (totalBytes > 0) {
        downloadProgress.value = (received / totalBytes).clamp(0.05, 0.99);
      }
    }
    await sink.flush();
    await sink.close();

    if (received < 1024) {
      try { outFile.deleteSync(); } catch (_) {}
      return false;
    }

    final newId = 'dl_${savePath.hashCode}';
    appState.unmarkDeleted(newId, savePath);

    final newTrack = TrackItem(
      id: newId,
      title: title,
      artist: artist,
      album: 'AlexLMP Downloads',
      durationSeconds: 0,
      artColors: kArtPalettes[audioHandler.tracks.length % kArtPalettes.length].colors,
      artStyle: kArtStyles[audioHandler.tracks.length % kArtStyles.length],
      source: savePath,
      filePath: savePath,
    );

    await audioHandler.addTracks([newTrack], playFirst: true);
    appNotice.value = 'Downloaded "$title" into your library!';
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> downloadAudioIntoApp({
  required String inputUrlOrQuery,
  String? customTitle,
  String? customArtist,
}) async {
  final rawInput = inputUrlOrQuery.trim();
  if (rawInput.isEmpty) return false;

  _cancelCurrentDownload = false;

  // Direct File URL
  if (rawInput.startsWith('http') && 
     (rawInput.toLowerCase().endsWith('.mp3') || rawInput.toLowerCase().endsWith('.m4a') || rawInput.toLowerCase().endsWith('.wav'))) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      downloadProgress.value = 0.05;
      final uri = Uri.parse(rawInput);
      final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'Track';
      final decodedName = Uri.decodeComponent(p.basenameWithoutExtension(seg));
      String ext = p.extension(uri.path).toLowerCase();
      
      final ok = await _downloadBinaryStreamToLibrary(
        client: client,
        downloadUrl: rawInput,
        title: customTitle ?? decodedName,
        artist: customArtist ?? 'Direct Link',
        ext: ext,
      );
      return ok;
    } finally {
      client.close();
      downloadProgress.value = null;
      downloadStatus.value = null;
    }
  }

  // YouTube Explode Search/Extraction
  final yt = ytd.YoutubeExplode();
  try {
    downloadProgress.value = 0.1;
    ytd.Video? video;

    if (rawInput.startsWith('http') && rawInput.contains('youtu')) {
      downloadStatus.value = 'Parsing YouTube link…';
      video = await yt.videos.get(rawInput);
    } else {
      downloadStatus.value = 'Searching YouTube Music for "$rawInput"…';
      final results = await yt.search.search('$rawInput official audio');
      if (results.isNotEmpty) video = results.first;
    }

    if (video == null || _cancelCurrentDownload) {
      appNotice.value = 'Could not find a track for "$rawInput".';
      return false;
    }

    downloadStatus.value = 'Extracting audio stream…';
    final manifest = await yt.videos.streamsClient.getManifest(video.id);
    final audioStreams = manifest.audioOnly;
    if (audioStreams.isEmpty || _cancelCurrentDownload) return false;

    ytd.AudioStreamInfo? chosen;
    for (final s in audioStreams.sortByBitrate()) {
      if (s.container.name.toLowerCase().contains('mp4')) {
        chosen = s; break;
      }
    }
    chosen ??= audioStreams.withHighestBitrate();

    final finalTitle = (customTitle != null && customTitle.trim().isNotEmpty) ? customTitle.trim() : video.title.trim();
    final finalArtist = (customArtist != null && customArtist.trim().isNotEmpty) ? customArtist.trim() : video.author.replaceAll(' - Topic', '').trim();

    var safeName = '$finalArtist - $finalTitle'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safeName.isEmpty) safeName = 'Track_${DateTime.now().millisecondsSinceEpoch}';

    final dir = await _getMusicDownloadsDir();
    final savePath = p.join(dir.path, '$safeName.m4a');
    final outFile = File(savePath);
    final sink = outFile.openWrite();

    final totalBytes = chosen.size.totalBytes;
    int received = 0;

    downloadStatus.value = 'Downloading "$finalTitle"…';
    final byteStream = yt.videos.streamsClient.get(chosen);
    
    await for (final chunk in byteStream.timeout(const Duration(seconds: 15))) {
      if (_cancelCurrentDownload) {
        await sink.close();
        try { outFile.deleteSync(); } catch (_) {}
        return false;
      }
      sink.add(chunk);
      received += chunk.length;
      if (totalBytes > 0) {
        downloadProgress.value = (received / totalBytes).clamp(0.05, 0.99);
      }
    }
    await sink.flush();
    await sink.close();

    if (received < 1024) {
      try { outFile.deleteSync(); } catch (_) {}
      return false;
    }

    final newId = 'dl_${savePath.hashCode}';
    appState.unmarkDeleted(newId, savePath);

    final newTrack = TrackItem(
      id: newId,
      title: finalTitle,
      artist: finalArtist,
      album: 'AlexLMP Downloads',
      durationSeconds: video.duration?.inSeconds ?? 0,
      artColors: kArtPalettes[audioHandler.tracks.length % kArtPalettes.length].colors,
      artStyle: kArtStyles[audioHandler.tracks.length % kArtStyles.length],
      source: savePath,
      filePath: savePath,
    );

    await audioHandler.addTracks([newTrack], playFirst: true);
    appNotice.value = 'Downloaded "$finalTitle" into your library!';
    return true;
  } catch (e) {
    appNotice.value = 'Download error. Stream may be throttled.';
    return false;
  } finally {
    yt.close();
    downloadProgress.value = null;
    downloadStatus.value = null;
  }
}

Future<int> quickImportPhoneDownloadsFolder() async {
  int count = 0;
  try {
    await ensureMediaPermissions();
    final existingPaths = audioHandler.tracks.map((t) => t.filePath ?? t.source).toSet();
    final found = <TrackItem>[];
    final candidateDirs = [
      Directory('/storage/emulated/0/Download'),
      Directory('/storage/emulated/0/Music'),
    ];

    for (final d in candidateDirs) {
      if (!d.existsSync()) continue;
      for (final entity in d.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final ext = p.extension(entity.path).toLowerCase();
        if (!const ['.mp3', '.m4a', '.flac', '.wav', '.ogg', '.aac'].contains(ext)) continue;
        if (existingPaths.contains(entity.path)) continue;
        
        final id = 'local_${entity.path.hashCode}';
        if (appState.isDeleted(id, entity.path)) continue;
        final base = p.basenameWithoutExtension(entity.path);
        
        final t = TrackItem(
          id: id,
          title: base,
          artist: 'Local File',
          album: 'Phone Downloads',
          durationSeconds: 0,
          artColors: kArtPalettes[found.length % kArtPalettes.length].colors,
          artStyle: kArtStyles[found.length % kArtStyles.length],
          source: entity.path,
          filePath: entity.path,
        );
        appState.applyEdits(t);
        found.add(t);
        existingPaths.add(entity.path);
        count++;
      }
    }
    if (found.isNotEmpty) {
      await audioHandler.addTracks(found, playFirst: false);
    }
  } catch (_) {}
  return count;
}

// ─────────────────────────────────────────────────────────────────────────────
// App State & Preferences (Material 3 Themes)
// ─────────────────────────────────────────────────────────────────────────────

class AppState extends ChangeNotifier {
  SharedPreferences? _prefs;
  Color seedColor = const Color(0xFFD0BCFF);
  bool useAmoled = true;
  bool vinylSpinMode = false;
  bool stopOnTaskClear = true;
  bool linkSpeedAndPitch = false;
  double speed = 1.0;
  double pitch = 1.0;
  String searchProvider = 'YouTube Music';
  final Set<String> liked = {};
  final Set<String> deletedIds = {};
  Map<String, dynamic> _edits = {};
  final List<Playlist> playlists = [];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final seedInt = prefs.getInt('seed_color') ?? 0xFFD0BCFF;
    seedColor = Color(seedInt);
    useAmoled = prefs.getBool('use_amoled') ?? true;
    vinylSpinMode = prefs.getBool('vinyl_spin_mode') ?? false;
    stopOnTaskClear = prefs.getBool('stop_on_task_clear') ?? true;
    linkSpeedAndPitch = prefs.getBool('link_speed_pitch') ?? false;
    speed = prefs.getDouble('playback_speed') ?? 1.0;
    pitch = prefs.getDouble('playback_pitch') ?? 1.0;
    searchProvider = prefs.getString('search_provider') ?? 'YouTube Music';
    
    liked.addAll(prefs.getStringList('liked_ids') ?? const []);
    deletedIds.addAll(prefs.getStringList('deleted_ids') ?? const []);
    try {
      final raw = jsonDecode(prefs.getString('playlists') ?? '[]') as List;
      playlists..clear()..addAll(raw.map((e) => Playlist.fromJson(Map<String, dynamic>.from(e as Map))));
    } catch (_) { playlists.clear(); }
    try {
      _edits = Map<String, dynamic>.from(jsonDecode(prefs.getString('track_edits') ?? '{}') as Map);
    } catch (_) { _edits = {}; }
    notifyListeners();
  }

  void setSeedColor(Color c) {
    seedColor = c;
    _prefs?.setInt('seed_color', c.value);
    notifyListeners();
  }

  void setAmoled(bool v) {
    useAmoled = v;
    _prefs?.setBool('use_amoled', v);
    notifyListeners();
  }
  
  void setSearchProvider(String p) {
    searchProvider = p;
    _prefs?.setString('search_provider', p);
    notifyListeners();
  }

  void setVinylSpinMode(bool v) {
    vinylSpinMode = v;
    _prefs?.setBool('vinyl_spin_mode', v);
    notifyListeners();
  }

  void setStopOnTaskClear(bool v) {
    stopOnTaskClear = v;
    _prefs?.setBool('stop_on_task_clear', v);
    notifyListeners();
  }

  void setLinkSpeedAndPitch(bool v) {
    linkSpeedAndPitch = v;
    _prefs?.setBool('link_speed_pitch', v);
    notifyListeners();
  }

  void setSpeed(double v) {
    speed = v.clamp(0.5, 2.0);
    _prefs?.setDouble('playback_speed', speed);
    notifyListeners();
  }

  void setPitch(double v) {
    pitch = v.clamp(0.5, 2.0);
    _prefs?.setDouble('playback_pitch', pitch);
    notifyListeners();
  }

  bool isDeleted(String id, [String? path]) {
    if (deletedIds.contains(id)) return true;
    if (path != null && path.isNotEmpty && deletedIds.contains(path)) return true;
    return false;
  }

  void markDeleted(TrackItem t) {
    deletedIds.add(t.id);
    if (t.filePath != null && t.filePath!.isNotEmpty) deletedIds.add(t.filePath!);
    if (t.source.isNotEmpty) deletedIds.add(t.source);
    _prefs?.setStringList('deleted_ids', deletedIds.toList());
    liked.remove(t.id);
    _prefs?.setStringList('liked_ids', liked.toList());
    for (final pl in playlists) { pl.trackIds.remove(t.id); }
    _savePlaylists();
  }

  void unmarkDeleted(String id, [String? path]) {
    deletedIds.remove(id);
    if (path != null) deletedIds.remove(path);
    _prefs?.setStringList('deleted_ids', deletedIds.toList());
  }

  bool isLiked(String id) => liked.contains(id);
  void toggleLike(String id) {
    if (!liked.remove(id)) liked.add(id);
    _prefs?.setStringList('liked_ids', liked.toList());
    notifyListeners();
  }

  Playlist? playlistById(String id) {
    for (final pl in playlists) { if (pl.id == id) return pl; }
    return null;
  }

  void _savePlaylists() {
    _prefs?.setString('playlists', jsonEncode(playlists.map((pl) => pl.toJson()).toList()));
    notifyListeners();
  }

  Playlist createPlaylist(String name, {String? cover}) {
    final pl = Playlist(
      id: 'pl_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'New Playlist' : name.trim(),
      cover: cover,
    );
    playlists.add(pl);
    _savePlaylists();
    return pl;
  }

  void setPlaylistInfo(String id, String name, String? cover) {
    final pl = playlistById(id);
    if (pl == null) return;
    pl.name = name.trim().isEmpty ? pl.name : name.trim();
    pl.cover = cover;
    _savePlaylists();
  }

  void deletePlaylist(String id) {
    playlists.removeWhere((pl) => pl.id == id);
    _savePlaylists();
  }

  bool inPlaylist(String pid, String tid) => playlistById(pid)?.trackIds.contains(tid) ?? false;
  
  void togglePlaylistTrack(String pid, String tid) {
    final pl = playlistById(pid);
    if (pl == null) return;
    if (!pl.trackIds.remove(tid)) pl.trackIds.add(tid);
    _savePlaylists();
  }

  void addToPlaylist(String pid, String tid) {
    final pl = playlistById(pid);
    if (pl == null || pl.trackIds.contains(tid)) return;
    pl.trackIds.add(tid);
    _savePlaylists();
  }

  void removeFromPlaylist(String pid, String tid) {
    final pl = playlistById(pid);
    if (pl == null) return;
    pl.trackIds.remove(tid);
    _savePlaylists();
  }

  void movePlaylistTrack(String pid, int from, int to) {
    final pl = playlistById(pid);
    if (pl == null || from < 0 || from >= pl.trackIds.length) return;
    final id = pl.trackIds.removeAt(from);
    pl.trackIds.insert(to.clamp(0, pl.trackIds.length), id);
    _savePlaylists();
  }

  void applyEdits(TrackItem t) {
    final e = _edits[t.id];
    if (e is Map) {
      t.title = (e['title'] as String?) ?? t.title;
      t.artist = (e['artist'] as String?) ?? t.artist;
      t.artStyle = (e['style'] as String?) ?? t.artStyle;
    }
  }

  void saveEdit(TrackItem t) {
    _edits[t.id] = {'title': t.title, 'artist': t.artist, 'style': t.artStyle};
    _prefs?.setString('track_edits', jsonEncode(_edits));
    notifyListeners();
  }
}

class Playlist {
  final String id;
  String name;
  String? cover;
  final List<String> trackIds;

  Playlist({
    required this.id,
    required this.name,
    this.cover,
    List<String>? trackIds,
  }) : trackIds = trackIds ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'cover': cover,
        'tracks': trackIds,
      };

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: j['id'] as String,
        name: j['name'] as String,
        cover: j['cover'] as String?,
        trackIds: List<String>.from(j['tracks'] as List? ?? const []),
      );
}

class TrackItem {
  final String id;
  String title;
  String artist;
  final String album;
  final int durationSeconds;
  final List<Color> artColors;
  String artStyle;
  final String source;
  final String? filePath;

  TrackItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    required this.artColors,
    required this.source,
    this.artStyle = 'vinyl_record',
    this.filePath,
  });

  Uri get playbackUri {
    final fp = filePath;
    if (fp != null && fp.isNotEmpty) {
      try {
        if (File(fp).existsSync()) return Uri.file(fp);
      } catch (_) {}
    }
    return source.startsWith('content://') ? Uri.parse(source) : Uri.file(source);
  }

  MediaItem toMediaItem() {
    return MediaItem(
      id: id,
      title: title,
      artist: artist,
      album: album,
      duration: durationSeconds > 0 ? Duration(seconds: durationSeconds) : null,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Audio handler (Fixed Pitch via Native ExoPlayer binding)
// ─────────────────────────────────────────────────────────────────────────────

class MyAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player = AudioPlayer(
    handleInterruptions: true,
    androidApplyAudioAttributes: true,
    handleAudioSessionActivation: true,
  );
  final Random _rng = Random();

  List<TrackItem> tracks = [];
  int _index = 0;
  int _loadSeq = 0;
  String? _loadedId;
  bool _shuffle = false;
  AudioServiceRepeatMode _repeat = AudioServiceRepeatMode.none;
  final List<int> _history = [];

  final ValueNotifier<int> currentIndex = ValueNotifier<int>(0);
  final ValueNotifier<int> libraryRevision = ValueNotifier<int>(0);

  MyAudioHandler() {
    _init();
  }

  int get index => _index;
  TrackItem? get currentTrack => (_index >= 0 && _index < tracks.length) ? tracks[_index] : null;
  TrackItem? trackById(String id) {
    for (final t in tracks) { if (t.id == id) return t; }
    return null;
  }

  Future<void> _init() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {}

    try {
      // Required to keep SonicAudioProcessor active on ExoPlayer
      await player.setSkipSilenceEnabled(false);
    } catch (_) {}

    // Suppress all background playback errors from spamming the UI
    player.playbackEventStream.map(_transformEvent).listen(
      playbackState.add,
      onError: (Object _, StackTrace __) {}, 
    );

    player.processingStateStream.listen((state) {
      if (state == ProcessingState.ready) {
        _applySpeedAndPitch();
      } else if (state == ProcessingState.completed) {
        _onCompleted();
      }
    });

    player.playingStream.listen((isPlaying) {
      if (isPlaying) _applySpeedAndPitch();
    });

    player.durationStream.listen((d) {
      final item = mediaItem.value;
      if (d != null && item != null && d != item.duration) {
        mediaItem.add(item.copyWith(duration: d));
      }
    });
  }

  Future<void> _applySpeedAndPitch() async {
    final targetSpeed = appState.speed.clamp(0.5, 2.0);
    final targetPitch = appState.pitch.clamp(0.5, 2.0);
    try {
      if ((player.speed - targetSpeed).abs() > 0.005) {
        await player.setSpeed(targetSpeed);
      }
    } catch (_) {}
    try {
      // ExoPlayer natively supports pitch changes without rebuilding the pipeline
      // when set sequentially with speed.
      await player.setPitch(targetPitch);
    } catch (_) {}
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[player.processingState]!,
      playing: player.playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: _index,
      shuffleMode: _shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      repeatMode: _repeat,
    );
  }

  void _publishQueue() {
    queue.add(tracks.map((t) => t.toMediaItem()).toList());
    libraryRevision.value++;
  }

  Future<void> setTracks(List<TrackItem> list) async {
    final currentId = currentTrack?.id;
    tracks = list;
    _publishQueue();
    if (list.isEmpty) return;
    final keep = currentId == null ? -1 : list.indexWhere((t) => t.id == currentId);
    if (keep >= 0) {
      _index = keep;
      currentIndex.value = keep;
      return;
    }
    await _load(0, play: false);
  }

  Future<void> addTracks(List<TrackItem> items, {bool playFirst = false}) async {
    final wasEmpty = tracks.isEmpty;
    tracks = [...items, ...tracks];
    if (!wasEmpty) {
      _index += items.length;
      currentIndex.value = _index;
    }
    _publishQueue();
    if (wasEmpty || playFirst) await _load(0, play: true);
  }

  Future<void> deleteTrackFromLibrary(TrackItem t) async {
    final removeIdx = tracks.indexWhere((x) => x.id == t.id);
    final wasCurrent = currentTrack?.id == t.id;

    appState.markDeleted(t);

    final fp = t.filePath ?? (t.source.startsWith('/') ? t.source : null);
    if (fp != null && fp.isNotEmpty) {
      try {
        final f = File(fp);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }

    if (removeIdx >= 0) {
      final wasPlaying = player.playing;
      tracks.removeAt(removeIdx);
      if (tracks.isEmpty) {
        _index = 0;
        _loadedId = null;
        currentIndex.value = 0;
        await player.stop();
        mediaItem.add(null);
      } else if (wasCurrent) {
        if (_index >= tracks.length) _index = 0;
        currentIndex.value = _index;
        await _load(_index, play: wasPlaying);
      } else {
        if (removeIdx < _index) {
          _index = max(0, _index - 1);
          currentIndex.value = _index;
        }
      }
      _publishQueue();
    }
  }

  void moveTrack(int oldIndex, int newIndex) {
    final item = tracks.removeAt(oldIndex);
    tracks.insert(newIndex, item);
    if (_index == oldIndex) {
      _index = newIndex;
    } else if (oldIndex < _index && newIndex >= _index) {
      _index--;
    } else if (oldIndex > _index && newIndex <= _index) {
      _index++;
    }
    currentIndex.value = _index;
    _publishQueue();
  }

  void refreshMediaItem() {
    final t = currentTrack;
    if (t != null) {
      mediaItem.add(t.toMediaItem().copyWith(duration: player.duration));
    }
    _publishQueue();
  }

  Future<void> _load(int i, {bool play = true}) async {
    if (i < 0 || i >= tracks.length) return;
    final seq = ++_loadSeq;
    _index = i;
    currentIndex.value = i;
    final t = tracks[i];
    mediaItem.add(t.toMediaItem());
    try {
      try {
        await player.setAudioSource(AudioSource.uri(t.playbackUri));
      } catch (_) {
        final fallbackUri = t.source.startsWith('content://')
            ? Uri.parse(t.source)
            : Uri.file(t.source);
        await player.setAudioSource(AudioSource.uri(fallbackUri));
      }
      if (seq != _loadSeq) return;
      _loadedId = t.id;
      await _applySpeedAndPitch();
      if (play) player.play();
    } catch (_) {
      if (seq != _loadSeq) return;
      _loadedId = null;
    }
  }

  Future<void> playIndex(int i) async {
    if (i < 0 || i >= tracks.length) return;
    if (i == _index && _loadedId == tracks[i].id && player.processingState != ProcessingState.idle) {
      await _applySpeedAndPitch();
      player.play();
      return;
    }
    await _load(i, play: true);
  }

  Future<void> playTrackById(String id) async {
    final idx = tracks.indexWhere((t) => t.id == id);
    if (idx >= 0) await playIndex(idx);
  }

  int? _nextIndex({required bool auto}) {
    if (tracks.isEmpty) return null;
    if (_shuffle && tracks.length > 1) {
      int n;
      do { n = _rng.nextInt(tracks.length); } while (n == _index);
      return n;
    }
    final n = _index + 1;
    if (n < tracks.length) return n;
    if (_repeat == AudioServiceRepeatMode.all || !auto) return 0;
    return null;
  }

  Future<void> _onCompleted() async {
    if (_repeat == AudioServiceRepeatMode.one) {
      await player.seek(Duration.zero);
      player.play();
      return;
    }
    final n = _nextIndex(auto: true);
    if (n == null) {
      await _load(0, play: false);
    } else {
      _history.add(_index);
      await _load(n, play: true);
    }
  }

  @override
  Future<void> play() async {
    if (tracks.isEmpty) return;
    if (_loadedId == null) {
      await _load(_index, play: true);
    } else {
      await _applySpeedAndPitch();
      player.play();
    }
  }

  @override
  Future<void> pause() async {
    await player.pause();
  }

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() async {
    final n = _nextIndex(auto: false);
    if (n == null) return;
    _history.add(_index);
    if (_history.length > 50) _history.removeAt(0);
    await _load(n, play: true);
  }

  @override
  Future<void> skipToPrevious() async {
    if (tracks.isEmpty) return;
    if (player.position.inSeconds > 3) {
      await player.seek(Duration.zero);
      return;
    }
    int prev;
    if (_shuffle && _history.isNotEmpty) {
      prev = _history.removeLast();
    } else {
      prev = (_index - 1 + tracks.length) % tracks.length;
    }
    await _load(prev, play: true);
  }

  @override
  Future<void> skipToQueueItem(int i) => playIndex(i);

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    if (appState.stopOnTaskClear) await stop();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _shuffle = shuffleMode == AudioServiceShuffleMode.all;
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _repeat = repeatMode;
    await player.setLoopMode(
      repeatMode == AudioServiceRepeatMode.one ? LoopMode.one : LoopMode.off,
    );
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
  }

  @override
  Future<void> setSpeed(double speed) async {
    final clamped = speed.clamp(0.5, 2.0);
    try { await player.setSpeed(clamped); } catch (_) {}
    playbackState.add(playbackState.value.copyWith(speed: clamped));
  }

  Future<void> setPitch(double pitch) async {
    final clamped = pitch.clamp(0.5, 2.0);
    try { await player.setPitch(clamped); } catch (_) {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Library scanning / importing
// ─────────────────────────────────────────────────────────────────────────────

Future<bool> ensureMediaPermissions() async {
  var status = await Permission.audio.request();
  if (!status.isGranted) status = await Permission.storage.request();
  await Permission.notification.request();
  return status.isGranted;
}

Future<void> scanDeviceAudio() async {
  if (!Platform.isAndroid || scanning.value) return;
  scanning.value = true;
  try {
    final savedDownloads = await loadSavedDownloads();
    final granted = await ensureMediaPermissions();
    if (!granted) {
      if (savedDownloads.isNotEmpty) {
        await audioHandler.setTracks(savedDownloads);
      }
      return;
    }
    final raw = await _mediaChannel.invokeMethod('scanDeviceAudio') as List? ?? const [];
    final scanned = <TrackItem>[];
    for (var i = 0; i < raw.length; i++) {
      final m = Map<String, dynamic>.from(raw[i] as Map);
      final uri = (m['uri'] ?? '').toString();
      final path = (m['filePath'] ?? '').toString();
      final source = uri.isNotEmpty ? uri : path;
      if (source.isEmpty) continue;
      final id = 'ms_${m['id']}';
      if (appState.isDeleted(id, path.isEmpty ? source : path)) continue;
      final title = cleanText(m['title'], 'Unknown Track');
      if (title.toLowerCase().contains('306 bobby')) continue;
      final t = TrackItem(
        id: id,
        title: title,
        artist: cleanText(m['artist'], 'Unknown Artist'),
        album: cleanText(m['album'], 'Local Album'),
        durationSeconds: (m['durationSeconds'] as num?)?.toInt() ?? 0,
        artColors: kArtPalettes[i % kArtPalettes.length].colors,
        artStyle: kArtStyles[i % kArtStyles.length],
        source: source,
        filePath: path.isEmpty ? null : path,
      );
      appState.applyEdits(t);
      scanned.add(t);
    }
    final imported = audioHandler.tracks
        .where((t) => t.id.startsWith('local_') && !appState.isDeleted(t.id, t.filePath ?? t.source))
        .toList();
    await audioHandler.setTracks([...savedDownloads, ...imported, ...scanned]);
  } catch (_) {
  } finally {
    scanning.value = false;
  }
}

Future<void> pickLocalFiles() async {
  final result = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: true);
  if (result == null) return;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final added = <TrackItem>[];
  for (var i = 0; i < result.files.length; i++) {
    final path = result.files[i].path;
    if (path == null) continue;
    final id = 'local_${stamp}_$i';
    appState.unmarkDeleted(id, path);
    final t = TrackItem(
      id: id,
      title: p.basenameWithoutExtension(path),
      artist: 'Unknown Artist',
      album: 'Local Files',
      durationSeconds: 0,
      artColors: kArtPalettes[i % kArtPalettes.length].colors,
      artStyle: kArtStyles[i % kArtStyles.length],
      source: path,
      filePath: path,
    );
    added.add(t);
  }
  if (added.isNotEmpty) await audioHandler.addTracks(added, playFirst: true);
}

Future<int> quickImportPhoneDownloadsFolder() async {
  int count = 0;
  try {
    await ensureMediaPermissions();
    final existingPaths = audioHandler.tracks.map((t) => t.filePath ?? t.source).toSet();
    final found = <TrackItem>[];
    final candidateDirs = [
      Directory('/storage/emulated/0/Download'),
      Directory('/storage/emulated/0/Music'),
    ];

    for (final d in candidateDirs) {
      if (!d.existsSync()) continue;
      for (final entity in d.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final ext = p.extension(entity.path).toLowerCase();
        if (!const ['.mp3', '.m4a', '.flac', '.wav', '.ogg', '.aac'].contains(ext)) continue;
        if (existingPaths.contains(entity.path)) continue;
        
        final id = 'local_${entity.path.hashCode}';
        if (appState.isDeleted(id, entity.path)) continue;
        final base = p.basenameWithoutExtension(entity.path);
        
        final t = TrackItem(
          id: id,
          title: base,
          artist: 'Local File',
          album: 'Phone Downloads',
          durationSeconds: 0,
          artColors: kArtPalettes[found.length % kArtPalettes.length].colors,
          artStyle: kArtStyles[found.length % kArtStyles.length],
          source: entity.path,
          filePath: entity.path,
        );
        appState.applyEdits(t);
        found.add(t);
        existingPaths.add(entity.path);
        count++;
      }
    }
    if (found.isNotEmpty) {
      await audioHandler.addTracks(found, playFirst: false);
    }
  } catch (_) {}
  return count;
}

// ─────────────────────────────────────────────────────────────────────────────
// App UI (Material 3 Expressive Core)
// ─────────────────────────────────────────────────────────────────────────────

class AlexLmpApp extends StatelessWidget {
  const AlexLmpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final colorScheme = ColorScheme.fromSeed(
          seedColor: appState.seedColor,
          brightness: Brightness.dark,
        );
        
        // Pure AMOLED vs Material Dark
        final bg = appState.useAmoled ? Colors.black : colorScheme.surface;
        final surface = appState.useAmoled ? const Color(0xFF0F0F0F) : colorScheme.surfaceContainer;

        return MaterialApp(
          title: 'AlexLMP',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: colorScheme.copyWith(
              surface: bg,
              surfaceContainer: surface,
            ),
            scaffoldBackgroundColor: bg,
            navigationBarTheme: NavigationBarThemeData(
              backgroundColor: surface,
              indicatorColor: colorScheme.primaryContainer,
              labelTextStyle: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return TextStyle(fontWeight: FontWeight.w700, color: colorScheme.onSurface);
                }
                return TextStyle(fontWeight: FontWeight.w500, color: colorScheme.onSurfaceVariant);
              }),
            ),
            sliderTheme: SliderThemeData(
              activeTrackColor: colorScheme.primary,
              inactiveTrackColor: colorScheme.surfaceContainerHighest,
              thumbColor: colorScheme.primary,
              overlayColor: colorScheme.primary.withOpacity(0.12),
            ),
            splashFactory: InkSparkle.splashFactory,
            fontFamily: 'Roboto',
          ),
          home: const MainScaffold(),
        );
      },
    );
  }
}

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    appNotice.addListener(_onNotice);
    scanDeviceAudio();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onNotice());
  }

  @override
  void dispose() {
    appNotice.removeListener(_onNotice);
    super.dispose();
  }

  void _onNotice() {
    final msg = appNotice.value;
    if (msg == null || !mounted) return;
    appNotice.value = null;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 110),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        audioHandler.currentIndex,
        audioHandler.libraryRevision,
      ]),
      builder: (context, _) {
        final track = audioHandler.currentTrack;
        final hasMiniPlayer = track != null;

        return Scaffold(
          body: Stack(
            children: [
              IndexedStack(
                index: _currentIndex,
                children: const [
                  HomeTab(),
                  DiscoverDownloadTab(),
                  LibraryTab(),
                ],
              ),
              if (hasMiniPlayer)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 84, // Above NavigationBar
                  child: Reveal(dy: 40, child: MiniPlayer(track: track)),
                ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (i) => setState(() => _currentIndex = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.explore_outlined),
                selectedIcon: Icon(Icons.explore_rounded),
                label: 'Discover',
              ),
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music_rounded),
                label: 'Library',
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Home Tab (M3)
// ─────────────────────────────────────────────────────────────────────────────

class HomeTab extends StatelessWidget {
  const HomeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final tracks = audioHandler.tracks;
    final colorScheme = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          title: const Text('Good Morning', style: TextStyle(fontWeight: FontWeight.w800)),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings_rounded),
              onPressed: () => showSettingsSheet(context),
            ),
            const SizedBox(width: 8),
          ],
        ),
        if (tracks.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.music_note_rounded, size: 72, color: colorScheme.primary),
                  const SizedBox(height: 16),
                  const Text(
                    'No songs found yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Go to the Discover tab to download music, or scan your phone in Settings.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Quick Picks',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.8,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final t = tracks[i];
                  return Card(
                    elevation: 0,
                    color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => playAndOpen(context, i),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 56,
                            height: 56,
                            child: CustomAlbumArtwork(track: t),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              t.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  );
                },
                childCount: min(tracks.length, 6),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(
                'Recently Added',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final t = tracks.reversed.toList()[i];
                final realIndex = tracks.indexOf(t);
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: CustomAlbumArtwork(track: t),
                    ),
                  ),
                  title: Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    t.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.more_vert_rounded),
                    onPressed: () => showAddToPlaylistSheet(context, t),
                  ),
                  onTap: () => playAndOpen(context, realIndex),
                );
              },
              childCount: min(tracks.length, 20),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 180)),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Discover & Download Tab (M3)
// ─────────────────────────────────────────────────────────────────────────────

class DiscoverDownloadTab extends StatefulWidget {
  const DiscoverDownloadTab({super.key});
  @override
  State<DiscoverDownloadTab> createState() => _DiscoverDownloadTabState();
}

class _DiscoverDownloadTabState extends State<DiscoverDownloadTab> {
  int _mode = 0; // 0 = Search, 1 = Browser
  final _searchCtrl = TextEditingController();
  late final WebViewController _webCtrl;

  @override
  void initState() {
    super.initState();
    _webCtrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) {
            final url = req.url.toLowerCase();
            if (url.endsWith('.mp3') || url.endsWith('.m4a') || url.endsWith('.wav') || url.endsWith('.flac')) {
              _downloadFromUrl(req.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse('https://google.com'));
  }

  void _downloadFromUrl(String url) async {
    final ok = await _downloadBinaryStreamToLibrary(
      client: HttpClient()..connectionTimeout = const Duration(seconds: 15),
      downloadUrl: url,
      title: 'Browser Download',
      artist: 'Web File',
      ext: p.extension(Uri.parse(url).path),
    );
    if (ok) {
      appNotice.value = 'Downloaded file from browser!';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, icon: Icon(Icons.search_rounded), label: Text('Search')),
                ButtonSegment(value: 1, icon: Icon(Icons.public_rounded), label: Text('Browser')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ),
        ),
        Expanded(
          child: _mode == 0
              ? _buildSearchUI(colorScheme)
              : WebViewWidget(controller: _webCtrl),
        ),
      ],
    );
  }

  Widget _buildSearchUI(ColorScheme colorScheme) {
    return ListenableBuilder(
      listenable: Listenable.merge([downloadProgress, downloadStatus]),
      builder: (context, _) {
        final busy = downloadProgress.value != null;
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cloud_download_rounded, size: 64, color: colorScheme.primary),
              const SizedBox(height: 24),
              const Text(
                'Download Music',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Type a Song Name, or paste a Spotify, YouTube, or MP3 link to download directly to your library.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: 'e.g. The Weeknd - Timeless or https://...',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.content_paste_rounded),
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) _searchCtrl.text = data!.text!.trim();
                    },
                  ),
                  filled: true,
                  fillColor: colorScheme.surfaceContainer,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (v) => _startDownload(v),
              ),
              const SizedBox(height: 24),
              if (busy) ...[
                Text(
                  downloadStatus.value ?? 'Downloading...',
                  style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: downloadProgress.value,
                  borderRadius: BorderRadius.circular(8),
                  minHeight: 8,
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () {
                    _cancelCurrentDownload = true;
                    downloadProgress.value = null;
                    downloadStatus.value = null;
                  },
                  child: const Text('Cancel Download'),
                ),
              ] else
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  ),
                  onPressed: () => _startDownload(_searchCtrl.text),
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Download Track'),
                ),
            ],
          ),
        );
      },
    );
  }

  void _startDownload(String query) async {
    if (query.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    await downloadAudioIntoApp(inputUrlOrQuery: query);
    _searchCtrl.clear();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Library Tab (M3)
// ─────────────────────────────────────────────────────────────────────────────

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});
  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  int _filter = 0;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          title: const Text('Library', style: TextStyle(fontWeight: FontWeight.w800)),
          actions: [
            IconButton(
              icon: const Icon(Icons.folder_open_rounded),
              tooltip: 'Quick Grab from Phone /Download folder',
              onPressed: () async {
                final added = await quickImportPhoneDownloadsFolder();
                appNotice.value = added > 0 ? 'Imported $added tracks!' : 'No new files in Downloads.';
              },
            ),
            IconButton(
              icon: const Icon(Icons.wifi_tethering_rounded),
              tooltip: 'Start Wi-Fi Drop Server',
              onPressed: () async {
                await toggleWifiDropServer();
                if (wifiServerUrl.value != null) {
                  appNotice.value = 'Wi-Fi Drop active at ${wifiServerUrl.value}';
                }
              },
            ),
            const SizedBox(width: 8),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Songs')),
                ButtonSegment(value: 1, label: Text('Playlists')),
                ButtonSegment(value: 2, label: Text('Artists')),
              ],
              selected: {_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
          ),
        ),
        if (_filter == 0) _buildSongsList()
        else if (_filter == 1) _buildPlaylists()
        else _buildArtists(),
        const SliverToBoxAdapter(child: SizedBox(height: 180)),
      ],
    );
  }

  Widget _buildSongsList() {
    final tracks = audioHandler.tracks;
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) {
          final t = tracks[i];
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 48,
                height: 48,
                child: CustomAlbumArtwork(track: t),
              ),
            ),
            title: Text(
              t.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              t.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.more_vert_rounded),
              onPressed: () => showAddToPlaylistSheet(context, t),
            ),
            onTap: () => playAndOpen(context, i),
          );
        },
        childCount: tracks.length,
      ),
    );
  }

  Widget _buildPlaylists() {
    final pls = appState.playlists;
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) {
          if (i == 0) {
            return ListTile(
              leading: const CircleAvatar(child: Icon(Icons.add_rounded)),
              title: const Text('Create New Playlist', style: TextStyle(fontWeight: FontWeight.bold)),
              onTap: () => showCreateOrEditPlaylistDialog(context),
            );
          }
          final pl = pls[i - 1];
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: PlaylistCoverThumbnail(playlist: pl, size: 56),
            title: Text(pl.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('${pl.trackIds.length} songs'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlistId: pl.id)),
            ),
          );
        },
        childCount: pls.length + 1,
      ),
    );
  }

  Widget _buildArtists() {
    final byArtist = <String, List<TrackItem>>{};
    for (final t in audioHandler.tracks) {
      byArtist.putIfAbsent(t.artist, () => <TrackItem>[]).add(t);
    }
    final entries = byArtist.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) {
          final e = entries[i];
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: CircleAvatar(
              radius: 28,
              child: ClipOval(
                child: SizedBox(
                  width: 56, height: 56,
                  child: CustomAlbumArtwork(track: e.value.first),
                ),
              ),
            ),
            title: Text(e.key, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('${e.value.length} songs'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showArtistTracksSheet(context, e.key, e.value),
          );
        },
        childCount: entries.length,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Now Playing Screen (M3)
// ─────────────────────────────────────────────────────────────────────────────

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        appState,
        audioHandler.currentIndex,
      ]),
      builder: (context, _) {
        final track = audioHandler.currentTrack;
        if (track == null) return const Scaffold();

        final colorScheme = Theme.of(context).colorScheme;

        return Scaffold(
          body: Stack(
            children: [
              // M3 gradient wash based on track colors
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      track.artColors.first.withOpacity(0.4),
                      Theme.of(context).scaffoldBackgroundColor,
                    ],
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
                            onPressed: () => Navigator.pop(context),
                          ),
                          Column(
                            children: [
                              Text(
                                'NOW PLAYING',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.5,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              Text(
                                track.album,
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.more_vert_rounded),
                            onPressed: () => showAddToPlaylistSheet(context, track),
                          ),
                        ],
                      ),
                      Expanded(
                        child: Center(
                          child: Hero(
                            tag: 'now_playing_art',
                            child: Material(
                              elevation: 24,
                              shadowColor: track.artColors.first.withOpacity(0.5),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(appState.vinylSpinMode ? 999 : 32),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: AspectRatio(
                                aspectRatio: 1.0,
                                child: Interactive3DArtwork(
                                  track: track,
                                  playing: audioHandler.player.playing,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                                ),
                                Text(
                                  track.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 18, color: colorScheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              appState.isLiked(track.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                              color: appState.isLiked(track.id) ? colorScheme.primary : null,
                            ),
                            iconSize: 32,
                            onPressed: () => appState.toggleLike(track.id),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      WavySeekBar(fallbackSeconds: track.durationSeconds, active: colorScheme.primary, playing: audioHandler.player.playing),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            iconSize: 48,
                            icon: const Icon(Icons.skip_previous_rounded),
                            onPressed: audioHandler.skipToPrevious,
                          ),
                          FloatingActionButton.large(
                            elevation: 0,
                            backgroundColor: colorScheme.primaryContainer,
                            foregroundColor: colorScheme.onPrimaryContainer,
                            onPressed: () => audioHandler.player.playing ? audioHandler.pause() : audioHandler.play(),
                            child: Icon(audioHandler.player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 48),
                          ),
                          IconButton(
                            iconSize: 48,
                            icon: const Icon(Icons.skip_next_rounded),
                            onPressed: audioHandler.skipToNext,
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.tune_rounded),
                            color: (appState.speed != 1.0 || appState.pitch != 1.0) ? colorScheme.primary : colorScheme.onSurfaceVariant,
                            onPressed: () => showPlaybackSheet(context),
                          ),
                          IconButton(
                            icon: const Icon(Icons.queue_music_rounded),
                            color: colorScheme.onSurfaceVariant,
                            onPressed: () => showQueueSheet(context),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_rounded),
                            color: colorScheme.onSurfaceVariant,
                            onPressed: () => showEditTrackDialog(context, track),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
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

// ─────────────────────────────────────────────────────────────────────────────
// Audio Downloader (YouTube Explode & Direct HTTP)
// ─────────────────────────────────────────────────────────────────────────────

Future<bool> _downloadBinaryStreamToLibrary({
  required HttpClient client,
  required String downloadUrl,
  required String title,
  required String artist,
  required String ext,
}) async {
  try {
    downloadStatus.value = 'Downloading "$title"…';
    final uri = Uri.parse(downloadUrl);
    final req = await client.getUrl(uri);
    req.headers.set('User-Agent', 'Mozilla/5.0');
    final resp = await req.close().timeout(const Duration(seconds: 15));

    if (resp.statusCode < 200 || resp.statusCode >= 400) {
      return false;
    }

    var safeName = '$artist - $title'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safeName.isEmpty) {
      safeName = 'Track_${DateTime.now().millisecondsSinceEpoch}';
    }

    final dir = await _getMusicDownloadsDir();
    final savePath = p.join(dir.path, '$safeName$ext');
    final outFile = File(savePath);
    final sink = outFile.openWrite();

    final totalBytes = resp.contentLength;
    int received = 0;

    await for (final chunk in resp.timeout(const Duration(seconds: 20))) {
      if (_cancelCurrentDownload) {
        await sink.close();
        try { outFile.deleteSync(); } catch (_) {}
        return false;
      }
      sink.add(chunk);
      received += chunk.length;
      if (totalBytes > 0) {
        downloadProgress.value = (received / totalBytes).clamp(0.05, 0.99);
      }
    }
    await sink.flush();
    await sink.close();

    if (received < 1024) {
      try { outFile.deleteSync(); } catch (_) {}
      return false;
    }

    final newId = 'dl_${savePath.hashCode}';
    appState.unmarkDeleted(newId, savePath);

    final newTrack = TrackItem(
      id: newId,
      title: title,
      artist: artist,
      album: 'AlexLMP Downloads',
      durationSeconds: 0,
      artColors: kArtPalettes[audioHandler.tracks.length % kArtPalettes.length].colors,
      artStyle: kArtStyles[audioHandler.tracks.length % kArtStyles.length],
      source: savePath,
      filePath: savePath,
    );

    await audioHandler.addTracks([newTrack], playFirst: true);
    appNotice.value = 'Downloaded "$title" into your library!';
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> downloadAudioIntoApp({
  required String inputUrlOrQuery,
  String? customTitle,
  String? customArtist,
}) async {
  final rawInput = inputUrlOrQuery.trim();
  if (rawInput.isEmpty) return false;

  _cancelCurrentDownload = false;

  // Direct File URL
  if (rawInput.startsWith('http') && 
     (rawInput.toLowerCase().endsWith('.mp3') || rawInput.toLowerCase().endsWith('.m4a') || rawInput.toLowerCase().endsWith('.wav'))) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      downloadProgress.value = 0.05;
      final uri = Uri.parse(rawInput);
      final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'Track';
      final decodedName = Uri.decodeComponent(p.basenameWithoutExtension(seg));
      String ext = p.extension(uri.path).toLowerCase();
      
      final ok = await _downloadBinaryStreamToLibrary(
        client: client,
        downloadUrl: rawInput,
        title: customTitle ?? decodedName,
        artist: customArtist ?? 'Direct Link',
        ext: ext,
      );
      return ok;
    } finally {
      client.close();
      downloadProgress.value = null;
      downloadStatus.value = null;
    }
  }

  // YouTube Explode Search/Extraction
  final yt = ytd.YoutubeExplode();
  try {
    downloadProgress.value = 0.1;
    ytd.Video? video;

    if (rawInput.startsWith('http') && rawInput.contains('youtu')) {
      downloadStatus.value = 'Parsing YouTube link…';
      video = await yt.videos.get(rawInput);
    } else {
      downloadStatus.value = 'Searching YouTube Music for "$rawInput"…';
      final results = await yt.search.search('$rawInput official audio');
      if (results.isNotEmpty) video = results.first;
    }

    if (video == null || _cancelCurrentDownload) {
      appNotice.value = 'Could not find a track for "$rawInput".';
      return false;
    }

    downloadStatus.value = 'Extracting audio stream…';
    final manifest = await yt.videos.streamsClient.getManifest(video.id);
    final audioStreams = manifest.audioOnly;
    if (audioStreams.isEmpty || _cancelCurrentDownload) return false;

    ytd.AudioStreamInfo? chosen;
    for (final s in audioStreams.sortByBitrate()) {
      if (s.container.name.toLowerCase().contains('mp4')) {
        chosen = s; break;
      }
    }
    chosen ??= audioStreams.withHighestBitrate();

    final finalTitle = (customTitle != null && customTitle.trim().isNotEmpty) ? customTitle.trim() : video.title.trim();
    final finalArtist = (customArtist != null && customArtist.trim().isNotEmpty) ? customArtist.trim() : video.author.replaceAll(' - Topic', '').trim();

    var safeName = '$finalArtist - $finalTitle'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safeName.isEmpty) safeName = 'Track_${DateTime.now().millisecondsSinceEpoch}';

    final dir = await _getMusicDownloadsDir();
    final savePath = p.join(dir.path, '$safeName.m4a');
    final outFile = File(savePath);
    final sink = outFile.openWrite();

    final totalBytes = chosen.size.totalBytes;
    int received = 0;

    downloadStatus.value = 'Downloading "$finalTitle"…';
    final byteStream = yt.videos.streamsClient.get(chosen);
    
    await for (final chunk in byteStream.timeout(const Duration(seconds: 15))) {
      if (_cancelCurrentDownload) {
        await sink.close();
        try { outFile.deleteSync(); } catch (_) {}
        return false;
      }
      sink.add(chunk);
      received += chunk.length;
      if (totalBytes > 0) {
        downloadProgress.value = (received / totalBytes).clamp(0.05, 0.99);
      }
    }
    await sink.flush();
    await sink.close();

    if (received < 1024) {
      try { outFile.deleteSync(); } catch (_) {}
      return false;
    }

    final newId = 'dl_${savePath.hashCode}';
    appState.unmarkDeleted(newId, savePath);

    final newTrack = TrackItem(
      id: newId,
      title: finalTitle,
      artist: finalArtist,
      album: 'AlexLMP Downloads',
      durationSeconds: video.duration?.inSeconds ?? 0,
      artColors: kArtPalettes[audioHandler.tracks.length % kArtPalettes.length].colors,
      artStyle: kArtStyles[audioHandler.tracks.length % kArtStyles.length],
      source: savePath,
      filePath: savePath,
    );

    await audioHandler.addTracks([newTrack], playFirst: true);
    appNotice.value = 'Downloaded "$finalTitle" into your library!';
    return true;
  } catch (e) {
    appNotice.value = 'Download error. Stream may be throttled.';
    return false;
  } finally {
    yt.close();
    downloadProgress.value = null;
    downloadStatus.value = null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// UI Components
// ─────────────────────────────────────────────────────────────────────────────

class Interactive3DArtwork extends StatefulWidget {
  final TrackItem track;
  final bool playing;

  const Interactive3DArtwork({super.key, required this.track, required this.playing});

  @override
  State<Interactive3DArtwork> createState() => _Interactive3DArtworkState();
}

class _Interactive3DArtworkState extends State<Interactive3DArtwork> with SingleTickerProviderStateMixin {
  Offset _tilt = Offset.zero;
  late final AnimationController _spinCtrl;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 12));
    if (widget.playing && appState.vinylSpinMode) _spinCtrl.repeat();
  }

  @override
  void didUpdateWidget(covariant Interactive3DArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && appState.vinylSpinMode && !_spinCtrl.isAnimating) {
      _spinCtrl.repeat();
    } else if (!widget.playing && _spinCtrl.isAnimating) {
      _spinCtrl.stop();
    }
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spinMode = appState.vinylSpinMode;
    return GestureDetector(
      onPanUpdate: (d) => setState(() {
        _tilt = Offset(
          ((d.localPosition.dy / context.size!.height) - 0.5) * -0.4,
          ((d.localPosition.dx / context.size!.width) - 0.5) * 0.4,
        );
      }),
      onPanEnd: (_) => setState(() => _tilt = Offset.zero),
      onPanCancel: () => setState(() => _tilt = Offset.zero),
      onDoubleTap: () {
        HapticFeedback.mediumImpact();
        appState.setVinylSpinMode(!spinMode);
      },
      child: TweenAnimationBuilder<Offset>(
        tween: Tween<Offset>(begin: Offset.zero, end: _tilt),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        builder: (context, t, child) {
          final matrix = Matrix4.identity()..setEntry(3, 2, 0.002)..rotateX(t.dx)..rotateY(t.dy);
          return Transform(
            alignment: Alignment.center,
            transform: matrix,
            child: AnimatedBuilder(
              animation: _spinCtrl,
              builder: (context, _) {
                if (!spinMode) return CustomAlbumArtwork(track: widget.track);
                return Transform.rotate(
                  angle: _spinCtrl.value * 2 * pi,
                  child: ClipOval(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CustomAlbumArtwork(track: widget.track),
                        Container(
                          width: 64, height: 64,
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24, width: 2),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class Reveal extends StatelessWidget {
  final int delayMs;
  final double dy;
  final Widget child;

  const Reveal({super.key, this.delayMs = 0, this.dy = 22, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: 400 + delayMs),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0).toDouble(),
        child: Transform.translate(offset: Offset(0, (1 - t) * dy), child: child),
      ),
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Settings & Playlists Dialogs (M3)
// ─────────────────────────────────────────────────────────────────────────────

void showSettingsSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final colorScheme = Theme.of(context).colorScheme;
        return DraggableScrollableSheet(
          initialChildSize: 0.8,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, scrollCtrl) => ListView(
            controller: scrollCtrl,
            padding: const EdgeInsets.all(24),
            children: [
              Text('Settings', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              Text('Material You Theme Color', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: colorScheme.primary)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  Colors.blue, Colors.red, Colors.green, Colors.purple, Colors.orange, Colors.teal, const Color(0xFFD0BCFF)
                ].map((c) => InkWell(
                  onTap: () => appState.setSeedColor(c),
                  child: CircleAvatar(
                    backgroundColor: c,
                    radius: 20,
                    child: appState.seedColor.value == c.value ? const Icon(Icons.check, color: Colors.white) : null,
                  ),
                )).toList(),
              ),
              const SizedBox(height: 24),
              SwitchListTile(
                title: const Text('Pure AMOLED Black Background'),
                value: appState.useAmoled,
                onChanged: appState.setAmoled,
              ),
              SwitchListTile(
                title: const Text('Spinning Vinyl Mode'),
                value: appState.vinylSpinMode,
                onChanged: appState.setVinylSpinMode,
              ),
              const Divider(height: 32),
              Text('Download & Search Settings', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: colorScheme.primary)),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'YouTube Music', label: Text('YouTube Music')),
                  ButtonSegment(value: 'Jamendo', label: Text('Jamendo (Free)')),
                ],
                selected: {appState.searchProvider},
                onSelectionChanged: (s) => appState.setSearchProvider(s.first),
              ),
              const SizedBox(height: 24),
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.pop(ctx);
                  scanDeviceAudio();
                },
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Rescan Device Storage'),
              ),
            ],
          ),
        );
      },
    ),
  );
}

void showPlaybackSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Speed & Pitch', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    TextButton(
                      onPressed: () {
                        appState.setSpeed(1.0);
                        appState.setPitch(1.0);
                        audioHandler.setSpeed(1.0);
                        audioHandler.setPitch(1.0);
                      },
                      child: const Text('Reset'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: const Text('Link Speed & Pitch (Vinyl Mode)'),
                  value: appState.linkSpeedAndPitch,
                  onChanged: (v) {
                    appState.setLinkSpeedAndPitch(v);
                    if (v) {
                      appState.setSpeed(appState.pitch);
                      audioHandler.setSpeed(appState.pitch);
                    }
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.speed_rounded),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Slider(
                        value: appState.speed,
                        min: 0.5, max: 2.0, divisions: 30,
                        label: '${appState.speed.toStringAsFixed(2)}x',
                        onChanged: (v) {
                          appState.setSpeed(v);
                          audioHandler.setSpeed(v);
                          if (appState.linkSpeedAndPitch) {
                            appState.setPitch(v);
                            audioHandler.setPitch(v);
                          }
                        },
                      ),
                    ),
                    Text('${appState.speed.toStringAsFixed(2)}x'),
                  ],
                ),
                Row(
                  children: [
                    const Icon(Icons.graphic_eq_rounded),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Slider(
                        value: appState.pitch,
                        min: 0.5, max: 2.0, divisions: 60,
                        label: '${appState.pitch.toStringAsFixed(2)}x',
                        onChanged: (v) {
                          appState.setPitch(v);
                          audioHandler.setPitch(v);
                          if (appState.linkSpeedAndPitch) {
                            appState.setSpeed(v);
                            audioHandler.setSpeed(v);
                          }
                        },
                      ),
                    ),
                    Text('${appState.pitch.toStringAsFixed(2)}x'),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

void showQueueSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.7,
      child: ListenableBuilder(
        listenable: Listenable.merge([audioHandler.currentIndex, audioHandler.libraryRevision]),
        builder: (ctx, _) {
          final tracks = audioHandler.tracks;
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Up Next', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: tracks.length,
                  onReorder: (oldIndex, newIndex) {
                    if (newIndex > oldIndex) newIndex -= 1;
                    audioHandler.moveTrack(oldIndex, newIndex);
                  },
                  itemBuilder: (_, i) {
                    final t = tracks[i];
                    final active = i == audioHandler.index;
                    return ListTile(
                      key: ValueKey(t.id),
                      leading: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: t)),
                      title: Text(t.title, style: TextStyle(color: active ? Theme.of(context).colorScheme.primary : null, fontWeight: active ? FontWeight.bold : null)),
                      subtitle: Text(t.artist),
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: const Icon(Icons.drag_handle_rounded),
                      ),
                      onTap: () => audioHandler.playIndex(i),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

void showCreateOrEditPlaylistDialog(BuildContext context, {Playlist? existing, String? initialTrackId}) {
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  String? coverPath = existing?.cover;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: Text(existing == null ? 'Create Playlist' : 'Edit Playlist'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () async {
                final picked = await pickAndSaveGalleryImage();
                if (picked != null) setDialogState(() => coverPath = picked);
              },
              child: Container(
                width: 120, height: 120,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: (coverPath != null && File(coverPath!).existsSync())
                    ? ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.file(File(coverPath!), fit: BoxFit.cover))
                    : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.add_photo_alternate_rounded, size: 32), Text('Cover')]),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameCtrl,
              autofocus: existing == null,
              decoration: const InputDecoration(labelText: 'Playlist Name', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (existing == null) {
                final created = appState.createPlaylist(name.isEmpty ? 'My Playlist' : name, cover: coverPath);
                if (initialTrackId != null) appState.addToPlaylist(created.id, initialTrackId);
              } else {
                appState.setPlaylistInfo(existing.id, name.isEmpty ? existing.name : name, coverPath);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

void showAddToPlaylistSheet(BuildContext context, TrackItem track) {
  showModalBottomSheet(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final pls = appState.playlists;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: track)),
                title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: FilledButton.tonalIcon(
                  onPressed: () => showCreateOrEditPlaylistDialog(context, initialTrackId: track.id),
                  icon: const Icon(Icons.add), label: const Text('New'),
                ),
              ),
              const Divider(),
              if (pls.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text('No playlists yet.'))
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: pls.length,
                    itemBuilder: (_, i) {
                      final pl = pls[i];
                      final added = appState.inPlaylist(pl.id, track.id);
                      return ListTile(
                        leading: PlaylistCoverThumbnail(playlist: pl, size: 48),
                        title: Text(pl.name),
                        subtitle: Text('${pl.trackIds.length} songs'),
                        trailing: Icon(added ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded, color: added ? Theme.of(context).colorScheme.primary : null),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          appState.togglePlaylistTrack(pl.id, track.id);
                        },
                      );
                    },
                  ),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent),
                title: const Text('Delete from Library', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await audioHandler.deleteTrackFromLibrary(track);
                  appNotice.value = 'Deleted "${track.title}"';
                },
              ),
            ],
          ),
        );
      },
    ),
  );
}

class PlaylistCoverThumbnail extends StatelessWidget {
  final Playlist playlist;
  final double size;
  const PlaylistCoverThumbnail({super.key, required this.playlist, this.size = 60});

  @override
  Widget build(BuildContext context) {
    final cover = playlist.cover;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      return ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(File(cover), width: size, height: size, fit: BoxFit.cover));
    }
    TrackItem? firstTrack;
    if (playlist.trackIds.isNotEmpty) firstTrack = audioHandler.trackById(playlist.trackIds.first);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: size, height: size,
        child: firstTrack != null ? CustomAlbumArtwork(track: firstTrack) : Container(color: Theme.of(context).colorScheme.primaryContainer, child: Icon(Icons.queue_music, color: Theme.of(context).colorScheme.onPrimaryContainer)),
      ),
    );
  }
}

class PlaylistDetailScreen extends StatelessWidget {
  final String playlistId;
  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appState, audioHandler.libraryRevision]),
      builder: (context, _) {
        final pl = appState.playlistById(playlistId);
        if (pl == null) return const Scaffold();
        final resolvedTracks = pl.trackIds.map((id) => audioHandler.trackById(id)).whereType<TrackItem>().toList();

        return Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverAppBar.large(
                title: Text(pl.name),
                flexibleSpace: FlexibleSpaceBar(
                  background: PlaylistCoverThumbnail(playlist: pl, size: double.infinity),
                ),
                actions: [
                  IconButton(icon: const Icon(Icons.edit), onPressed: () => showCreateOrEditPlaylistDialog(context, existing: pl)),
                  IconButton(icon: const Icon(Icons.delete), onPressed: () { appState.deletePlaylist(pl.id); Navigator.pop(context); }),
                ],
              ),
              if (resolvedTracks.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton.icon(
                      onPressed: () { audioHandler.playTrackById(resolvedTracks.first.id); openPlayer(context); },
                      icon: const Icon(Icons.play_arrow_rounded), label: const Text('Play Playlist'),
                    ),
                  ),
                ),
              SliverReorderableList(
                itemCount: resolvedTracks.length,
                onReorder: (o, n) { if (n > o) n -= 1; HapticFeedback.mediumImpact(); appState.movePlaylistTrack(pl.id, o, n); },
                itemBuilder: (context, i) {
                  final t = resolvedTracks[i];
                  return ReorderableDragStartListener(
                    key: ValueKey(t.id),
                    index: i,
                    child: ListTile(
                      leading: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: t)),
                      title: Text(t.title, maxLines: 1),
                      subtitle: Text(t.artist, maxLines: 1),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => appState.removeFromPlaylist(pl.id, t.id)),
                          const Icon(Icons.drag_handle),
                        ],
                      ),
                      onTap: () { audioHandler.playTrackById(t.id); openPlayer(context); },
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

void showArtistTracksSheet(BuildContext context, String artist, List<TrackItem> tracks) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.7,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(artist, style: Theme.of(context).textTheme.headlineSmall),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (_, i) {
                final t = tracks[i];
                return ListTile(
                  leading: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: t)),
                  title: Text(t.title, maxLines: 1),
                  subtitle: Text(t.album, maxLines: 1),
                  trailing: IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showAddToPlaylistSheet(context, t)),
                  onTap: () { Navigator.pop(ctx); playAndOpen(context, audioHandler.tracks.indexOf(t)); },
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

void showEditTrackDialog(BuildContext context, TrackItem track) {
  final titleCtrl = TextEditingController(text: track.title);
  final artistCtrl = TextEditingController(text: track.artist);
  String style = track.artStyle;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Edit Song Details'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'Song Title')),
            const SizedBox(height: 12),
            TextField(controller: artistCtrl, decoration: const InputDecoration(labelText: 'Artist Name')),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: kArtStyles.map((s) => ChoiceChip(
                label: Text(s.replaceAll('_', ' ')),
                selected: style == s,
                onSelected: (_) => setDialogState(() => style = s),
              )).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              track.title = titleCtrl.text.trim();
              track.artist = artistCtrl.text.trim();
              track.artStyle = style;
              appState.saveEdit(track);
              audioHandler.refreshMediaItem();
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Custom Artwork View
// ─────────────────────────────────────────────────────────────────────────────

final Map<String, Object?> _artCache = {};

Future<Uint8List?> loadArt(TrackItem t) {
  final existing = _artCache[t.id];
  if (existing is Future<Uint8List?>) return existing;
  final fut = _fetchArtFromChannel(t);
  _artCache[t.id] = fut;
  return fut;
}

Future<Uint8List?> _fetchArtFromChannel(TrackItem t) async {
  if (!Platform.isAndroid) return null;
  try {
    final res = await _mediaChannel.invokeMethod('getArt', {'uri': t.source, 'path': t.filePath ?? ''});
    if (res is Uint8List) return res;
    return null;
  } catch (_) { return null; }
}

class CustomAlbumArtwork extends StatelessWidget {
  final TrackItem track;
  const CustomAlbumArtwork({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final placeholder = CustomPaint(painter: _ArtworkSymbolPainter(style: track.artStyle, colors: track.artColors), child: const SizedBox.expand());
    return FutureBuilder<Uint8List?>(
      future: loadArt(track),
      builder: (context, snap) {
        final bytes = snap.data;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: (bytes != null && bytes.isNotEmpty)
              ? SizedBox.expand(key: ValueKey('art_${track.id}'), child: Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 512, gaplessPlayback: true, errorBuilder: (_, __, ___) => placeholder))
              : SizedBox.expand(key: ValueKey('ph_${track.id}'), child: placeholder),
        );
      },
    );
  }
}

class _ArtworkSymbolPainter extends CustomPainter {
  final String style;
  final List<Color> colors;

  const _ArtworkSymbolPainter({required this.style, required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors).createShader(rect));
    final center = Offset(size.width / 2, size.height / 2);
    final s = size.shortestSide;

    if (style == 'vinyl_record') {
      final groove = Paint()..color = Colors.white.withOpacity(0.15)..style = PaintingStyle.stroke..strokeWidth = max(1.0, s * 0.01);
      for (double r = s * 0.15; r < s * 0.45; r += s * 0.05) canvas.drawCircle(center, r, groove);
      canvas.drawCircle(center, s * 0.12, Paint()..color = const Color(0xFFFFB59C));
      canvas.drawCircle(center, s * 0.03, Paint()..color = Colors.black);
    } else if (style == 'sound_wave') {
      final wave = Paint()..color = const Color(0xFF8CD0F0)..strokeWidth = max(1.5, s * 0.015)..strokeCap = StrokeCap.round;
      const bars = [0.09, 0.17, 0.26, 0.34, 0.21, 0.13, 0.30, 0.20, 0.11];
      double x = size.width * 0.15;
      for (final h in bars) {
        canvas.drawLine(Offset(x, center.dy - s * h), Offset(x, center.dy + s * h), wave);
        x += size.width * 0.08;
      }
    } else if (style == 'music_note_grid') {
      final k = s / 90;
      final note = Paint()..color = Colors.white;
      final stem = Paint()..color = Colors.white..strokeWidth = max(1.5, 3 * k);
      canvas.drawCircle(Offset(center.dx - 15 * k, center.dy + 10 * k), 8 * k, note);
      canvas.drawCircle(Offset(center.dx + 15 * k, center.dy + 5 * k), 8 * k, note);
      canvas.drawLine(Offset(center.dx - 7 * k, center.dy + 10 * k), Offset(center.dx - 7 * k, center.dy - 15 * k), stem);
      canvas.drawLine(Offset(center.dx + 23 * k, center.dy + 5 * k), Offset(center.dx + 23 * k, center.dy - 20 * k), stem);
      canvas.drawLine(Offset(center.dx - 7 * k, center.dy - 15 * k), Offset(center.dx + 23 * k, center.dy - 20 * k), stem);
    } else if (style == 'equalizer_bars') {
      final bar = Paint()..strokeWidth = max(2.0, s * 0.045);
      const heights = [0.3, 0.6, 0.9, 0.5, 0.7, 0.4];
      double x = size.width * 0.2;
      for (int i = 0; i < heights.length; i++) {
        bar.color = i % 2 == 0 ? const Color(0xFF8CD0F0) : const Color(0xFFFFB59C);
        final h = size.height * 0.4 * heights[i];
        canvas.drawLine(Offset(x, center.dy + h), Offset(x, center.dy - h), bar);
        x += size.width * 0.12;
      }
    } else if (style == 'neon_vinyl') {
      final neon = Paint()..color = const Color(0xFFF09CE2)..style = PaintingStyle.stroke..strokeWidth = max(2.0, s * 0.02);
      canvas.drawCircle(center, s * 0.35, neon);
      canvas.drawCircle(center, s * 0.22, neon);
      canvas.drawCircle(center, s * 0.08, Paint()..color = const Color(0xFF9CF0C0));
    }
  }
  @override bool shouldRepaint(covariant _ArtworkSymbolPainter old) => old.style != style || old.colors != colors;
}

class WavySeekBar extends StatefulWidget {
  final int fallbackSeconds;
  final Color active;
  final bool playing;
  const WavySeekBar({super.key, required this.fallbackSeconds, required this.active, required this.playing});
  @override State<WavySeekBar> createState() => _WavySeekBarState();
}

class _WavySeekBarState extends State<WavySeekBar> with SingleTickerProviderStateMixin {
  double? _drag;
  late final AnimationController _waveCtrl;

  @override void initState() {
    super.initState();
    _waveCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  }
  @override void dispose() { _waveCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return TrackProgress(
      fallbackSeconds: widget.fallbackSeconds,
      builder: (context, pos, dur) {
        final maxMs = max(dur.inMilliseconds, 1).toDouble();
        final value = (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, maxMs).toDouble();
        final frac = (value / maxMs).clamp(0.0, 1.0);
        final shown = Duration(milliseconds: value.toInt());

        return Column(
          children: [
            SizedBox(
              height: 32,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (d) => setState(() => _drag = (d.localPosition.dx / w).clamp(0.0, 1.0) * maxMs),
                    onHorizontalDragUpdate: (d) => setState(() => _drag = (d.localPosition.dx / w).clamp(0.0, 1.0) * maxMs),
                    onHorizontalDragEnd: (_) {
                      if (_drag != null) {
                        audioHandler.seek(Duration(milliseconds: _drag!.toInt()));
                        setState(() => _drag = null);
                      }
                    },
                    onTapDown: (d) => audioHandler.seek(Duration(milliseconds: ((d.localPosition.dx / w).clamp(0.0, 1.0) * maxMs).toInt())),
                    child: AnimatedBuilder(
                      animation: _waveCtrl,
                      builder: (context, _) => CustomPaint(
                        painter: _WavyTrackPainter(
                          progress: frac, phase: _waveCtrl.value * 2 * pi,
                          activeColor: widget.active, inactiveColor: Colors.white24,
                          waveAmplitude: widget.playing ? 4.2 : 0.0,
                        ),
                        size: Size(w, 32),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(formatDuration(shown), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  Text(formatDuration(dur), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _WavyTrackPainter extends CustomPainter {
  final double progress, phase, waveAmplitude;
  final Color activeColor, inactiveColor;
  const _WavyTrackPainter({required this.progress, required this.phase, required this.activeColor, required this.inactiveColor, required this.waveAmplitude});

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final activeX = size.width * progress;

    if (activeX < size.width) {
      canvas.drawLine(Offset(activeX, cy), Offset(size.width, cy), Paint()..color = inactiveColor..strokeWidth = 4.5..strokeCap = StrokeCap.round);
    }

    final activePaint = Paint()..color = activeColor..style = PaintingStyle.stroke..strokeWidth = 4.5..strokeCap = StrokeCap.round;
    final path = Path()..moveTo(0, cy);
    for (double x = 0; x <= activeX; x += 2.0) {
      path.lineTo(x, cy + sin((x / 28.0) * 2 * pi - phase) * waveAmplitude);
    }
    canvas.drawPath(path, activePaint);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(activeX, cy), width: 10, height: 22), const Radius.circular(6)), Paint()..color = activeColor);
  }
  @override bool shouldRepaint(covariant _WavyTrackPainter old) => old.progress != progress || old.phase != phase || old.waveAmplitude != waveAmplitude || old.activeColor != activeColor;
}
