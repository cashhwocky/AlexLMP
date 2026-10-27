import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

late AudioHandlerEx _audioHandler;

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

  _audioHandler = await AudioService.init(
    builder: () => AudioHandlerEx(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.archivetune.app.channel.audio',
      androidNotificationChannelName: 'Archive Tune Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );

  runApp(const ArchiveTuneApp());
}

class TrackItem {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String radioName;
  final bool isExplicit;
  final bool hasParentalBadge;
  final int durationSeconds;
  final List<Color> artColors;
  final String artStyle;
  final List<String> syncedLyrics;
  final Color playerBg;
  final Color playerSurface;
  final Color playerButtonBrown;
  final Color playerAccentPeach;
  final Color playerOnAccent;
  final String? filePath;

  const TrackItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    this.radioName = '"Archive" Radio',
    this.isExplicit = false,
    this.hasParentalBadge = false,
    required this.durationSeconds,
    required this.artColors,
    this.artStyle = 'window_sunset',
    required this.syncedLyrics,
    this.playerBg = const Color(0xFF20130E),
    this.playerSurface = const Color(0xFF362721),
    this.playerButtonBrown = const Color(0xFF5D3A28),
    this.playerAccentPeach = const Color(0xFFFFB59C),
    this.playerOnAccent = const Color(0xFF4D1600),
    this.filePath,
  });

  MediaItem toMediaItem() {
    return MediaItem(
      id: id,
      title: title,
      artist: artist,
      album: album,
      duration: Duration(seconds: durationSeconds),
      artUri: Uri.parse('https://images.unsplash.com/photo-1514525253161-7a46d19cd819?w=300'),
    );
  }
}

class AudioHandlerEx extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  List<TrackItem> playlist = [];
  int currentIndex = 0;

  AudioHandlerEx() {
    _init();
  }

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);

    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        skipToNext();
      }
    });
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
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
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: currentIndex,
    );
  }

  void setQueue(List<TrackItem> items, int index) {
    playlist = items;
    currentIndex = index;
    if (playlist.isNotEmpty) {
      playTrack(currentIndex);
    }
  }

  Future<void> playTrack(int index) async {
    if (index < 0 || index >= playlist.length) return;
    currentIndex = index;
    final track = playlist[currentIndex];
    mediaItem.add(track.toMediaItem());

    try {
      if (track.filePath != null && track.filePath!.isNotEmpty && File(track.filePath!).existsSync()) {
        await _player.setFilePath(track.filePath!);
      } else {
        await _player.setUrl('https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3');
      }
      play();
    } catch (_) {
      play();
    }
  }

  @override
  Future<void> play() async {
    _player.play();
  }

  @override
  Future<void> pause() async {
    _player.pause();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (playlist.isEmpty) return;
    currentIndex = (currentIndex + 1) % playlist.length;
    await playTrack(currentIndex);
  }

  @override
  Future<void> skipToPrevious() async {
    if (playlist.isEmpty) return;
    if (_player.position.inSeconds > 4) {
      seek(Duration.zero);
      return;
    }
    currentIndex = (currentIndex - 1 + playlist.length) % playlist.length;
    await playTrack(currentIndex);
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }
}

class ArchiveTuneApp extends StatelessWidget {
  const ArchiveTuneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Archive Tune',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF111416),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8CD0F0),
          onPrimary: Color(0xFF003549),
          secondary: Color(0xFFB5C9D7),
          surface: Color(0xFF111416),
          surfaceContainer: Color(0xFF1C2124),
        ),
        fontFamily: 'Roboto',
      ),
      home: const ArchiveTuneRoot(),
    );
  }
}

class ArchiveTuneRoot extends StatefulWidget {
  const ArchiveTuneRoot({super.key});

  @override
  State<ArchiveTuneRoot> createState() => _ArchiveTuneRootState();
}

class _ArchiveTuneRootState extends State<ArchiveTuneRoot> {
  static const MethodChannel _mediaChannel = MethodChannel('com.archivetune.app/media');

