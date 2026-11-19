import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// AI features used all over the app: search help, AI picks, AI mixes and
/// song info. Everything goes through [AiHelper], which talks to the same free
/// text model as the AI DJ chat. If the AI can't be reached, every feature
/// quietly hides itself and the normal app keeps working.

class AiSong {
  final String title;
  final String artist;
  const AiSong(this.title, this.artist);
  String get query => '$title $artist'.trim();
  String get label => artist.isEmpty ? title : '$title · $artist';
}

class AiSearchResult {
  final String corrected; // the query with typos fixed
  final String kind; // song | artist | album | mood | other
  final String note; // short friendly line from the AI
  final List<AiSong> picks;
  const AiSearchResult(this.corrected, this.kind, this.note, this.picks);
}

class AiHelper {
  static final Map<String, AiSearchResult?> _searchCache = {};
  static final Map<String, List<AiSong>> _mixCache = {};
  static final Map<String, String> _infoCache = {};

  static const MethodChannel _ytCh = MethodChannel('com.alexlmp.app/ytmusic');

  static String? lastProblem;

  /// What the app knows about your listening (set in main.dart).
  static String Function()? taste;

  static String tasteText() {
    try {
      return taste?.call() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Sends a whole conversation to the AI and returns its reply.
  ///
  /// Tries, in order: your own AI service and key (Settings > AI), the free
  /// Pollinations endpoint, the older Pollinations endpoint, and finally a
  /// small built-in fallback so commands still work offline.
  static Future<String?> ask(
    List<Map<String, String>> messages, {
    int maxTokens = 700,
    Duration timeout = const Duration(seconds: 30),
    bool json = false,
    double temperature = 0.8,
    bool allowLocal = true,
  }) async {
    await AiConfig.load();
    lastProblem = null;
    final problems = <String>[];

    Future<String?> post(String url, String? key, String model,
        {bool jsonMode = false}) async {
      final client = http.Client();
      try {
        final body = <String, dynamic>{
          'model': model,
          'messages': messages,
          'max_tokens': maxTokens,
          'temperature': temperature,
          if (jsonMode) 'response_format': {'type': 'json_object'},
        };
        final res = await client
            .post(
              Uri.parse(url),
              headers: {
                'Content-Type': 'application/json',
                if (key != null && key.isNotEmpty) 'Authorization': 'Bearer $key',
              },
              body: jsonEncode(body),
            )
            .timeout(timeout);
        final text = utf8.decode(res.bodyBytes);
        if (res.statusCode != 200) {
          problems.add('$url -> HTTP ${res.statusCode}: '
              '${text.length > 220 ? text.substring(0, 220) : text}');
          // Some models don't support JSON mode: try once without it.
          if (jsonMode && res.statusCode == 400) {
            return post(url, key, model);
          }
          return null;
        }
        final j = jsonDecode(text);
        final out = (j['choices']?[0]?['message']?['content'] ?? '')
            .toString()
            .trim();
        if (out.isEmpty) {
          problems.add('$url -> empty reply');
          return null;
        }
        return out;
      } catch (e) {
        problems.add('$url -> $e');
        return null;
      } finally {
        client.close();
      }
    }

    final base = AiConfig.base.replaceAll(RegExp(r'/+$'), '');
    final key = AiConfig.key;

    // 1. Your service + key.
    var r = await post('$base/chat/completions', key, AiConfig.model,
        jsonMode: json);
    // 2. The free Pollinations gateway with a standard model.
    if (r == null && (key.isEmpty || !base.contains('pollinations'))) {
      r = await post('https://gen.pollinations.ai/v1/chat/completions',
          base.contains('pollinations') ? key : null, 'openai',
          jsonMode: json);
    }
    if (r == null && AiConfig.model != 'openai' && base.contains('pollinations')) {
      r = await post('$base/chat/completions', key, 'openai', jsonMode: json);
    }
    // 3. The older free endpoint (no key).
    r ??= await post('https://text.pollinations.ai/openai', null, 'openai');
    if (r != null) {
      final low = r.toLowerCase();
      if (r.startsWith('<') ||
          low.contains('rate limit') ||
          low.contains('enter.pollinations.ai')) {
        problems.add('AI service answered: ${r.length > 160 ? r.substring(0, 160) : r}');
        r = null;
      }
    }
    if (r != null) return r;

    lastProblem = problems.join('\n');
    if (!allowLocal) return null;
    var sys = '';
    for (final m in messages) {
      if (m['role'] == 'system') {
        sys = m['content'] ?? '';
        break;
      }
    }
    final usr = messages.isNotEmpty ? (messages.last['content'] ?? '') : '';
    return _localBrain(sys, usr);
  }

  /// A short spoken DJ line (no tags), or null if the AI isn't reachable.
  static Future<String?> djLine(
    String kind, {
    required String justPlayed,
    required String next,
    String taste = '',
  }) async {
    final sys =
        'You are the AI DJ inside AlexLMP, a music player. You talk to ONE listener like a real radio host: '
        'warm, confident, natural, a little playful. Write ONE spoken line, 14 to 34 words, no emojis, '
        'no hashtags, no quotes, no stage directions, nothing in brackets. Mention the artist (and song if it '
        'sounds natural) of what plays next, and say something real and specific about it or why it fits right now '
        '(the mood, the time of day, their taste). Never invent fake facts; if unsure, talk about the vibe.';
    final usr = [
      'Moment: $kind.',
      if (justPlayed.isNotEmpty) 'Just played: $justPlayed.',
      'Next song: $next.',
      if (kind == 'skip') 'They just skipped two songs fast, so acknowledge it and promise a different direction.',
      if (kind == 'intro') 'This is the very start of their DJ session: greet them first.',
      if (taste.isNotEmpty) 'About the listener:\n$taste',
    ].join('\n');
    final r = await ask(
      [
        {'role': 'system', 'content': sys},
        {'role': 'user', 'content': usr},
      ],
      maxTokens: 120,
      temperature: 0.95,
      timeout: const Duration(seconds: 9),
      allowLocal: false,
    );
    if (r == null) return null;
    final clean = r
        .replaceAll(RegExp(r'\[\[.*?\]\]'), '')
        .replaceAll(RegExp(r'[*_#"“”]'), '')
        .trim();
    return clean.isEmpty ? null : clean;
  }

  static Future<String> _localBrain(String sys, String usr) async {
    final q = usr.trim();
    final low = q.toLowerCase();

    if (sys.contains('search brain of a music player')) {
      final picks = <Map<String, String>>[];
      try {
        final raw = await _ytCh.invokeMethod('ytSearch', {'query': q}) as List? ?? const [];
        for (final item in raw.take(6)) {
          if (item is Map) {
            final t = (item['title'] ?? '').toString().trim();
            final a = (item['artist'] ?? '').toString().trim();
            if (t.isNotEmpty) picks.add({'t': t, 'a': a});
          }
        }
      } catch (_) {}
      return jsonEncode({
        'corrected': q,
        'kind': 'song',
        'note': 'Top matches for "$q"',
        'picks': picks,
      });
    }

    if (sys.contains('You build playlists for a music player')) {
      final out = <Map<String, String>>[];
      try {
        final raw = await _ytCh.invokeMethod('ytSearch', {'query': '$q mix'}) as List? ?? const [];
        for (final item in raw.take(10)) {
          if (item is Map) {
            final t = (item['title'] ?? '').toString().trim();
            final a = (item['artist'] ?? '').toString().trim();
            if (t.isNotEmpty) out.add({'t': t, 'a': a});
          }
        }
      } catch (_) {}
      return jsonEncode(out);
    }

    final nowMatch = RegExp(r'Now playing:\s*(.+)\.\$').firstMatch(sys);
    final nowPlaying = nowMatch?.group(1)?.trim() ?? '';

    if (RegExp(r'^(hi|hey|hello|yo|sup|what.*up)\b').hasMatch(low)) {
      return nowPlaying.isNotEmpty
          ? "Yo! We've got $nowPlaying spinning right now. Tell me a song, artist, or vibe you want next—or say \"make me a mix\"."
          : "Yo! I'm your AlexLMP DJ. Tell me any song or artist to play, ask for a workout or late-night mix, or tell me to shuffle your library.";
    }
    if (low.contains('what') && (low.contains('playing') || low.contains('this song'))) {
      return nowPlaying.isNotEmpty
          ? "Right now you're listening to $nowPlaying. Want more tracks with this vibe?"
          : "Nothing's playing yet—tell me a track or artist and I'll drop it right now.";
    }
    if (low.contains('workout') || low.contains('gym') || low.contains('hype')) {
      return "Bet, locking in a high-energy hype mix for you right now.\n[[mix: hype workout rage trap]]";
    }
    if (low.contains('chill') || low.contains('late night') || low.contains('rain') || low.contains('study')) {
      return "Got you—queuing up a smooth late-night chill session.\n[[mix: late night chill underground]]";
    }
    if (low.contains('more like') || low.contains('similar')) {
      final seed = nowPlaying.isNotEmpty ? nowPlaying : 'underground rap hits';
      return "Pulling up a fresh mix inspired by $seed.\n[[mix:$seed]]";
    }
    if (low.contains('mix') || low.contains('playlist') || low.contains('something')) {
      final cleanVibe = q
          .replaceAll(RegExp(r'^(make|build|play|give)\s+(me\s+)?(a\s+)?(mix|playlist|something)\s*(for|of|like)?\s*', caseSensitive: false), '')
          .trim();
      final target = cleanVibe.isEmpty ? (nowPlaying.isNotEmpty ? nowPlaying : 'popular hits') : cleanVibe;
      return "Cooking up a custom mix for $target right now.\n[[mix:$target]]";
    }
    if (low.startsWith('play ') || low.startsWith('put on ')) {
      final target = q.replaceFirst(RegExp(r'^(play|put on)\s+', caseSensitive: false), '').trim();
      return "On it—loading up $target.\n[[play:$target]]";
    }
    if (low.startsWith('queue ') || low.startsWith('add ')) {
      final target = q.replaceFirst(RegExp(r'^(queue|add)\s+', caseSensitive: false), '').trim();
      return "Adding $target to your queue.\n[[queue:$target]]";
    }
    if (low.contains('skip') || low.contains('next')) {
      return "Skipping to the next track.\n[[next]]";
    }
    if (low.contains('pause') || low.contains('stop')) {
      return "Pausing playback.\n[[pause]]";
    }
    if (low.contains('shuffle')) {
      return "Shuffling your rotation.\n[[shuffle]]";
    }

    return "Got you—let's spin some $q right now.\n[[play:$q]]";
  }

  static String problemText() => lastProblem == null || lastProblem!.isEmpty
      ? "Ready to spin, tell me any song, artist, or mood."
      : "Couldn't reach the AI right now.\n\nDetails: $lastProblem";

  static dynamic _json(String s) {
    final text = s.replaceAll(RegExp(r'```(?:json)?'), '').trim();
    for (final pair in const [('{', '}'), ('[', ']')]) {
      final a = text.indexOf(pair.$1);
      final b = text.lastIndexOf(pair.$2);
      if (a >= 0 && b > a) {
        try {
          return jsonDecode(text.substring(a, b + 1));
        } catch (_) {}
      }
    }
    return null;
  }

  static List<AiSong> _songs(dynamic list, {int max = 10}) {
    final out = <AiSong>[];
    final seen = <String>{};
    if (list is List) {
      for (final e in list) {
        if (e is! Map) continue;
        final t = ('${e['t'] ?? e['title'] ?? ''}').trim();
        final a = ('${e['a'] ?? e['artist'] ?? ''}').trim();
        if (t.isEmpty) continue;
        if (!seen.add('${t.toLowerCase()}|${a.toLowerCase()}')) continue;
        out.add(AiSong(t, a));
        if (out.length >= max) break;
      }
    }
    return out;
  }

  static Future<AiSearchResult?> interpretSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return null;
    final key = q.toLowerCase();
    if (_searchCache.containsKey(key)) return _searchCache[key];
    final taste = tasteText();
    final reply = await ask([
      {
        'role': 'system',
        'content':
            'You are the search brain of a music player. Read what the user typed and reply with JSON only: '
                '{"corrected": "<the search with typos fixed>", "kind": "song|artist|album|playlist|mood", '
                '"note": "<one short friendly line about what you found, max 12 words>", '
                '"picks": [{"t": "<real song title>", "a": "<real artist>"}]}. '
                'Give 8 real, existing songs that best match: exact songs if they named one, otherwise songs '
                'for the mood, genre, era or activity. Prefer songs that fit the listener below. '
                'Never invent songs.${taste.isEmpty ? '' : '\n\nListener:\n$taste'}'
      },
      {'role': 'user', 'content': q},
    ], maxTokens: 600, json: true, temperature: 0.4, timeout: const Duration(seconds: 15));
    final j = reply == null ? null : _json(reply);
    if (j is Map) {
      final r = AiSearchResult(
        ('${j['corrected'] ?? q}').trim().isEmpty ? q : '${j['corrected']}',
        '${j['kind'] ?? 'song'}',
        ('${j['note'] ?? ''}').trim().isEmpty ? 'Top picks for "$q"' : '${j['note']}',
        _songs(j['picks'], max: 8),
      );
      if (r.picks.isNotEmpty) {
        _searchCache[key] = r;
        return r;
      }
    }
    // Fallback: plain YouTube Music matches.
    final local = _json(await _localBrain('search brain of a music player', q));
    if (local is Map) {
      return AiSearchResult(q, 'song', 'Top picks for "$q"', _songs(local['picks'], max: 8));
    }
    return null;
  }

  /// Real songs for a vibe, a request, or "more like this". Uses what the
  /// listener likes and avoids what they just heard.
  static Future<List<AiSong>> mix(String vibe,
      {int count = 10, String nowPlaying = '', bool fresh = false}) async {
    final v = vibe.trim().isEmpty ? nowPlaying : vibe.trim();
    final key = '${v.toLowerCase()}|$count';
    if (!fresh && _mixCache.containsKey(key)) return _mixCache[key]!;
    final taste = tasteText();
    final reply = await ask([
      {
        'role': 'system',
        'content':
            'You build playlists for a music player like a great human DJ. Reply with JSON only: '
                '{"songs": [{"t": "<real song title>", "a": "<real artist>"}]}. '
                'Give exactly $count real, existing songs (no duplicates, no made-up titles) in an order that flows: '
                'smooth energy, tempo and mood changes, varied artists (max 2 per artist). '
                'Fit the request first, then the listener\'s taste. Do not repeat songs they just played or that are up next.'
                '${taste.isEmpty ? '' : '\n\nListener:\n$taste'}'
      },
      {
        'role': 'user',
        'content': nowPlaying.isEmpty ? 'Request: $v' : 'Request: $v\nCurrently playing: $nowPlaying'
      },
    ], maxTokens: 900, json: true, temperature: fresh ? 1.0 : 0.8, timeout: const Duration(seconds: 25));
    var list = <AiSong>[];
    if (reply != null) {
      final j = _json(reply);
      list = _songs(j is Map ? (j['songs'] ?? j['picks'] ?? j['playlist']) : j, max: count);
    }
    if (list.isEmpty) {
      list = _songs(_json(await _localBrain('You build playlists for a music player', v)), max: count);
    }
    if (list.isNotEmpty && !fresh) _mixCache[key] = list;
    return list;
  }

  static Future<String?> songInfo(String title, String artist) async {
    final cleanT = title.trim();
    final cleanA = (artist.trim().isEmpty || artist == 'Unknown Artist') ? '' : artist.trim();
    final key = '${cleanT.toLowerCase()}|${cleanA.toLowerCase()}';
    if (_infoCache.containsKey(key)) return _infoCache[key];

    String? albumTitle;
    String? releaseYear;
    String? albumKind;
    String? albumInfo;
    String? realDescription;
    final realSimilar = <AiSong>[];
    final seenTitles = <String>{cleanT.toLowerCase()};

    try {
      final query = cleanA.isEmpty ? cleanT : '$cleanT $cleanA';
      final searchRaw = await _ytCh.invokeMethod('ytSearch', {'query': query}) as List? ?? const [];
      String? videoId;

      for (final item in searchRaw) {
        if (item is! Map) continue;
        final vid = (item['videoId'] ?? '').toString();
        final t = (item['title'] ?? '').toString().trim();
        final a = (item['artist'] ?? '').toString().trim();
        if (videoId == null && vid.isNotEmpty) {
          videoId = vid;
        }
        if (t.isNotEmpty && seenTitles.add(t.toLowerCase()) && realSimilar.length < 4) {
          realSimilar.add(AiSong(t, a));
        }
      }

      if (realSimilar.length < 3 && cleanA.isNotEmpty) {
        final artistRaw = await _ytCh.invokeMethod('ytSearch', {'query': cleanA}) as List? ?? const [];
        for (final item in artistRaw) {
          if (item is! Map) continue;
          final t = (item['title'] ?? '').toString().trim();
          final a = (item['artist'] ?? '').toString().trim();
          if (t.isNotEmpty && seenTitles.add(t.toLowerCase()) && realSimilar.length < 4) {
            realSimilar.add(AiSong(t, a));
          }
        }
      }

      if (videoId != null && videoId.isNotEmpty) {
        final links = await _ytCh.invokeMethod('ytTrackLinks', {'videoId': videoId});
        if (links is Map) {
          albumTitle = (links['albumTitle'] ?? '').toString().trim();
          final browseId = (links['albumBrowseId'] ?? '').toString().trim();
          final albumUrl = (links['albumUrl'] ?? '').toString().trim();
          final ref = browseId.isNotEmpty ? browseId : albumUrl;
          if (ref.isNotEmpty) {
            try {
              final alb = await _ytCh.invokeMethod('ytAlbumPage', {'ref': ref});
              if (alb is Map) {
                albumTitle = (alb['title'] ?? albumTitle ?? '').toString().trim();
                releaseYear = (alb['year'] ?? '').toString().trim();
                albumKind = (alb['kind'] ?? '').toString().trim();
                albumInfo = (alb['info'] ?? '').toString().trim();
                realDescription = (alb['description'] ?? '').toString().trim();
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    final facts = <String>[
      if (cleanA.isNotEmpty) 'Artist: $cleanA',
      if (albumTitle != null && albumTitle.isNotEmpty)
        'Release: $albumTitle${(releaseYear != null && releaseYear.isNotEmpty) ? " ($releaseYear)" : ""}',
      if (albumKind != null && albumKind.isNotEmpty && albumInfo != null && albumInfo.isNotEmpty)
        '$albumKind · $albumInfo',
    ];

    String bodyText;
    if (realDescription != null && realDescription.isNotEmpty) {
      bodyText = '${facts.join(" • ")}\n\n$realDescription';
    } else if (facts.isNotEmpty) {
      bodyText = '${facts.join("\n")}\n\n'
          '"$cleanT" is an official release${cleanA.isNotEmpty ? " by $cleanA" : ""}'
          '${(albumTitle != null && albumTitle.isNotEmpty) ? " featured on $albumTitle" : ""}.';
    } else {
      bodyText = '"$cleanT"${cleanA.isNotEmpty ? " by $cleanA" : ""} — tap any track below to jump into related songs.';
    }

    // Ask the AI what the song is about, using the real facts above.
    try {
      final reply = await ask([
        {
          'role': 'system',
          'content':
              'You are a music expert inside a music player. Reply with JSON only: '
                  '{"about": "<3 to 5 sentences: what the song is about, its sound, where it fits in the artist\'s '
                  'work, and one interesting real detail. Only say things you are confident are true; if you do '
                  'not know the song, describe its likely mood from the title and artist and say so.>", '
                  '"similar": [{"t": "<real song>", "a": "<real artist>"}]} with 4 similar real songs.'
        },
        {
          'role': 'user',
          'content': 'Song: $cleanT${cleanA.isEmpty ? '' : ' by $cleanA'}\nFacts: ${facts.join('; ')}'
              '${(realDescription ?? '').isEmpty ? '' : '\nAlbum notes: ${realDescription!.length > 600 ? realDescription.substring(0, 600) : realDescription}'}'
        },
      ], maxTokens: 500, json: true, temperature: 0.5, timeout: const Duration(seconds: 18), allowLocal: false);
      final j = reply == null ? null : _json(reply);
      if (j is Map) {
        final about = ('${j['about'] ?? ''}').trim();
        if (about.isNotEmpty) {
          bodyText = facts.isEmpty ? about : '${facts.join(" • ")}\n\n$about';
        }
        final sim = _songs(j['similar'], max: 4);
        if (sim.isNotEmpty) {
          realSimilar
            ..clear()
            ..addAll(sim);
        }
      }
    } catch (_) {}

    final simString = realSimilar.isEmpty
        ? ''
        : '\nSimilar: ${realSimilar.map((s) => "${s.title} - ${s.artist}").join(" | ")}';

    final fullResult = '$bodyText$simString';
    _infoCache[key] = fullResult;
    return fullResult;
  }

  static ({String text, List<AiSong> similar}) parseInfo(String raw) {
    final i = raw.toLowerCase().lastIndexOf('similar:');
    if (i < 0) return (text: raw.trim(), similar: const <AiSong>[]);
    final text = raw.substring(0, i).trim();
    final out = <AiSong>[];
    for (final part in raw.substring(i + 8).split('|')) {
      final bits = part.trim().split(RegExp(r'\s+[-–—]\s+'));
      if (bits.first.trim().isEmpty) continue;
      out.add(AiSong(bits.first.trim(), bits.length > 1 ? bits[1].trim() : ''));
    }
    return (text: text, similar: out);
  }
}

// ═════════════════════════════ Widgets ═════════════════════════════

/// The little rainbow sparkle used wherever the AI is involved.
class AiSpark extends StatelessWidget {
  final double size;
  const AiSpark({super.key, this.size = 20});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (r) => const LinearGradient(
        colors: [Color(0xFF22D3EE), Color(0xFF8B5CF6), Color(0xFFF472B6)],
      ).createShader(r),
      child: Icon(Icons.auto_awesome_rounded, size: size, color: Colors.white),
    );
  }
}

/// Shows under a search: "Did you mean...", and the songs the AI thinks you
/// are looking for. Hides itself if the AI has nothing to add.
class AiSearchPanel extends StatefulWidget {
  final String query;
  final void Function(AiSong song) onPick;
  final void Function(List<AiSong> songs) onPlayAll;
  final void Function(String query) onUseQuery;
  final Color accent;
  final Color surface;
  final Color text;
  final Color subtext;

  const AiSearchPanel({
    super.key,
    required this.query,
    required this.onPick,
    required this.onPlayAll,
    required this.onUseQuery,
    required this.accent,
    required this.surface,
    this.text = Colors.white,
    this.subtext = Colors.white60,
  });

  @override
  State<AiSearchPanel> createState() => _AiSearchPanelState();
}

class _AiSearchPanelState extends State<AiSearchPanel> {
  late Future<AiSearchResult?> _f;

  @override
  void initState() {
    super.initState();
    _f = AiHelper.interpretSearch(widget.query);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AiSearchResult?>(
      future: _f,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return _thinking();
        final r = snap.data;
        if (r == null) return const SizedBox.shrink();
        final changed = r.corrected.trim().toLowerCase() !=
                widget.query.trim().toLowerCase() &&
            r.corrected.trim().isNotEmpty;
        if (!changed && r.picks.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (changed) _didYouMean(r.corrected),
              if (r.picks.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const AiSpark(size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        r.note.isNotEmpty ? r.note : 'AI picks for "${widget.query}"',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: widget.text,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        widget.onPlayAll(r.picks);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: widget.accent.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.play_arrow_rounded,
                                size: 18, color: widget.accent),
                            const SizedBox(width: 2),
                            Text('Play all',
                                style: TextStyle(
                                    color: widget.accent,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w800)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: widget.surface,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    children: [
                      for (final s in r.picks)
                        InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            widget.onPick(s);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(s.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: widget.text,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700)),
                                      if (s.artist.isNotEmpty)
                                        Text(s.artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                color: widget.subtext,
                                                fontSize: 12.5)),
                                    ],
                                  ),
                                ),
                                Icon(Icons.play_circle_rounded,
                                    color: widget.accent, size: 28),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _didYouMean(String fixed) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onUseQuery(fixed);
      },
      child: Container(
        margin: const EdgeInsets.only(top: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: widget.accent.withOpacity(0.14),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            const AiSpark(size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: TextStyle(color: widget.subtext, fontSize: 14),
                  children: [
                    const TextSpan(text: 'Did you mean '),
                    TextSpan(
                        text: fixed,
                        style: TextStyle(
                            color: widget.text, fontWeight: FontWeight.w800)),
                    const TextSpan(text: '?'),
                  ],
                ),
              ),
            ),
            Icon(Icons.arrow_forward_rounded, size: 18, color: widget.accent),
          ],
        ),
      ),
    );
  }

