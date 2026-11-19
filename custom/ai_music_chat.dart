import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_features.dart';

/// Runs a command for the chat. Implemented in main.dart so the chat can
/// search the library / YouTube Music and drive the real player.
///   action: play | queue | pause | resume | next | previous | shuffle
///   query:  song / artist text (play and queue only)
/// Returns a short result line to show in the chat ("Now playing ...").
typedef MusicCommand = Future<String> Function(String action, String query);

const String _prefsKey = 'ai_dj_chat_v1';

const String _greeting =
    "Hey! I'm your DJ, and I know what you've been listening to. Ask me to play anything, "
    "build a mix or a whole playlist, explain a song, set a sleep timer, or start the AI DJ.";

String _system(String nowPlaying) {
  final taste = AiHelper.tasteText();
  return "You are DJ, the AI inside AlexLMP, a music player app. You know music deeply (genres, eras, scenes, "
      "producers, samples, lyrics' meaning, similar artists) and you know this listener (below). Talk like a sharp, "
      "warm friend: natural and specific, usually under 80 words, longer only when they ask to explain something. "
      "Recommend REAL songs and artists only, never invent titles.\n\n"
      "You can control the app. Put command tags at the very end of your reply, each on its own line, up to 4:\n"
      "[[play: song - artist]] play a song now\n"
      "[[queue: song - artist]] add a song to the queue\n"
      "[[mix: description]] build and play a whole AI playlist (moods, activities, 'more like this', an artist's style)\n"
      "[[playlist: Name | song - artist; song - artist; ...]] save a new playlist to their library (8 to 25 real songs)\n"
      "[[like]] [[unlike]] the current song\n"
      "[[pause]] [[resume]] [[next]] [[previous]] [[shuffle]] [[unshuffle]]\n"
      "[[repeat: one|all|off]] [[sleep: 30 minutes|end of song|off]] [[volume: 0-100]]\n"
      "[[dj: start|stop]] start or stop the AI DJ\n"
      "Only use tags for things the user actually asked for. For questions or chat, just answer. "
      "If they name a song vaguely, use your best guess of the real title and artist. Don't describe the tags.\n\n"
      "${nowPlaying.isEmpty ? 'Nothing is playing right now.' : 'Now playing: $nowPlaying.'}"
      "${taste.isEmpty ? '' : '\n\nAbout the listener:\n$taste'}";
}

final RegExp _tag = RegExp(
    r'\[\[\s*(play|queue|mix|playlist|like|unlike|pause|resume|next|previous|shuffle|unshuffle|repeat|sleep|volume|dj)\s*(?::\s*([^\]]*?))?\s*\]\]',
    caseSensitive: false);

class _Msg {
  String text;
  final bool user;
  final bool action; // a result line from the player
  _Msg(this.text, this.user, {this.action = false});

  Map<String, dynamic> toJson() => {'t': text, 'u': user, 'a': action};
  factory _Msg.fromJson(Map<String, dynamic> j) => _Msg(
      (j['t'] as String?) ?? '', (j['u'] as bool?) ?? false,
      action: (j['a'] as bool?) ?? false);
}

/// A mood = two or three glowing colours the whole screen drifts into.
class _Mood {
  final String name;
  final List<Color> colors;
  const _Mood(this.name, this.colors);
}

const _Mood _moodDefault = _Mood('default',
    [Color(0xFF22D3EE), Color(0xFF6366F1), Color(0xFFA855F7)]);
const List<_Mood> _sendBursts = [
  _Mood('cyan', [Color(0xFF06B6D4), Color(0xFF3B82F6), Color(0xFF8B5CF6)]),
  _Mood('aurora', [Color(0xFF10B981), Color(0xFF22D3EE), Color(0xFF6366F1)]),
  _Mood('ice', [Color(0xFF38BDF8), Color(0xFF818CF8), Color(0xFFE879F9)]),
  _Mood('neon', [Color(0xFFA78BFA), Color(0xFF22D3EE), Color(0xFF2DD4BF)]),
  _Mood('deep', [Color(0xFF2563EB), Color(0xFF7C3AED), Color(0xFF0EA5E9)]),
];