  List<TrackItem> _tracks = [];
  int _currentIndex = 0;
  int _selectedBottomTab = 0; // 0 = Home, 1 = Mix, 2 = Library
  String _selectedChip = 'All';

  bool _isShuffle = false;
  int _repeatMode = 0; // 0: off, 1: all, 2: one
  double _playbackSpeed = 1.0;
  double _playbackPitch = 1.0;
  bool _stopOnTaskClear = true;

  final Set<String> _likedIds = {};
  final Set<String> _savedIds = {};

  TrackItem get _currentTrack {
    if (_tracks.isEmpty) {
      return TrackItem(
        id: 'placeholder',
        title: 'No audio found',
        artist: 'Import or Scan local files',
        album: 'Archive Tune',
        durationSeconds: 0,
        artColors: const [Color(0xFF1C2124), Color(0xFF2E373D)],
        syncedLyrics: const ['Import local tracks or scan storage to begin'],
      );
    }
    return _tracks[_currentIndex.clamp(0, _tracks.length - 1)];
  }

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _autoScanStorage();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _stopOnTaskClear = prefs.getBool('stop_on_task_clear') ?? true;
    });
  }

  Future<void> _autoScanStorage() async {
    await Permission.storage.request();
    await Permission.audio.request();
    if (Platform.isAndroid) {
      try {
        final List<dynamic>? raw = await _mediaChannel.invokeMethod('scanDeviceAudio');
        if (raw != null && raw.isNotEmpty && mounted) {
          final scanned = raw.map((item) {
            final map = Map<String, dynamic>.from(item);
            return TrackItem(
              id: 'scan_${map['filePath']}',
              title: map['title']?.toString() ?? 'Unknown Track',
              artist: map['artist']?.toString() ?? 'Local Artist',
              album: map['album']?.toString() ?? 'Local Album',
              radioName: '"Local Storage" Radio',
              isExplicit: false,
              hasParentalBadge: false,
              durationSeconds: (map['durationSeconds'] as int?) ?? 180,
              artColors: const [Color(0xFF1E2830), Color(0xFF111416), Color(0xFF2B3A45)],
              syncedLyrics: const [
                'Local device audio track',
                'Imported and indexed via Archive Tune engine',
              ],
              filePath: map['filePath']?.toString(),
            );
          }).toList();

          setState(() {
            _tracks = scanned;
            if (_tracks.isNotEmpty) {
              _audioHandler.setQueue(_tracks, 0);
              _audioHandler.pause();
            }
          });
        }
      } catch (_) {}
    }
  }

  Future<void> _importOrScanMusic() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C2124),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Add Music to Archive Tune',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFF283740),
                    child: Icon(Icons.folder_open, color: Color(0xFF8CD0F0)),
                  ),
                  title: const Text('Pick Local Audio Files'),
                  subtitle: const Text('Import MP3, FLAC, WAV, M4A from device'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final result = await FilePicker.platform.pickFiles(
                      type: FileType.audio,
                      allowMultiple: true,
                    );
                    if (result != null && result.files.isNotEmpty) {
                      final added = <TrackItem>[];
                      for (final file in result.files) {
                        if (file.path == null) continue;
                        final name = p.basenameWithoutExtension(file.path!);
                        added.add(
                          TrackItem(
                            id: 'local_${DateTime.now().microsecondsSinceEpoch}_${added.length}',
                            title: name,
                            artist: 'Imported Artist',
                            album: 'Local Files',
                            radioName: '"Imported" Radio',
                            isExplicit: false,
                            hasParentalBadge: false,
                            durationSeconds: 180,
                            artColors: const [Color(0xFF3E1C0C), Color(0xFFD96B38), Color(0xFF1A0F0A)],
                            syncedLyrics: const [
                              'Playing custom imported local audio',
                              'Stored directly on device storage',
                            ],
                            filePath: file.path,
                          ),
                        );
                      }
                      if (added.isNotEmpty && mounted) {
                        setState(() {
                          _tracks.insertAll(0, added);
                          _audioHandler.setQueue(_tracks, 0);
                        });
                      }
                    }
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFF283740),
                    child: Icon(Icons.radar, color: Color(0xFF8CD0F0)),
                  ),
                  title: const Text('Scan Device MediaStore'),
                  subtitle: const Text('Index all music files on phone storage'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _autoScanStorage();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openFullScreenPlayer() {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (context, animation, secondaryAnimation) {
          return FadeTransition(
            opacity: animation,
            child: StatefulBuilder(
              builder: (context, setModalState) {
                return _buildNowPlayingScreen(setModalState);
              },
            ),
          );
        },
      ),
    );
  }

  void _openSearchSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111416),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        String query = '';
        return StatefulBuilder(
          builder: (ctx, setSearchState) {
            final filtered = _tracks.where((t) {
              final q = query.toLowerCase();
              return t.title.toLowerCase().contains(q) ||
                  t.artist.toLowerCase().contains(q) ||
                  t.album.toLowerCase().contains(q);
            }).toList();
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.85,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              builder: (_, scrollController) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Column(
                    children: [
                      TextField(
                        autofocus: true,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Search downloaded songs & artists...',
                          hintStyle: const TextStyle(color: Colors.white54),
                          prefixIcon: const Icon(Icons.search, color: Color(0xFF8CD0F0)),
                          filled: true,
                          fillColor: const Color(0xFF1C2124),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (val) => setSearchState(() => query = val),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: filtered.isEmpty
                            ? const Center(
                                child: Text(
                                  'No downloaded songs found. Tap + to add music.',
                                  style: TextStyle(color: Colors.white54),
                                ),
                              )
                            : ListView.builder(
                                controller: scrollController,
                                itemCount: filtered.length,
                                itemBuilder: (_, idx) {
                                  final item = filtered[idx];
                                  final masterIndex = _tracks.indexOf(item);
                                  return ListTile(
                                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                                    leading: SizedBox(
                                      width: 52,
                                      height: 52,
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: CustomAlbumArtwork(track: item),
                                      ),
                                    ),
                                    title: Text(
                                      item.title,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    subtitle: Text(
                                      item.artist,
                                      style: const TextStyle(color: Color(0xFFA6ADB2)),
                                    ),
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      setState(() => _currentIndex = masterIndex);
                                      _audioHandler.setQueue(_tracks, masterIndex);
                                      _openFullScreenPlayer();
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C2124),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Archive Tune Settings',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Made by Alex Desrosier',
                      style: TextStyle(
                        fontSize: 14,
                        color: Color(0xFF8CD0F0),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SwitchListTile(
                      title: const Text('Stop music on task clear'),
                      subtitle: const Text('Stops playback when swiped away from recents'),
                      value: _stopOnTaskClear,
                      activeColor: const Color(0xFF8CD0F0),
                      onChanged: (val) async {
                        setSheetState(() => _stopOnTaskClear = val);
                        setState(() => _stopOnTaskClear = val);
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool('stop_on_task_clear', val);
                      },
                    ),
                    const Divider(color: Color(0xFF2E373D)),
                    const SizedBox(height: 10),
                    Text(
                      'Playback Speed: ${_playbackSpeed.toStringAsFixed(2)}x',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    Slider(
                      value: _playbackSpeed,
                      min: 0.5,
                      max: 2.0,
                      divisions: 15,
                      activeColor: const Color(0xFF8CD0F0),
                      onChanged: (v) {
                        setSheetState(() => _playbackSpeed = v);
                        setState(() => _playbackSpeed = v);
                        _audioHandler._player.setSpeed(v);
                      },
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

  String _formatDuration(Duration d) {
    final mins = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final secs = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: _audioHandler.playbackState,
      builder: (context, snapshot) {
        final playbackState = snapshot.data;
        final bool isPlaying = playbackState?.playing ?? false;
        final Duration position = playbackState?.position ?? Duration.zero;
        final int queueIndex = playbackState?.queueIndex ?? _currentIndex;
        if (queueIndex >= 0 && queueIndex < _tracks.length && queueIndex != _currentIndex) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _currentIndex = queueIndex);
          });
        }
        final currentTrack = _currentTrack;
        final duration = Duration(seconds: currentTrack.durationSeconds > 0 ? currentTrack.durationSeconds : 180);
        final progress = duration.inMilliseconds > 0
            ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;

        return Scaffold(
          backgroundColor: const Color(0xFF111416),
          body: Stack(
            children: [
              SafeArea(
                bottom: false,
                child: IndexedStack(
                  index: _selectedBottomTab,
                  children: [
                    _buildHomeTab(isPlaying),
                    _buildMixTab(),
                    _buildLibraryTab(),
                  ],
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: MediaQuery.of(context).padding.bottom + 8,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: _openFullScreenPlayer,
                      onHorizontalDragEnd: (details) {
                        if ((details.primaryVelocity ?? 0) < -200) {
                          _audioHandler.skipToNext();
                        } else if ((details.primaryVelocity ?? 0) > 200) {
                          _audioHandler.skipToPrevious();
                        }
                      },
                      child: Container(
                        height: 66,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1C2226).withOpacity(0.97),
                          borderRadius: BorderRadius.circular(34),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.45),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 46,
                              height: 46,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  SizedBox(
                                    width: 46,
                                    height: 46,
                                    child: CircularProgressIndicator(
                                      value: progress,
                                      strokeWidth: 2.6,
                                      backgroundColor: const Color(0xFF2E373D),
                                      valueColor: const AlwaysStoppedAnimation<Color>(
                                        Color(0xFF8AD0EE),
                                      ),
                                    ),
                                  ),
                                  ClipOval(
                                    child: SizedBox(
                                      width: 36,
                                      height: 36,
                                      child: CustomAlbumArtwork(
                                        track: currentTrack,
                                        showParentalBadge: false,
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
                                    currentTrack.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    children: [
                                      if (currentTrack.isExplicit) ...[
                                        const _ExplicitBadge(),
                                        const SizedBox(width: 6),
                                      ],
                                      Expanded(
                                        child: Text(
                                          currentTrack.artist,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Color(0xFFB3B9BE),
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  if (_likedIds.contains(currentTrack.id)) {
                                    _likedIds.remove(currentTrack.id);
                                  } else {
                                    _likedIds.add(currentTrack.id);
                                  }
                                });
                              },
                              child: Container(
                                width: 44,
                                height: 44,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF2A3136),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  _likedIds.contains(currentTrack.id)
                                      ? Icons.favorite_rounded
                                      : Icons.favorite_border_rounded,
                                  color: const Color(0xFFD5DCE0),
                                  size: 21,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () {
                                if (_tracks.isEmpty) return;
                                if (isPlaying) {
                                  _audioHandler.pause();
                                } else {
                                  if (_audioHandler._player.audioSource == null) {
                                    _audioHandler.setQueue(_tracks, _currentIndex);
                                  } else {
                                    _audioHandler.play();
                                  }
                                }
                              },
                              child: Container(
                                width: 46,
                                height: 46,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF8AD0EE),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                  color: const Color(0xFF062938),
                                  size: 26,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 68,
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1C2226).withOpacity(0.98),
                              borderRadius: BorderRadius.circular(36),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.45),
                                  blurRadius: 14,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                _buildNavTab(index: 0, icon: Icons.home_rounded, label: 'Home'),
                                _buildNavTab(index: 1, icon: Icons.sensors_rounded, label: 'Mix'),
                                _buildNavTab(index: 2, icon: Icons.library_music_rounded, label: 'Library'),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: _openSearchSheet,
                          child: Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1C2226).withOpacity(0.98),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.45),
                                  blurRadius: 14,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.search_rounded,
                              color: Color(0xFFD5DCE0),
                              size: 26,
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

  Widget _buildNavTab({required int index, required IconData icon, required String label}) {
    final bool selected = _selectedBottomTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedBottomTab = index),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF283740) : Colors.transparent,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: selected ? const Color(0xFF8AD0EE) : const Color(0xFFB3B9BE),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? const Color(0xFF8AD0EE) : const Color(0xFFB3B9BE),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeTab(bool isPlaying) {
    if (_tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.music_note_rounded, size: 64, color: Color(0xFF8CD0F0)),
              const SizedBox(height: 16),
              const Text(
                'No downloaded songs found on device',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Tap the + button above or scan storage to load your music files.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFFA6ADB2), fontSize: 14),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _importOrScanMusic,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add Music Files'),
              ),
            ],
          ),
        ),
      );
    }

    final quickPicksColumn1 = _tracks.take(4).toList();
    final quickPicksColumn2 = _tracks.skip(4).take(4).toList();
    if (quickPicksColumn2.isEmpty && _tracks.isNotEmpty) {
      quickPicksColumn2.addAll(_tracks);
    }
    final listenAgainTracks = _tracks.reversed.take(4).toList();

    return ListView(
      padding: const EdgeInsets.only(top: 10, bottom: 185),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: const BoxDecoration(
                  color: Color(0xFF283740),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.headphones_rounded, color: Color(0xFF8CD0F0), size: 24),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () => setState(() => _selectedChip = 'All'),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: _selectedChip == 'All' ? const Color(0xFF8AD0EE) : Colors.transparent,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: _selectedChip == 'All' ? const Color(0xFF8AD0EE) : const Color(0xFF3A4146),
                    ),
                  ),
                  child: Text(
                    'All',
                    style: TextStyle(
                      color: _selectedChip == 'All' ? const Color(0xFF062938) : Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: () => setState(() => _selectedChip = 'Mood'),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: _selectedChip == 'Mood' ? const Color(0xFF8AD0EE) : Colors.transparent,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: _selectedChip == 'Mood' ? const Color(0xFF8AD0EE) : const Color(0xFF3A4146),
                    ),
                  ),
                  child: Text(
                    'Mood',
                    style: TextStyle(
                      color: _selectedChip == 'Mood' ? const Color(0xFF062938) : const Color(0xFFD5DCE0),
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _importOrScanMusic,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFF21282C),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF333B40)),
                  ),
                  child: const Icon(Icons.add_rounded, color: Color(0xFFD5DCE0), size: 24),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _openSettingsSheet,
                child: const Icon(Icons.settings_rounded, color: Colors.white, size: 26),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "LET'S START WITH A RADIO",
                      style: TextStyle(
                        color: Color(0xFF9EA6AC),
                        fontSize: 12,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Quick picks',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () {
                  setState(() => _currentIndex = 0);
                  _audioHandler.setQueue(_tracks, 0);
                  _openFullScreenPlayer();
                },
                child: const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text(
                    'Play all',
                    style: TextStyle(
                      color: Color(0xFFB3B9BE),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
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
                width: MediaQuery.of(context).size.width - 42,
                child: Column(
                  children: quickPicksColumn1.map((track) => _buildQuickPickRow(track)).toList(),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: MediaQuery.of(context).size.width - 42,
                child: Column(
                  children: quickPicksColumn2.map((track) => _buildQuickPickRow(track)).toList(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LIBRARY RECENT',
                style: TextStyle(
                  color: Color(0xFF9EA6AC),
                  fontSize: 12,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w500,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Listen again',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 230,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: listenAgainTracks.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, idx) {
              final track = listenAgainTracks[idx];
              final masterIdx = _tracks.indexOf(track);
              return GestureDetector(
                onTap: () {
                  setState(() => _currentIndex = masterIdx);
                  _audioHandler.setQueue(_tracks, masterIdx);
                  _openFullScreenPlayer();
                },
                child: SizedBox(
                  width: 168,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 168,
                          height: 168,
                          child: CustomAlbumArtwork(
                            track: track,
                            showParentalBadge: track.hasParentalBadge,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        track.title,
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
                        track.artist,
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

  Widget _buildQuickPickRow(TrackItem track) {
    final masterIdx = _tracks.indexOf(track);
    return InkWell(
      onTap: () {
        setState(() => _currentIndex = masterIdx);
        _audioHandler.setQueue(_tracks, masterIdx);
        _openFullScreenPlayer();
      },
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 54,
                height: 54,
                child: CustomAlbumArtwork(
                  track: track,
                  showParentalBadge: false,
                ),
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
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (track.isExplicit) ...[
                        const _ExplicitBadge(),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFA6ADB2),
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
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
      ),
    );
  }

  Widget _buildMixTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 185),
      children: [
        const Text(
          'CUSTOM STATIONS',
          style: TextStyle(color: Color(0xFF9EA6AC), fontSize: 12, letterSpacing: 0.8),
        ),
        const SizedBox(height: 4),
        const Text(
          'Your Archive Mixes',
          style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 16),
        if (_tracks.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text('No tracks available for mix', style: TextStyle(color: Colors.white54)),
            ),
          ),
        ..._tracks.asMap().entries.map((entry) {
          final i = entry.key;
          final t = entry.value;
          return Card(
            color: const Color(0xFF1C2226),
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: ListTile(
              contentPadding: const EdgeInsets.all(12),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: CustomAlbumArtwork(track: t, showParentalBadge: false),
                ),
              ),
              title: Text(
                t.title,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                t.artist,
                style: const TextStyle(color: Color(0xFFA6ADB2)),
              ),
              trailing: const CircleAvatar(
                backgroundColor: Color(0xFF8AD0EE),
                child: Icon(Icons.play_arrow_rounded, color: Color(0xFF062938)),
              ),
              onTap: () {
                setState(() => _currentIndex = i);
                _audioHandler.setQueue(_tracks, i);
                _openFullScreenPlayer();
              },
            ),
          );
        }),
      ],
    );
  }

  Widget _buildLibraryTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 185),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Library',
              style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800),
            ),
            FilledButton.tonalIcon(
              onPressed: _importOrScanMusic,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('Import Local'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (_tracks.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(
              child: Text(
                'No local audio files found.',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
            ),
          ),
        ..._tracks.asMap().entries.map((entry) {
          final t = entry.value;
          return _buildQuickPickRow(t);
        }),
      ],
    );
  }

  Widget _buildNowPlayingScreen(StateSetter setModalState) {
    final track = _currentTrack;
    return StreamBuilder<PlaybackState>(
      stream: _audioHandler.playbackState,
      builder: (context, snapshot) {
        final playbackState = snapshot.data;
        final bool isPlaying = playbackState?.playing ?? false;
        final Duration position = playbackState?.position ?? Duration.zero;
        final int maxSeconds = max(track.durationSeconds, 1);
        final int currentSeconds = position.inSeconds.clamp(0, maxSeconds);

        return Scaffold(
          backgroundColor: track.playerBg,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: track.playerSurface,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 28),
                        ),
                      ),
                      Column(
                        children: [
                          const Text(
                            'NOW PLAYING',
                            style: TextStyle(
                              color: Color(0xFFE5DDD9),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            track.radioName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      GestureDetector(
                        onTap: _openSettingsSheet,
                        child: Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: track.playerSurface,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 24),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(flex: 2),
                  Center(
                    child: AspectRatio(
                      aspectRatio: 1.0,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.45),
                              blurRadius: 24,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: CustomAlbumArtwork(
                            track: track,
                            showParentalBadge: track.hasParentalBadge,
                            largeBadge: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(flex: 2),
                  Text(
                    track.syncedLyrics.isNotEmpty ? track.syncedLyrics.first : track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
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
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.4,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                if (track.isExplicit) ...[
                                  const _ExplicitBadge(),
                                  const SizedBox(width: 7),
                                ],
                                Expanded(
                                  child: Text(
                                    track.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFFC8BDB7),
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            if (_savedIds.contains(track.id)) {
                              _savedIds.remove(track.id);
                            } else {
                              _savedIds.add(track.id);
                            }
                          });
                          setModalState(() {});
                        },
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: track.playerSurface,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.add_circle_outline_rounded,
                            color: Color(0xFFEAE0DC),
                            size: 24,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            if (_likedIds.contains(track.id)) {
                              _likedIds.remove(track.id);
                            } else {
                              _likedIds.add(track.id);
                            }
                          });
                          setModalState(() {});
                        },
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: track.playerSurface,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _likedIds.contains(track.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                            color: const Color(0xFFEAE0DC),
                            size: 23,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4.5,
                          activeTrackColor: track.playerAccentPeach,
                          inactiveTrackColor: const Color(0xFF42312B),
                          thumbColor: track.playerAccentPeach,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7.5),
                          overlayShape: SliderComponentShape.noOverlay,
                        ),
                        child: Stack(
                          alignment: Alignment.centerRight,
                          children: [
                            Slider(
                              value: currentSeconds.toDouble(),
                              min: 0,
                              max: maxSeconds.toDouble(),
                              onChanged: (val) {
                                _audioHandler.seek(Duration(seconds: val.toInt()));
                                setModalState(() {});
                              },
                            ),
                            Container(
                              width: 4,
                              height: 4,
                              margin: const EdgeInsets.only(right: 2),
                              decoration: BoxDecoration(
                                color: track.playerAccentPeach,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(position),
                            style: const TextStyle(
                              color: Color(0xFFC8BDB7),
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            _formatDuration(Duration(seconds: maxSeconds)),
                            style: const TextStyle(
                              color: Color(0xFFC8BDB7),
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () => _audioHandler.skipToPrevious(),
                        child: Container(
                          width: 88,
                          height: 70,
                          decoration: BoxDecoration(
                            color: track.playerButtonBrown,
                            borderRadius: BorderRadius.circular(35),
                          ),
                          child: const Icon(
                            Icons.skip_previous_rounded,
                            color: Color(0xFFF6E6DF),
                            size: 32,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            if (isPlaying) {
                              _audioHandler.pause();
                            } else {
                              _audioHandler.play();
                            }
                            setModalState(() {});
                          },
                          child: Container(
                            height: 70,
                            decoration: BoxDecoration(
                              color: track.playerAccentPeach,
                              borderRadius: BorderRadius.circular(35),
                            ),
                            child: Icon(
                              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              color: track.playerOnAccent,
                              size: 34,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () => _audioHandler.skipToNext(),
                        child: Container(
                          width: 88,
                          height: 70,
                          decoration: BoxDecoration(
                            color: track.playerButtonBrown,
                            borderRadius: BorderRadius.circular(35),
                          ),
                          child: const Icon(
                            Icons.skip_next_rounded,
                            color: Color(0xFFF6E6DF),
                            size: 32,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: SizedBox(
                      height: 52,
                      child: Row(
                        children: [
                          _buildSegmentedBottomBtn(
                            icon: Icons.info_rounded,
                            surface: track.playerSurface,
                            onTap: () => _showTrackInfoDialog(track),
                            isFirst: true,
                          ),
                          const SizedBox(width: 3),
                          _buildSegmentedBottomBtn(
                            icon: Icons.headphones_rounded,
                            surface: track.playerSurface,
                            onTap: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Audio Output: MediaSession Active'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 3),
                          _buildSegmentedBottomBtn(
                            icon: Icons.shuffle_rounded,
                            surface: _isShuffle ? track.playerButtonBrown : track.playerSurface,
                            onTap: () => setState(() => _isShuffle = !_isShuffle),
                          ),
                          const SizedBox(width: 3),
                          _buildSegmentedBottomBtn(
                            icon: _repeatMode == 2 ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                            surface: _repeatMode > 0 ? track.playerButtonBrown : track.playerSurface,
                            onTap: () => setState(() => _repeatMode = (_repeatMode + 1) % 3),
                          ),
                          const SizedBox(width: 3),
                          _buildSegmentedBottomBtn(
                            icon: Icons.playlist_add_rounded,
                            surface: track.playerSurface,
                            onTap: _importOrScanMusic,
                          ),
                          const SizedBox(width: 3),
                          _buildSegmentedBottomBtn(
                            icon: Icons.queue_music_rounded,
                            surface: track.playerSurface,
                            onTap: () => _showQueueBottomSheet(setModalState),
                          ),
                          const SizedBox(width: 3),
                          _buildSegmentedBottomBtn(
                            icon: Icons.comment_rounded,
                            surface: track.playerSurface,
                            onTap: () => _showLyricsBottomSheet(track),
                            isLast: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSegmentedBottomBtn({
    required IconData icon,
    required Color surface,
    required VoidCallback onTap,
    bool isFirst = false,
    bool isLast = false,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(isFirst ? 26 : 6),
              right: Radius.circular(isLast ? 26 : 6),
            ),
          ),
          child: Icon(icon, color: const Color(0xFFEAE0DC), size: 21),
        ),
      ),
    );
  }

  void _showTrackInfoDialog(TrackItem track) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2B1D18),
        title: Text(track.title, style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Artist: ${track.artist}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 6),
            Text('Album: ${track.album}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 6),
            Text('File Path: ${track.filePath ?? "Stream"}', style: const TextStyle(color: Colors.white70)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Color(0xFFFFB59C))),
          ),
        ],
      ),
    );
  }

  void _showQueueBottomSheet(StateSetter setModalState) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF281A14),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: _tracks.length,
          itemBuilder: (_, idx) {
            final t = _tracks[idx];
            final active = idx == _currentIndex;
            return ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 46,
                  height: 46,
                  child: CustomAlbumArtwork(track: t, showParentalBadge: false),
                ),
              ),
              title: Text(
                t.title,
                style: TextStyle(
                  color: active ? const Color(0xFFFFB59C) : Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(t.artist, style: const TextStyle(color: Colors.white70)),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _currentIndex = idx);
                _audioHandler.setQueue(_tracks, idx);
                setModalState(() {});
              },
            );
          },
        );
      },
    );
  }

  void _showLyricsBottomSheet(TrackItem track) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF281A14),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${track.title} — Lyrics',
                style: const TextStyle(
                  color: Color(0xFFFFB59C),
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView.separated(
                  itemCount: track.syncedLyrics.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 16),
                  itemBuilder: (_, i) {
                    return Text(
                      track.syncedLyrics[i],
                      style: TextStyle(
                        color: i == 0 ? Colors.white : Colors.white60,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ExplicitBadge extends StatelessWidget {
  const _ExplicitBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 15,
      height: 15,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFC8C5C3),
        borderRadius: BorderRadius.circular(3),
      ),
      child: const Text(
        'E',
        style: TextStyle(
          color: Color(0xFF1A1512),
          fontSize: 10,
          fontWeight: FontWeight.w900,
          height: 1.0,
        ),
      ),
    );
  }
}