  Widget _thinking() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
      child: Row(
        children: [
          const AiSpark(size: 18),
          const SizedBox(width: 10),
          Text('AI is finding the best matches…',
              style: TextStyle(color: widget.subtext, fontSize: 13.5)),
          const SizedBox(width: 10),
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: widget.accent),
          ),
        ],
      ),
    );
  }
}

/// Tappable ideas shown when the search box is empty.
class AiPromptChips extends StatelessWidget {
  final void Function(String prompt) onTap;
  final Color accent;
  final Color surface;
  final Color text;
  const AiPromptChips({
    super.key,
    required this.onTap,
    required this.accent,
    required this.surface,
    this.text = Colors.white,
  });

  static const List<String> prompts = [
    'songs for a rainy night',
    'gym hype',
    'late night drive',
    'focus and study',
    'sad songs that hit hard',
    'throwback 2000s hits',
    'chill sunday morning',
    'party starters',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const AiSpark(size: 18),
            const SizedBox(width: 8),
            Text('Ask AI for anything',
                style: TextStyle(
                    color: text, fontSize: 16, fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in prompts)
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  onTap(p);
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: accent.withOpacity(0.35)),
                  ),
                  child: Text(p,
                      style: TextStyle(color: text, fontSize: 13.5)),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A card that builds and plays an AI mix when tapped (used on Home).
class AiMixCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final Future<String> Function() onStart; // returns a short result line
  final Color surface;
  final Color text;
  final Color subtext;
  final Color accent;

