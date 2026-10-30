import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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
// Helpers
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

Future<String?> pickAndSaveGalleryImage() async {
  try {
    final res = await FilePicker.platform.pickFiles(type: FileType.image);
    if (res == null || res.files.isEmpty) return null;
    final srcPath = res.files.single.path;
    if (srcPath == null) return null;
    final dir = await getApplicationDocumentsDirectory();
    final ext = p.extension(srcPath).isEmpty ? '.jpg' : p.extension(srcPath);
    final dst = p.join(dir.path, 'pl_cover_${DateTime.now().microsecondsSinceEpoch}$ext');
    await File(srcPath).copy(dst);
    return dst;
  } catch (_) {
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// App UI Core (Material 3)
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

void openPlayer(BuildContext context) {
  if (audioHandler.tracks.isEmpty) {
    appNotice.value = 'No tracks in library yet.';
    return;
  }
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 520),
      reverseTransitionDuration: const Duration(milliseconds: 360),
      pageBuilder: (_, __, ___) => const NowPlayingScreen(),
      transitionsBuilder: (_, anim, __, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(curved),
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
      listenable: Listenable.merge([audioHandler.currentIndex, audioHandler.libraryRevision]),
      builder: (context, _) {
        final track = audioHandler.currentTrack;
        final hasMiniPlayer = track != null;

        return Scaffold(
          body: Stack(
            children: [
              IndexedStack(
                index: _currentIndex,
                children: const [HomeTab(), DiscoverDownloadTab(), LibraryTab()],
              ),
              if (hasMiniPlayer)
                Positioned(
                  left: 12, right: 12, bottom: 8, // Just above NavBar
                  child: Reveal(dy: 40, child: MiniPlayer(track: track)),
                ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (i) => setState(() => _currentIndex = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore_rounded), label: 'Discover'),
              NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music_rounded), label: 'Library'),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Home Tab
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
            IconButton(icon: const Icon(Icons.settings_rounded), onPressed: () => showSettingsSheet(context)),
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
                  const Text('No songs found yet.', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Go to the Discover tab to download music, or scan your phone in Settings.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text('Quick Picks', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold)),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 2.8,
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
                          SizedBox(width: 56, height: 56, child: CustomAlbumArtwork(track: t)),
                          const SizedBox(width: 12),
                          Expanded(child: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  );
                },
                childCount: math.min(tracks.length, 6),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text('Recently Added', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold)),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final t = tracks.reversed.toList()[i];
                final realIndex = tracks.indexOf(t);
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: t))),
                  title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(icon: const Icon(Icons.more_vert_rounded), onPressed: () => showAddToPlaylistSheet(context, t)),
                  onTap: () => playAndOpen(context, realIndex),
                );
              },
              childCount: math.min(tracks.length, 20),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 180)),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Discover & Download Tab
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
    if (ok) appNotice.value = 'Downloaded file from browser!';
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
              const Text('Download Music', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Type a Song Name, or paste a Spotify, YouTube, or MP3 link to download directly to your library.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
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
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                ),
                onSubmitted: (v) => _startDownload(v),
              ),
              const SizedBox(height: 24),
              if (busy) ...[
                Text(downloadStatus.value ?? 'Downloading...', style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: downloadProgress.value, borderRadius: BorderRadius.circular(8), minHeight: 8),
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
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16)),
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
// Library Tab
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
    return ListenableBuilder(
      listenable: wifiServerUrl,
      builder: (context, _) {
        final wifiUrl = wifiServerUrl.value;
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
                  icon: Icon(wifiUrl != null ? Icons.wifi_tethering : Icons.wifi_tethering_off),
                  color: wifiUrl != null ? Theme.of(context).colorScheme.primary : null,
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
              child: SizedBox(width: 48, height: 48, child: CustomAlbumArtwork(track: t)),
            ),
            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(icon: const Icon(Icons.more_vert_rounded), onPressed: () => showAddToPlaylistSheet(context, t)),
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
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlistId: pl.id))),
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
              child: ClipOval(child: SizedBox(width: 56, height: 56, child: CustomAlbumArtwork(track: e.value.first))),
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
// MiniPlayer & WavySeekBar
// ─────────────────────────────────────────────────────────────────────────────