class CustomAlbumArtwork extends StatelessWidget {
  final TrackItem track;
  final bool showParentalBadge;
  final bool largeBadge;

  const CustomAlbumArtwork({
    super.key,
    required this.track,
    this.showParentalBadge = false,
    this.largeBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(
          painter: _ArtworkScenePainter(
            style: track.artStyle,
            colors: track.artColors,
          ),
        ),
        if (showParentalBadge)
          Positioned(
            right: largeBadge ? 14 : 8,
            bottom: largeBadge ? 12 : 6,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: largeBadge ? 6 : 4,
                vertical: largeBadge ? 3 : 2,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.88),
                border: Border.all(color: Colors.white70, width: 0.7),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'P A R E N T A L',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: largeBadge ? 6.5 : 4.2,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
                    child: Text(
                      'ADVISORY',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: largeBadge ? 10.5 : 6.0,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ArtworkScenePainter extends CustomPainter {
  final String style;
  final List<Color> colors;

  const _ArtworkScenePainter({required this.style, required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bgPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ).createShader(rect);
    canvas.drawRect(rect, bgPaint);

    final linePaint = Paint()
      ..color = Colors.white.withOpacity(0.08)
      ..strokeWidth = 1.5;
    for (double i = 0; i < size.width; i += 16) {
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