  const AiMixCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onStart,
    required this.surface,
    required this.text,
    required this.subtext,
    required this.accent,
  });

  @override
  State<AiMixCard> createState() => _AiMixCardState();
}

class _AiMixCardState extends State<AiMixCard> {
  bool _busy = false;
  String? _result;

  Future<void> _go() async {
    if (_busy) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _busy = true;
      _result = null;
    });
    String r;
    try {
      r = await widget.onStart();
    } catch (_) {
      r = "Couldn't build that mix right now.";
    }
    if (!mounted) return;
    HapticFeedback.lightImpact();
    setState(() {
      _busy = false;
      _result = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _go,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF22D3EE).withOpacity(0.20),
              const Color(0xFF8B5CF6).withOpacity(0.22),
              const Color(0xFFF472B6).withOpacity(0.20),
            ],
          ),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.35), shape: BoxShape.circle),
              child: Center(
                child: _busy
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: widget.accent))
                    : const AiSpark(size: 26),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title,
                      style: TextStyle(
                          color: widget.text,
                          fontSize: 16.5,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(_busy ? 'Building your mix…' : (_result ?? widget.subtitle),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: widget.subtext, fontSize: 13)),
                ],
              ),
            ),
            Icon(Icons.play_circle_fill_rounded, color: widget.accent, size: 34),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet for the player: what the song is about, plus similar songs.