class MiniPlayer extends StatelessWidget {
  final TrackItem track;
  const MiniPlayer({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => openPlayer(context),
      borderRadius: BorderRadius.circular(34),
      child: Container(
        height: 66,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(34),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Row(
          children: [
            SizedBox(
              width: 46, height: 46,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  TrackProgress(
                    fallbackSeconds: track.durationSeconds,
                    builder: (_, pos, dur) {
                      final v = dur.inMilliseconds > 0 ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0) : 0.0;
                      return SizedBox(width: 46, height: 46, child: CircularProgressIndicator(value: v, strokeWidth: 2.6, backgroundColor: Colors.black26, valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary)));
                    },
                  ),
                  Hero(
                    tag: 'now_playing_art',
                    child: ClipOval(child: SizedBox(width: 36, height: 36, child: CustomAlbumArtwork(track: track))),
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
                  Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            IconButton(
              icon: Icon(appState.isLiked(track.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: appState.isLiked(track.id) ? colorScheme.primary : null),
              onPressed: () => appState.toggleLike(track.id),
            ),
            StreamBuilder<PlaybackState>(
              stream: audioHandler.playbackState,
              builder: (context, snap) {
                final playing = (snap.data ?? audioHandler.playbackState.value).playing;
                return IconButton(
                  style: IconButton.styleFrom(backgroundColor: colorScheme.primaryContainer, foregroundColor: colorScheme.onPrimaryContainer),
                  icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  onPressed: () => playing ? audioHandler.pause() : audioHandler.play(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class TrackProgress extends StatelessWidget {
  final int fallbackSeconds;
  final Widget Function(BuildContext context, Duration position, Duration duration) builder;
  const TrackProgress({super.key, required this.fallbackSeconds, required this.builder});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: audioHandler.player.durationStream,
      initialData: audioHandler.player.duration,
      builder: (context, durSnap) {
        final dur = durSnap.data ?? Duration(seconds: fallbackSeconds);
        return StreamBuilder<Duration>(
          stream: audioHandler.player.positionStream,
          initialData: audioHandler.player.position,
          builder: (context, posSnap) => builder(context, posSnap.data ?? Duration.zero, dur),
        );
      },
    );
  }
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

  @override
  void initState() {
    super.initState();
    _waveCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  }
  @override void dispose() { _waveCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return TrackProgress(
      fallbackSeconds: widget.fallbackSeconds,
      builder: (context, pos, dur) {
        final maxMs = math.max(dur.inMilliseconds, 1).toDouble();
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
                          progress: frac, phase: _waveCtrl.value * 2 * math.pi,
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
      path.lineTo(x, cy + math.sin((x / 28.0) * 2 * math.pi - phase) * waveAmplitude);
    }
    canvas.drawPath(path, activePaint);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(activeX, cy), width: 10, height: 22), const Radius.circular(6)), Paint()..color = activeColor);
  }
  @override bool shouldRepaint(covariant _WavyTrackPainter old) => old.progress != progress || old.phase != phase || old.waveAmplitude != waveAmplitude || old.activeColor != activeColor;
}

// ─────────────────────────────────────────────────────────────────────────────
// Utilities & Artwork Code (unchanged logic, consolidated spacing)
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

    if (resp.statusCode < 200 || resp.statusCode >= 400) return false;

    var safeName = '$artist - $title'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safeName.isEmpty) safeName = 'Track_${DateTime.now().millisecondsSinceEpoch}';

    final dir = await _getMusicDownloadsDir();
    final savePath = p.join(dir.path, '$safeName$ext');
    final outFile = File(savePath);
    final sink = outFile.openWrite();

    final totalBytes = resp.contentLength;
    int received = 0;

    await for (final chunk in resp.timeout(const Duration(seconds: 20))) {
      if (_cancelCurrentDownload) { await sink.close(); try { outFile.deleteSync(); } catch (_) {} return false; }
      sink.add(chunk);
      received += chunk.length;
      if (totalBytes > 0) downloadProgress.value = (received / totalBytes).clamp(0.05, 0.99);
    }
    await sink.flush();
    await sink.close();

    if (received < 1024) { try { outFile.deleteSync(); } catch (_) {} return false; }

    final newId = 'dl_${savePath.hashCode}';
    appState.unmarkDeleted(newId, savePath);

    final newTrack = TrackItem(
      id: newId, title: title, artist: artist, album: 'AlexLMP Downloads', durationSeconds: 0,
      artColors: kArtPalettes[audioHandler.tracks.length % kArtPalettes.length].colors,
      artStyle: kArtStyles[audioHandler.tracks.length % kArtStyles.length],
      source: savePath, filePath: savePath,
    );

    await audioHandler.addTracks([newTrack], playFirst: true);
    appNotice.value = 'Downloaded "$title" into your library!';
    return true;
  } catch (_) { return false; }
}

Future<bool> downloadAudioIntoApp({
  required String inputUrlOrQuery, String? customTitle, String? customArtist,
}) async {
  final rawInput = inputUrlOrQuery.trim();
  if (rawInput.isEmpty) return false;

  _cancelCurrentDownload = false;

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
        client: client, downloadUrl: rawInput, title: customTitle ?? decodedName, artist: customArtist ?? 'Direct Link', ext: ext,
      );
      return ok;
    } finally { client.close(); downloadProgress.value = null; downloadStatus.value = null; }
  }

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

    if (video == null || _cancelCurrentDownload) { appNotice.value = 'Could not find a track for "$rawInput".'; return false; }

    downloadStatus.value = 'Extracting audio stream…';
    final manifest = await yt.videos.streamsClient.getManifest(video.id);
    final audioStreams = manifest.audioOnly;
    if (audioStreams.isEmpty || _cancelCurrentDownload) return false;

    ytd.AudioStreamInfo? chosen;
    for (final s in audioStreams.sortByBitrate()) {
      if (s.container.name.toLowerCase().contains('mp4')) { chosen = s; break; }
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
      if (_cancelCurrentDownload) { await sink.close(); try { outFile.deleteSync(); } catch (_) {} return false; }
      sink.add(chunk);
      received += chunk.length;
      if (totalBytes > 0) downloadProgress.value = (received / totalBytes).clamp(0.05, 0.99);
    }
    await sink.flush();
    await sink.close();

    if (received < 1024) { try { outFile.deleteSync(); } catch (_) {} return false; }

    final newId = 'dl_${savePath.hashCode}';
    appState.unmarkDeleted(newId, savePath);

    final newTrack = TrackItem(
      id: newId, title: finalTitle, artist: finalArtist, album: 'AlexLMP Downloads', durationSeconds: video.duration?.inSeconds ?? 0,
      artColors: kArtPalettes[audioHandler.tracks.length % kArtPalettes.length].colors,
      artStyle: kArtStyles[audioHandler.tracks.length % kArtStyles.length], source: savePath, filePath: savePath,
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
