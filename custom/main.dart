import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
// Helpers & Hard Race-Timer (Guarantees ZERO Infinite Hangs!)
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

// ─────────────────────────────────────────────────────────────────────────────
// Built-In Wi-Fi PC/Phone Browser Drop Server
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
  body { background:#09090e; color:#fff; font-family:sans-serif; text-align:center; padding:40px 20px; }
  .box { max-width:480px; margin:0 auto; background:#15141e; border:2px dashed #d0bcff; border-radius:24px; padding:40px 20px; }
  h1 { color:#d0bcff; margin-top:0; }
  input[type=file] { margin:20px 0; color:#fff; }
  button { background:#d0bcff; color:#261059; border:none; padding:14px 28px; border-radius:24px; font-weight:bold; font-size:16px; cursor:pointer; }
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
// All-In-One Downloader: Native yt-dlp (#2) + 320kbps Studio CDNs (#1) + Fallbacks
// ─────────────────────────────────────────────────────────────────────────────

class ResolvedStream {
  final String url;
  final String title;
  final String artist;
  final String ext;
  final int totalBytes;
  const ResolvedStream({
    required this.url,
    required this.title,
    required this.artist,
    this.ext = '.m4a',
    this.totalBytes = 0,
  });
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

Future<String?> _resolveSpotifyQuery(HttpClient client, String spotifyUrl) async {
  return await withHardTimeout<String>(() async {
    try {
      final oembedUri = Uri.parse(
        'https://open.spotify.com/oembed?url=${Uri.encodeComponent(spotifyUrl)}',
      );
      final req = await client.getUrl(oembedUri);
      req.headers.set('User-Agent', 'Mozilla/5.0');
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map;
        final title = json['title']?.toString().trim();
        if (title != null && title.isNotEmpty) return title;
      }
    } catch (_) {}
    try {
      final req = await client.getUrl(Uri.parse(spotifyUrl));
      req.headers.set(
        'User-Agent',
        'Mozilla/5.0 (Linux; Android 15; Pixel 10) AppleWebKit/537.36',
      );
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final html = await resp.transform(utf8.decoder).join();
        final titleMatch = RegExp(
          r'<title>(.*?)</title>',
          caseSensitive: false,
        ).firstMatch(html);
        if (titleMatch != null) {
          var raw = titleMatch.group(1) ?? '';
          raw = raw
              .replaceAll('| Spotify', '')
              .replaceAll('- song and lyrics by', '-')
              .replaceAll('- song by', '-')
              .replaceAll('&#x27;', "'")
              .replaceAll('&amp;', '&')
              .replaceAll('&quot;', '"')
              .trim();
          if (raw.isNotEmpty && !raw.toLowerCase().startsWith('spotify')) {
            return raw;
          }
        }
      }
    } catch (_) {}
    return null;
  }(), 6);
}

Future<String?> _resolveYouTubeTitleViaOembed(
  HttpClient client,
  String videoId,
) async {
  return await withHardTimeout<String>(() async {
    try {
      final url =
          'https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$videoId&format=json';
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'Mozilla/5.0');
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map;
        final title = (data['title'] ?? '').toString().trim();
        final author = (data['author_name'] ?? '')
            .toString()
            .replaceAll(' - Topic', '')
            .trim();
        if (title.isNotEmpty) {
          if (title.contains('-')) return title;
          return author.isNotEmpty ? '$author - $title' : title;
        }
      }
    } catch (_) {}
    return null;
  }(), 5);
}

String? _extractYouTubeVideoId(String input) {
  final trimmed = input.trim();
  final reg = RegExp(
    r'(?:youtube\.com\/(?:[^\/]+\/.+\/|(?:v|e(?:mbed)?|shorts|live)\/|.*[?&]v=)|youtu\.be\/)([a-zA-Z0-9_-]{11})',
  );
  final m = reg.firstMatch(trimmed);
  if (m != null) return m.group(1);
  if (RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(trimmed)) return trimmed;
  return null;
}

/// ENGINE #1: 320kbps Direct Studio Music CDN (Zero YouTube throttling!)
Future<ResolvedStream?> _resolveViaStudioMusicCdn(
  HttpClient client,
  String query,
) async {
  final cleanedQuery = query
      .replaceAll(RegExp(r'\(official.*?\)', caseSensitive: false), '')
      .replaceAll(RegExp(r'\[official.*?\]', caseSensitive: false), '')
      .replaceAll(RegExp(r'official\s*(music\s*)?(video|audio|lyric.*)', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\(\)\[\]]'), ' ')
      .trim();

  const endpoints = [
    'https://saavn.dev/api/search/songs?query=',
    'https://jiosaavn-api-privatecvc2.vercel.app/search/songs?query=',
    'https://saavn.me/search/songs?query=',
  ];

  for (final base in endpoints) {
    if (_cancelCurrentDownload) return null;
    final hit = await withHardTimeout<ResolvedStream>(() async {
      try {
        final uri = Uri.parse('$base${Uri.encodeQueryComponent(cleanedQuery)}');
        final req = await client.getUrl(uri);
        req.headers.set('User-Agent', 'Mozilla/5.0');
        final resp = await req.close();
        if (resp.statusCode != 200) return null;
        final body = await resp.transform(utf8.decoder).join();
        final root = jsonDecode(body);
        if (root is! Map) return null;

        List? results;
        final dataNode = root['data'];
        if (dataNode is Map && dataNode['results'] is List) {
          results = dataNode['results'] as List;
        } else if (dataNode is List) {
          results = dataNode;
        }
        if (results == null || results.isEmpty) return null;

        final first = results.first;
        if (first is! Map) return null;

        final title = cleanText(
          first['name'] ?? first['title'],
          'Downloaded Song',
        )
            .replaceAll('&quot;', '"')
            .replaceAll('&amp;', '&')
            .replaceAll('&#039;', "'");

        String artist = 'Artist';
        if (first['primaryArtists'] != null) {
          artist = first['primaryArtists'].toString();
        } else if (first['artists'] is Map &&
            (first['artists']['primary'] is List) &&
            (first['artists']['primary'] as List).isNotEmpty) {
          artist =
              ((first['artists']['primary'] as List).first['name'] ?? 'Artist')
                  .toString();
        }

        final dlUrls = first['downloadUrl'];
        String? streamUrl;
        if (dlUrls is List && dlUrls.isNotEmpty) {
          final last = dlUrls.last;
          if (last is Map) {
            streamUrl = (last['url'] ?? last['link'] ?? '').toString();
          } else if (last is String) {
            streamUrl = last;
          }
        }
        if (streamUrl != null && streamUrl.startsWith('http')) {
          return ResolvedStream(
            url: streamUrl,
            title: title,
            artist: artist,
            ext: '.m4a',
          );
        }
      } catch (_) {}
      return null;
    }(), 6);

    if (hit != null) return hit;
  }
  return null;
}

/// ENGINE #2: Native Android `yt-dlp` C++/Python Engine (`youtubedl-android` in MainActivity.kt)
Future<bool> _downloadViaNativeYtDlp({
  required String targetUrlOrQuery,
  String? customTitle,
  String? customArtist,
}) async {
  if (!Platform.isAndroid || _cancelCurrentDownload) return false;
  try {
    downloadStatus.value = 'Running native Android yt-dlp engine…';
    downloadProgress.value = 0.35;
    final dir = await _getMusicDownloadsDir();

    final rawRes = await withHardTimeout<dynamic>(
      _mediaChannel.invokeMethod('nativeYtDlpDownload', {
        'target': targetUrlOrQuery,
        'dir': dir.path,
      }),
      40,
    );

    if (rawRes is Map) {
      final savedPath = (rawRes['path'] ?? '').toString();
      final rawName = (rawRes['name'] ?? '').toString();
      if (savedPath.isNotEmpty && File(savedPath).existsSync()) {
        String finalTitle = customTitle?.trim() ?? '';
        String finalArtist = customArtist?.trim() ?? '';
        if (finalTitle.isEmpty) {
          if (rawName.contains(' - ')) {
            final parts = rawName.split(' - ');
            finalArtist = parts.first.trim();
            finalTitle = parts.sublist(1).join(' - ').trim();
          } else {
            finalTitle = rawName.isEmpty
                ? p.basenameWithoutExtension(savedPath)
                : rawName;
            finalArtist = 'Downloaded Track';
          }
        }
        if (finalArtist.isEmpty) finalArtist = 'Downloaded Track';

        final newId = 'dl_${savedPath.hashCode}';
        appState.unmarkDeleted(newId, savedPath);

        final newTrack = TrackItem(
          id: newId,
          title: finalTitle,
          artist: finalArtist,
          album: 'AlexLMP Downloads',
          durationSeconds: 0,
          artColors: kArtPalettes[
                  audioHandler.tracks.length % kArtPalettes.length]
              .colors,
          artStyle: kArtStyles[audioHandler.tracks.length % kArtStyles.length],
          source: savedPath,
          filePath: savedPath,
        );

        await audioHandler.addTracks([newTrack], playFirst: true);
        appNotice.value = 'Downloaded "$finalTitle" via native yt-dlp!';
        return true;
      }
    }
  } catch (_) {}
  return false;
}

/// ENGINE #3: Range-Chunked InnerTube VR + YoutubeExplode with Hard Kill-Switch
Future<String?> _searchYouTubeVideoIdDirect(
  HttpClient client,
  String query,
) async {
  return await withHardTimeout<String>(() async {
    try {
      final uri = Uri.parse(
        'https://www.youtube.com/youtubei/v1/search?prettyPrint=false',
      );
      final req = await client.postUrl(uri);
      req.headers.set('Content-Type', 'application/json');
      req.headers.set(
        'User-Agent',
        'com.google.android.youtube/19.29.37 (Linux; U; Android 15) gzip',
      );
      req.add(
        utf8.encode(
          jsonEncode({
            'context': {
              'client': {
                'clientName': 'ANDROID',
                'clientVersion': '19.29.37',
                'androidSdkVersion': 35,
                'hl': 'en',
                'gl': 'US',
              },
            },
            'query': '$query official audio',
          }),
        ),
      );
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final match =
            RegExp(r'"videoId"\s*:\s*"([a-zA-Z0-9_-]{11})"').firstMatch(body);
        if (match != null) return match.group(1);
      }
    } catch (_) {}
    return null;
  }(), 6);
}

Future<ResolvedStream?> _extractViaDirectInnerTube(
  HttpClient client,
  String videoId,
) async {
  final clients = [
    {
      'clientName': 'ANDROID_VR',
      'clientVersion': '1.60.19',
      'deviceMake': 'Oculus',
      'deviceModel': 'Quest 3',
      'osName': 'Android',
      'osVersion': '12L',
      'androidSdkVersion': 32,
      'ua':
          'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    },
    {
      'clientName': 'IOS',
      'clientVersion': '19.45.4',
      'deviceMake': 'Apple',
      'deviceModel': 'iPhone16,2',
      'osName': 'iPhone',
      'osVersion': '18.1.0.22B83',
      'ua':
          'com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X;)',
    },
  ];

  for (final c in clients) {
    if (_cancelCurrentDownload) return null;
    final res = await withHardTimeout<ResolvedStream>(() async {
      try {
        final uri = Uri.parse(
          'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
        );
        final req = await client.postUrl(uri);
        req.headers.set('Content-Type', 'application/json');
        req.headers.set('User-Agent', c['ua'].toString());

        final clientMap = <String, dynamic>{
          'clientName': c['clientName'],
          'clientVersion': c['clientVersion'],
          'hl': 'en',
          'gl': 'US',
        };
        if (c['deviceMake'] != null) clientMap['deviceMake'] = c['deviceMake'];
        if (c['deviceModel'] != null) {
          clientMap['deviceModel'] = c['deviceModel'];
        }
        if (c['osName'] != null) clientMap['osName'] = c['osName'];
        if (c['osVersion'] != null) clientMap['osVersion'] = c['osVersion'];
        if (c['androidSdkVersion'] != null) {
          clientMap['androidSdkVersion'] = c['androidSdkVersion'];
        }

        req.add(
          utf8.encode(
            jsonEncode({
              'videoId': videoId,
              'context': {'client': clientMap},
              'contentCheckOk': true,
              'racyCheckOk': true,
            }),
          ),
        );

        final resp = await req.close();
        if (resp.statusCode != 200) return null;
        final body = await resp.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map;

        final details = data['videoDetails'] as Map?;
        final title = (details?['title'] ?? 'Downloaded Song').toString();
        final author = (details?['author'] ?? 'Artist')
            .toString()
            .replaceAll(' - Topic', '');

        final streamingData = data['streamingData'] as Map?;
        if (streamingData == null) return null;

        final adaptive =
            (streamingData['adaptiveFormats'] as List?) ?? const [];
        final formats = (streamingData['formats'] as List?) ?? const [];
        final allFormats = [...adaptive, ...formats];

        String? bestUrl;
        String bestExt = '.m4a';
        int bestBitrate = -1;
        int bestLength = 0;

        for (final f in allFormats) {
          if (f is! Map) continue;
          final url = (f['url'] ?? '').toString();
          if (!url.startsWith('http')) continue;
          final mime = (f['mimeType'] ?? '').toString().toLowerCase();
          final bitrate = (f['bitrate'] as num?)?.toInt() ?? 0;
          final clen =
              int.tryParse((f['contentLength'] ?? '0').toString()) ?? 0;

          if (mime.startsWith('audio/')) {
            final bonus = mime.contains('mp4') ? 500000 : 0;
            if (bitrate + bonus > bestBitrate) {
              bestBitrate = bitrate + bonus;
              bestUrl = url;
              bestExt = mime.contains('mp4') ? '.m4a' : '.ogg';
              bestLength = clen;
            }
          }
        }

        if (bestUrl != null) {
          return ResolvedStream(
            url: bestUrl,
            title: title,
            artist: author,
            ext: bestExt,
            totalBytes: bestLength,
          );
        }
      } catch (_) {}
      return null;
    }(), 6);

    if (res != null) return res;
  }
  return null;
}

Future<bool> _downloadBinaryStreamToLibrary({
  required HttpClient client,
  required String downloadUrl,
  required String title,
  required String artist,
  required String ext,
  int totalBytesHint = 0,
}) async {
  try {
    downloadStatus.value = 'Downloading "$title"…';
    var safeName = '$artist - $title'
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    if (safeName.isEmpty) {
      safeName = 'Track_${DateTime.now().millisecondsSinceEpoch}';
    }

    final dir = await _getMusicDownloadsDir();
    final savePath = p.join(dir.path, '$safeName$ext');
    final outFile = File(savePath);
    final sink = outFile.openWrite();

    int received = 0;
    final isGoogleVideo = downloadUrl.contains('googlevideo.com');

    if (isGoogleVideo && totalBytesHint > 0) {
      const chunkSize = 524288;
      while (received < totalBytesHint) {
        if (_cancelCurrentDownload) {
          await sink.close();
          try {
            outFile.deleteSync();
          } catch (_) {}
          return false;
        }
        final end = min(received + chunkSize - 1, totalBytesHint - 1);
        final sep = downloadUrl.contains('?') ? '&' : '?';
        final chunkUri = Uri.parse('$downloadUrl${sep}range=$received-$end');

        final chunkBytes = await withHardTimeout<List<int>>(() async {
          final req = await client.getUrl(chunkUri);
          req.headers.set(
            'User-Agent',
            'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L) gzip',
          );
          final resp = await req.close();
          if (resp.statusCode < 200 || resp.statusCode >= 400) return null;
          final buffer = <int>[];
          await for (final b in resp) {
            buffer.addAll(b);
          }
          return buffer;
        }(), 8);

        if (chunkBytes == null || chunkBytes.isEmpty) break;
        sink.add(chunkBytes);
        received += chunkBytes.length;
        downloadProgress.value =
            (received / totalBytesHint).clamp(0.05, 0.99);
      }
    } else {
      final ok = await withHardTimeout<bool>(() async {
        final uri = Uri.parse(downloadUrl);
        final req = await client.getUrl(uri);
        req.headers.set(
          'User-Agent',
          'Mozilla/5.0 (Linux; Android 15; Pixel 10) AppleWebKit/537.36',
        );
        final resp = await req.close();
        if (resp.statusCode < 200 || resp.statusCode >= 400) return false;
        final totalBytes = resp.contentLength;
        await for (final chunk in resp) {
          if (_cancelCurrentDownload) return false;
          sink.add(chunk);
          received += chunk.length;
          if (totalBytes > 0) {
            downloadProgress.value = (received / totalBytes).clamp(0.05, 0.99);
          }
        }
        return true;
      }(), 20);

      if (ok != true) {
        await sink.close();
        try {
          outFile.deleteSync();
        } catch (_) {}
        return false;
      }
    }

    await sink.flush();
    await sink.close();

    if (received < 1024) {
      try {
        outFile.deleteSync();
      } catch (_) {}
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
      artColors:
          kArtPalettes[audioHandler.tracks.length % kArtPalettes.length].colors,
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

/// Master Coordinator: Runs #1 (Fast 320kbps Studio CDN) + #2 (Native yt-dlp) + #3 (Chunked InnerTube)
Future<bool> downloadAudioIntoApp({
  required String inputUrlOrQuery,
  String? customTitle,
  String? customArtist,
}) async {
  final rawInput = inputUrlOrQuery.trim();
  if (rawInput.isEmpty) return false;

  _cancelCurrentDownload = false;
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  try {
    downloadProgress.value = 0.05;
    downloadStatus.value = 'Resolving song info…';

    final isHttp =
        rawInput.startsWith('http://') || rawInput.startsWith('https://');
    final lower = rawInput.toLowerCase();

    // Direct file links (.mp3, .flac, .wav, .m4a, Catbox, Discord, Dropbox, Drive)
    final isDirectAudioLink = isHttp &&
        !lower.contains('youtube.com') &&
        !lower.contains('youtu.be') &&
        !lower.contains('spotify.com') &&
        !lower.contains('soundcloud.com') &&
        !lower.contains('tiktok.com');

    if (isDirectAudioLink) {
      String directUrl = rawInput;
      if (directUrl.contains('dropbox.com') && directUrl.contains('dl=0')) {
        directUrl = directUrl.replaceAll('dl=0', 'dl=1');
      }
      if (directUrl.contains('drive.google.com/file/d/')) {
        final parts = directUrl.split('/file/d/');
        if (parts.length > 1) {
          final fileId = parts[1].split('/').first;
          directUrl = 'https://drive.google.com/uc?export=download&id=$fileId';
        }
      }
      final uri = Uri.parse(directUrl);
      final seg =
          uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'Track';
      final decodedName = Uri.decodeComponent(p.basenameWithoutExtension(seg));
      String ext = p.extension(uri.path).toLowerCase();
      if (!const ['.mp3', '.flac', '.wav', '.m4a', '.ogg', '.aac', '.opus']
          .contains(ext)) {
        ext = '.mp3';
      }
      final ok = await _downloadBinaryStreamToLibrary(
        client: client,
        downloadUrl: directUrl,
        title: (customTitle != null && customTitle.trim().isNotEmpty)
            ? customTitle.trim()
            : (decodedName.isEmpty ? 'Downloaded Track' : decodedName),
        artist: (customArtist != null && customArtist.trim().isNotEmpty)
            ? customArtist.trim()
            : 'Downloaded Track',
        ext: ext,
      );
      if (ok) return true;
    }

    // Extract song query from Spotify link, YouTube link, or plain text
    String? songQuery;
    final ytId = _extractYouTubeVideoId(rawInput);

    if (isHttp && lower.contains('spotify.com')) {
      downloadStatus.value = 'Reading Spotify track title…';
      songQuery = await _resolveSpotifyQuery(client, rawInput);
    } else if (ytId != null && (isHttp || rawInput.length == 11)) {
      downloadStatus.value = 'Reading YouTube track title…';
      songQuery = await _resolveYouTubeTitleViaOembed(client, ytId);
    } else if (!isHttp) {
      songQuery = rawInput;
    }

    // ── STEP 1 (#1): Try 320kbps Studio Music CDN First (Downloads in 2 seconds, zero YouTube blocks!)
    if (songQuery != null && songQuery.isNotEmpty && !_cancelCurrentDownload) {
      downloadStatus.value = 'Checking 320kbps Studio CDN for "$songQuery"…';
      downloadProgress.value = 0.18;
      final studio = await _resolveViaStudioMusicCdn(client, songQuery);
      if (studio != null && !_cancelCurrentDownload) {
        final ok = await _downloadBinaryStreamToLibrary(
          client: client,
          downloadUrl: studio.url,
          title: (customTitle != null && customTitle.trim().isNotEmpty)
              ? customTitle.trim()
              : studio.title,
          artist: (customArtist != null && customArtist.trim().isNotEmpty)
              ? customArtist.trim()
              : studio.artist,
          ext: studio.ext,
        );
        if (ok) return true;
      }
    }

    // ── STEP 2 (#2): Run Native Android `yt-dlp` Engine (Solves YouTube JS challenges natively!)
    if (!_cancelCurrentDownload) {
      final ytdlpTarget = (isHttp && !lower.contains('spotify.com'))
          ? rawInput
          : (songQuery ?? rawInput);
      final okNative = await _downloadViaNativeYtDlp(
        targetUrlOrQuery: ytdlpTarget,
        customTitle: customTitle,
        customArtist: customArtist,
      );
      if (okNative) return true;
    }

    // ── STEP 3: Fallback to Range-Chunked InnerTube VR Stream
    if (!_cancelCurrentDownload) {
      downloadStatus.value = 'Trying range-chunked VR stream…';
      final targetVid = ytId ??
          (songQuery != null
              ? await _searchYouTubeVideoIdDirect(client, songQuery)
              : null);
      if (targetVid != null) {
        final stream = await _extractViaDirectInnerTube(client, targetVid);
        if (stream != null) {
          final ok = await _downloadBinaryStreamToLibrary(
            client: client,
            downloadUrl: stream.url,
            title: customTitle ?? stream.title,
            artist: customArtist ?? stream.artist,
            ext: stream.ext,
            totalBytesHint: stream.totalBytes,
          );
          if (ok) return true;
        }
      }
    }

    if (!_cancelCurrentDownload) {
      appNotice.value =
          'Could not grab stream from that URL. Try typing "Artist - Song Name" instead!';
    }
    return false;
  } catch (e) {
    appNotice.value = 'Download failed: $e';
    return false;
  } finally {
    client.close();
    downloadProgress.value = null;
    downloadStatus.value = null;
  }
}

Future<int> quickImportPhoneDownloadsFolder() async {
  int count = 0;
  try {
    await ensureMediaPermissions();
    final existingPaths = audioHandler.tracks
        .map((t) => t.filePath ?? t.source)
        .toSet();
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
        if (!const ['.mp3', '.m4a', '.flac', '.wav', '.ogg', '.aac']
            .contains(ext)) {
          continue;
        }
        if (existingPaths.contains(entity.path)) continue;
        final id = 'local_${entity.path.hashCode}';
        if (appState.isDeleted(id, entity.path)) continue;
        final base = p.basenameWithoutExtension(entity.path);
        if (base.toLowerCase().contains('306 bobby')) continue;
        final t = TrackItem(
          id: id,
          title: base,
          artist: 'Downloads Folder',
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
// Palettes / AppState
// ─────────────────────────────────────────────────────────────────────────────

class AppPalette {
  final String name;
  final Color accent;
  final Color onAccent;
  final Color container;
  final Color bg;
  final Color surface;
  final Color playerBg;
  final Color playerSurface;
  final Color playerButton;
  final Color playerAccent;
  final Color playerOnAccent;

  const AppPalette({
    required this.name,
    required this.accent,
    required this.onAccent,
    required this.container,
    required this.bg,
    required this.surface,
    required this.playerBg,
    required this.playerSurface,
    required this.playerButton,
    required this.playerAccent,
    required this.playerOnAccent,
  });

  static const classicBlue = AppPalette(
    name: 'Classic Blue',
    accent: Color(0xFF8CD0F0),
    onAccent: Color(0xFF062938),
    container: Color(0xFF283740),
    bg: Color(0xFF111416),
    surface: Color(0xFF1C2124),
    playerBg: Color(0xFF141C24),
    playerSurface: Color(0xFF212D38),
    playerButton: Color(0xFF2C4254),
    playerAccent: Color(0xFF8CD0F0),
    playerOnAccent: Color(0xFF062938),
  );
  static const emerald = AppPalette(
    name: 'Emerald',
    accent: Color(0xFF9CF0C0),
    onAccent: Color(0xFF00391F),
    container: Color(0xFF22392D),
    bg: Color(0xFF0F1512),
    surface: Color(0xFF18211C),
    playerBg: Color(0xFF0E2014),
    playerSurface: Color(0xFF1F3527),
    playerButton: Color(0xFF2F5A40),
    playerAccent: Color(0xFF9CF0C0),
    playerOnAccent: Color(0xFF00391F),
  );
  static const sunsetPeach = AppPalette(
    name: 'Sunset Peach',
    accent: Color(0xFFFFB59C),
    onAccent: Color(0xFF4D1600),
    container: Color(0xFF3A2A23),
    bg: Color(0xFF151110),
    surface: Color(0xFF211A17),
    playerBg: Color(0xFF20130E),
    playerSurface: Color(0xFF362721),
    playerButton: Color(0xFF5D3A28),
    playerAccent: Color(0xFFFFC09C),
    playerOnAccent: Color(0xFF4D1600),
  );
  static const cyberpunk = AppPalette(
    name: 'Cyberpunk',
    accent: Color(0xFFF09CE2),
    onAccent: Color(0xFF3C0036),
    container: Color(0xFF3A2438),
    bg: Color(0xFF140F14),
    surface: Color(0xFF211820),
    playerBg: Color(0xFF200E20),
    playerSurface: Color(0xFF36213A),
    playerButton: Color(0xFF5A2A5A),
    playerAccent: Color(0xFFF09CE2),
    playerOnAccent: Color(0xFF3C0036),
  );
  static const amoled = AppPalette(
    name: 'AMOLED',
    accent: Color(0xFFD0BCFF),
    onAccent: Color(0xFF261059),
    container: Color(0xFF171520),
    bg: Color(0xFF000000),
    surface: Color(0xFF0A0A0E),
    playerBg: Color(0xFF000000),
    playerSurface: Color(0xFF121118),
    playerButton: Color(0xFF242038),
    playerAccent: Color(0xFFD0BCFF),
    playerOnAccent: Color(0xFF261059),
  );

  static const all = [classicBlue, emerald, sunsetPeach, cyberpunk, amoled];

  static AppPalette byName(String name) =>
      all.firstWhere((p) => p.name == name, orElse: () => classicBlue);
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

class AppState extends ChangeNotifier {
  SharedPreferences? _prefs;
  String themeName = 'AMOLED';
  bool liquidGlass = false;
  bool vinylSpinMode = false;
  bool stopOnTaskClear = true;
  bool linkSpeedAndPitch = false;
  double speed = 1.0;
  double pitch = 1.0;
  String playlistName = 'Your AlexLMP Mixes';
  String playlistStyle = 'equalizer_bars';
  final Set<String> liked = {};
  final Set<String> deletedIds = {};
  Map<String, dynamic> _edits = {};
  final List<Playlist> playlists = [];

  AppPalette get palette => AppPalette.byName(themeName);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    themeName = prefs.getString('theme_name') ?? themeName;
    liquidGlass = prefs.getBool('liquid_glass_beta') ?? false;
    vinylSpinMode = prefs.getBool('vinyl_spin_mode') ?? false;
    stopOnTaskClear = prefs.getBool('stop_on_task_clear') ?? true;
    linkSpeedAndPitch = prefs.getBool('link_speed_pitch') ?? false;
    speed = prefs.getDouble('playback_speed') ?? 1.0;
    pitch = prefs.getDouble('playback_pitch') ?? 1.0;
    playlistName = prefs.getString('playlist_name') ?? playlistName;
    playlistStyle = prefs.getString('playlist_style') ?? playlistStyle;
    liked.addAll(prefs.getStringList('liked_ids') ?? const []);
    deletedIds.addAll(prefs.getStringList('deleted_ids') ?? const []);
    try {
      final raw = jsonDecode(prefs.getString('playlists') ?? '[]') as List;
      playlists
        ..clear()
        ..addAll(
          raw.map((e) => Playlist.fromJson(Map<String, dynamic>.from(e as Map))),
        );
    } catch (_) {
      playlists.clear();
    }
    try {
      _edits = Map<String, dynamic>.from(
        jsonDecode(prefs.getString('track_edits') ?? '{}') as Map,
      );
    } catch (_) {
      _edits = {};
    }
    notifyListeners();
  }

  bool isDeleted(String id, [String? path]) {
    if (deletedIds.contains(id)) return true;
    if (path != null && path.isNotEmpty && deletedIds.contains(path)) {
      return true;
    }
    return false;
  }

  void markDeleted(TrackItem t) {
    deletedIds.add(t.id);
    if (t.filePath != null && t.filePath!.isNotEmpty) {
      deletedIds.add(t.filePath!);
    }
    if (t.source.isNotEmpty) {
      deletedIds.add(t.source);
    }
    _prefs?.setStringList('deleted_ids', deletedIds.toList());
    liked.remove(t.id);
    _prefs?.setStringList('liked_ids', liked.toList());
    for (final pl in playlists) {
      pl.trackIds.remove(t.id);
    }
    _savePlaylists();
  }

  void unmarkDeleted(String id, [String? path]) {
    deletedIds.remove(id);
    if (path != null) deletedIds.remove(path);
    _prefs?.setStringList('deleted_ids', deletedIds.toList());
  }

  void setTheme(String name) {
    themeName = name;
    _prefs?.setString('theme_name', name);
    notifyListeners();
  }

  void setLiquidGlass(bool v) {
    liquidGlass = v;
    _prefs?.setBool('liquid_glass_beta', v);
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

  void setPlaylist(String name, String style) {
    playlistName = name;
    playlistStyle = style;
    _prefs?.setString('playlist_name', name);
    _prefs?.setString('playlist_style', style);
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

  bool isLiked(String id) => liked.contains(id);

  void toggleLike(String id) {
    if (!liked.remove(id)) liked.add(id);
    _prefs?.setStringList('liked_ids', liked.toList());
    notifyListeners();
  }

  Playlist? playlistById(String id) {
    for (final pl in playlists) {
      if (pl.id == id) return pl;
    }
    return null;
  }

  void _savePlaylists() {
    _prefs?.setString(
      'playlists',
      jsonEncode(playlists.map((pl) => pl.toJson()).toList()),
    );
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

  bool inPlaylist(String pid, String tid) =>
      playlistById(pid)?.trackIds.contains(tid) ?? false;

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

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

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
        if (File(fp).existsSync()) {
          return Uri.file(fp);
        }
      } catch (_) {}
    }
    return source.startsWith('content://')
        ? Uri.parse(source)
        : Uri.file(source);
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
// Audio handler (NO error snackbars!)
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
  TrackItem? get currentTrack =>
      (_index >= 0 && _index < tracks.length) ? tracks[_index] : null;

  TrackItem? trackById(String id) {
    for (final t in tracks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> _init() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {}

    try {
      await player.setSkipSilenceEnabled(false);
    } catch (_) {}

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
      if (isPlaying) {
        _applySpeedAndPitch();
      }
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
      shuffleMode: _shuffle
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
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
    final keep =
        currentId == null ? -1 : list.indexWhere((t) => t.id == currentId);
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
        if (f.existsSync()) {
          f.deleteSync();
        }
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
      if (play) {
        player.play();
      }
    } catch (_) {
      if (seq != _loadSeq) return;
      _loadedId = null;
    }
  }

  Future<void> playIndex(int i) async {
    if (i < 0 || i >= tracks.length) return;
    if (i == _index &&
        _loadedId == tracks[i].id &&
        player.processingState != ProcessingState.idle) {
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
      do {
        n = _rng.nextInt(tracks.length);
      } while (n == _index);
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
    try {
      await player.setSpeed(clamped);
    } catch (_) {}
    playbackState.add(playbackState.value.copyWith(speed: clamped));
  }

  Future<void> setPitch(double pitch) async {
    final clamped = pitch.clamp(0.5, 2.0);
    try {
      await player.setPitch(clamped);
    } catch (_) {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Library scanning / importing
// ─────────────────────────────────────────────────────────────────────────────

Future<bool> ensureMediaPermissions() async {
  var status = await Permission.audio.request();
  if (!status.isGranted) {
    status = await Permission.storage.request();
  }
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
    final raw =
        await _mediaChannel.invokeMethod('scanDeviceAudio') as List? ??
            const [];
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
        .where((t) =>
            t.id.startsWith('local_') &&
            !appState.isDeleted(t.id, t.filePath ?? t.source))
        .toList();
    await audioHandler.setTracks([...savedDownloads, ...imported, ...scanned]);
  } catch (_) {
  } finally {
    scanning.value = false;
  }
}

Future<void> pickLocalFiles() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.audio,
    allowMultiple: true,
  );
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

// ─────────────────────────────────────────────────────────────────────────────
// iOS 27 Liquid Glass (Beta) & Ambient Mesh Backdrop Components
// ─────────────────────────────────────────────────────────────────────────────

class LiquidGlassBox extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final Color fallbackColor;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final double tintOpacity;
  final List<BoxShadow>? boxShadow;

  const LiquidGlassBox({
    super.key,
    required this.child,
    required this.borderRadius,
    required this.fallbackColor,
    this.padding,
    this.blur = 24,
    this.tintOpacity = 0.12,
    this.boxShadow,
  });

  @override
  Widget build(BuildContext context) {
    if (!appState.liquidGlass) {
      return Container(
        padding: padding,
        decoration: BoxDecoration(
          color: fallbackColor,
          borderRadius: borderRadius,
          boxShadow: boxShadow,
        ),
        child: child,
      );
    }
    final pal = appState.palette;
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: boxShadow ??
            [
              BoxShadow(
                color: Colors.black.withOpacity(0.45),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
              BoxShadow(
                color: pal.accent.withOpacity(0.08),
                blurRadius: 18,
                spreadRadius: -2,
              ),
            ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(tintOpacity + 0.08),
                  pal.accent.withOpacity(0.06),
                  Colors.white.withOpacity(tintOpacity * 0.35),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
              border: Border.all(
                color: Colors.white.withOpacity(0.22),
                width: 1.1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class AuroraPlasmaBackground extends StatefulWidget {
  final Color accent;
  final Color secondary;
  final bool intense;

  const AuroraPlasmaBackground({
    super.key,
    required this.accent,
    required this.secondary,
    this.intense = false,
  });

  @override
  State<AuroraPlasmaBackground> createState() => _AuroraPlasmaBackgroundState();
}

class _AuroraPlasmaBackgroundState extends State<AuroraPlasmaBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!appState.liquidGlass) return const SizedBox.shrink();
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final a = _c.value * 2 * pi;
          return CustomPaint(
            painter: _AuroraPainter(
              angle: a,
              c1: widget.accent,
              c2: widget.secondary,
              intense: widget.intense,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double angle;
  final Color c1;
  final Color c2;
  final bool intense;

  const _AuroraPainter({
    required this.angle,
    required this.c1,
    required this.c2,
    required this.intense,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final alpha1 = intense ? 0.28 : 0.16;
    final alpha2 = intense ? 0.22 : 0.12;
    final p1 = Offset(
      size.width * (0.28 + 0.22 * cos(angle)),
      size.height * (0.22 + 0.15 * sin(angle)),
    );
    final p2 = Offset(
      size.width * (0.75 + 0.20 * sin(angle * 0.8)),
      size.height * (0.68 + 0.18 * cos(angle * 0.8)),
    );
    final r1 = size.shortestSide * 0.65;
    final r2 = size.shortestSide * 0.72;

    canvas.drawCircle(
      p1,
      r1,
      Paint()
        ..shader = RadialGradient(
          colors: [c1.withOpacity(alpha1), Colors.transparent],
        ).createShader(Rect.fromCircle(center: p1, radius: r1)),
    );
    canvas.drawCircle(
      p2,
      r2,
      Paint()
        ..shader = RadialGradient(
          colors: [c2.withOpacity(alpha2), Colors.transparent],
        ).createShader(Rect.fromCircle(center: p2, radius: r2)),
    );
  }

  @override
  bool shouldRepaint(covariant _AuroraPainter old) =>
      old.angle != angle || old.c1 != c1 || old.intense != intense;
}

// ─────────────────────────────────────────────────────────────────────────────
// App
// ─────────────────────────────────────────────────────────────────────────────

class AlexLmpApp extends StatelessWidget {
  const AlexLmpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final pal = appState.palette;
        return MaterialApp(
          title: 'AlexLMP',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: pal.bg,
            colorScheme: ColorScheme.dark(
              primary: pal.accent,
              onPrimary: pal.onAccent,
              secondary: pal.accent,
              surface: pal.bg,
              surfaceContainer: pal.surface,
            ),
            splashFactory: InkSparkle.splashFactory,
            fontFamily: 'Roboto',
          ),
          home: const AlexLmpRoot(),
        );
      },
    );
  }
}

void openPlayer(BuildContext context) {
  if (audioHandler.tracks.isEmpty) {
    showAddMusicSheet(context);
    return;
  }
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 520),
      reverseTransitionDuration: const Duration(milliseconds: 360),
      pageBuilder: (_, __, ___) => const NowPlayingScreen(),
      transitionsBuilder: (_, anim, __, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: kEmphasizedDecel,
          reverseCurve: kEmphasizedAccel,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    ),
  );
}

void playAndOpen(BuildContext context, int index) {
  audioHandler.playIndex(index);
  openPlayer(context);
}

class AlexLmpRoot extends StatefulWidget {
  const AlexLmpRoot({super.key});

  @override
  State<AlexLmpRoot> createState() => _AlexLmpRootState();
}

class _AlexLmpRootState extends State<AlexLmpRoot> {
  int _tab = 0;
  int _dir = 1;
  String _chip = 'All';
  int _libraryFilter = 0;

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
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 190),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        appState,
        audioHandler.libraryRevision,
        audioHandler.currentIndex,
        scanning,
        downloadProgress,
        wifiServerUrl,
      ]),
      builder: (context, _) {
        final pal = appState.palette;
        final tracks = audioHandler.tracks;
        final bottomInset = MediaQuery.of(context).padding.bottom;

        return Scaffold(
          backgroundColor: pal.bg,
          body: Stack(
            children: [
              AuroraPlasmaBackground(
                accent: pal.accent,
                secondary: const Color(0xFFF09CE2),
              ),
              SafeArea(
                bottom: false,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 380),
                  switchInCurve: kEmphasizedDecel,
                  switchOutCurve: kEmphasizedAccel,
                  transitionBuilder: (child, anim) {
                    final incoming = child.key == ValueKey(_tab);
                    final begin = Offset(0.08 * (incoming ? _dir : -_dir), 0);
                    return FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(begin: begin, end: Offset.zero)
                            .animate(anim),
                        child: child,
                      ),
                    );
                  },
                  child: KeyedSubtree(
                    key: ValueKey(_tab),
                    child: _tabBody(context, pal, tracks),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: bottomInset + 8,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (audioHandler.currentTrack != null)
                      Reveal(
                        dy: 40,
                        child: MiniPlayer(
                          track: audioHandler.currentTrack!,
                          palette: pal,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _navBar(pal)),
                        const SizedBox(width: 10),
                        SquishyGesture(
                          onTap: () => showSearchSheet(context),
                          child: LiquidGlassBox(
                            borderRadius: BorderRadius.circular(32),
                            fallbackColor: pal.surface,
                            boxShadow: _shadow,
                            child: const SizedBox(
                              width: 64,
                              height: 64,
                              child: Icon(
                                Icons.search_rounded,
                                color: Color(0xFFD5DCE0),
                                size: 26,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tabBody(BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    switch (_tab) {
      case 1:
        return _mixTab(context, pal, tracks);
      case 2:
        return _libraryTab(context, pal, tracks);
      default:
        return _homeTab(context, pal, tracks);
    }
  }

  Widget _navBar(AppPalette pal) {
    return LiquidGlassBox(
      borderRadius: BorderRadius.circular(36),
      fallbackColor: pal.surface,
      padding: const EdgeInsets.all(6),
      boxShadow: _shadow,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            _navTab(pal, 0, Icons.home_rounded, 'Home'),
            _navTab(pal, 1, Icons.sensors_rounded, 'Mix'),
            _navTab(pal, 2, Icons.library_music_rounded, 'Library'),
          ],
        ),
      ),
    );
  }

  Widget _navTab(AppPalette pal, int i, IconData icon, String label) {
    final selected = _tab == i;
    return Expanded(
      child: SquishyGesture(
        pressedScale: 0.92,
        onTap: () => setState(() {
          _dir = i >= _tab ? 1 : -1;
          _tab = i;
        }),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected
                ? (appState.liquidGlass
                    ? pal.accent.withOpacity(0.24)
                    : pal.container)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(30),
            border: selected && appState.liquidGlass
                ? Border.all(color: pal.accent.withOpacity(0.45))
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: selected ? pal.accent : const Color(0xFFB3B9BE),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  color: selected ? pal.accent : const Color(0xFFB3B9BE),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _homeTab(BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [pal.accent, pal.container],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.graphic_eq_rounded, color: pal.onAccent, size: 24),
          ),
          const SizedBox(width: 12),
          _chipButton(pal, 'All'),
          const SizedBox(width: 10),
          _chipButton(pal, 'Mood'),
          const Spacer(),
          SquishyGesture(
            onTap: () => showAddMusicSheet(context),
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: pal.surface,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF333B40)),
              ),
              child: const Icon(
                Icons.add_rounded,
                color: Color(0xFFD5DCE0),
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SquishyGesture(
            onTap: () => showSettingsSheet(context),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.settings_rounded, color: Colors.white, size: 26),
            ),
          ),
        ],
      ),
    );

    if (tracks.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(top: 10, bottom: 185),
        children: [
          header,
          const SizedBox(height: 90),
          _emptyState(context, pal),
        ],
      );
    }

    final col1 = tracks.take(4).toList();
    final col2 = tracks.skip(4).take(4).toList();
    final listenAgain = tracks.reversed.take(8).toList();
    final colWidth = MediaQuery.of(context).size.width - 42;

    return ListView(
      padding: const EdgeInsets.only(top: 10, bottom: 185),
      children: [
        Reveal(child: header),
        const SizedBox(height: 22),
        _sectionHeader(
          "LET'S START WITH A RADIO",
          'Quick picks',
          trailing: SquishyGesture(
            onTap: () => playAndOpen(context, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: pal.container,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Play all',
                style: TextStyle(
                  color: pal.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 280,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 16),
            children: [
              SizedBox(
                width: colWidth,
                child: Column(
                  children: col1.map((t) => _trackRow(context, pal, t)).toList(),
                ),
              ),
              if (col2.isNotEmpty) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: colWidth,
                  child: Column(
                    children:
                        col2.map((t) => _trackRow(context, pal, t)).toList(),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 22),
        _sectionHeader('LIBRARY RECENT', 'Listen again'),
        const SizedBox(height: 14),
        SizedBox(
          height: 230,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: listenAgain.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final t = listenAgain[i];
              return SquishyGesture(
                pressedScale: 0.95,
                onTap: () => playAndOpen(context, tracks.indexOf(t)),
                child: SizedBox(
                  width: 168,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: SizedBox(
                          width: 168,
                          height: 168,
                          child: CustomAlbumArtwork(track: t),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF9EA6AC),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _emptyState(BuildContext context, AppPalette pal) {
    final busy = scanning.value;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          busy
              ? SizedBox(
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(color: pal.accent),
                )
              : Icon(Icons.music_note_rounded, size: 64, color: pal.accent),
          const SizedBox(height: 16),
          Text(
            busy ? 'Scanning your music…' : 'No songs found on this device',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Download any song by name or link, or scan your phone to get started.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFA6ADB2), fontSize: 14),
          ),
          const SizedBox(height: 24),
          SquishyGesture(
            onTap: () => showDirectUrlDownloadSheet(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: pal.accent,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_download_rounded, color: pal.onAccent),
                  const SizedBox(width: 8),
                  Text(
                    'Download Song / Paste Link',
                    style: TextStyle(
                      color: pal.onAccent,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
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

  Widget _chipButton(AppPalette pal, String label) {
    final selected = _chip == label;
    return SquishyGesture(
      onTap: () => setState(() => _chip = label),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? pal.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected ? pal.accent : const Color(0xFF3A4146),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? pal.onAccent : Colors.white,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String eyebrow, String title, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  eyebrow,
                  style: const TextStyle(
                    color: Color(0xFF9EA6AC),
                    fontSize: 12,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _trackRow(BuildContext context, AppPalette pal, TrackItem t) {
    final idx = audioHandler.tracks.indexOf(t);
    return Reveal(
      delayMs: min(max(idx, 0), 8) * 40,
      dy: 16,
      child: TrackRow(
        track: t,
        palette: pal,
        active: audioHandler.currentTrack?.id == t.id,
        onTap: () => playAndOpen(context, idx),
        onMore: () => showAddToPlaylistSheet(context, t),
      ),
    );
  }

  Widget _mixTab(BuildContext context, AppPalette pal, List<TrackItem> tracks) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 185),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'CUSTOM STATIONS',
              style: TextStyle(
                color: Color(0xFF9EA6AC),
                fontSize: 12,
                letterSpacing: 0.8,
              ),
            ),
            SquishyGesture(
              onTap: () => showPlaylistEditDialog(context),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(Icons.edit_rounded, color: pal.accent, size: 20),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          appState.playlistName,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 16),
        if (tracks.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No tracks available for mix',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ),
        for (var i = 0; i < tracks.length; i++)
          Reveal(
            delayMs: min(i, 8) * 45,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SquishyGesture(
                pressedScale: 0.97,
                onTap: () => playAndOpen(context, i),
                child: LiquidGlassBox(
                  borderRadius: BorderRadius.circular(22),
                  fallbackColor: pal.surface,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 56,
                          height: 56,
                          child: CustomAlbumArtwork(track: tracks[i]),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tracks[i].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              tracks[i].artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Color(0xFFA6ADB2)),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: pal.accent,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: pal.onAccent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _libraryTab(
    BuildContext context,
    AppPalette pal,
    List<TrackItem> tracks,
  ) {
    final busyDl = downloadProgress.value != null;
    final wifiUrl = wifiServerUrl.value;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 185),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Your Library',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            Row(
              children: [
                if (_libraryFilter == 1)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SquishyGesture(
                      onTap: () => showCreateOrEditPlaylistDialog(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: pal.accent,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_rounded, color: pal.onAccent, size: 20),
                            const SizedBox(width: 6),
                            Text(
                              'New Playlist',
                              style: TextStyle(
                                color: pal.onAccent,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                SquishyGesture(
                  onTap: () => showAddMusicSheet(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: pal.container,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.folder_open_rounded,
                          color: pal.accent,
                          size: 19,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Import',
                          style: TextStyle(
                            color: pal.accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                pal.accent.withOpacity(0.24),
                pal.container.withOpacity(0.95),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: pal.accent.withOpacity(0.55)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SquishyGesture(
                pressedScale: 0.98,
                onTap: () => showDirectUrlDownloadSheet(context),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: pal.accent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.cloud_download_rounded,
                        color: pal.onAccent,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Direct Song & yt-dlp Downloader',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            busyDl
                                ? (downloadStatus.value ?? 'Downloading…')
                                : 'Tap to search song or paste Spotify / YT / MP3 link',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFD0D7DC),
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: SquishyGesture(
                      onTap: () async {
                        final added = await quickImportPhoneDownloadsFolder();
                        appNotice.value = added > 0
                            ? 'Imported $added new track(s) from Phone Downloads!'
                            : 'No new audio files in Phone Downloads folder.';
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.35),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.download_done_rounded,
                              color: pal.accent,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            const Text(
                              'Grab DL Folder',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SquishyGesture(
                      onTap: toggleWifiDropServer,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: wifiUrl != null
                              ? pal.accent
                              : Colors.black.withOpacity(0.35),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: wifiUrl != null ? pal.accent : Colors.white24,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.wifi_tethering_rounded,
                              color: wifiUrl != null
                                  ? pal.onAccent
                                  : pal.accent,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                wifiUrl ?? 'Wi-Fi PC Drop',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: wifiUrl != null
                                      ? pal.onAccent
                                      : Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (busyDl) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: downloadProgress.value,
                          backgroundColor: Colors.black38,
                          valueColor: AlwaysStoppedAnimation<Color>(pal.accent),
                          minHeight: 6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () {
                        _cancelCurrentDownload = true;
                        downloadProgress.value = null;
                        downloadStatus.value = null;
                      },
                      child: const Text(
                        'Cancel',
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        LiquidGlassBox(
          borderRadius: BorderRadius.circular(26),
          fallbackColor: pal.surface,
          padding: const EdgeInsets.all(5),
          child: Row(
            children: [
              _libFilterSegment(pal, 0, Icons.music_note_rounded, 'Songs'),
              _libFilterSegment(pal, 1, Icons.queue_music_rounded, 'Playlists'),
              _libFilterSegment(pal, 2, Icons.person_rounded, 'Artists'),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (_libraryFilter == 0) ...[
          if (tracks.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(
                child: Text(
                  'No local audio files found.',
                  style: TextStyle(color: Colors.white54, fontSize: 16),
                ),
              ),
            ),
          ...tracks.map((t) => _trackRow(context, pal, t)),
        ] else if (_libraryFilter == 1) ...[
          _buildPlaylistsSection(context, pal),
        ] else ...[
          _buildArtistsSection(context, pal, tracks),
        ],
      ],
    );
  }

  Widget _libFilterSegment(
    AppPalette pal,
    int index,
    IconData icon,
    String label,
  ) {
    final selected = _libraryFilter == index;
    return Expanded(
      child: SquishyGesture(
        pressedScale: 0.94,
        onTap: () => setState(() => _libraryFilter = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: selected ? pal.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? pal.onAccent : Colors.white70,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? pal.onAccent : Colors.white70,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaylistsSection(BuildContext context, AppPalette pal) {
    final pls = appState.playlists;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SquishyGesture(
          pressedScale: 0.97,
          onTap: () => showCreateOrEditPlaylistDialog(context),
          child: LiquidGlassBox(
            borderRadius: BorderRadius.circular(22),
            fallbackColor: pal.surface,
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: pal.accent.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: pal.accent.withOpacity(0.5)),
                  ),
                  child: Icon(Icons.add_rounded, color: pal.accent, size: 30),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Create a Playlist',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Custom title, gallery photo icon & drag-and-drop song order',
                        style: TextStyle(
                          color: Color(0xFFA6ADB2),
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (pls.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 28),
            child: Center(
              child: Text(
                'No playlists yet. Tap "Create a Playlist" above!',
                style: TextStyle(color: Colors.white54, fontSize: 15),
              ),
            ),
          ),
        for (int i = 0; i < pls.length; i++)
          Reveal(
            delayMs: min(i, 8) * 45,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SquishyGesture(
                pressedScale: 0.97,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PlaylistDetailScreen(playlistId: pls[i].id),
                  ),
                ),
                child: LiquidGlassBox(
                  borderRadius: BorderRadius.circular(22),
                  fallbackColor: pal.surface,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      PlaylistCoverThumbnail(playlist: pls[i], size: 62),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              pls[i].name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${pls[i].trackIds.length} ${pls[i].trackIds.length == 1 ? 'song' : 'songs'}',
                              style: const TextStyle(
                                color: Color(0xFFA6ADB2),
                                fontSize: 13.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SquishyGesture(
                        onTap: () => showCreateOrEditPlaylistDialog(
                          context,
                          existing: pls[i],
                        ),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: pal.container,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.edit_rounded,
                            color: pal.accent,
                            size: 19,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white54,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildArtistsSection(
    BuildContext context,
    AppPalette pal,
    List<TrackItem> tracks,
  ) {
    final byArtist = <String, List<TrackItem>>{};
    for (final t in tracks) {
      byArtist.putIfAbsent(t.artist, () => <TrackItem>[]).add(t);
    }
    final entries = byArtist.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 40),
        child: Center(
          child: Text(
            'No artists found.',
            style: TextStyle(color: Colors.white54, fontSize: 16),
          ),
        ),
      );
    }

    return Column(
      children: [
        for (int i = 0; i < entries.length; i++)
          Reveal(
            delayMs: min(i, 8) * 40,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SquishyGesture(
                pressedScale: 0.97,
                onTap: () => showArtistTracksSheet(
                  context,
                  entries[i].key,
                  entries[i].value,
                ),
                child: LiquidGlassBox(
                  borderRadius: BorderRadius.circular(20),
                  fallbackColor: pal.surface,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      ClipOval(
                        child: SizedBox(
                          width: 54,
                          height: 54,
                          child: CustomAlbumArtwork(
                            track: entries[i].value.first,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entries[i].key,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${entries[i].value.length} ${entries[i].value.length == 1 ? 'track' : 'tracks'}',
                              style: const TextStyle(
                                color: Color(0xFFA6ADB2),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: pal.accent),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

final List<BoxShadow> _shadow = [
  BoxShadow(
    color: Colors.black.withOpacity(0.45),
    blurRadius: 16,
    offset: const Offset(0, 6),
  ),
];

// ─────────────────────────────────────────────────────────────────────────────
// Direct URL / YouTube / Spotify Downloader Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────

void showDirectUrlDownloadSheet(BuildContext context) {
  final urlCtrl = TextEditingController();
  final titleCtrl = TextEditingController();
  final artistCtrl = TextEditingController();

  _sheet(
    context,
    (ctx) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(ctx).viewInsets.bottom,
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge([
          appState,
          downloadProgress,
          downloadStatus,
        ]),
        builder: (ctx, _) {
          final pal = appState.palette;
          final busy = downloadProgress.value != null;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.cloud_download_rounded,
                        color: pal.accent,
                        size: 26,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Direct Song & yt-dlp Downloader',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Powered by 320kbps Studio CDN + Native Android yt-dlp. Type "Artist - Song Name" or paste a Spotify, YouTube, SoundCloud, or MP3 link.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: urlCtrl,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Song Name, Spotify Link, YouTube Link, or MP3 URL',
                      labelStyle: const TextStyle(color: Colors.white70),
                      hintText: 'e.g. The Weeknd - Timeless or https://...',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: pal.container,
                      prefixIcon: Icon(Icons.link_rounded, color: pal.accent),
                      suffixIcon: IconButton(
                        icon: const Icon(
                          Icons.content_paste_rounded,
                          color: Colors.white70,
                        ),
                        tooltip: 'Paste from clipboard',
                        onPressed: () async {
                          final data = await Clipboard.getData('text/plain');
                          if (data?.text != null) {
                            urlCtrl.text = data!.text!.trim();
                          }
                        },
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: titleCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Custom Title (Optional)',
                            labelStyle: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                            filled: true,
                            fillColor: pal.container,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: artistCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Artist (Optional)',
                            labelStyle: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                            filled: true,
                            fillColor: pal.container,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (busy) ...[
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            downloadStatus.value ?? 'Downloading…',
                            style: TextStyle(
                              color: pal.accent,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            _cancelCurrentDownload = true;
                            downloadProgress.value = null;
                            downloadStatus.value = null;
                          },
                          child: const Text(
                            'Cancel',
                            style: TextStyle(
                              color: Colors.redAccent,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: downloadProgress.value,
                        backgroundColor: Colors.white12,
                        valueColor: AlwaysStoppedAnimation<Color>(pal.accent),
                        minHeight: 7,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: pal.accent,
                        foregroundColor: pal.onAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(26),
                        ),
                      ),
                      onPressed: busy
                          ? null
                          : () async {
                              final input = urlCtrl.text.trim();
                              if (input.isEmpty) return;
                              final ok = await downloadAudioIntoApp(
                                inputUrlOrQuery: input,
                                customTitle: titleCtrl.text.trim().isEmpty
                                    ? null
                                    : titleCtrl.text.trim(),
                                customArtist: artistCtrl.text.trim().isEmpty
                                    ? null
                                    : artistCtrl.text.trim(),
                              );
                              if (ok && ctx.mounted) {
                                Navigator.pop(ctx);
                              }
                            },
                      icon: Icon(
                        busy
                            ? Icons.hourglass_top_rounded
                            : Icons.download_rounded,
                      ),
                      label: Text(
                        busy ? 'Downloading…' : 'Download Straight to Library',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
    scroll: true,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Playlist Cover & Full Playlist Detail Screen
// ─────────────────────────────────────────────────────────────────────────────

class PlaylistCoverThumbnail extends StatelessWidget {
  final Playlist playlist;
  final double size;

  const PlaylistCoverThumbnail({
    super.key,
    required this.playlist,
    this.size = 60,
  });

  @override
  Widget build(BuildContext context) {
    final pal = appState.palette;
    final cover = playlist.cover;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.file(
          File(cover),
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    }
    TrackItem? firstTrack;
    if (playlist.trackIds.isNotEmpty) {
      firstTrack = audioHandler.trackById(playlist.trackIds.first);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: SizedBox(
        width: size,
        height: size,
        child: firstTrack != null
            ? CustomAlbumArtwork(track: firstTrack)
            : Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [pal.accent, pal.container],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Icon(
                  Icons.queue_music_rounded,
                  color: pal.onAccent,
                  size: size * 0.48,
                ),
              ),
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
      listenable: Listenable.merge([
        appState,
        audioHandler.libraryRevision,
        audioHandler.currentIndex,
      ]),
      builder: (context, _) {
        final pal = appState.palette;
        final pl = appState.playlistById(playlistId);
        if (pl == null) {
          return Scaffold(
            backgroundColor: pal.bg,
            body: const Center(child: Text('Playlist deleted')),
          );
        }

        final resolvedTracks = <TrackItem>[];
        for (final id in pl.trackIds) {
          final t = audioHandler.trackById(id);
          if (t != null) resolvedTracks.add(t);
        }

        return Scaffold(
          backgroundColor: pal.bg,
          body: Stack(
            children: [
              AuroraPlasmaBackground(
                accent: pal.accent,
                secondary: const Color(0xFF8CD0F0),
                intense: true,
              ),
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                      child: Row(
                        children: [
                          SquishyGesture(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: pal.surface,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.arrow_back_rounded,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const Spacer(),
                          SquishyGesture(
                            onTap: () => showAddTracksToPlaylistPicker(
                              context,
                              pl,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: pal.container,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.playlist_add_rounded,
                                    color: pal.accent,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Add Songs',
                                    style: TextStyle(
                                      color: pal.accent,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SquishyGesture(
                            onTap: () => showCreateOrEditPlaylistDialog(
                              context,
                              existing: pl,
                            ),
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: pal.surface,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.edit_rounded,
                                color: pal.accent,
                                size: 20,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SquishyGesture(
                            onTap: () {
                              appState.deletePlaylist(pl.id);
                              Navigator.pop(context);
                            },
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: pal.surface,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.delete_outline_rounded,
                                color: Colors.redAccent,
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          SquishyGesture(
                            onTap: () => showCreateOrEditPlaylistDialog(
                              context,
                              existing: pl,
                            ),
                            child: Stack(
                              alignment: Alignment.bottomRight,
                              children: [
                                PlaylistCoverThumbnail(playlist: pl, size: 104),
                                Container(
                                  margin: const EdgeInsets.all(6),
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.7),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.photo_library_rounded,
                                    color: pal.accent,
                                    size: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 18),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  pl.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.4,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${resolvedTracks.length} songs • Drag handle to sort order',
                                  style: const TextStyle(
                                    color: Color(0xFFA6ADB2),
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                if (resolvedTracks.isNotEmpty)
                                  SquishyGesture(
                                    onTap: () {
                                      audioHandler.playTrackById(
                                        resolvedTracks.first.id,
                                      );
                                      openPlayer(context);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 9,
                                      ),
                                      decoration: BoxDecoration(
                                        color: pal.accent,
                                        borderRadius: BorderRadius.circular(24),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.play_arrow_rounded,
                                            color: pal.onAccent,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Play Playlist',
                                            style: TextStyle(
                                              color: pal.onAccent,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(color: Colors.white12, height: 20),
                    Expanded(
                      child: resolvedTracks.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.queue_music_rounded,
                                    size: 54,
                                    color: pal.accent.withOpacity(0.6),
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'Playlist is empty',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Tap "Add Songs" above or use the 3-dot menu in Now Playing.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ReorderableListView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                4,
                                16,
                                40,
                              ),
                              buildDefaultDragHandles: false,
                              itemCount: resolvedTracks.length,
                              onReorder: (oldIndex, newIndex) {
                                if (newIndex > oldIndex) newIndex -= 1;
                                HapticFeedback.mediumImpact();
                                appState.movePlaylistTrack(
                                  pl.id,
                                  oldIndex,
                                  newIndex,
                                );
                              },
                              itemBuilder: (context, i) {
                                final t = resolvedTracks[i];
                                final active =
                                    audioHandler.currentTrack?.id == t.id;
                                return Container(
                                  key: ValueKey('pl_${pl.id}_${t.id}'),
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: pal.surface.withOpacity(
                                      appState.liquidGlass ? 0.55 : 1.0,
                                    ),
                                    borderRadius: BorderRadius.circular(18),
                                    border: appState.liquidGlass
                                        ? Border.all(
                                            color: Colors.white.withOpacity(
                                              0.12,
                                            ),
                                          )
                                        : null,
                                  ),
                                  child: Row(
                                    children: [
                                      ReorderableDragStartListener(
                                        index: i,
                                        child: const Padding(
                                          padding: EdgeInsets.only(right: 10),
                                          child: Icon(
                                            Icons.drag_indicator_rounded,
                                            color: Colors.white54,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () {
                                            audioHandler.playTrackById(t.id);
                                            openPlayer(context);
                                          },
                                          child: Row(
                                            children: [
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                child: SizedBox(
                                                  width: 48,
                                                  height: 48,
                                                  child: CustomAlbumArtwork(
                                                    track: t,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      t.title,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: active
                                                            ? pal.accent
                                                            : Colors.white,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 15.5,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      t.artist,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        color:
                                                            Color(0xFFA6ADB2),
                                                        fontSize: 13,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      PopupMenuButton<String>(
                                        icon: const Icon(
                                          Icons.more_vert_rounded,
                                          color: Colors.white70,
                                        ),
                                        color: pal.surface,
                                        onSelected: (action) {
                                          if (action == 'first') {
                                            appState.movePlaylistTrack(
                                              pl.id,
                                              i,
                                              0,
                                            );
                                          } else if (action == 'last') {
                                            appState.movePlaylistTrack(
                                              pl.id,
                                              i,
                                              resolvedTracks.length - 1,
                                            );
                                          } else if (action == 'remove') {
                                            appState.removeFromPlaylist(
                                              pl.id,
                                              t.id,
                                            );
                                          }
                                        },
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                            value: 'first',
                                            child: Text(
                                              'Move to First',
                                              style: TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                          PopupMenuItem(
                                            value: 'last',
                                            child: Text(
                                              'Move to Last',
                                              style: TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                          PopupMenuItem(
                                            value: 'remove',
                                            child: Text(
                                              'Remove from Playlist',
                                              style: TextStyle(
                                                color: Colors.redAccent,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
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
// Reusable animations & interactive widgets
// ─────────────────────────────────────────────────────────────────────────────

const Curve kEmphasized = Cubic(0.2, 0.0, 0.0, 1.0);
const Curve kEmphasizedDecel = Cubic(0.05, 0.7, 0.1, 1.0);
const Curve kEmphasizedAccel = Cubic(0.3, 0.0, 0.8, 0.15);

class Reveal extends StatelessWidget {
  final int delayMs;
  final double dy;
  final Widget child;

  const Reveal({
    super.key,
    this.delayMs = 0,
    this.dy = 22,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final total = 480 + delayMs;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delayMs / total, 1.0, curve: kEmphasizedDecel),
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0).toDouble(),
        child: Transform.translate(
          offset: Offset(0, (1 - t) * dy),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class Interactive3DArtwork extends StatefulWidget {
  final TrackItem track;
  final bool playing;

  const Interactive3DArtwork({
    super.key,
    required this.track,
    required this.playing,
  });

  @override
  State<Interactive3DArtwork> createState() => _Interactive3DArtworkState();
}

class _Interactive3DArtworkState extends State<Interactive3DArtwork>
    with SingleTickerProviderStateMixin {
  Offset _tilt = Offset.zero;
  late final AnimationController _spinCtrl;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    if (widget.playing) _spinCtrl.repeat();
  }

  @override
  void didUpdateWidget(covariant Interactive3DArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !_spinCtrl.isAnimating) {
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

  void _onPanUpdate(DragUpdateDetails d, Size size) {
    final nx = ((d.localPosition.dx / size.width) - 0.5) * 2;
    final ny = ((d.localPosition.dy / size.height) - 0.5) * 2;
    setState(() {
      _tilt = Offset(ny.clamp(-1.0, 1.0) * -0.22, nx.clamp(-1.0, 1.0) * 0.22);
    });
  }

  void _resetTilt() {
    setState(() => _tilt = Offset.zero);
  }

  @override
  Widget build(BuildContext context) {
    final spinMode = appState.vinylSpinMode;
    return LayoutBuilder(
      builder: (context, constraints) {
        final sz = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onPanUpdate: (d) => _onPanUpdate(d, sz),
          onPanEnd: (_) => _resetTilt(),
          onPanCancel: _resetTilt,
          onDoubleTap: () {
            HapticFeedback.mediumImpact();
            appState.setVinylSpinMode(!spinMode);
          },
          child: TweenAnimationBuilder<Offset>(
            tween: Tween<Offset>(begin: Offset.zero, end: _tilt),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) {
              final matrix = Matrix4.identity()
                ..setEntry(3, 2, 0.0014)
                ..rotateX(t.dx)
                ..rotateY(t.dy);
              return Transform(
                alignment: Alignment.center,
                transform: matrix,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    child!,
                    IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            spinMode ? 999 : 28,
                          ),
                          gradient: RadialGradient(
                            center: Alignment(
                              (-t.dy * 3.0).clamp(-1.0, 1.0),
                              (-t.dx * 3.0).clamp(-1.0, 1.0),
                            ),
                            radius: 1.1,
                            colors: [
                              Colors.white.withOpacity(
                                (t.distance * 0.65).clamp(0.0, 0.28),
                              ),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
            child: AnimatedBuilder(
              animation: _spinCtrl,
              builder: (context, artChild) {
                if (!spinMode) return artChild!;
                return Transform.rotate(
                  angle: _spinCtrl.value * 2 * pi,
                  child: ClipOval(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        artChild!,
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.82),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white38,
                              width: 2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
              child: CustomAlbumArtwork(track: widget.track),
            ),
          ),
        );
      },
    );
  }
}

class EqBars extends StatefulWidget {
  final Color color;
  const EqBars({super.key, required this.color});

  @override
  State<EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<EqBars> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: audioHandler.player.playingStream,
      initialData: audioHandler.player.playing,
      builder: (context, snap) {
        final playing = snap.data ?? false;
        return AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            return SizedBox(
              width: 22,
              height: 20,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(3, (i) {
                  final h = playing
                      ? 5 + 15 * (0.5 + 0.5 * sin(2 * pi * (_c.value + i / 3)))
                      : 5.0;
                  return Container(
                    width: 4.5,
                    height: h,
                    decoration: BoxDecoration(
                      color: widget.color,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  );
                }),
              ),
            );
          },
        );
      },
    );
  }
}

class SwipeDownDismiss extends StatefulWidget {
  final Widget child;
  const SwipeDownDismiss({super.key, required this.child});

  @override
  State<SwipeDownDismiss> createState() => _SwipeDownDismissState();
}

class _SwipeDownDismissState extends State<SwipeDownDismiss>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _c = AnimationController.unbounded(vsync: this, value: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    if (_dismissing) return;
    _c.value = (_c.value + d.delta.dy).clamp(-24.0, double.infinity).toDouble();
  }

  void _springBack(double velocity) {
    _c.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 320, damping: 26),
        _c.value,
        0,
        velocity,
      ),
    );
  }

  void _end(DragEndDetails d) {
    if (_dismissing) return;
    final v = d.velocity.pixelsPerSecond.dy;
    final h = MediaQuery.of(context).size.height;
    if (_c.value > h * 0.16 || v > 900) {
      HapticFeedback.lightImpact();
      setState(() => _dismissing = true);
      _c
          .animateTo(
            h,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeInCubic,
          )
          .whenComplete(() {
        if (mounted) Navigator.of(context).pop();
      });
    } else {
      _springBack(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragUpdate: _update,
      onVerticalDragEnd: _end,
      onVerticalDragCancel: () => _springBack(0),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final h = MediaQuery.of(context).size.height;
          final p = (_c.value / h).clamp(0.0, 1.0).toDouble();
          return Transform.translate(
            offset: Offset(0, _c.value),
            child: Transform.scale(
              scale: 1 - 0.05 * p,
              alignment: Alignment.topCenter,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(min(1.0, p * 8) * 36),
                child: child,
              ),
            ),
          );
        },
        child: HeroMode(enabled: !_dismissing, child: widget.child),
      ),
    );
  }
}

Widget _artShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromContext,
  BuildContext toContext,
) {
  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final t = direction == HeroFlightDirection.push
          ? animation.value
          : 1 - animation.value;
      final track = audioHandler.currentTrack;
      return ClipRRect(
        borderRadius: BorderRadius.circular(18 + 10 * t),
        child:
            track == null ? const SizedBox() : CustomAlbumArtwork(track: track),
      );
    },
  );
}

RectTween _arcTween(Rect? begin, Rect? end) =>
    MaterialRectArcTween(begin: begin, end: end);

class SquishyGesture extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;

  const SquishyGesture({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.88,
  });

  @override
  State<SquishyGesture> createState() => _SquishyGestureState();
}

class _SquishyGestureState extends State<SquishyGesture>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  DateTime _downAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _c = AnimationController.unbounded(vsync: this, value: 1.0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down() {
    _downAt = DateTime.now();
    _c.animateTo(
      widget.pressedScale,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
    );
  }

  void _release() {
    if (!mounted) return;
    _c.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 380, damping: 13),
        _c.value,
        1.0,
        0.0,
      ),
    );
  }

  void _up() {
    final elapsed = DateTime.now().difference(_downAt).inMilliseconds;
    final wait = max(0, 90 - elapsed);
    if (wait == 0) {
      _release();
    } else {
      Future.delayed(Duration(milliseconds: wait), _release);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _down(),
      onTapUp: (_) {
        HapticFeedback.lightImpact();
        widget.onTap?.call();
        _up();
      },
      onTapCancel: _up,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) => Transform.scale(
          scale: _c.value.clamp(0.5, 1.15).toDouble(),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

class TrackRow extends StatelessWidget {
  final TrackItem track;
  final AppPalette palette;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onMore;

  const TrackRow({
    super.key,
    required this.track,
    required this.palette,
    required this.active,
    required this.onTap,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return SquishyGesture(
      pressedScale: 0.97,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 54,
                height: 54,
                child: CustomAlbumArtwork(track: track),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? palette.accent : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFA6ADB2),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            if (active)
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 4),
                child: EqBars(color: palette.accent),
              ),
            if (onMore != null)
              SquishyGesture(
                onTap: onMore,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(
                    Icons.more_vert_rounded,
                    color: Colors.white54,
                    size: 20,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class TrackProgress extends StatelessWidget {
  final int fallbackSeconds;
  final Widget Function(
    BuildContext context,
    Duration position,
    Duration duration,
  ) builder;

  const TrackProgress({
    super.key,
    required this.fallbackSeconds,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    final player = audioHandler.player;
    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      initialData: player.duration,
      builder: (context, durSnap) {
        final dur = durSnap.data ?? Duration(seconds: fallbackSeconds);
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          initialData: player.position,
          builder: (context, posSnap) {
            return builder(context, posSnap.data ?? Duration.zero, dur);
          },
        );
      },
    );
  }
}

class MiniPlayer extends StatelessWidget {
  final TrackItem track;
  final AppPalette palette;

  const MiniPlayer({super.key, required this.track, required this.palette});

  @override
  Widget build(BuildContext context) {
    return SquishyGesture(
      pressedScale: 0.97,
      onTap: () => openPlayer(context),
      child: LiquidGlassBox(
        borderRadius: BorderRadius.circular(34),
        fallbackColor: palette.surface,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        boxShadow: _shadow,
        child: SizedBox(
          height: 66,
          child: Row(
            children: [
              SizedBox(
                width: 46,
                height: 46,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    TrackProgress(
                      fallbackSeconds: track.durationSeconds,
                      builder: (_, pos, dur) {
                        final v = dur.inMilliseconds > 0
                            ? (pos.inMilliseconds / dur.inMilliseconds)
                                .clamp(0.0, 1.0)
                            : 0.0;
                        return SizedBox(
                          width: 46,
                          height: 46,
                          child: CircularProgressIndicator(
                            value: v,
                            strokeWidth: 2.6,
                            backgroundColor: const Color(0xFF2E373D),
                            valueColor:
                                AlwaysStoppedAnimation<Color>(palette.accent),
                          ),
                        );
                      },
                    ),
                    Hero(
                      tag: 'now_playing_art',
                      createRectTween: _arcTween,
                      flightShuttleBuilder: _artShuttle,
                      child: ClipOval(
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: CustomAlbumArtwork(track: track),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFB3B9BE),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              SquishyGesture(
                onTap: () => appState.toggleLike(track.id),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: palette.container,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    appState.isLiked(track.id)
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: appState.isLiked(track.id)
                        ? palette.accent
                        : const Color(0xFFD5DCE0),
                    size: 21,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              StreamBuilder<PlaybackState>(
                stream: audioHandler.playbackState,
                builder: (context, snap) {
                  final playing =
                      (snap.data ?? audioHandler.playbackState.value).playing;
                  return SquishyGesture(
                    onTap: () =>
                        playing ? audioHandler.pause() : audioHandler.play(),
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: palette.accent,
                        shape: BoxShape.circle,
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (c, a) => ScaleTransition(
                          scale: a,
                          child: FadeTransition(opacity: a, child: c),
                        ),
                        child: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          key: ValueKey(playing),
                          color: palette.onAccent,
                          size: 26,
                        ),
                      ),
                    ),
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

// ─────────────────────────────────────────────────────────────────────────────
// Now Playing
// ─────────────────────────────────────────────────────────────────────────────

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        appState,
        audioHandler.libraryRevision,
        audioHandler.currentIndex,
      ]),
      builder: (context, _) {
        final pal = appState.palette;
        final track = audioHandler.currentTrack;
        if (track == null) {
          return Scaffold(backgroundColor: pal.playerBg);
        }
        return StreamBuilder<PlaybackState>(
          stream: audioHandler.playbackState,
          builder: (context, snap) {
            final state = snap.data ?? audioHandler.playbackState.value;
            final playing = state.playing;
            final loading =
                state.processingState == AudioProcessingState.loading;
            final shuffle = state.shuffleMode == AudioServiceShuffleMode.all;
            final repeat = state.repeatMode;
            final liked = appState.isLiked(track.id);

            return SwipeDownDismiss(
              child: Scaffold(
                backgroundColor: pal.playerBg,
                body: Stack(
                  children: [
                    AuroraPlasmaBackground(
                      accent: pal.playerAccent,
                      secondary: track.artColors.first,
                      intense: true,
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                SquishyGesture(
                                  onTap: () => Navigator.of(context).pop(),
                                  child: LiquidGlassBox(
                                    borderRadius: BorderRadius.circular(23),
                                    fallbackColor: pal.playerSurface,
                                    child: const SizedBox(
                                      width: 46,
                                      height: 46,
                                      child: Icon(
                                        Icons.keyboard_arrow_down_rounded,
                                        color: Colors.white,
                                        size: 28,
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: Column(
                                      children: [
                                        const Text(
                                          'NOW PLAYING',
                                          style: TextStyle(
                                            color: Color(0xFFE5DDD9),
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 1.0,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          track.album,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 15.5,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                SquishyGesture(
                                  onTap: () =>
                                      showEditTrackDialog(context, track),
                                  child: LiquidGlassBox(
                                    borderRadius: BorderRadius.circular(16),
                                    fallbackColor: pal.playerSurface,
                                    child: const SizedBox(
                                      width: 44,
                                      height: 44,
                                      child: Icon(
                                        Icons.edit_rounded,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SquishyGesture(
                                  onTap: () =>
                                      showAddToPlaylistSheet(context, track),
                                  child: LiquidGlassBox(
                                    borderRadius: BorderRadius.circular(16),
                                    fallbackColor: pal.playerSurface,
                                    child: const SizedBox(
                                      width: 44,
                                      height: 44,
                                      child: Icon(
                                        Icons.more_vert_rounded,
                                        color: Colors.white,
                                        size: 22,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                child: Center(
                                  child: AspectRatio(
                                    aspectRatio: 1.0,
                                    child: AnimatedScale(
                                      scale: playing ? 1.0 : 0.91,
                                      duration: const Duration(
                                        milliseconds: 450,
                                      ),
                                      curve: Curves.easeOutBack,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            appState.vinylSpinMode ? 999 : 28,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: pal.playerAccent
                                                  .withOpacity(
                                                    playing ? 0.22 : 0.06,
                                                  ),
                                              blurRadius: 36,
                                              spreadRadius: 2,
                                            ),
                                            BoxShadow(
                                              color: Colors.black.withOpacity(
                                                0.55,
                                              ),
                                              blurRadius: 24,
                                              offset: const Offset(0, 12),
                                            ),
                                          ],
                                        ),
                                        child: Hero(
                                          tag: 'now_playing_art',
                                          createRectTween: _arcTween,
                                          flightShuttleBuilder: _artShuttle,
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              appState.vinylSpinMode ? 999 : 28,
                                            ),
                                            child: AnimatedSwitcher(
                                              duration: const Duration(
                                                milliseconds: 450,
                                              ),
                                              switchInCurve: kEmphasizedDecel,
                                              transitionBuilder: (c, a) =>
                                                  FadeTransition(
                                                opacity: a,
                                                child: ScaleTransition(
                                                  scale: Tween<double>(
                                                    begin: 0.92,
                                                    end: 1.0,
                                                  ).animate(a),
                                                  child: c,
                                                ),
                                              ),
                                              child: KeyedSubtree(
                                                key: ValueKey(
                                                  '${track.id}_${track.artStyle}',
                                                ),
                                                child: Interactive3DArtwork(
                                                  track: track,
                                                  playing: playing,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Reveal(
                              delayMs: 100,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          track.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 24,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.4,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          track.artist,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Color(0xFFC8BDB7),
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  if (appState.speed != 1.0 ||
                                      appState.pitch != 1.0)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: SquishyGesture(
                                        onTap: () => showPlaybackSheet(context),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: pal.playerAccent.withOpacity(
                                              0.2,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                            border: Border.all(
                                              color: pal.playerAccent,
                                            ),
                                          ),
                                          child: Text(
                                            '${appState.speed.toStringAsFixed(2)}x • ${appState.pitch.toStringAsFixed(2)}p',
                                            style: TextStyle(
                                              color: pal.playerAccent,
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  SquishyGesture(
                                    onTap: () => appState.toggleLike(track.id),
                                    child: LiquidGlassBox(
                                      borderRadius: BorderRadius.circular(26),
                                      fallbackColor: pal.playerSurface,
                                      child: SizedBox(
                                        width: 52,
                                        height: 52,
                                        child: AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 220,
                                          ),
                                          transitionBuilder: (c, a) =>
                                              ScaleTransition(
                                            scale: a,
                                            child: c,
                                          ),
                                          child: Icon(
                                            liked
                                                ? Icons.favorite_rounded
                                                : Icons.favorite_border_rounded,
                                            key: ValueKey(liked),
                                            color: liked
                                                ? pal.playerAccent
                                                : const Color(0xFFEAE0DC),
                                            size: 24,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            Reveal(
                              delayMs: 160,
                              child: WavySeekBar(
                                fallbackSeconds: track.durationSeconds,
                                active: pal.playerAccent,
                                playing: playing,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Reveal(
                              delayMs: 220,
                              child: Row(
                                children: [
                                  SquishyGesture(
                                    onTap: audioHandler.skipToPrevious,
                                    child: LiquidGlassBox(
                                      borderRadius: BorderRadius.circular(35),
                                      fallbackColor: pal.playerButton,
                                      child: const SizedBox(
                                        width: 88,
                                        height: 70,
                                        child: Icon(
                                          Icons.skip_previous_rounded,
                                          color: Color(0xFFF6E6DF),
                                          size: 32,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: SquishyGesture(
                                      pressedScale: 0.94,
                                      onTap: () => playing
                                          ? audioHandler.pause()
                                          : audioHandler.play(),
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 450,
                                        ),
                                        curve: kEmphasized,
                                        height: 70,
                                        decoration: BoxDecoration(
                                          color: pal.playerAccent,
                                          borderRadius: BorderRadius.circular(
                                            playing ? 22 : 35,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: pal.playerAccent
                                                  .withOpacity(0.35),
                                              blurRadius: 18,
                                              offset: const Offset(0, 6),
                                            ),
                                          ],
                                        ),
                                        child: loading
                                            ? Center(
                                                child: SizedBox(
                                                  width: 26,
                                                  height: 26,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 3,
                                                    color: pal.playerOnAccent,
                                                  ),
                                                ),
                                              )
                                            : AnimatedSwitcher(
                                                duration: const Duration(
                                                  milliseconds: 200,
                                                ),
                                                transitionBuilder: (c, a) =>
                                                    ScaleTransition(
                                                  scale: a,
                                                  child: FadeTransition(
                                                    opacity: a,
                                                    child: c,
                                                  ),
                                                ),
                                                child: Icon(
                                                  playing
                                                      ? Icons.pause_rounded
                                                      : Icons
                                                          .play_arrow_rounded,
                                                  key: ValueKey(playing),
                                                  color: pal.playerOnAccent,
                                                  size: 36,
                                                ),
                                              ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  SquishyGesture(
                                    onTap: audioHandler.skipToNext,
                                    child: LiquidGlassBox(
                                      borderRadius: BorderRadius.circular(35),
                                      fallbackColor: pal.playerButton,
                                      child: const SizedBox(
                                        width: 88,
                                        height: 70,
                                        child: Icon(
                                          Icons.skip_next_rounded,
                                          color: Color(0xFFF6E6DF),
                                          size: 32,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            Reveal(
                              delayMs: 280,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(26),
                                child: SizedBox(
                                  height: 52,
                                  child: Row(
                                    children: [
                                      _segBtn(
                                        pal,
                                        Icons.info_rounded,
                                        false,
                                        () =>
                                            showTrackInfoDialog(context, track),
                                        isFirst: true,
                                      ),
                                      const SizedBox(width: 3),
                                      _segBtn(
                                        pal,
                                        Icons.tune_rounded,
                                        appState.speed != 1.0 ||
                                            appState.pitch != 1.0,
                                        () => showPlaybackSheet(context),
                                      ),
                                      const SizedBox(width: 3),
                                      _segBtn(
                                        pal,
                                        Icons.shuffle_rounded,
                                        shuffle,
                                        () {
                                          audioHandler.setShuffleMode(
                                            shuffle
                                                ? AudioServiceShuffleMode.none
                                                : AudioServiceShuffleMode.all,
                                          );
                                        },
                                      ),
                                      const SizedBox(width: 3),
                                      _segBtn(
                                        pal,
                                        repeat == AudioServiceRepeatMode.one
                                            ? Icons.repeat_one_rounded
                                            : Icons.repeat_rounded,
                                        repeat != AudioServiceRepeatMode.none,
                                        () {
                                          final next = switch (repeat) {
                                            AudioServiceRepeatMode.none =>
                                              AudioServiceRepeatMode.all,
                                            AudioServiceRepeatMode.all =>
                                              AudioServiceRepeatMode.one,
                                            _ => AudioServiceRepeatMode.none,
                                          };
                                          audioHandler.setRepeatMode(next);
                                        },
                                      ),
                                      const SizedBox(width: 3),
                                      _segBtn(
                                        pal,
                                        Icons.playlist_add_rounded,
                                        false,
                                        () => showAddToPlaylistSheet(
                                          context,
                                          track,
                                        ),
                                      ),
                                      const SizedBox(width: 3),
                                      _segBtn(
                                        pal,
                                        Icons.queue_music_rounded,
                                        false,
                                        () => showQueueSheet(context),
                                      ),
                                      const SizedBox(width: 3),
                                      _segBtn(
                                        pal,
                                        Icons.album_rounded,
                                        appState.vinylSpinMode,
                                        () => appState.setVinylSpinMode(
                                          !appState.vinylSpinMode,
                                        ),
                                        isLast: true,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _segBtn(
    AppPalette pal,
    IconData icon,
    bool active,
    VoidCallback onTap, {
    bool isFirst = false,
    bool isLast = false,
  }) {
    return Expanded(
      child: SquishyGesture(
        pressedScale: 0.9,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          height: 52,
          decoration: BoxDecoration(
            color: active ? pal.playerButton : pal.playerSurface,
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(isFirst ? 26 : 6),
              right: Radius.circular(isLast ? 26 : 6),
            ),
          ),
          child: Icon(
            icon,
            color: active ? pal.playerAccent : const Color(0xFFEAE0DC),
            size: 21,
          ),
        ),
      ),
    );
  }
}

class WavySeekBar extends StatefulWidget {
  final int fallbackSeconds;
  final Color active;
  final bool playing;

  const WavySeekBar({
    super.key,
    required this.fallbackSeconds,
    required this.active,
    required this.playing,
  });

  @override
  State<WavySeekBar> createState() => _WavySeekBarState();
}

class _WavySeekBarState extends State<WavySeekBar>
    with SingleTickerProviderStateMixin {
  double? _drag;
  late final AnimationController _waveCtrl;

  @override
  void initState() {
    super.initState();
    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _waveCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TrackProgress(
      fallbackSeconds: widget.fallbackSeconds,
      builder: (context, pos, dur) {
        final maxMs = max(dur.inMilliseconds, 1).toDouble();
        final value = (_drag ?? pos.inMilliseconds.toDouble())
            .clamp(0.0, maxMs)
            .toDouble();
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
                    onHorizontalDragStart: (d) {
                      final f = (d.localPosition.dx / w).clamp(0.0, 1.0);
                      setState(() => _drag = f * maxMs);
                    },
                    onHorizontalDragUpdate: (d) {
                      final f = (d.localPosition.dx / w).clamp(0.0, 1.0);
                      setState(() => _drag = f * maxMs);
                    },
                    onHorizontalDragEnd: (_) {
                      if (_drag != null) {
                        audioHandler.seek(
                          Duration(milliseconds: _drag!.toInt()),
                        );
                        setState(() => _drag = null);
                      }
                    },
                    onTapDown: (d) {
                      final f = (d.localPosition.dx / w).clamp(0.0, 1.0);
                      audioHandler.seek(
                        Duration(milliseconds: (f * maxMs).toInt()),
                      );
                    },
                    child: AnimatedBuilder(
                      animation: _waveCtrl,
                      builder: (context, _) {
                        return CustomPaint(
                          painter: _WavyTrackPainter(
                            progress: frac,
                            phase: _waveCtrl.value * 2 * pi,
                            activeColor: widget.active,
                            inactiveColor: Colors.white24,
                            waveAmplitude: widget.playing ? 4.2 : 0.0,
                          ),
                          size: Size(w, 32),
                        );
                      },
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
                  Text(
                    formatDuration(shown),
                    style: const TextStyle(
                      color: Color(0xFFC8BDB7),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    formatDuration(dur),
                    style: const TextStyle(
                      color: Color(0xFFC8BDB7),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
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
  final double progress;
  final double phase;
  final Color activeColor;
  final Color inactiveColor;
  final double waveAmplitude;

  const _WavyTrackPainter({
    required this.progress,
    required this.phase,
    required this.activeColor,
    required this.inactiveColor,
    required this.waveAmplitude,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final activeX = size.width * progress;

    final inactivePaint = Paint()
      ..color = inactiveColor
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;
    if (activeX < size.width) {
      canvas.drawLine(
        Offset(activeX, cy),
        Offset(size.width, cy),
        inactivePaint,
      );
    }

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;

    final path = Path();
    path.moveTo(0, cy);
    const wavelength = 28.0;
    for (double x = 0; x <= activeX; x += 2.0) {
      final y = cy + sin((x / wavelength) * 2 * pi - phase) * waveAmplitude;
      path.lineTo(x, y);
    }
    canvas.drawPath(path, activePaint);

    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(activeX, cy), width: 10, height: 22),
      const Radius.circular(6),
    );
    canvas.drawRRect(thumbRect, Paint()..color = activeColor);
  }

  @override
  bool shouldRepaint(covariant _WavyTrackPainter old) =>
      old.progress != progress ||
      old.phase != phase ||
      old.waveAmplitude != waveAmplitude ||
      old.activeColor != activeColor;
}

// ─────────────────────────────────────────────────────────────────────────────
// Sheets & Dialogs
// ─────────────────────────────────────────────────────────────────────────────

Future<dynamic> _sheet(
  BuildContext context,
  WidgetBuilder builder, {
  bool scroll = false,
  Color? color,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: scroll,
    showDragHandle: true,
    backgroundColor: color ?? appState.palette.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: builder,
  );
}

Widget _sheetTile(
  AppPalette pal,
  IconData icon,
  String title,
  String subtitle,
  VoidCallback onTap,
) {
  return SquishyGesture(
    pressedScale: 0.97,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: pal.container,
            child: Icon(icon, color: pal.accent),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFFA6ADB2),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

void showAddToPlaylistSheet(BuildContext context, TrackItem track) {
  _sheet(
    context,
    (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final pal = appState.palette;
        final pls = appState.playlists;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 46,
                        height: 46,
                        child: CustomAlbumArtwork(track: track),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: pal.accent,
                        foregroundColor: pal.onAccent,
                      ),
                      onPressed: () {
                        showCreateOrEditPlaylistDialog(
                          context,
                          initialTrackId: track.id,
                        );
                      },
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('New Playlist'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'ADD TO PLAYLIST',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                if (pls.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: Text(
                        'No playlists yet — tap "New Playlist" above!',
                        style: TextStyle(color: Colors.white60),
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: pls.length,
                      itemBuilder: (_, i) {
                        final pl = pls[i];
                        final added = appState.inPlaylist(pl.id, track.id);
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: PlaylistCoverThumbnail(
                            playlist: pl,
                            size: 46,
                          ),
                          title: Text(
                            pl.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Text(
                            '${pl.trackIds.length} songs',
                            style: const TextStyle(color: Colors.white54),
                          ),
                          trailing: Icon(
                            added
                                ? Icons.check_circle_rounded
                                : Icons.add_circle_outline_rounded,
                            color: added ? pal.accent : Colors.white54,
                            size: 26,
                          ),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            appState.togglePlaylistTrack(pl.id, track.id);
                          },
                        );
                      },
                    ),
                  ),
                const Divider(color: Colors.white12, height: 24),
                SquishyGesture(
                  pressedScale: 0.97,
                  onTap: () async {
                    Navigator.pop(ctx);
                    await audioHandler.deleteTrackFromLibrary(track);
                    appNotice.value = 'Deleted "${track.title}" from library.';
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: Colors.redAccent.withOpacity(0.45),
                      ),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.delete_forever_rounded,
                          color: Colors.redAccent,
                          size: 22,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Delete Song from Library',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
    scroll: true,
  );
}

void showCreateOrEditPlaylistDialog(
  BuildContext context, {
  Playlist? existing,
  String? initialTrackId,
}) {
  final pal = appState.palette;
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  String? coverPath = existing?.cover;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: pal.surface,
        title: Text(
          existing == null ? 'Create Playlist' : 'Edit Playlist',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SquishyGesture(
                onTap: () async {
                  final picked = await pickAndSaveGalleryImage();
                  if (picked != null) {
                    setDialogState(() => coverPath = picked);
                  }
                },
                child: Column(
                  children: [
                    Container(
                      width: 112,
                      height: 112,
                      decoration: BoxDecoration(
                        color: pal.container,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: pal.accent.withOpacity(0.5),
                          width: 1.5,
                        ),
                      ),
                      child: (coverPath != null && File(coverPath!).existsSync())
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(22),
                              child: Image.file(
                                File(coverPath!),
                                fit: BoxFit.cover,
                              ),
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.add_photo_alternate_rounded,
                                  color: pal.accent,
                                  size: 36,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Pick Gallery Icon',
                                  style: TextStyle(
                                    color: pal.accent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                    ),
                    if (coverPath != null)
                      TextButton(
                        onPressed: () => setDialogState(() => coverPath = null),
                        child: const Text(
                          'Remove custom photo',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: nameCtrl,
                autofocus: existing == null,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Playlist Name',
                  labelStyle: const TextStyle(color: Colors.white70),
                  filled: true,
                  fillColor: pal.container,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: pal.accent,
              foregroundColor: pal.onAccent,
            ),
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (existing == null) {
                final created = appState.createPlaylist(
                  name.isEmpty ? 'My Playlist' : name,
                  cover: coverPath,
                );
                if (initialTrackId != null) {
                  appState.addToPlaylist(created.id, initialTrackId);
                }
              } else {
                appState.setPlaylistInfo(
                  existing.id,
                  name.isEmpty ? existing.name : name,
                  coverPath,
                );
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

void showAddTracksToPlaylistPicker(BuildContext context, Playlist pl) {
  _sheet(
    context,
    (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.75,
      child: ListenableBuilder(
        listenable: appState,
        builder: (ctx, _) {
          final pal = appState.palette;
          final tracks = audioHandler.tracks;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add Songs to "${pl.name}"',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    itemCount: tracks.length,
                    itemBuilder: (_, i) {
                      final t = tracks[i];
                      final inPl = appState.inPlaylist(pl.id, t.id);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 46,
                            height: 46,
                            child: CustomAlbumArtwork(track: t),
                          ),
                        ),
                        title: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white60),
                        ),
                        trailing: Icon(
                          inPl
                              ? Icons.check_circle_rounded
                              : Icons.add_circle_outline_rounded,
                          color: inPl ? pal.accent : Colors.white54,
                        ),
                        onTap: () => appState.togglePlaylistTrack(pl.id, t.id),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
    scroll: true,
  );
}

void showArtistTracksSheet(
  BuildContext context,
  String artist,
  List<TrackItem> tracks,
) {
  final pal = appState.palette;
  _sheet(
    context,
    (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.65,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              artist,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              '${tracks.length} songs',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: tracks.length,
                itemBuilder: (_, i) {
                  final t = tracks[i];
                  return TrackRow(
                    track: t,
                    palette: pal,
                    active: audioHandler.currentTrack?.id == t.id,
                    onTap: () {
                      Navigator.pop(ctx);
                      final idx = audioHandler.tracks.indexOf(t);
                      playAndOpen(context, idx);
                    },
                    onMore: () => showAddToPlaylistSheet(context, t),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
    scroll: true,
  );
}

void showAddMusicSheet(BuildContext context) {
  final pal = appState.palette;
  _sheet(
    context,
    (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add Music to AlexLMP',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            _sheetTile(
              pal,
              Icons.cloud_download_rounded,
              'Direct Song & yt-dlp Downloader',
              'Type Song Name or paste Spotify, YouTube, or MP3 link',
              () {
                Navigator.pop(ctx);
                showDirectUrlDownloadSheet(context);
              },
            ),
            _sheetTile(
              pal,
              Icons.wifi_tethering_rounded,
              'Toggle Wi-Fi PC/Phone Drop Server',
              wifiServerUrl.value != null
                  ? 'Active at ${wifiServerUrl.value} (Tap to stop)'
                  : 'Send songs from PC or phone browser straight into AlexLMP',
              () async {
                Navigator.pop(ctx);
                await toggleWifiDropServer();
                if (wifiServerUrl.value != null) {
                  appNotice.value =
                      'Wi-Fi Drop active! Open ${wifiServerUrl.value} in browser.';
                }
              },
            ),
            _sheetTile(
              pal,
              Icons.download_done_rounded,
              'Quick-Import Phone Downloads Folder',
              'Grab all audio files inside /Download & /Music automatically',
              () async {
                Navigator.pop(ctx);
                final added = await quickImportPhoneDownloadsFolder();
                appNotice.value = added > 0
                    ? 'Imported $added new track(s) from Phone Downloads!'
                    : 'No new audio files found in Phone Downloads.';
              },
            ),
            _sheetTile(
              pal,
              Icons.folder_open_rounded,
              'Pick Local Audio Files',
              'Import MP3, FLAC, WAV, M4A from device',
              () {
                Navigator.pop(ctx);
                pickLocalFiles();
              },
            ),
            _sheetTile(
              pal,
              Icons.radar_rounded,
              'Scan Device Music',
              'Index all music files on phone storage',
              () {
                Navigator.pop(ctx);
                scanDeviceAudio();
              },
            ),
          ],
        ),
      ),
    ),
  );
}

void showSettingsSheet(BuildContext context) {
  _sheet(
    context,
    (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final pal = appState.palette;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'AlexLMP Settings',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Made by Alex Desrosier',
                    style: TextStyle(
                      fontSize: 14,
                      color: pal.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Color Theme (Includes True AMOLED)',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: AppPalette.all.map((t) {
                      final selected = appState.themeName == t.name;
                      return Expanded(
                        child: SquishyGesture(
                          onTap: () => appState.setTheme(t.name),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: selected ? t.accent : pal.container,
                              borderRadius: BorderRadius.circular(14),
                              border: t.name == 'AMOLED'
                                  ? Border.all(
                                      color: Colors.white30,
                                      width: 1,
                                    )
                                  : null,
                            ),
                            child: Column(
                              children: [
                                Container(
                                  width: 14,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    color: t.name == 'AMOLED'
                                        ? Colors.black
                                        : (selected ? t.onAccent : t.accent),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white38,
                                      width: 1,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  t.name.split(' ').first,
                                  style: TextStyle(
                                    color: selected ? t.onAccent : Colors.white,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Row(
                      children: [
                        const Text(
                          'iOS 27 Liquid Glass UI',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: pal.accent.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: pal.accent),
                          ),
                          child: Text(
                            'BETA',
                            style: TextStyle(
                              color: pal.accent,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                    subtitle: const Text(
                      'Experimental frosted blur cards & aurora plasma mesh (Off by default)',
                    ),
                    value: appState.liquidGlass,
                    activeColor: pal.accent,
                    onChanged: appState.setLiquidGlass,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Spinning Vinyl Artwork Mode',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'Rotates album art like a turntable record (or double-tap art)',
                    ),
                    value: appState.vinylSpinMode,
                    activeColor: pal.accent,
                    onChanged: appState.setVinylSpinMode,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Stop music on task clear'),
                    subtitle: const Text(
                      'Stops playback when swiped away from recents',
                    ),
                    value: appState.stopOnTaskClear,
                    activeColor: pal.accent,
                    onChanged: appState.setStopOnTaskClear,
                  ),
                  _sheetTile(
                    pal,
                    Icons.refresh_rounded,
                    'Rescan music library',
                    'Pick up newly added songs',
                    () {
                      Navigator.pop(ctx);
                      scanDeviceAudio();
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
    scroll: true,
  );
}

void showPlaybackSheet(BuildContext context) {
  _sheet(
    context,
    (ctx) => ListenableBuilder(
      listenable: appState,
      builder: (ctx, _) {
        final pal = appState.palette;
        final semitones = (12 * (log(appState.pitch) / ln2)).round();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Speed & Pitch Shifter',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    SquishyGesture(
                      onTap: () {
                        appState.setSpeed(1.0);
                        appState.setPitch(1.0);
                        audioHandler.setSpeed(1.0);
                        audioHandler.setPitch(1.0);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          'Reset',
                          style: TextStyle(
                            color: pal.playerAccent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    'Link Speed & Pitch (Vinyl / Nightcore Mode)',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                  subtitle: const Text(
                    'Shifts pitch & tempo together like a real turntable',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  value: appState.linkSpeedAndPitch,
                  activeColor: pal.playerAccent,
                  onChanged: (v) {
                    appState.setLinkSpeedAndPitch(v);
                    if (v) {
                      appState.setSpeed(appState.pitch);
                      audioHandler.setSpeed(appState.pitch);
                    }
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  'Speed: ${appState.speed.toStringAsFixed(2)}x',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Slider(
                  value: appState.speed.clamp(0.5, 2.0),
                  min: 0.5,
                  max: 2.0,
                  divisions: 30,
                  activeColor: pal.playerAccent,
                  onChanged: (v) {
                    appState.setSpeed(v);
                    audioHandler.setSpeed(v);
                    if (appState.linkSpeedAndPitch) {
                      appState.setPitch(v);
                      audioHandler.setPitch(v);
                    }
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  'Pitch: ${appState.pitch.toStringAsFixed(2)}x  (${semitones >= 0 ? '+$semitones' : '$semitones'} semitones)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Slider(
                  value: appState.pitch.clamp(0.5, 2.0),
                  min: 0.5,
                  max: 2.0,
                  divisions: 60,
                  activeColor: pal.playerAccent,
                  onChanged: (v) {
                    appState.setPitch(v);
                    audioHandler.setPitch(v);
                    if (appState.linkSpeedAndPitch) {
                      appState.setSpeed(v);
                      audioHandler.setSpeed(v);
                    }
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [-6, -3, -1, 0, 1, 3, 6].map((st) {
                    final targetPitch = pow(2.0, st / 12.0).toDouble();
                    final active = (appState.pitch - targetPitch).abs() < 0.02;
                    return ChoiceChip(
                      label: Text(
                        st == 0 ? '0 st' : (st > 0 ? '+$st st' : '$st st'),
                      ),
                      selected: active,
                      showCheckmark: false,
                      selectedColor: pal.playerAccent,
                      backgroundColor: pal.playerButton,
                      labelStyle: TextStyle(
                        color: active ? pal.playerOnAccent : Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                      onSelected: (_) {
                        appState.setPitch(targetPitch);
                        audioHandler.setPitch(targetPitch);
                        if (appState.linkSpeedAndPitch) {
                          appState.setSpeed(targetPitch);
                          audioHandler.setSpeed(targetPitch);
                        }
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      },
    ),
    color: appState.palette.playerSurface,
  );
}

void showQueueSheet(BuildContext context) {
  _sheet(
    context,
    (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.7,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          audioHandler.libraryRevision,
          audioHandler.currentIndex,
          appState,
        ]),
        builder: (ctx, _) {
          final pal = appState.palette;
          final tracks = audioHandler.tracks;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              children: [
                const Text(
                  'Reorder Queue',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
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
                        contentPadding: EdgeInsets.zero,
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: CustomAlbumArtwork(track: t),
                          ),
                        ),
                        title: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: active ? pal.playerAccent : Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        trailing: ReorderableDragStartListener(
                          index: i,
                          child: const Icon(
                            Icons.drag_handle_rounded,
                            color: Colors.white54,
                          ),
                        ),
                        onTap: () => audioHandler.playIndex(i),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
    scroll: true,
    color: appState.palette.playerSurface,
  );
}

void showTrackInfoDialog(BuildContext context, TrackItem track) {
  final pal = appState.palette;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: pal.playerSurface,
      title: Text(track.title, style: const TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Artist: ${track.artist}',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 6),
          Text(
            'Album: ${track.album}',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 6),
          Text(
            'File: ${track.filePath ?? track.source}',
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text('Close', style: TextStyle(color: pal.playerAccent)),
        ),
      ],
    ),
  );
}

Widget _styleChips(
  String selected,
  ValueChanged<String> onSelect,
  AppPalette pal,
) {
  const labels = {
    'vinyl_record': 'Vinyl Record',
    'sound_wave': 'Sound Wave',
    'music_note_grid': 'Music Notes',
    'equalizer_bars': 'Equalizer Bars',
    'neon_vinyl': 'Neon Vinyl',
  };
  return Wrap(
    spacing: 8,
    runSpacing: 8,
    children: labels.entries.map((e) {
      final sel = selected == e.key;
      return ChoiceChip(
        label: Text(e.value),
        selected: sel,
        showCheckmark: false,
        selectedColor: pal.accent,
        backgroundColor: pal.container,
        labelStyle: TextStyle(
          color: sel ? pal.onAccent : Colors.white,
          fontWeight: FontWeight.w600,
        ),
        side: BorderSide.none,
        onSelected: (_) => onSelect(e.key),
      );
    }).toList(),
  );
}

void showEditTrackDialog(BuildContext context, TrackItem track) {
  final pal = appState.palette;
  final titleCtrl = TextEditingController(text: track.title);
  final artistCtrl = TextEditingController(text: track.artist);
  String style = track.artStyle;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: pal.surface,
        title: const Text(
          'Edit Song Details',
          style: TextStyle(color: Colors.white),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: titleCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Song Title',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: artistCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Artist Name',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Album art style',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 8),
              _styleChips(style, (s) => setDialogState(() => style = s), pal),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: pal.accent,
              foregroundColor: pal.onAccent,
            ),
            onPressed: () {
              final title = titleCtrl.text.trim();
              final artist = artistCtrl.text.trim();
              if (title.isNotEmpty) track.title = title;
              if (artist.isNotEmpty) track.artist = artist;
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

void showPlaylistEditDialog(BuildContext context) {
  final pal = appState.palette;
  final nameCtrl = TextEditingController(text: appState.playlistName);
  String style = appState.playlistStyle;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: pal.surface,
        title: const Text(
          'Edit Mix Title',
          style: TextStyle(color: Colors.white),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Mix Title',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Cover style',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 8),
              _styleChips(style, (s) => setDialogState(() => style = s), pal),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: pal.accent,
              foregroundColor: pal.onAccent,
            ),
            onPressed: () {
              final name = nameCtrl.text.trim();
              appState.setPlaylist(
                name.isEmpty ? appState.playlistName : name,
                style,
              );
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

void showSearchSheet(BuildContext context) {
  _sheet(
    context,
    (ctx) => SearchSheet(parentContext: context),
    scroll: true,
    color: appState.palette.bg,
  );
}

class SearchSheet extends StatefulWidget {
  final BuildContext parentContext;
  const SearchSheet({super.key, required this.parentContext});

  @override
  State<SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<SearchSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final pal = appState.palette;
    final tracks = audioHandler.tracks;
    final q = _query.toLowerCase();
    final filtered = tracks.where((t) {
      return t.title.toLowerCase().contains(q) ||
          t.artist.toLowerCase().contains(q) ||
          t.album.toLowerCase().contains(q);
    }).toList();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Column(
            children: [
              TextField(
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search songs & artists...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  prefixIcon: Icon(Icons.search, color: pal.accent),
                  filled: true,
                  fillColor: pal.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: filtered.isEmpty
                    ? const Center(
                        child: Text(
                          'No songs found.',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final t = filtered[i];
                          return TrackRow(
                            track: t,
                            palette: pal,
                            active: audioHandler.currentTrack?.id == t.id,
                            onTap: () {
                              final idx = tracks.indexOf(t);
                              Navigator.pop(context);
                              playAndOpen(widget.parentContext, idx);
                            },
                            onMore: () => showAddToPlaylistSheet(context, t),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Artwork
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
    final res = await _mediaChannel.invokeMethod('getArt', {
      'uri': t.source,
      'path': t.filePath ?? '',
    });
    if (res is Uint8List) return res;
    return null;
  } catch (_) {
    return null;
  }
}

class CustomAlbumArtwork extends StatelessWidget {
  final TrackItem track;

  const CustomAlbumArtwork({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final placeholder = CustomPaint(
      painter: _ArtworkSymbolPainter(
        style: track.artStyle,
        colors: track.artColors,
      ),
      child: const SizedBox.expand(),
    );
    return FutureBuilder<Uint8List?>(
      future: loadArt(track),
      builder: (context, snap) {
        final bytes = snap.data;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: (bytes != null && bytes.isNotEmpty)
              ? SizedBox.expand(
                  key: ValueKey('art_${track.id}'),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    cacheWidth: 512,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => placeholder,
                  ),
                )
              : SizedBox.expand(
                  key: ValueKey('ph_${track.id}'),
                  child: placeholder,
                ),
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
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(rect),
    );

    final center = Offset(size.width / 2, size.height / 2);
    final s = size.shortestSide;

    if (style == 'vinyl_record') {
      final groove = Paint()
        ..color = Colors.white.withOpacity(0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1.0, s * 0.01);
      for (double r = s * 0.15; r < s * 0.45; r += s * 0.05) {
        canvas.drawCircle(center, r, groove);
      }
      canvas.drawCircle(
        center,
        s * 0.12,
        Paint()..color = const Color(0xFFFFB59C),
      );
      canvas.drawCircle(center, s * 0.03, Paint()..color = Colors.black);
    } else if (style == 'sound_wave') {
      final wave = Paint()
        ..color = const Color(0xFF8CD0F0)
        ..strokeWidth = max(1.5, s * 0.015)
        ..strokeCap = StrokeCap.round;
      const bars = [0.09, 0.17, 0.26, 0.34, 0.21, 0.13, 0.30, 0.20, 0.11];
      double x = size.width * 0.15;
      for (final h in bars) {
        canvas.drawLine(
          Offset(x, center.dy - s * h),
          Offset(x, center.dy + s * h),
          wave,
        );
        x += size.width * 0.08;
      }
    } else if (style == 'music_note_grid') {
      final k = s / 90;
      final note = Paint()..color = Colors.white;
      final stem = Paint()
        ..color = Colors.white
        ..strokeWidth = max(1.5, 3 * k);
      canvas.drawCircle(
        Offset(center.dx - 15 * k, center.dy + 10 * k),
        8 * k,
        note,
      );
      canvas.drawCircle(
        Offset(center.dx + 15 * k, center.dy + 5 * k),
        8 * k,
        note,
      );
      canvas.drawLine(
        Offset(center.dx - 7 * k, center.dy + 10 * k),
        Offset(center.dx - 7 * k, center.dy - 15 * k),
        stem,
      );
      canvas.drawLine(
        Offset(center.dx + 23 * k, center.dy + 5 * k),
        Offset(center.dx + 23 * k, center.dy - 20 * k),
        stem,
      );
      canvas.drawLine(
        Offset(center.dx - 7 * k, center.dy - 15 * k),
        Offset(center.dx + 23 * k, center.dy - 20 * k),
        stem,
      );
    } else if (style == 'equalizer_bars') {
      final bar = Paint()..strokeWidth = max(2.0, s * 0.045);
      const heights = [0.3, 0.6, 0.9, 0.5, 0.7, 0.4];
      double x = size.width * 0.2;
      for (int i = 0; i < heights.length; i++) {
        bar.color =
            i % 2 == 0 ? const Color(0xFF8CD0F0) : const Color(0xFFFFB59C);
        final h = size.height * 0.4 * heights[i];
        canvas.drawLine(
          Offset(x, center.dy + h),
          Offset(x, center.dy - h),
          bar,
        );
        x += size.width * 0.12;
      }
    } else if (style == 'neon_vinyl') {
      final neon = Paint()
        ..color = const Color(0xFFF09CE2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(2.0, s * 0.02);
      canvas.drawCircle(center, s * 0.35, neon);
      canvas.drawCircle(center, s * 0.22, neon);
      canvas.drawCircle(
        center,
        s * 0.08,
        Paint()..color = const Color(0xFF9CF0C0),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ArtworkSymbolPainter old) =>
      old.style != style || old.colors != colors;
}