Future<void> showAiSongInfo(
  BuildContext context, {
  required String title,
  required String artist,
  required void Function(AiSong song) onPlay,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF0B0B10),
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (ctx) => _AiSongInfoSheet(
        title: title, artist: artist, onPlay: (s) {
      Navigator.of(ctx).pop();
      onPlay(s);
    }),
  );
}

class _AiSongInfoSheet extends StatelessWidget {
  final String title;
  final String artist;
  final void Function(AiSong song) onPlay;
  const _AiSongInfoSheet(
      {required this.title, required this.artist, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.78;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const AiSpark(size: 22),
                  const SizedBox(width: 8),
                  const Text('About this song',
                      style: TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4)),
                ],
              ),
              const SizedBox(height: 8),
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      height: 1.15)),
              if (artist.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(artist,
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 15)),
                ),
              const SizedBox(height: 16),
              FutureBuilder<String?>(
                future: AiHelper.songInfo(title, artist),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 30),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final raw = snap.data;
                  if (raw == null) {
                    return const Text(
                        "Couldn't reach the AI right now. Try again in a moment.",
                        style: TextStyle(color: Colors.white60, fontSize: 15));
                  }
                  final info = AiHelper.parseInfo(raw);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.text,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15.5,
                              height: 1.45)),
                      if (info.similar.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        const Text('Similar songs',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        for (final s in info.similar)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(s.title,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700)),
                            subtitle: Text(s.artist,
                                style: const TextStyle(color: Colors.white54)),
                            trailing: const Icon(Icons.play_circle_rounded,
                                color: Color(0xFF8B5CF6), size: 30),
                            onTap: () => onPlay(s),
                          ),
                      ],
                    ],
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


