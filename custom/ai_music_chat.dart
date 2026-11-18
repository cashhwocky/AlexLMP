import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Runs a command for the chat. Implemented in main.dart so the chat can
/// search the library / YouTube Music and drive the real player.
///   action: play | queue | pause | resume | next | previous | shuffle
///   query:  song / artist text (play and queue only)
/// Returns a short result line to show in the chat ("Now playing ...").
typedef MusicCommand = Future<String> Function(String action, String query);

const String _prefsKey = 'ai_dj_chat_v1';

const String _greeting =
    "Hey! I'm your DJ. Tell me what to play, like \"play Blinding Lights by The Weeknd\", "
    "and I'll find it and start it. I can also queue songs, skip, pause and shuffle.";

String _system(String nowPlaying) =>
    "You are DJ, the assistant inside AlexLMP, a music player app. Be short, warm and casual "
    "(under 50 words). You CAN control the player by writing a command tag on its own line at the very "
    "end of your reply. Tags: [[play: song title - artist]] plays a song, [[queue: song title - artist]] "
    "adds a song to the queue, and [[pause]] [[resume]] [[next]] [[previous]] [[shuffle]]. "
    "Only add a tag when the user asked for that action, and write only one tag. If the user names a "
    "song vaguely, use your best guess of the real title and artist. If they just want to chat or want "
    "recommendations, answer normally with no tag (you may suggest songs by name). "
    "${nowPlaying.isEmpty ? 'Nothing is playing right now.' : 'Now playing: $nowPlaying.'}";

final RegExp _tag = RegExp(
    r'\[\[\s*(play|queue|pause|resume|next|previous|shuffle)\s*(?::\s*([^\]]*?))?\s*\]\]',
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

class AiMusicChat extends StatefulWidget {
  final MusicCommand onCommand;
  final String Function() nowPlaying;
  final Color bg;
  final Color surface;
  final Color userBubble;
  final Color onUserBubble;
  final Color text;
  final Color subtext;
  final Color accent;
  final double bottomPad;

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
  });

  @override
  State<AiMusicChat> createState() => _AiMusicChatState();
}

class _AiMusicChatState extends State<AiMusicChat> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_Msg> _msgs = [];
  bool _busy = false;

  static const List<String> _chips = [
    'Play something upbeat',
    'Queue a chill song',
    'Skip this song',
    'Shuffle my library',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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
    setState(() {
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
    HapticFeedback.selectionClick();
    _input.clear();
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
            "I can't reach the AI right now, but commands like \"play <song>\" still work.",
            null);
      }
      return;
    }

    final m = _tag.firstMatch(reply);
    final shown = reply.replaceAll(_tag, '').trim();
    String? result;
    if (m != null) {
      final act = m.group(1)!.toLowerCase();
      var q = (m.group(2) ?? '').trim().replaceAll(' - ', ' ');
      result = await _runCommand(act, q);
    } else if (direct != null) {
      result = await _runCommand(direct.action, direct.query);
    }
    _finish(shown.isEmpty ? null : shown, result);
  }

  void _finish(String? text, String? result) {
    if (!mounted) return;
    setState(() {
      if (text != null) _msgs.add(_Msg(text, false));
      if (result != null && result.isNotEmpty) {
        _msgs.add(_Msg(result, false, action: true));
      }
      _busy = false;
    });
    _save();
    _jumpToEnd();
  }

  // ── AI ────────────────────────────────────────────────────────────────

  Future<String?> _ask() async {
    final recent = _msgs.where((m) => !m.action).toList();
    final tail = recent.length > 8 ? recent.sublist(recent.length - 8) : recent;
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': _system(widget.nowPlaying())},
      for (final m in tail) {'role': m.user ? 'user' : 'assistant', 'content': m.text},
    ];
    for (final model in const ['openai-fast', 'openai']) {
      final client = http.Client();
      try {
        final res = await client
            .post(
              Uri.parse('https://text.pollinations.ai/openai'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'model': model,
                'messages': messages,
                'max_tokens': 220,
                'private': true,
              }),
            )
            .timeout(const Duration(seconds: 18));
        if (res.statusCode != 200) continue;
        final body = utf8.decode(res.bodyBytes);
        try {
          final j = jsonDecode(body);
          final t = (j['choices'][0]['message']['content'] as String?)?.trim();
          if (t != null && t.isNotEmpty) return t;
        } catch (_) {
          if (body.trim().isNotEmpty) return body.trim();
        }
      } catch (_) {
      } finally {
        client.close();
      }
    }
    return null;
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final kb = MediaQuery.of(context).viewInsets.bottom;
    final bottom = (kb > 0 ? kb : widget.bottomPad) + 8;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 10, 6),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_rounded, color: widget.accent, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('AI DJ',
                      style: TextStyle(
                          color: widget.text,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5)),
                ),
                IconButton(
                  tooltip: 'New chat',
                  onPressed: _clear,
                  icon: Icon(Icons.refresh_rounded, color: widget.subtext),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              itemCount: _msgs.length + (_busy ? 1 : 0),
              itemBuilder: (context, i) {
                if (i >= _msgs.length) return _typing();
                return _bubble(_msgs[i]);
              },
            ),
          ),
          if (_msgs.length <= 1 && !_busy)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final c in _chips)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(c, style: TextStyle(color: widget.text)),
                        backgroundColor: widget.surface,
                        side: BorderSide.none,
                        onPressed: () => _send(c),
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(14, 6, 14, bottom),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: widget.surface,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      style: TextStyle(color: widget.text, fontSize: 16),
                      cursorColor: widget.accent,
                      decoration: InputDecoration(
                        hintText: 'Ask for a song...',
                        hintStyle: TextStyle(color: widget.subtext),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _busy ? null : _send,
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: _busy ? widget.surface : widget.accent,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.arrow_upward_rounded,
                        color: _busy ? widget.subtext : widget.bg),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _typing() => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
              color: widget.surface, borderRadius: BorderRadius.circular(20)),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: widget.accent),
          ),
        ),
      );

  Widget _bubble(_Msg m) {
    final w = MediaQuery.of(context).size.width * 0.8;
    if (m.action) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: w),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: widget.accent.withOpacity(0.16),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.graphic_eq_rounded, size: 18, color: widget.accent),
              const SizedBox(width: 8),
              Flexible(
                child: Text(m.text,
                    style: TextStyle(
                        color: widget.text,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      );
    }
    return Align(
      alignment: m.user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: w),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: m.user ? widget.userBubble : widget.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(m.text,
            style: TextStyle(
                color: m.user ? widget.onUserBubble : widget.text,
                fontSize: 15.5,
                height: 1.3)),
      ),
    );
  }
}