/// Picks a mood from what was said (and what the AI said back).
_Mood? _moodFor(String s) {
  final t = s.toLowerCase();
  bool has(List<String> w) => w.any(t.contains);
  if (has(['sad', 'cry', 'heartbreak', 'lonely', 'miss ', 'melanchol', 'blue'])) {
    return const _Mood('sad', [Color(0xFF1D4ED8), Color(0xFF4F46E5), Color(0xFF0EA5E9)]);
  }
  if (has(['chill', 'relax', 'calm', 'sleep', 'lofi', 'lo-fi', 'study', 'focus', 'ambient'])) {
    return const _Mood('chill', [Color(0xFF2DD4BF), Color(0xFF38BDF8), Color(0xFF818CF8)]);
  }
  if (has(['party', 'dance', 'club', 'upbeat', 'hype', 'energy', 'workout', 'gym', 'pump', 'rave'])) {
    return const _Mood('hype', [Color(0xFFF43F5E), Color(0xFFD946EF), Color(0xFF8B5CF6)]);
  }
  if (has(['love', 'romantic', 'date', 'crush', 'kiss'])) {
    return const _Mood('love', [Color(0xFFEC4899), Color(0xFFA855F7), Color(0xFF6366F1)]);
  }
  if (has(['rock', 'metal', 'punk', 'angry', 'loud'])) {
    return const _Mood('rock', [Color(0xFFF97316), Color(0xFFEF4444), Color(0xFFD946EF)]);
  }
  if (has(['rap', 'hip hop', 'hip-hop', 'trap', 'drill'])) {
    return const _Mood('rap', [Color(0xFFA855F7), Color(0xFF6366F1), Color(0xFF22D3EE)]);
  }
  if (has(['happy', 'summer', 'sun', 'good vibes', 'fun'])) {
    return const _Mood('happy', [Color(0xFF22D3EE), Color(0xFF34D399), Color(0xFFFACC15)]);
  }
  return null;
}

class AiMusicChat extends StatefulWidget {
  final MusicCommand onCommand;
  final String Function() nowPlaying;
  // Kept so existing call sites keep working. The AI tab now draws its own
  // AMOLED black look, so only `accent` is used as the starting glow.
  final Color bg;
  final Color surface;
  final Color userBubble;
  final Color onUserBubble;
  final Color text;
  final Color subtext;
  final Color accent;
  final double bottomPad;
  /// AlexLMP Liquid Glass look (see-through, iOS style).
  final bool glass;
  /// Starts the AI DJ (shown as a card at the top in the glass look).
  final VoidCallback? onDj;

  const AiMusicChat({
    super.key,
    required this.onCommand,
    required this.nowPlaying,
    required this.bg,
    required this.surface,
    required this.userBubble,
    required this.onUserBubble,
    required this.text,
    required this.subtext,
    required this.accent,
    this.bottomPad = 120,
    this.glass = false,
    this.onDj,
  });

  @override
  State<AiMusicChat> createState() => _AiMusicChatState();
}