// ═════════════════════════════ Settings ═════════════════════════════

/// Where the AI lives. Works with Pollinations (free key from
/// enter.pollinations.ai) or any OpenAI-compatible service.
class AiConfig {
  static String key = '';
  static String base = 'https://gen.pollinations.ai/v1';
  static String model = 'openai';
  static bool _loaded = false;
  static bool get hasKey => key.isNotEmpty;

  static Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final p = await SharedPreferences.getInstance();
      key = (p.getString('ai_key') ?? '').trim();
      final b = (p.getString('ai_base') ?? '').trim();
      final m = (p.getString('ai_model') ?? '').trim();
      if (b.isNotEmpty) base = b;
      // The old default model name doesn't exist on the free service.
      if (m.isNotEmpty && m != 'openai/gpt-5.4-nano') model = m;
    } catch (_) {}
    _loaded = true;
  }

  static Future<void> save(String k, String b, String m) async {
    key = k.trim();
    base = b.trim().isEmpty ? 'https://gen.pollinations.ai/v1' : b.trim();
    model = m.trim().isEmpty ? 'openai' : m.trim();
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('ai_key', key);
      await p.setString('ai_base', base);
      await p.setString('ai_model', model);
    } catch (_) {}
  }
}

/// Dialog to paste an AI key, with a test button.
Future<void> showAiSetup(BuildContext context) async {
  await AiConfig.load(force: true);
  if (!context.mounted) return;
  final keyC = TextEditingController(text: AiConfig.key);
  final baseC = TextEditingController(text: AiConfig.base);
  final modelC = TextEditingController(text: AiConfig.model);
  String status = '';
  bool busy = false;
  bool advanced = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        backgroundColor: const Color(0xFF14141C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Row(children: [
          AiSpark(size: 22),
          SizedBox(width: 10),
          Text('AI setup', style: TextStyle(color: Colors.white)),
        ]),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'The AI features (search help, AI picks, mixes, AI DJ) need an AI key. '
                  'Make a free one at enter.pollinations.ai, copy it, and paste it below. '
                  'It stays on this phone.',
                  style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4)),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(
                        const ClipboardData(text: 'https://enter.pollinations.ai'));
                    set(() => status = 'Link copied. Open it in your browser.');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Copy enter.pollinations.ai'),
                ),
              ),
              TextField(
                controller: keyC,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                    labelText: 'AI key (sk_...)', border: OutlineInputBorder()),
              ),
              if (advanced) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: baseC,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                      labelText: 'Base URL (OpenAI-compatible)',
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: modelC,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                      labelText: 'Model', border: OutlineInputBorder()),
                ),
              ] else
                TextButton(
                    onPressed: () => set(() => advanced = true),
                    child: const Text('Advanced: use another AI service')),
              if (status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(status,
                      style: const TextStyle(color: Color(0xFF67E8F9), fontSize: 13.5)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    set(() {
                      busy = true;
                      status = 'Testing…';
                    });
                    await AiConfig.save(keyC.text, baseC.text, modelC.text);
                    final r = await AiHelper.ask([
                      {'role': 'user', 'content': 'Reply with the single word: ready'}
                    ], maxTokens: 12, timeout: const Duration(seconds: 15));
                    set(() {
                      busy = false;
                      status = r != null
                          ? 'Connected. The AI is ready.'
                          : AiHelper.problemText();
                    });
                  },
            child: Text(busy ? 'Testing…' : 'Save & test'),
          ),
        ],
      ),
    ),
  );
}


