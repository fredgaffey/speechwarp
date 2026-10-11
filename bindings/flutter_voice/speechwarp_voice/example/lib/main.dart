import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speechwarp_voice/speechwarp_voice.dart';

/// `flutter run --dart-define=AUTOPLAY=true` starts reading as soon as the voices are listed.
const autoplay = bool.fromEnvironment('AUTOPLAY');

void main() => runApp(const MaterialApp(title: 'speechwarp voice', home: ReaderPage()));

const sampleText = 'speechwarp reads text aloud, sentence by sentence, with whatever voice you choose. '
    'It speaks ahead of what you hear, on a thread of its own, so the audio never waits. '
    'The speed-up is nonlinear: pauses shrink more than words do, so fast speech stays easy to follow. '
    'Change the voice and it carries on from the next sentence. '
    'Tap a sentence to jump to it.';

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  List<VoiceInfo> _voices = [];
  String? _voiceId;
  VoiceReader? _reader;
  StreamSubscription<ReaderPosition>? _subscription;
  ReaderPosition _position = const ReaderPosition();
  double _speed = 1.5;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadVoices();
  }

  Future<void> _loadVoices() async {
    try {
      final voices = (await VoiceReader.listVoices()).where((v) => v.isInstalled && v.engine != 'kokoro').toList()
        ..sort((a, b) => _rank(a).compareTo(_rank(b)));
      setState(() {
        _voices = voices;
        _voiceId = voices.isEmpty ? null : voices.first.id;
      });
      if (autoplay && _voiceId != null) await _run(() async => (await _ensureReader()).play());
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  // English system voices first, then eSpeak's.
  static int _rank(VoiceInfo v) =>
      (v.language.toLowerCase().startsWith('en') ? 0 : 2) + (v.engine == 'espeak' ? 1 : 0);

  Future<VoiceReader> _ensureReader() async {
    final existing = _reader;
    if (existing != null) return existing;
    final reader = await VoiceReader.create(sampleText,
        voiceId: _voiceId!, options: ReaderOptions(speed: _speed));
    _subscription = reader.positions.listen((p) => setState(() => _position = p));
    setState(() => _reader = reader);
    return reader;
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      setState(() => _error = null);
      await action();
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _reader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reader = _reader;
    final playing = _position.isPlaying;
    return Scaffold(
      appBar: AppBar(title: const Text('speechwarp voice')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButton<String>(
            key: const Key('voice'),
            isExpanded: true,
            value: _voiceId,
            hint: const Text('Loading voices...'),
            items: [
              for (final v in _voices)
                DropdownMenuItem(value: v.id, child: Text('${v.name} (${v.language}, ${v.engine})')),
            ],
            onChanged: (id) {
              setState(() => _voiceId = id);
              if (id != null && reader != null) _run(() => reader.setVoice(id));
            },
          ),
          const SizedBox(height: 16),
          _Text(
            sentences: reader?.sentences ?? const [],
            current: reader == null ? -1 : _position.sentence,
            onTap: (i) => _run(() async => (await _ensureReader()).seekToSentence(i)),
          ),
          const SizedBox(height: 16),
          Row(children: [
            IconButton.filled(
              key: const Key('play'),
              iconSize: 36,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              onPressed: _voiceId == null
                  ? null
                  : () => _run(() async {
                        final r = await _ensureReader();
                        playing ? await r.pause() : await r.play();
                      }),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                'Speed ${_speed.toStringAsFixed(1)}x\n'
                'Character ${_position.character}, sentence ${_position.sentence + 1}'
                '${_position.isWaiting ? ', waiting for the voice' : ''}${_position.isFinished ? ', finished' : ''}',
                key: const Key('status'),
              ),
            ),
          ]),
          Slider(
            min: 0.5,
            max: 6,
            divisions: 22,
            value: _speed,
            label: '${_speed.toStringAsFixed(1)}x',
            onChanged: (v) {
              setState(() => _speed = v);
              if (reader != null) _run(() => reader.setSpeed(v));
            },
          ),
          if (_error != null || _position.error != null)
            Text(_error ?? _position.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ),
    );
  }
}

class _Text extends StatelessWidget {
  const _Text({required this.sentences, required this.current, required this.onTap});

  final List<SentenceRange> sentences;
  final int current;
  final void Function(int sentence) onTap;

  @override
  Widget build(BuildContext context) {
    final highlight = Theme.of(context).colorScheme.primaryContainer;
    if (sentences.isEmpty) return const Text(sampleText, style: TextStyle(fontSize: 18));
    return Wrap(children: [
      for (var i = 0; i < sentences.length; i++)
        GestureDetector(
          onTap: () => onTap(i),
          child: Container(
            color: i == current ? highlight : null,
            child: Text(sampleText.substring(sentences[i].start, sentences[i].end), style: const TextStyle(fontSize: 18)),
          ),
        ),
    ]);
  }
}