class _AiMusicChatState extends State<AiMusicChat>
    with TickerProviderStateMixin {
  static const Color _black = Color(0xFF000000);
  static const Color _gptSurface = Color(0xFF212121);
  static const Color _gptUser = Color(0xFF2F2F2F);
  static const Color _gptText = Color(0xFFECECEC);
  static const Color _gptSub = Color(0xFF9B9B9B);

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_Msg> _msgs = [];
  bool _busy = false;

  // Mood colours + animation
  _Mood _mood = _moodDefault;
  int _burstIdx = 0;
  late final AnimationController _drift; // slow ambient movement
  late final AnimationController _pulse; // quick flash when you send
  Timer? _typeTimer;
  _Msg? _typing; // message currently being "typed" out
  int _shown = 0; // characters of _typing already revealed
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);

  static const List<String> _chips = [
    'Make me a workout mix',
    'More songs like this',
    "What's this song about?",
    'Play something upbeat',
  ];

  @override
  void initState() {
    super.initState();
    _drift = AnimationController(vsync: this, duration: const Duration(seconds: 14))
      ..repeat();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100));
    // Whenever the AI tab opens, make the system bars AMOLED black too.
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: widget.glass ? Colors.transparent : _black,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
    _load();
  }

  @override
  void dispose() {
    _typeTimer?.cancel();
    _drift.dispose();
    _pulse.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        _msgs.addAll(
            list.map((e) => _Msg.fromJson(Map<String, dynamic>.from(e as Map))));
      }
    } catch (_) {}
    if (_msgs.isEmpty) _msgs.add(_Msg(_greeting, false));
    if (mounted) setState(() {});
    _jumpToEnd();
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      final keep = _msgs.length > 60 ? _msgs.sublist(_msgs.length - 60) : _msgs;
      await p.setString(_prefsKey, jsonEncode(keep.map((m) => m.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> _clear() async {
    HapticFeedback.selectionClick();
    _typeTimer?.cancel();
    _typing = null;
    setState(() {
      _mood = _moodDefault;
      _msgs
        ..clear()
        ..add(_Msg(_greeting, false));
    });
    _save();
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent + 200,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    });
  }

  // ── Mood + haptics ────────────────────────────────────────────────────

  void _burst(String text) {
    // Sending always throws a fresh cool colour; keywords choose a real mood.
    _burstIdx = (_burstIdx + 1) % _sendBursts.length;
    setState(() => _mood = _moodFor(text) ?? _sendBursts[_burstIdx]);
    _pulse.forward(from: 0);
  }

  /// Types the AI's reply out letter by letter with soft haptic ticks.
  void _typeOut(_Msg m, {VoidCallback? done}) {
    _typeTimer?.cancel();
    _typing = m;
    _shown = 0;
    HapticFeedback.mediumImpact(); // it started answering
    _typeTimer = Timer.periodic(const Duration(milliseconds: 22), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      _shown = math.min(m.text.length, _shown + 2);
      final now = DateTime.now();
      if (now.difference(_lastTick).inMilliseconds > 70 && _shown % 4 == 0) {
        _lastTick = now;
        HapticFeedback.selectionClick();
      }
      setState(() {});
      if (_shown % 24 == 0) _jumpToEnd();
      if (_shown >= m.text.length) {
        t.cancel();
        _typing = null;
        HapticFeedback.lightImpact();
        done?.call();
      }
    });
  }

  // ── Commands ──────────────────────────────────────────────────────────

  /// Plain commands that don't need the AI at all (also the offline fallback).
  ({String action, String query})? _simple(String raw) {
    final t = raw.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    final l = t.toLowerCase();
    if (RegExp(r'^(pause|stop|stop music|pause music)$').hasMatch(l)) {
      return (action: 'pause', query: '');
    }
    if (RegExp(r'^(resume|continue|unpause|play|keep playing)$').hasMatch(l)) {
      return (action: 'resume', query: '');
    }
    if (RegExp(r'^(next|skip|skip song|skip this song|next song|skip this)$')
        .hasMatch(l)) {
      return (action: 'next', query: '');
    }
    if (RegExp(r'^(previous|prev|back|last song|previous song|go back)$')
        .hasMatch(l)) {
      return (action: 'previous', query: '');
    }
    if (RegExp(r'^(shuffle|shuffle on|shuffle my library|shuffle all)$')
        .hasMatch(l)) {
      return (action: 'shuffle', query: '');
    }
    final m = RegExp(
            r'^(?:please\s+)?(?:can you\s+|could you\s+)?(play|put on|queue|add)\s+(.+)$',
            caseSensitive: false)
        .firstMatch(t);
    if (m != null) {
      var q = m.group(2)!.trim();
      q = q.replaceAll(RegExp(r'\s+(please|for me)$', caseSensitive: false), '');
      q = q.replaceFirst(RegExp(r'\s+(to|in)\s+(the\s+)?queue$', caseSensitive: false), '');
      final verb = m.group(1)!.toLowerCase();
      return (
        action: (verb == 'queue' || verb == 'add') ? 'queue' : 'play',
        query: q
      );
    }
    return null;
  }

  Future<String> _runCommand(String action, String query) async {
    try {
      return await widget.onCommand(action, query);
    } catch (_) {
      return "Couldn't do that just now.";
    }
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _busy) return;
    if (_typing != null) {
      _typeTimer?.cancel(); // finish the previous reply instantly
      _typing = null;
    }
    HapticFeedback.lightImpact();
    _input.clear();
    _burst(text); // cool colour burst when you send
    setState(() {
      _msgs.add(_Msg(text, true));
      _busy = true;
    });
    _jumpToEnd();

    // Exact commands run instantly, no AI round trip needed.
    final direct = _simple(text);
    if (direct != null && direct.action != 'play' && direct.action != 'queue') {
      final r = await _runCommand(direct.action, direct.query);
      _finish(null, r);
      return;
    }

    final reply = await _ask();
    if (reply == null) {
      // AI unreachable: "play X" style commands still work.
      if (direct != null) {
        final r = await _runCommand(direct.action, direct.query);
        _finish(null, r);
      } else {
        _finish(
            '${AiHelper.problemText()} Commands like "play <song>" still work without it.',
            null);
      }
      return;
    }

    final tags = _tag.allMatches(reply).take(4).toList();
    final shown = reply.replaceAll(_tag, '').trim();
    String? result;
    if (tags.isNotEmpty) {
      final lines = <String>[];
      for (final m in tags) {
        final act = m.group(1)!.toLowerCase();
        var q = (m.group(2) ?? '').trim();
        if (act == 'play' || act == 'queue') q = q.replaceAll(' - ', ' ');
        final r = await _runCommand(act, q);
        if (r.isNotEmpty) lines.add(r);
      }
      result = lines.join('\n');
    } else if (direct != null) {
      result = await _runCommand(direct.action, direct.query);
    }
    _finish(shown.isEmpty ? null : shown, result);
  }

  void _finish(String? text, String? result) {
    if (!mounted) return;
    void showResult() {
      if (!mounted) return;
      if (result != null && result.isNotEmpty) {
        HapticFeedback.heavyImpact(); // the player actually did something
        setState(() => _msgs.add(_Msg(result, false, action: true)));
      }
      setState(() => _busy = false);
      _save();
      _jumpToEnd();
    }

    if (text != null) {
      final m = _Msg(text, false);
      // The reply can change the mood too ("chill", "party", ...).
      final mood = _moodFor('$text ${result ?? ''}');
      setState(() {
        _msgs.add(m);
        _busy = false;
        if (mood != null) _mood = mood;
      });
      _pulse.forward(from: 0);
      _jumpToEnd();
      _typeOut(m, done: showResult);
    } else {
      showResult();
    }
  }

  // ── AI ────────────────────────────────────────────────────────────────

  Future<String?> _ask() async {
    final recent = _msgs.where((m) => !m.action).toList();
    final tail = recent.length > 20 ? recent.sublist(recent.length - 20) : recent;
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': _system(widget.nowPlaying())},
      for (final m in tail) {'role': m.user ? 'user' : 'assistant', 'content': m.text},
    ];
    return AiHelper.ask(messages, maxTokens: 900);
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.glass) return _glassBuild(context);
    final top = MediaQuery.of(context).padding.top;
    final kb = MediaQuery.of(context).viewInsets.bottom;
    final bottom = (kb > 0 ? kb : widget.bottomPad) + 8;
    return ColoredBox(
      color: _black, // AMOLED
      child: Stack(
        children: [
          Positioned.fill(child: _glow()),
          Padding(
            padding: EdgeInsets.only(top: top),
            child: Column(
              children: [
                _header(),
                Expanded(
                  child: _msgs.length <= 1 && !_busy
                      ? _empty()
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                          itemCount: _msgs.length + (_busy ? 1 : 0),
                          itemBuilder: (context, i) {
                            if (i >= _msgs.length) return _thinking();
                            return _bubble(_msgs[i]);
                          },
                        ),
                ),
                _composer(bottom),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── Liquid Glass look ─────────────────────────

  static const Color _gAccent = Color(0xFF6E8BFF);
  static const Color _gSub = Color(0x9EEBEBF5);

  Widget _gGlass({required Widget child, double r = 22, EdgeInsets? pad, bool strong = false}) =>
      ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: Container(
          padding: pad,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(r),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withOpacity(strong ? 0.20 : 0.13),
                Colors.white.withOpacity(strong ? 0.09 : 0.05),
              ],
            ),
            border: Border.all(color: Colors.white.withOpacity(0.20), width: 0.7),
          ),
          child: child,
        ),
      );

  Widget _gCircle(IconData icon, VoidCallback onTap, String tip) => Tooltip(
        message: tip,
        child: GestureDetector(
          onTap: onTap,
          child: _gGlass(
            r: 19,
            strong: true,
            child: SizedBox(
                width: 38, height: 38, child: Icon(icon, color: Colors.white, size: 20)),
          ),
        ),
      );

  Future<void> _listen() async {
    try {
      final t = await const MethodChannel('com.alexlmp.app/media')
          .invokeMethod<String>('listen', {'prompt': 'Ask anything about music'});
      if (t != null && t.trim().isNotEmpty) _send(t);
    } catch (_) {}
  }

  void _history() {
    final asks = [
      for (final m in _msgs.reversed)
        if (m.user) m.text
    ].toSet().take(12).toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 20, 22, 8),
              child: Text('Recent',
                  style: TextStyle(
                      color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
            ),
            if (asks.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 4, 22, 24),
                child: Text('Nothing asked yet.', style: TextStyle(color: _gSub)),
              ),
            for (final a in asks)
              ListTile(
                leading: const Icon(Icons.history_rounded, color: _gSub),
                title: Text(a,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _send(a);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _gDjCard() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        child: _gGlass(
          pad: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF6E8BFF), Color(0xFFA770EF), Color(0xFFFF5E7E)],
                  ),
                ),
                child: const Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 13),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('AI DJ',
                        style: TextStyle(
                            color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                    SizedBox(height: 2),
                    Text('Talks between songs and picks what plays next',
                        style: TextStyle(color: _gSub, fontSize: 13, height: 1.25)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: widget.onDj,
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: Colors.white, borderRadius: BorderRadius.circular(17)),
                  child: const Text('Start',
                      style: TextStyle(
                          color: Colors.black, fontSize: 14.5, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _gBubble(_Msg m) {
    final w = MediaQuery.of(context).size.width;
    if (m.action) {
      // Result of something the AI did (a mix, a queue): a glass card.
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10, right: 30),
        child: _gGlass(
          r: 18,
          pad: const EdgeInsets.all(10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF5B86E5), Color(0xFFA770EF)],
                  ),
                ),
                child: const Icon(Icons.queue_music_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(m.text,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      );
    }
    final typing = identical(m, _typing);
    final shown = typing ? m.text.substring(0, _shown.clamp(0, m.text.length)) : m.text;
    final text = Text(shown + (typing ? ' ▍' : ''),
        style: const TextStyle(color: Colors.white, fontSize: 15.5, height: 1.38));
    return Align(
      alignment: m.user ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(top: 5, bottom: 5, left: m.user ? 50 : 0, right: m.user ? 0 : 40),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: w * 0.8),
          child: m.user
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                  decoration: BoxDecoration(
                      color: _gAccent, borderRadius: BorderRadius.circular(20)),
                  child: text,
                )
              : _gGlass(
                  r: 20,
                  pad: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                  child: text),
        ),
      ),
    );
  }

  Widget _gChips() => SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            for (final c in _chips)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => _send(c),
                  child: _gGlass(
                    r: 20,
                    pad: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                    child: Text(c,
                        style: const TextStyle(color: Colors.white, fontSize: 14)),
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _gComposer(double bottom) {
    final canSend = !_busy && _input.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottom),
      child: _gGlass(
        r: 26,
        strong: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 18, right: 4),
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _send(),
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  cursorColor: _gAccent,
                  decoration: const InputDecoration(
                    hintText: 'Ask anything about music',
                    hintStyle: TextStyle(color: _gSub),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 15),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Speak',
              onPressed: _busy ? null : _listen,
              icon: const Icon(Icons.mic_rounded, color: _gSub, size: 23),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 6, 6),
              child: GestureDetector(
                onTap: canSend ? _send : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: canSend ? _gAccent : _gAccent.withOpacity(0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.arrow_upward_rounded, size: 22, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _glassBuild(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final kb = MediaQuery.of(context).viewInsets.bottom;
    final bottom = (kb > 0 ? kb : widget.bottomPad) + 8;
    final items = _msgs.length + (_busy ? 1 : 0);
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(20, top + 10, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text('AI',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6)),
              ),
              _gCircle(Icons.schedule_rounded, _history, 'Recent'),
              const SizedBox(width: 10),
              _gCircle(Icons.add_rounded, _clear, 'New chat'),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
            itemCount: items + 1,
            itemBuilder: (context, i) {
              if (i == 0) return _gDjCard();
              final k = i - 1;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: k >= _msgs.length ? _thinking() : _gBubble(_msgs[k]),
              );
            },
          ),
        ),
        _gChips(),
        _gComposer(bottom),
      ],
    );
  }

  /// Soft moving colour glow on pure black. Shifts to the mood colours.
  Widget _glow() {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([_drift, _pulse]),
        builder: (context, _) {
          final a = _drift.value * 2 * math.pi;
          final flash = Curves.easeOut.transform(1 - _pulse.value) *
              (_pulse.isAnimating ? 1 : 0);
          return TweenAnimationBuilder<List<Color>>(
            tween: _ColorsTween(end: _mood.colors),
            duration: const Duration(milliseconds: 900),
            builder: (context, cs, _) {
              Widget blob(Color c, Alignment al, double r, double o) => Align(
                    alignment: al,
                    child: Container(
                      width: r,
                      height: r,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [
                          c.withOpacity((o + flash * 0.30).clamp(0.0, 1.0)),
                          c.withOpacity(0),
                        ]),
                      ),
                    ),
                  );
              return Stack(
                children: [
                  blob(cs[0], Alignment(-1.0 + 0.5 * math.sin(a), -1.05), 520, 0.20),
                  blob(cs[1], Alignment(1.0 - 0.5 * math.cos(a), -0.55), 460, 0.14),
                  blob(cs[2], Alignment(0.6 * math.sin(a + 2), 1.15), 560, 0.18),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 8, 6),
      child: Row(
        children: [
          _spark(26),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('AI DJ',
                style: TextStyle(
                    color: _gptText,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2)),
          ),
          IconButton(
            tooltip: 'AI settings',
            onPressed: () => showAiSetup(context),
            icon: const Icon(Icons.tune_rounded, color: _gptText, size: 22),
          ),
          IconButton(
            tooltip: 'New chat',
            onPressed: _clear,
            icon: const Icon(Icons.edit_outlined, color: _gptText, size: 22),
          ),
        ],
      ),
    );
  }

  /// Round avatar with the current mood gradient.
  Widget _spark(double s) {
    return TweenAnimationBuilder<List<Color>>(
      tween: _ColorsTween(end: _mood.colors),
      duration: const Duration(milliseconds: 700),
      builder: (context, cs, _) => Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
              colors: [cs[0], cs[2]],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
          boxShadow: [BoxShadow(color: cs[1].withOpacity(0.45), blurRadius: 12)],
        ),
        child: Icon(Icons.graphic_eq_rounded, color: Colors.white, size: s * 0.6),
      ),
    );
  }

  /// Centered welcome like ChatGPT's empty state, with suggestion cards.
  Widget _empty() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _spark(56),
            const SizedBox(height: 18),
            const Text('What should we play?',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: _gptText,
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.4)),
            const SizedBox(height: 8),
            const Text(
                'Ask for a song, queue something, or just tell me your mood.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _gptSub, fontSize: 14.5, height: 1.35)),
            const SizedBox(height: 26),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _chips)
                  GestureDetector(
                    onTap: () => _send(c),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 11),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white.withOpacity(0.12)),
                      ),
                      child: Text(c,
                          style: const TextStyle(
                              color: _gptText, fontSize: 14, height: 1.2)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer(double bottom) {
    final glow = _mood.colors[1];
    final canSend = !_busy && _input.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 6, 12, bottom),
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final f = Curves.easeOut.transform(1 - _pulse.value) *
              (_pulse.isAnimating ? 1 : 0);
          return Container(
            decoration: BoxDecoration(
              color: _gptSurface,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                  color: Color.lerp(Colors.white.withOpacity(0.10), glow, f)!,
                  width: 1 + f),
              boxShadow: [
                BoxShadow(color: glow.withOpacity(0.35 * f), blurRadius: 24),
              ],
            ),
            child: child,
          );
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 20, right: 6),
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _send(),
                  style: const TextStyle(color: _gptText, fontSize: 16),
                  cursorColor: glow,
                  decoration: const InputDecoration(
                    hintText: 'Message AI DJ',
                    hintStyle: TextStyle(color: _gptSub),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 15),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(6),
              child: GestureDetector(
                onTap: canSend ? _send : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: canSend ? Colors.white : const Color(0xFF3A3A3A),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.arrow_upward_rounded,
                      size: 22,
                      color: canSend ? Colors.black : const Color(0xFF777777)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thinking() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            _spark(28),
            const SizedBox(width: 12),
            AnimatedBuilder(
              animation: _drift,
              builder: (context, _) => Row(
                children: [
                  for (var i = 0; i < 3; i++)
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _mood.colors[i % _mood.colors.length].withOpacity(
                            0.35 +
                                0.65 *
                                    (0.5 +
                                        0.5 *
                                            math.sin(_drift.value * 2 * math.pi * 7 -
                                                i * 1.1))),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _bubble(_Msg m) {
    final w = MediaQuery.of(context).size.width;
    if (m.action) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(40, 4, 0, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(maxWidth: w * 0.8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _mood.colors[0].withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _mood.colors[0].withOpacity(0.35)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.graphic_eq_rounded, size: 18, color: _mood.colors[0]),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(m.text,
                      style: const TextStyle(
                          color: _gptText,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (m.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(maxWidth: w * 0.78),
          margin: const EdgeInsets.only(top: 10, bottom: 10, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            color: _gptUser,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Text(m.text,
              style: const TextStyle(
                  color: _gptText, fontSize: 16, height: 1.35)),
        ),
      );
    }
    // Assistant: no bubble, just avatar + text (ChatGPT style).
    final typing = identical(m, _typing);
    final shown = typing ? m.text.substring(0, _shown.clamp(0, m.text.length)) : m.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _spark(28),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(shown + (typing ? ' ▍' : ''),
                style: const TextStyle(
                    color: _gptText, fontSize: 16, height: 1.45)),
          ),
        ],
      ),
    );
  }
}

/// Smoothly blends between two lists of colours (used for the mood shifts).
class _ColorsTween extends Tween<List<Color>> {
  _ColorsTween({required List<Color> end}) : super(begin: end, end: end);

  @override
  List<Color> lerp(double t) {
    final a = begin!;
    final b = end!;
    return [
      for (var i = 0; i < b.length; i++)
        Color.lerp(i < a.length ? a[i] : b[i], b[i], t)!,
    ];
  }
}