// ═══════════════════════════════ AI DJ ═══════════════════════════════

class AiDjState extends ChangeNotifier {
  static final AiDjState i = AiDjState._();
  AiDjState._() {
    _loadVoicePref();
  }

  bool active = false;
  bool speaking = false;
  String line = "Tap play to spin a personalized mix from your history & fresh discoveries.";
  String modeTag = "AI DJ";
  String voice = "nova"; // Default: natural female studio voice

  static const List<(String, String, String)> voices = [
    ('nova', 'Nova (Female · Studio)', 'Natural, upbeat American female DJ voice'),
    ('kira', 'Kira (Female · Warm)', 'Smooth, laid-back late-night female DJ voice'),
    ('aria', 'Aria (Female · Bright)', 'Crisp, energetic radio host female voice'),
    ('xavier', 'Xavier (Male · Deep)', 'Classic smooth male radio DJ voice'),
  ];

  String get voiceTitle {
    for (final v in voices) {
      if (v.$1 == voice) return v.$2;
    }
    return voices.first.$2;
  }

  Future<void> _loadVoicePref() async {
    try {
      final p = await SharedPreferences.getInstance();
      final saved = p.getString('ai_dj_voice');
      if (saved != null && saved.isNotEmpty) {
        voice = saved;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> setVoice(String v) async {
    voice = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('ai_dj_voice', v);
    } catch (_) {}
  }

  void setSpeaking(bool v) {
    if (speaking == v) return;
    speaking = v;
    notifyListeners();
  }

  void update({bool? isActive, bool? isSpeaking, String? text, String? tag}) {
    if (isActive != null) active = isActive;
    if (isSpeaking != null) speaking = isSpeaking;
    if (text != null) line = text;
    if (tag != null) modeTag = tag;
    notifyListeners();
  }
}

/// Bottom sheet in Settings -> AI to pick and preview the AI DJ voice.
Future<void> showAiDjVoicePicker(
  BuildContext context, {
  required Future<void> Function(String voiceKey) onPreview,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF121218),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) => ListenableBuilder(
      listenable: AiDjState.i,
      builder: (ctx, _) {
        final current = AiDjState.i.voice;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Row(
                  children: [
                    AiDjLogoIcon(size: 26),
                    SizedBox(width: 10),
                    Text(
                      'AI DJ Voice',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Choose the voice for your AI DJ transitions. Tap any voice to select and preview it.',
                  style: TextStyle(color: Colors.white60, fontSize: 13.5),
                ),
                const SizedBox(height: 14),
                for (final v in AiDjState.voices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () async {
                        HapticFeedback.selectionClick();
                        await AiDjState.i.setVoice(v.$1);
                        await onPreview(v.$1);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 13),
                        decoration: BoxDecoration(
                          color: current == v.$1
                              ? const Color(0xFF22D3EE).withOpacity(0.16)
                              : Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: current == v.$1
                                ? const Color(0xFF22D3EE)
                                : Colors.white12,
                            width: current == v.$1 ? 1.4 : 1.0,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              current == v.$1
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_off_rounded,
                              color: current == v.$1
                                  ? const Color(0xFF22D3EE)
                                  : Colors.white54,
                              size: 22,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    v.$2,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    v.$3,
                                    style: const TextStyle(
                                      color: Colors.white60,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.volume_up_rounded,
                              color: Colors.white54,
                              size: 20,
                            ),
                          ],
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
  );
}

class AiDjVisualizer extends StatefulWidget {
  final bool active;
  final double size;
  final Color accent;
  const AiDjVisualizer({
    super.key,
    required this.active,
    this.size = 44,
    this.accent = const Color(0xFFCBBAFF),
  });

  @override
  State<AiDjVisualizer> createState() => _AiDjVisualizerState();
}

class _AiDjVisualizerState extends State<AiDjVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value * 6.2831853;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF10B981), Color(0xFF06B6D4), Color(0xFF6366F1)],
            ),
            boxShadow: widget.active
                ? [
                    BoxShadow(
                      color: const Color(0xFF06B6D4).withOpacity(0.45),
                      blurRadius: 14,
                    ),
                  ]
                : null,
          ),
          child: CustomPaint(
            painter: _AiDjWaveBarsPainter(
              phase: t,
              speaking: widget.active,
              accent: Colors.white,
            ),
          ),
        );
      },
    );
  }
}

