import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

void main() {
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
  runApp(const ArchiveTuneApp());
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
    this.radioName = '"No Doubt" Radio',
    this.isExplicit = true,
    this.hasParentalBadge = true,
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
}

class _InMemoryWavSource extends StreamAudioSource {
  final Uint8List wavBytes;
  _InMemoryWavSource(this.wavBytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final s = start ?? 0;
    final e = end ?? wavBytes.length;
    return StreamAudioResponse(
      sourceLength: wavBytes.length,
      contentLength: e - s,
      offset: s,
      stream: Stream.value(wavBytes.sublist(s, e)),
      contentType: 'audio/wav',
    );
  }
}

Uint8List _generateSynthPreviewWav(int seed) {
  const int sampleRate = 22050;
  const int seconds = 12;
  const int numSamples = sampleRate * seconds;
  final int dataSize = numSamples * 2;
  final ByteData buffer = ByteData(44 + dataSize);

  void writeString(int offset, String s) {
    for (int i = 0; i < s.length; i++) {
      buffer.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeString(0, 'RIFF');
  buffer.setUint32(4, 36 + dataSize, Endian.little);
  writeString(8, 'WAVE');
  writeString(12, 'fmt ');
  buffer.setUint32(16, 16, Endian.little);
  buffer.setUint16(20, 1, Endian.little);
  buffer.setUint16(22, 1, Endian.little);
  buffer.setUint32(24, sampleRate, Endian.little);
  buffer.setUint32(28, sampleRate * 2, Endian.little);
  buffer.setUint16(32, 2, Endian.little);
  buffer.setUint16(34, 16, Endian.little);
  writeString(36, 'data');
  buffer.setUint32(40, dataSize, Endian.little);

  final chords = [
    [220.0, 261.63, 329.63],
    [196.0, 246.94, 293.66],
    [174.61, 220.0, 261.63],
    [164.81, 196.0, 246.94],
  ];

  for (int i = 0; i < numSamples; i++) {
    final double t = i / sampleRate;
    final int chordIdx = ((t / 3.0).floor() + seed) % chords.length;
    final chord = chords[chordIdx];
    final double env = 0.55 + 0.35 * sin(t * pi * 2);
    final double wave = (sin(2 * pi * chord[0] * t) +
            0.7 * sin(2 * pi * chord[1] * t) +
            0.5 * sin(2 * pi * chord[2] * t)) /
        2.2;
    final int pcm = (wave * env * 9000).clamp(-32767, 32767).toInt();
    buffer.setInt16(44 + i * 2, pcm, Endian.little);
  }
  return buffer.buffer.asUint8List();
}

final List<TrackItem> defaultArchiveTracks = [
  const TrackItem(
    id: 'lowkey_2',
    title: 'Lowkey II',
    artist: 'YCK',
    album: 'Lowkey II - Single',
    radioName: '"No Doubt" Radio',
    isExplicit: true,
    hasParentalBadge: true,
    durationSeconds: 138, // 02:18
    artColors: [Color(0xFF3E1C0C), Color(0xFFD96B38), Color(0xFF1A0F0A)],
    artStyle: 'window_sunset',
    syncedLyrics: [
      'Rolling up first then I\'m getting proceeds',
      'Staying in my lane while the city goes to sleep',
      'Counting every step from the bottom to the peak',
      'Keep the circle tight, yeah we moving lowkey',
      'Shadows on the blinds while the sunset fades',
      'Built it from the ground, never needed no handouts',
    ],
  ),
  const TrackItem(
    id: 'wishing_well',
    title: 'Wishing Well',
    artist: 'Juice WRLD',
    album: 'Legends Never Die',
    radioName: '"Legends" Radio',
    isExplicit: true,
    hasParentalBadge: true,
    durationSeconds: 194,
    artColors: [Color(0xFF42173B), Color(0xFFE0538A), Color(0xFF28193D)],
    artStyle: 'pink_sunset',
    syncedLyrics: [
      'Ring-ring, plug hit my phone, perfect timing',
      'I still try even though I know I\'m gon\' fail',
      'Tossing my pain with my wishes in a wishing well',
    ],
  ),
  const TrackItem(
    id: 'feasting_angels',
    title: 'Feasting.On.The.Guts.Of.Angels.',
    artist: 'Grim Salvo',
    album: 'MILDRED',
    radioName: '"Dark Trap" Radio',
    isExplicit: true,
    hasParentalBadge: true,
    durationSeconds: 176,
    artColors: [Color(0xFF2B2B2B), Color(0xFF8C8C8C), Color(0xFF121212)],
    artStyle: 'mono_portrait',
    syncedLyrics: [
      'Walking through the static in the dead of the night',
      'Echoes in the hallway cutting through the light',
      'Feasting on the rhythm till the morning arrives',
    ],
  ),
  const TrackItem(
    id: 'gravewalker',
    title: 'Gravewalker\'s Anthem',
    artist: 'MOSSBACK',
    album: 'Gravewalker',
    radioName: '"Underground" Radio',
    isExplicit: true,
    hasParentalBadge: true,
    durationSeconds: 162,
    artColors: [Color(0xFF062A4E), Color(0xFF1F7AE0), Color(0xFF0A2416)],
    artStyle: 'blue_silhouette',
    syncedLyrics: [
      'Out across the ridge where the cold wind blows',
      'Following the trail that nobody else knows',
      'Gravewalker stepping through the midnight glow',
    ],
  ),
  const TrackItem(
    id: 'money_on_the_dash',
    title: 'MONEY ON THE DASH',
    artist: 'Elley Duhé',
    album: 'MONEY ON THE DASH - Single',
    radioName: '"Night Drive" Radio',
    isExplicit: false,
    hasParentalBadge: false,
    durationSeconds: 148,
    artColors: [Color(0xFF4A1E0D), Color(0xFFE66833), Color(0xFF1B110E)],
    artStyle: 'amber_flames',
    syncedLyrics: [
      'Money on the dash, pedal to the floor',
      'Headlights flashing as we fly past the shore',
      'Never looking back, yeah we chasing something more',
    ],
  ),
  const TrackItem(
    id: 'back_to_life',
    title: 'Back to Life (Birthdae)',
    artist: 'ScurtDae',
    album: 'BIRTHDAE',
    radioName: '306BOBBY Radio',
    isExplicit: true,
    hasParentalBadge: true,
    durationSeconds: 165,
    artColors: [Color(0xFF5A5B56), Color(0xFF2C2D2A), Color(0xFF171816)],
    artStyle: 'birthdae_columns',
    syncedLyrics: [
      'Standing on the pillars while the clouds roll by',
      'Brought it back to life underneath the grey sky',
      'Every single verse etched deep in stone',
    ],
  ),
  const TrackItem(
    id: 'life_venfex',
    title: 'Life (feat. Faceless 1-7)',
    artist: 'Venfex',
    album: 'Night Skies',
    radioName: '306BOBBY Radio',
    isExplicit: true,
    hasParentalBadge: true,
    durationSeconds: 189,
    artColors: [Color(0xFF0B1325), Color(0xFF14457A), Color(0xFFD68A28)],
    artStyle: 'twin_hoodies',
    syncedLyrics: [
      'Looking at the stars above the golden clouds',
      'Two silhouettes far away from the crowds',
      'Living every moment while the night stays young',
    ],
  ),
  const TrackItem(
    id: 'scars_30',
    title: 'Scars in the Neon',
    artist: '306Bobby',
    album: 'After Hours',
    radioName: '306BOBBY Radio',
    isExplicit: true,
    hasParentalBadge: true,
    durationSeconds: 152,
    artColors: [Color(0xFF1A3A2A), Color(0xFF9C27B0), Color(0xFF00BCD4)],
    artStyle: 'neon_abstract',
    syncedLyrics: [
      'Neon reflections on the wet pavement',
      'Every late night feels like a statement',
    ],
  ),
];

class ArchiveTuneRoot extends StatefulWidget {
  const ArchiveTuneRoot({super.key});

  @override
  State<ArchiveTuneRoot> createState() => _ArchiveTuneRootState();
}

class _ArchiveTuneRootState extends State<ArchiveTuneRoot> {
  static const MethodChannel _mediaChannel =
      MethodChannel('com.archivetune.app/media');

  final AudioPlayer _audioPlayer = AudioPlayer();

  List<TrackItem> _tracks = List.from(defaultArchiveTracks);
  int _currentIndex = 0;
  int _selectedBottomTab = 0; // 0 = Home, 1 = Mix, 2 = Library
  String _selectedChip = 'All';

  bool _isPlaying = false;
  bool _isShuffle = false;
  int _repeatMode = 0; // 0: off, 1: all, 2: one
  double _playbackSpeed = 1.0;
  double _playbackPitch = 1.0;

  Duration _position = const Duration(minutes: 1, seconds: 48);
  Duration _duration = const Duration(minutes: 2, seconds: 18);
  final Set<String> _likedIds = {'lowkey_2'};
  final Set<String> _savedIds = {'lowkey_2', 'wishing_well', 'back_to_life'};

  Timer? _uiProgressTimer;

  TrackItem get _currentTrack => _tracks[_currentIndex];

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  Future<void> _initAudio() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {}

    _audioPlayer.positionStream.listen((pos) {
      if (_isPlaying && mounted && _currentTrack.filePath != null) {
        setState(() {
          _position = pos;
        });
      }
    });

    _audioPlayer.durationStream.listen((dur) {
      if (dur != null && mounted && _currentTrack.filePath != null) {
        setState(() {
          _duration = dur;
        });
      }
    });

    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _skipNext();
      }
    });
  }

  @override
  void dispose() {
    _uiProgressTimer?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadAndPlayTrack(int index, {bool autoPlay = true}) async {
    final clampedIndex = index.clamp(0, _tracks.length - 1);
    final track = _tracks[clampedIndex];

    setState(() {
      _currentIndex = clampedIndex;
      _duration = Duration(seconds: track.durationSeconds);
      _position = track.id == 'lowkey_2' && !autoPlay
          ? const Duration(minutes: 1, seconds: 48)
          : Duration.zero;
    });

    try {
      if (track.filePath != null && track.filePath!.isNotEmpty) {
        await _audioPlayer.setFilePath(track.filePath!);
      } else {
        final wavBytes = _generateSynthPreviewWav(clampedIndex);
        await _audioPlayer.setAudioSource(_InMemoryWavSource(wavBytes));
        await _audioPlayer.setLoopMode(LoopMode.one);
      }
      await _audioPlayer.setSpeed(_playbackSpeed);
      if (autoPlay) {
        _startPlayback();
      }
    } catch (_) {
      if (autoPlay) {
        _startPlayback();
      }
    }
  }

  void _startPlayback() {
    setState(() => _isPlaying = true);
    _audioPlayer.play();
    _uiProgressTimer?.cancel();
    _uiProgressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_isPlaying) return;
      if (_currentTrack.filePath == null) {
        setState(() {
          final nextSec = _position.inSeconds + 1;
          if (nextSec >= _duration.inSeconds) {
            if (_repeatMode == 2) {
              _position = Duration.zero;
            } else {
              _skipNext();
            }
          } else {
            _position = Duration(seconds: nextSec);
          }
        });
      }
    });
  }

  void _pausePlayback() {
    setState(() => _isPlaying = false);
    _audioPlayer.pause();
    _uiProgressTimer?.cancel();
  }

  void _togglePlayPause() {
    if (_isPlaying) {
      _pausePlayback();
    } else {
      if (_audioPlayer.audioSource == null) {
        _loadAndPlayTrack(_currentIndex, autoPlay: true);
      } else {
        _startPlayback();
      }
    }
  }

  void _skipNext() {
    if (_isShuffle && _tracks.length > 1) {
      final next = Random().nextInt(_tracks.length);
      _loadAndPlayTrack(next, autoPlay: _isPlaying);
    } else {
      final next = (_currentIndex + 1) % _tracks.length;
      _loadAndPlayTrack(next, autoPlay: _isPlaying);
    }
  }

  void _skipPrevious() {
    if (_position.inSeconds > 5) {
      setState(() => _position = Duration.zero);
      _audioPlayer.seek(Duration.zero);
      return;
    }
    final prev = (_currentIndex - 1 + _tracks.length) % _tracks.length;
    _loadAndPlayTrack(prev, autoPlay: _isPlaying);
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
                  subtitle: const Text('Import MP3, FLAC, WAV, or M4A files'),
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
                            artist: 'Local Artist',
                            album: 'Imported Audio',
                            radioName: '"Local Files" Radio',
                            isExplicit: false,
                            hasParentalBadge: false,
                            durationSeconds: 180,
                            artColors: const [
                              Color(0xFF3E1C0C),
                              Color(0xFFD96B38),
                              Color(0xFF1A0F0A)
                            ],
                            syncedLyrics: const [
                              'Playing local lossless audio track',
                              'Imported directly from device storage',
                            ],
                            filePath: file.path,
                          ),
                        );
                      }
                      if (added.isNotEmpty && mounted) {
                        setState(() {
                          _tracks.insertAll(0, added);
                        });
                        _loadAndPlayTrack(0, autoPlay: true);
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
                  subtitle: const Text('Automatically index all songs on phone'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Permission.audio.request();
                    await Permission.storage.request();
                    try {
                      final List<dynamic>? raw =
                          await _mediaChannel.invokeMethod('scanDeviceAudio');
                      if (raw != null && raw.isNotEmpty && mounted) {
                        final scanned = raw.map((item) {
                          final map = Map<String, dynamic>.from(item);
                          return TrackItem(
                            id: 'scan_${map['filePath']}',
                            title: map['title']?.toString() ?? 'Unknown',
                            artist: map['artist']?.toString() ?? 'Unknown Artist',
                            album: map['album']?.toString() ?? 'Local Album',
                            radioName: '"Local Library" Radio',
                            isExplicit: false,
                            hasParentalBadge: false,
                            durationSeconds:
                                (map['durationSeconds'] as int?) ?? 180,
                            artColors: const [
                              Color(0xFF243B4A),
                              Color(0xFF8CD0F0),
                              Color(0xFF111416)
                            ],
                            syncedLyrics: const [
                              'Local device audio track',
                              'Synced with Archive Tune engine',
                            ],
                            filePath: map['filePath']?.toString(),
                          );
                        }).toList();
                        setState(() {
                          _tracks.addAll(scanned);
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content:
                                Text('Added ${scanned.length} local tracks!'),
                          ),
                        );
                      }
                    } catch (_) {}
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
                          hintText: 'Search songs, artists, radios...',
                          hintStyle: const TextStyle(color: Colors.white54),
                          prefixIcon: const Icon(Icons.search,
                              color: Color(0xFF8CD0F0)),
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
                        child: ListView.builder(
                          controller: scrollController,
                          itemCount: filtered.length,
                          itemBuilder: (_, idx) {
                            final item = filtered[idx];
                            final masterIndex = _tracks.indexOf(item);
                            return ListTile(
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 4),
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
                              subtitle: Row(
                                children: [
                                  if (item.isExplicit) ...[
                                    const _ExplicitBadge(),
                                    const SizedBox(width: 6),
                                  ],
                                  Text(
                                    item.artist,
                                    style: const TextStyle(
                                      color: Color(0xFFA6ADB2),
                                    ),
                                  ),
                                ],
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                _loadAndPlayTrack(masterIndex, autoPlay: true);
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
                    const SizedBox(height: 16),
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
                        _audioPlayer.setSpeed(v);
                      },
                    ),
                    Text(
                      'Pitch Shift: ${_playbackPitch.toStringAsFixed(2)}x',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    Slider(
                      value: _playbackPitch,
                      min: 0.5,
                      max: 1.5,
                      divisions: 10,
                      activeColor: const Color(0xFF8CD0F0),
                      onChanged: (v) {
                        setSheetState(() => _playbackPitch = v);
                        setState(() => _playbackPitch = v);
                        try {
                          _audioPlayer.setPitch(v);
                        } catch (_) {}
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

  String _currentSyncedLyric(TrackItem track) {
    if (track.syncedLyrics.isEmpty) return '';
    if (track.id == 'lowkey_2' && _position.inSeconds == 108) {
      return 'Rolling up first then I\'m getting proceeds';
    }
    final idx =
        (_position.inSeconds ~/ 15).clamp(0, track.syncedLyrics.length - 1);
    return track.syncedLyrics[idx];
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.78;

    return Scaffold(
      backgroundColor: const Color(0xFF111416),
      body: Stack(
        children: [
          // Main scrollable content matching Archive Tune screenshot 2
          SafeArea(
            bottom: false,
            child: IndexedStack(
              index: _selectedBottomTab,
              children: [
                _buildHomeTab(),
                _buildMixTab(),
                _buildLibraryTab(),
              ],
            ),
          ),

          // Floating Mini-Player + Bottom Navigation Bar + Floating Search Button
          Positioned(
            left: 12,
            right: 12,
            bottom: MediaQuery.of(context).padding.bottom + 8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Mini-Player Pill
                GestureDetector(
                  onTap: _openFullScreenPlayer,
                  onHorizontalDragEnd: (details) {
                    if ((details.primaryVelocity ?? 0) < -200) {
                      _skipNext();
                    } else if ((details.primaryVelocity ?? 0) > 200) {
                      _skipPrevious();
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
                        // Circular album artwork wrapped inside light-blue progress arc
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
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                    Color(0xFF8AD0EE),
                                  ),
                                ),
                              ),
                              ClipOval(
                                child: SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: CustomAlbumArtwork(
                                    track: _currentTrack,
                                    showParentalBadge: false,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Title + [E] Artist
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _currentTrack.title,
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
                                  if (_currentTrack.isExplicit) ...[
                                    const _ExplicitBadge(),
                                    const SizedBox(width: 6),
                                  ],
                                  Expanded(
                                    child: Text(
                                      _currentTrack.artist,
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
                        // Heart circle button
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              if (_likedIds.contains(_currentTrack.id)) {
                                _likedIds.remove(_currentTrack.id);
                              } else {
                                _likedIds.add(_currentTrack.id);
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
                              _likedIds.contains(_currentTrack.id)
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              color: const Color(0xFFD5DCE0),
                              size: 21,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Light-blue circular Play/Pause button
                        GestureDetector(
                          onTap: _togglePlayPause,
                          child: Container(
                            width: 46,
                            height: 46,
                            decoration: const BoxDecoration(
                              color: Color(0xFF8AD0EE),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
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
                // Bottom Navigation Pill + Detached Circular Search Button
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
                            _buildNavTab(
                              index: 0,
                              icon: Icons.home_rounded,
                              label: 'Home',
                            ),
                            _buildNavTab(
                              index: 1,
                              icon: Icons.sensors_rounded,
                              label: 'Mix',
                            ),
                            _buildNavTab(
                              index: 2,
                              icon: Icons.library_music_rounded,
                              label: 'Library',
                            ),
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
  }

  Widget _buildNavTab({
    required int index,
    required IconData icon,
    required String label,
  }) {
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
                color: selected
                    ? const Color(0xFF8AD0EE)
                    : const Color(0xFFB3B9BE),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? const Color(0xFF8AD0EE)
                      : const Color(0xFFB3B9BE),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeTab() {
    // Quick picks items (first 4 match screenshot 2, plus second column peeking)
    final quickPicksColumn1 = [
      _tracks[1], // Wishing Well - Juice WRLD
      _tracks[2], // Feasting.On.The.Guts.Of.Angels. - Grim Salvo
      _tracks[3], // Gravewalker's Anthem - MOSSBACK
      _tracks[4], // MONEY ON THE DASH - Elley Duhé
    ];
    final quickPicksColumn2 = [
      _tracks[0], // Lowkey II - YCK
      _tracks[5], // Back to Life (Birthdae) - ScurtDae
      _tracks[6], // Life (feat. Faceless 1-7) - Venfex
      _tracks[7], // Scars in the Neon - 306Bobby
    ];

    final listenAgainTracks = [
      _tracks[5], // Back to Life (Birthdae) - ScurtDae
      _tracks[6], // Life (feat. Faceless 1-7) - Venfex
      _tracks[7], // Scars in the Neon - 306Bobby
      _tracks[0], // Lowkey II - YCK
    ];

    return ListView(
      padding: const EdgeInsets.only(top: 10, bottom: 185),
      children: [
        // Top header bar: Avatar, All & Mood chips, + button, Gear icon
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // Pixel-art style circular avatar matching screenshot 2
              Container(
                width: 46,
                height: 46,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: ClipOval(
                  child: CustomPaint(
                    painter: _PixelDragonAvatarPainter(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // "All" pill chip
              GestureDetector(
                onTap: () => setState(() => _selectedChip = 'All'),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: _selectedChip == 'All'
                        ? const Color(0xFF8AD0EE)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: _selectedChip == 'All'
                          ? const Color(0xFF8AD0EE)
                          : const Color(0xFF3A4146),
                    ),
                  ),
                  child: Text(
                    'All',
                    style: TextStyle(
                      color: _selectedChip == 'All'
                          ? const Color(0xFF062938)
                          : Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // "Mood" pill chip
              GestureDetector(
                onTap: () => setState(() => _selectedChip = 'Mood'),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: _selectedChip == 'Mood'
                        ? const Color(0xFF8AD0EE)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: _selectedChip == 'Mood'
                          ? const Color(0xFF8AD0EE)
                          : const Color(0xFF3A4146),
                    ),
                  ),
                  child: Text(
                    'Mood',
                    style: TextStyle(
                      color: _selectedChip == 'Mood'
                          ? const Color(0xFF062938)
                          : const Color(0xFFD5DCE0),
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              // Circular "+" button
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
                  child: const Icon(
                    Icons.add_rounded,
                    color: Color(0xFFD5DCE0),
                    size: 24,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Settings gear icon
              GestureDetector(
                onTap: _openSettingsSheet,
                child: const Icon(
                  Icons.settings_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // LET'S START WITH A RADIO / Quick picks
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
                onTap: () => _loadAndPlayTrack(1, autoPlay: true),
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

        // 4-row horizontal paging list with peeking second column on the right edge
        SizedBox(
          height: 280,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 16),
            children: [
              SizedBox(
                width: MediaQuery.of(context).size.width - 42,
                child: Column(
                  children: quickPicksColumn1
                      .map((track) => _buildQuickPickRow(track))
                      .toList(),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: MediaQuery.of(context).size.width - 42,
                child: Column(
                  children: quickPicksColumn2
                      .map((track) => _buildQuickPickRow(track))
                      .toList(),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 22),

        // 306BOBBY / Listen again
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '306BOBBY',
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

        // Large Square Album Cards for "Listen again"
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
                  _loadAndPlayTrack(masterIdx, autoPlay: true);
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

        const SizedBox(height: 18),

        // Bottom peeking section matching "STATION / Listen..." in screenshot 2
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'STATION',
                style: TextStyle(
                  color: Color(0xFF9EA6AC),
                  fontSize: 12,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w500,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Live radios for you',
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
        const SizedBox(height: 12),
        SizedBox(
          height: 180,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _tracks.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, idx) {
              final track = _tracks[(_tracks.length - 1) - idx];
              return GestureDetector(
                onTap: () => _loadAndPlayTrack(
                  _tracks.indexOf(track),
                  autoPlay: true,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 168,
                    height: 168,
                    child: CustomAlbumArtwork(track: track),
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
        _loadAndPlayTrack(masterIdx, autoPlay: true);
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
          style: TextStyle(
            color: Color(0xFF9EA6AC),
            fontSize: 12,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Your Archive Mixes',
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 16),
        ..._tracks.asMap().entries.map((entry) {
          final i = entry.key;
          final t = entry.value;
          return Card(
            color: const Color(0xFF1C2226),
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
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
                t.radioName,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(
                'Featuring ${t.artist} • ${t.title}',
                style: const TextStyle(color: Color(0xFFA6ADB2)),
              ),
              trailing: const CircleAvatar(
                backgroundColor: Color(0xFF8AD0EE),
                child: Icon(Icons.play_arrow_rounded, color: Color(0xFF062938)),
              ),
              onTap: () {
                _loadAndPlayTrack(i, autoPlay: true);
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
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: _importOrScanMusic,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('Import Local'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ..._tracks.asMap().entries.map((entry) {
          final idx = entry.key;
          final t = entry.value;
          return _buildQuickPickRow(t);
        }),
      ],
    );
  }

  // ===========================================================================
  // FULL-SCREEN NOW PLAYING UI (Identical to Screenshot 1)
  // ===========================================================================
  Widget _buildNowPlayingScreen(StateSetter setModalState) {
    final track = _currentTrack;
    final maxSeconds = max(track.durationSeconds, 1);
    final currentSeconds = _position.inSeconds.clamp(0, maxSeconds);

    return Scaffold(
      backgroundColor: track.playerBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              // Top Header: Circular Down Chevron | NOW PLAYING / "No Doubt" Radio | Rounded 3-Dots
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
                      child: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
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
                      child: const Icon(
                        Icons.more_vert_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ],
              ),

              const Spacer(flex: 2),

              // Center Rounded Square Album Artwork with Parental Advisory Badge
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

              // Synced Lyric Line directly above Song Title (matching Screenshot 1)
              Text(
                _currentSyncedLyric(track),
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

              // Song Title + [E] Artist on left, Circular (+) and (♡) buttons on right
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
                  // Add (+) circle button
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
                      child: Icon(
                        _savedIds.contains(track.id)
                            ? Icons.add_circle_outline_rounded
                            : Icons.add_circle_outline_rounded,
                        color: const Color(0xFFEAE0DC),
                        size: 24,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Heart (♡) circle button
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
                        _likedIds.contains(track.id)
                            ? Icons.favorite_border_rounded
                            : Icons.favorite_border_rounded,
                        color: const Color(0xFFEAE0DC),
                        size: 23,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              // Custom Material You Seekbar with end stop dot + timestamps
              Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4.5,
                      activeTrackColor: track.playerAccentPeach,
                      inactiveTrackColor: const Color(0xFF42312B),
                      thumbColor: track.playerAccentPeach,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7.5,
                      ),
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
                            final newPos = Duration(seconds: val.toInt());
                            setState(() => _position = newPos);
                            setModalState(() {});
                            _audioPlayer.seek(newPos);
                          },
                        ),
                        // Tiny peach dot at the right end of the inactive track
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
                        _formatDuration(_position),
                        style: const TextStyle(
                          color: Color(0xFFC8BDB7),
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _formatDuration(_duration),
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

              // Main Transport Controls Row: Brown Pill Prev | Wide Peach Pill Play | Brown Pill Next
              Row(
                children: [
                  // Skip Previous Button
                  GestureDetector(
                    onTap: () {
                      _skipPrevious();
                      setModalState(() {});
                    },
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
                  // Wide Center Peach Play/Pause Pill Button
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        _togglePlayPause();
                        setModalState(() {});
                      },
                      child: Container(
                        height: 70,
                        decoration: BoxDecoration(
                          color: track.playerAccentPeach,
                          borderRadius: BorderRadius.circular(35),
                        ),
                        child: Icon(
                          _isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: track.playerOnAccent,
                          size: 34,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Skip Next Button
                  GestureDetector(
                    onTap: () {
                      _skipNext();
                      setModalState(() {});
                    },
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

              // 7-Segment Bottom Action Bar (matching Screenshot 1)
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
                              content: Text('Audio Output: High-Res Active'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 3),
                      _buildSegmentedBottomBtn(
                        icon: Icons.shuffle_rounded,
                        surface: _isShuffle
                            ? track.playerButtonBrown
                            : track.playerSurface,
                        onTap: () {
                          setState(() => _isShuffle = !_isShuffle);
                          setModalState(() {});
                        },
                      ),
                      const SizedBox(width: 3),
                      _buildSegmentedBottomBtn(
                        icon: _repeatMode == 2
                            ? Icons.repeat_one_rounded
                            : Icons.repeat_rounded,
                        surface: _repeatMode > 0
                            ? track.playerButtonBrown
                            : track.playerSurface,
                        onTap: () {
                          setState(() => _repeatMode = (_repeatMode + 1) % 3);
                          setModalState(() {});
                        },
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
          child: Icon(
            icon,
            color: const Color(0xFFEAE0DC),
            size: 21,
          ),
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
            Text('Artist: ${track.artist}',
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 6),
            Text('Album: ${track.album}',
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 6),
            Text('Station: ${track.radioName}',
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 6),
            const Text('Codec: 24-bit / 48kHz Lossless Engine',
                style: TextStyle(color: Color(0xFFFFB59C))),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close',
                style: TextStyle(color: Color(0xFFFFB59C))),
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
              subtitle: Text(
                t.artist,
                style: const TextStyle(color: Colors.white70),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _loadAndPlayTrack(idx, autoPlay: true);
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
                '${track.title} — Synced Lyrics',
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
    this.showParentalBadge = true,
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
        if (track.artStyle == 'birthdae_columns')
          const Positioned(
            top: 10,
            left: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'B I R T H D A E',
                  style: TextStyle(
                    color: Color(0xFFE0E0DD),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                    fontFamily: 'serif',
                  ),
                ),
                Text(
                  'S C U R T D A E',
                  style: TextStyle(
                    color: Color(0xFFC5C5C0),
                    fontSize: 9,
                    letterSpacing: 1.2,
                    fontFamily: 'serif',
                  ),
                ),
              ],
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
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
                  Text(
                    'EXPLICIT CONTENT',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: largeBadge ? 5.8 : 3.8,
                      fontWeight: FontWeight.w700,
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

    if (style == 'window_sunset') {
      // Recreates the warm sunset room with window blinds & houseplant from Screenshot 1
      final windowRect = Rect.fromLTWH(
        size.width * 0.56,
        size.height * 0.22,
        size.width * 0.38,
        size.height * 0.55,
      );
      canvas.drawRect(
        windowRect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFFFDFC2),
              Color(0xFFE7A98B),
              Color(0xFF8C7A78),
            ],
          ).createShader(windowRect),
      );
      // Horizontal window blinds
      final blindPaint = Paint()
        ..color = const Color(0xFF4B2B1B).withOpacity(0.55)
        ..strokeWidth = 2.0;
      for (double y = windowRect.top; y < windowRect.bottom; y += 7) {
        canvas.drawLine(
          Offset(windowRect.left, y),
          Offset(windowRect.right, y),
          blindPaint,
        );
      }
      // Warm orange wall sunbeams on left wall
      final beamPaint = Paint()
        ..color = const Color(0xFFFF6D24).withOpacity(0.42);
      canvas.drawRect(
        Rect.fromLTWH(
            0, size.height * 0.25, size.width * 0.34, size.height * 0.45),
        beamPaint,
      );
      // Indoor leafy plant silhouette in center
      final plantPaint = Paint()..color = const Color(0xFF1F160E);
      for (int i = 0; i < 16; i++) {
        final angle = (i / 16) * pi * 2;
        final cx = size.width * 0.48 + cos(angle) * size.width * 0.12;
        final cy = size.height * 0.52 + sin(angle) * size.height * 0.14;
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(cx, cy),
            width: size.width * 0.14,
            height: size.height * 0.06,
          ),
          plantPaint,
        );
      }
    } else if (style == 'twin_hoodies') {
      // Starry night sky + golden clouds + 2 blue hoodie figures from Screenshot 2
      final cloudPaint = Paint()..color = const Color(0xFFE59A28);
      canvas.drawCircle(
          Offset(size.width * 0.15, size.height * 0.85), 26, cloudPaint);
      canvas.drawCircle(
          Offset(size.width * 0.85, size.height * 0.82), 30, cloudPaint);
      final figurePaint = Paint()..color = const Color(0xFF0A2239);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(size.width * 0.30, size.height * 0.48,
              size.width * 0.18, size.height * 0.45),
          const Radius.circular(12),
        ),
        figurePaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(size.width * 0.52, size.height * 0.46,
              size.width * 0.18, size.height * 0.47),
          const Radius.circular(12),
        ),
        figurePaint,
      );
    } else if (style == 'birthdae_columns') {
      // Monochrome classical pillars scene from Screenshot 2
      final colPaint = Paint()..color = const Color(0xFFD2D4D0);
      for (int i = 0; i < 4; i++) {
        final x = size.width * (0.16 + i * 0.21);
        final top = size.height * (0.35 + (i % 2) * 0.08);
        canvas.drawRect(
          Rect.fromLTWH(x, top, size.width * 0.07, size.height * 0.45),
          colPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PixelDragonAvatarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0xFF1A2859);
    final dots = [
      const Offset(0.3, 0.25),
      const Offset(0.45, 0.2),
      const Offset(0.6, 0.3),
      const Offset(0.35, 0.45),
      const Offset(0.5, 0.5),
      const Offset(0.28, 0.65),
      const Offset(0.42, 0.72),
    ];
    for (final d in dots) {
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(size.width * d.dx, size.height * d.dy),
          width: size.width * 0.16,
          height: size.height * 0.16,
        ),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