class _AiDjWaveBarsPainter extends CustomPainter {
  final double phase;
  final bool speaking;
  final Color accent;
  const _AiDjWaveBarsPainter({
    required this.phase,
    required this.speaking,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final barPaint = Paint()
      ..color = accent
      ..strokeCap = StrokeCap.round
      ..strokeWidth = size.width * 0.08;

    const weights = [0.55, 0.85, 1.0, 0.85, 0.55];
    for (int i = 0; i < 5; i++) {
      final offsetIdx = i - 2;
      final x = c.dx + offsetIdx * (size.width * 0.13);
      final wave = ((phase + i * 0.95).sin() * 0.5 + 0.5);
      final factor = speaking ? (0.14 + 0.25 * wave * weights[i]) : 0.08;
      final h = size.height * factor;
      canvas.drawLine(Offset(x, c.dy - h), Offset(x, c.dy + h), barPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _AiDjWaveBarsPainter old) =>
      old.phase != phase || old.speaking != speaking;
}

extension _TrigExt on double {
  double sin() => _sinTable(this);
  static double _sinTable(double x) {
    var a = x % 6.283185307179586;
    if (a > 3.141592653589793) a -= 6.283185307179586;
    if (a < -3.141592653589793) a += 6.283185307179586;
    final a2 = a * a;
    return a * (1 - a2 / 6 * (1 - a2 / 20 * (1 - a2 / 42)));
  }
}

/// AI DJ Home banner (no voice picker button here).
class AiDjHomeCard extends StatelessWidget {
  final VoidCallback onStartOrSkip;
  final VoidCallback onStop;
  final Color surface;
  final Color text;
  final Color subtext;
  final Color accent;

  const AiDjHomeCard({
    super.key,
    required this.onStartOrSkip,
    required this.onStop,
    required this.surface,
    required this.text,
    required this.subtext,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AiDjState.i,
      builder: (context, _) {
        final st = AiDjState.i;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () {
              HapticFeedback.mediumImpact();
              onStartOrSkip();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(surface, const Color(0xFF06B6D4), 0.18)!,
                    Color.lerp(surface, const Color(0xFF6366F1), 0.22)!,
                  ],
                ),
                border: Border.all(
                  color: st.speaking
                      ? const Color(0xFF22D3EE).withOpacity(0.65)
                      : Colors.white.withOpacity(0.09),
                  width: 1.1,
                ),
              ),
              child: Row(
                children: [
                  AiDjVisualizer(
                    active: st.speaking,
                    size: 50,
                    accent: accent,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF22D3EE).withOpacity(0.20),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                st.speaking
                                    ? 'LIVE ON AIR'
                                    : (st.active ? st.modeTag : 'AI DJ'),
                                style: const TextStyle(
                                  color: Color(0xFF67E8F9),
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.8,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'DJ',
                              style: TextStyle(
                                color: text,
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.3,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          st.line,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: st.speaking ? text : subtext,
                            fontSize: 12.8,
                            fontWeight:
                                st.speaking ? FontWeight.w600 : FontWeight.w500,
                            height: 1.28,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (st.active)
                    IconButton(
                      tooltip: 'Switch Up Vibe',
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        onStartOrSkip();
                      },
                      icon: Icon(Icons.skip_next_rounded, color: text, size: 26),
                    ),
                  IconButton(
                    tooltip: st.active ? 'Stop DJ' : 'Start DJ',
                    onPressed: () {
                      HapticFeedback.mediumImpact();
                      st.active ? onStop() : onStartOrSkip();
                    },
                    icon: Icon(
                      st.active
                          ? Icons.stop_circle_rounded
                          : Icons.play_circle_fill_rounded,
                      color: const Color(0xFF22D3EE),
                      size: 34,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class AiDjPlayerBanner extends StatelessWidget {
  final VoidCallback onNextVibe;
  final Color accent;
  const AiDjPlayerBanner({
    super.key,
    required this.onNextVibe,
    this.accent = const Color(0xFFCBBAFF),
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AiDjState.i,
      builder: (context, _) {
        final st = AiDjState.i;
        final show = st.speaking;
        return IgnorePointer(
          ignoring: !show,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 340),
            curve: Curves.easeOutCubic,
            offset: show ? Offset.zero : const Offset(0, -0.35),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOut,
              opacity: show ? 1.0 : 0.0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                child: Material(
                  color: const Color(0xEE14141C),
                  elevation: 10,
                  shadowColor: Colors.black87,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                    side: BorderSide(
                      color: const Color(0xFF22D3EE).withOpacity(0.45),
                      width: 1.1,
                    ),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: () {
                      HapticFeedback.lightImpact();
                      onNextVibe();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 11),
                      child: Row(
                        children: [
                          AiDjVisualizer(
                            active: show,
                            size: 38,
                            accent: accent,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'DJ · ${st.modeTag}',
                                  style: const TextStyle(
                                    color: Color(0xFF67E8F9),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.8,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  st.line,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12.8,
                                    fontWeight: FontWeight.w600,
                                    height: 1.25,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.skip_next_rounded,
                            color: Color(0xFF67E8F9),
                            size: 22,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class AiDjLogoIcon extends StatelessWidget {
  final double size;
  final Color? background;
  final Color? foreground;
  const AiDjLogoIcon(
      {super.key, this.size = 22, this.background, this.foreground});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _AiDjLogoPainter(
          background ?? const Color(0xFFD3C5F6),
          foreground ?? const Color(0xFF271D40),
        ),
      ),
    );
  }
}

/// The AI DJ mark: a soft scalloped disc with a "voice" of three bars and a
/// small spark, in the Bloom colours.
class _AiDjLogoPainter extends CustomPainter {
  final Color bg;
  final Color fg;
  const _AiDjLogoPainter(this.bg, this.fg);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    // Scalloped disc (9 soft bumps).
    final path = Path();
    for (var i = 0; i <= 90; i++) {
      final t = i / 90 * 6.283185307179586;
      final rr = r / 1.07 * (1 + 0.07 * (9 * t + 1.5707963267948966).sin());
      final p = c + Offset(rr * (t + 1.5707963267948966).sin(), rr * t.sin());
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path..close(), Paint()..color = bg);
    final bar = Paint()
      ..color = fg
      ..strokeCap = StrokeCap.round
      ..strokeWidth = size.width * 0.11;
    const hs = [0.14, 0.27, 0.19];
    for (var i = -1; i <= 1; i++) {
      final x = c.dx + i * size.width * 0.19 - size.width * 0.04;
      final h = size.height * hs[i + 1];
      canvas.drawLine(Offset(x, c.dy - h), Offset(x, c.dy + h), bar);
    }
    // Spark.
    final sx = c.dx + size.width * 0.27, sy = c.dy - size.height * 0.2;
    final k = size.width * 0.09;
    final spark = Path()
      ..moveTo(sx, sy - k)
      ..quadraticBezierTo(sx, sy, sx + k, sy)
      ..quadraticBezierTo(sx, sy, sx, sy + k)
      ..quadraticBezierTo(sx, sy, sx - k, sy)
      ..quadraticBezierTo(sx, sy, sx, sy - k)
      ..close();
    canvas.drawPath(spark, Paint()..color = fg);
  }

  @override
  bool shouldRepaint(covariant _AiDjLogoPainter o) => o.bg != bg || o.fg != fg;
}

// ═══════════════════════ AI DJ: talking screen ═══════════════════════

/// Covers the whole player while the AI DJ is talking: a big moving voice,
/// the words appearing as they're spoken, and a tap to skip the talk.
class AiDjSpeakingOverlay extends StatefulWidget {
  final Color accent;
  final String track;
  final VoidCallback onSkip;
  const AiDjSpeakingOverlay({
    super.key,
    required this.accent,
    required this.track,
    required this.onSkip,
  });

  @override
  State<AiDjSpeakingOverlay> createState() => _AiDjSpeakingOverlayState();
}

class _AiDjSpeakingOverlayState extends State<AiDjSpeakingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
      vsync: this, duration: const Duration(seconds: 6))
    ..repeat();
  DateTime? _since;
  bool _was = false;

  @override
  void initState() {
    super.initState();
    AiDjState.i.addListener(_changed);
    _changed();
  }

  String _line = '';
  void _changed() {
    final now = AiDjState.i.speaking;
    final line = AiDjState.i.line;
    // Captions restart when the DJ starts talking or gets a new line.
    if ((now && !_was) || line != _line) _since = DateTime.now();
    _line = line;
    _was = now;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AiDjState.i.removeListener(_changed);
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = AiDjState.i;
    final show = st.speaking && st.active;
    final a = widget.accent;
    final top = MediaQuery.of(context).padding.top;
    final bottom = MediaQuery.of(context).padding.bottom;
    return IgnorePointer(
      ignoring: !show,
      child: AnimatedOpacity(
        opacity: show ? 1 : 0,
        // Quick to appear, slow fade away into the song.
        duration: Duration(milliseconds: show ? 250 : 1400),
        curve: show ? Curves.easeOut : Curves.easeInOutCubic,
        child: Material(
        type: MaterialType.canvas,
        color: const Color(0xFF0B0A12),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSkip,
          child: AnimatedBuilder(
            animation: _t,
            builder: (context, _) {
              final v = _t.value * 2 * 3.141592653589793;
              final words = st.line.split(RegExp(r'\s+'));
              final elapsed = _since == null
                  ? 0.0
                  : DateTime.now().difference(_since!).inMilliseconds / 1000;
              // About 2.7 words a second, like the voice.
              final shown =
                  (elapsed * 2.7 + 1).floor().clamp(0, words.length).toInt();
              return Container(
                // Solid (no see-through): the DJ has the whole screen.
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0.3 * (v * 0.5).sin(), -0.35),
                    radius: 1.25,
                    colors: [
                      Color.lerp(const Color(0xFF0B0A12),
                          Color.lerp(a, const Color(0xFF06B6D4), 0.3)!, 0.42)!,
                      const Color(0xFF0B0A12),
                    ],
                  ),
                ),
                padding: EdgeInsets.fromLTRB(28, top + 24, 28, bottom + 28),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const AiDjLogoIcon(size: 30),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            st.modeTag.isEmpty ? 'YOUR DJ' : st.modeTag,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.6,
                            ),
                          ),
                        ),
                        Text(
                          AiDjState.i.voiceTitle.split(' ').first,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.6),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 240,
                      height: 240,
                      child: CustomPaint(
                        painter: _DjVoicePainter(phase: v, accent: a),
                      ),
                    ),
                    const SizedBox(height: 34),
                    // Live captions: the words appear as the DJ says them.
                    if (st.line.trim().isEmpty)
                      Text('Getting your set ready...',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withOpacity(
                                0.45 + 0.35 * (v * 2).sin().abs()),
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ))
                    else
                    Text.rich(
                      TextSpan(children: [
                        for (var i = 0; i < words.length; i++)
                          TextSpan(
                            text: '${words[i]} ',
                            style: TextStyle(
                              color: i < shown
                                  ? Colors.white
                                  : Colors.white.withOpacity(0.18),
                            ),
                          ),
                      ]),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 25,
                        height: 1.3,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const Spacer(),
                    if (widget.track.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Text(
                          'Up next: ${widget.track}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.skip_next_rounded,
                              color: Colors.white, size: 18),
                          SizedBox(width: 6),
                          Text('Tap to skip the talk',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        ),
      ),
    );
  }
}

/// A soft glowing orb with wavy rings that move like a voice.
class _DjVoicePainter extends CustomPainter {
  final double phase;
  final Color accent;
  _DjVoicePainter({required this.phase, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r0 = size.width * 0.26;
    final colors = [
      accent,
      const Color(0xFF06B6D4),
      const Color(0xFF6366F1),
      const Color(0xFF10B981),
    ];
    // Glow.
    canvas.drawCircle(
      c,
      r0 * 1.9,
      Paint()
        ..shader = RadialGradient(colors: [
          accent.withOpacity(0.45),
          accent.withOpacity(0),
        ]).createShader(Rect.fromCircle(center: c, radius: r0 * 1.9)),
    );
    // Wavy rings.
    for (var k = 0; k < 4; k++) {
      final path = Path();
      final amp = r0 * (0.10 + 0.05 * k) *
          (0.65 + 0.35 * (phase * 3 + k).sin().abs());
      final base = r0 * (1.0 + 0.16 * k);
      for (var i = 0; i <= 120; i++) {
        final t = i / 120 * 6.283185307179586;
        final wob = (t * (4 + k) + phase * (2 + k * 0.7)).sin() * amp +
            (t * (7 - k) - phase * 1.6).sin() * amp * 0.45;
        final r = base + wob;
        final p = c + Offset(r * _cos(t), r * (t).sin());
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.2 - k * 0.5
          ..color = colors[k].withOpacity(0.85 - k * 0.15),
      );
    }
    // Core.
    canvas.drawCircle(
      c,
      r0 * (0.78 + 0.06 * (phase * 4).sin()),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors[1], colors[2], accent],
        ).createShader(Rect.fromCircle(center: c, radius: r0)),
    );
  }

  static double _cos(double t) => (t + 1.5707963267948966).sin();

  @override
  bool shouldRepaint(_DjVoicePainter o) => o.phase != phase;
}
