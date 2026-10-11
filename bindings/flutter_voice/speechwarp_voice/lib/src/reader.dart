import 'dart:async';

import 'package:flutter/services.dart';

import 'types.dart';

const MethodChannel _methods = MethodChannel('speechwarp_voice');
const EventChannel _events = EventChannel('speechwarp_voice/positions');

/// A text read aloud by a voice, sentence by sentence, sped up by speechwarp and played by the platform (AVAudioEngine
/// on iOS, AudioTrack on Android).
///
/// The native reader speaks sentences on a thread of its own, ahead of what is being heard, and never makes the
/// audio wait: when the next sentence is not ready there is silence and [ReaderPosition.isWaiting] says so. The voice
/// can change between sentences ([setVoice]). [positions] reports what is being heard about 20 times a second while
/// playing, and after every change.
///
/// Every reader holds a native reader and an audio output until [dispose].
class VoiceReader {
  VoiceReader._(this._id, this.text, this.sentences, this.sampleRate, String voiceId)
      : _position = ReaderPosition(voiceId: voiceId);

  final int _id;

  /// The text being read.
  final String text;

  /// The text cut into sentences, by the platform's rules (what [ReaderPosition.sentence] indexes).
  final List<SentenceRange> sentences;

  /// The sample rate of the audio played: the first voice's. Voices at another rate are converted to it.
  final int sampleRate;

  final StreamController<ReaderPosition> _controller = StreamController<ReaderPosition>.broadcast();
  ReaderPosition _position;
  bool _disposed = false;

  /// Reads [text] with the voice [voiceId] (an id from [listVoices]). Nothing plays until [play].
  ///
  /// Making the first voice can take a moment (Android's text-to-speech service starts, Kokoro's model is opened
  /// when first needed, not here). Throws a [PlatformException] when the voice cannot be made: code "voice" for an
  /// unknown id or an engine whose package is not in the app, "kokoro" when Kokoro has no model directory or no
  /// phonemizer.
  static Future<VoiceReader> create(String text, {required String voiceId, ReaderOptions options = const ReaderOptions()}) async {
    _ensureListening();
    final result = await _methods.invokeMapMethod<String, Object?>('create', {
      'text': text,
      'voiceId': voiceId,
      'options': options.toMap(),
    });
    final ranges = (result!['sentences']! as List<Object?>).cast<int>();
    final sentences = <SentenceRange>[
      for (var i = 0; i + 1 < ranges.length; i += 2) SentenceRange(ranges[i], ranges[i + 1]),
    ];
    final reader = VoiceReader._(result['id']! as int, text, List.unmodifiable(sentences),
        result['sampleRate']! as int, voiceId);
    _readers[reader._id] = reader;
    return reader;
  }

  /// Every voice the platform has, and the Kokoro and eSpeak voices when their packages are in the app:
  ///
  /// - iOS: Apple's voices ("apple:..."), whatever is installed (Settings > Accessibility > Spoken Content > Voices
  ///   adds more, including the Eloquence voices from iOS 16).
  /// - Android: the text-to-speech engine's voices ("android:..."), installed or not ([VoiceInfo.isInstalled]).
  /// - Kokoro (`speechwarp_voice_kokoro`): its 54 voices, each installed when its files are in [kokoroDirectory].
  /// - eSpeak NG (`speechwarp_voice_espeak`, GPL-3.0-or-later): its English voices.
  static Future<List<VoiceInfo>> listVoices({String? kokoroDirectory, String? kokoroModelFile}) async {
    final list = await _methods.invokeListMethod<Object?>('listVoices', {
      'kokoroDirectory': kokoroDirectory,
      'kokoroModelFile': kokoroModelFile,
    });
    return [for (final v in list ?? const []) VoiceInfo.fromMap(v! as Map<Object?, Object?>)];
  }

  /// What is being heard, and whether it is playing. Events come about 20 times a second while playing, and after
  /// every call that changes something.
  Stream<ReaderPosition> get positions => _controller.stream;

  /// The most recent position.
  ReaderPosition get position => _position;

  /// Starts or carries on playing.
  Future<void> play() => _call('play');

  /// Pauses; [play] carries on from here.
  Future<void> pause() => _call('pause');

  /// Carries on from the start of the sentence holding [character] (an index into [text]). Keeps playing if it was.
  Future<void> seek(int character) => _call('seek', {'character': character});

  /// Carries on from the start of [sentence] (an index into [sentences]).
  Future<void> seekToSentence(int sentence) {
    if (sentences.isEmpty) return seek(0);
    return seek(sentences[sentence.clamp(0, sentences.length - 1)].start);
  }

  /// speechwarp's speed, 0.05 to 20: 2 plays twice as fast as the voice speaks. Takes effect at once.
  Future<void> setSpeed(double speed) => _call('setSpeed', {'speed': speed});

  /// speechwarp's other settings. Only those given change.
  Future<void> configure(SpeedUpSettings settings) => _call('configure', {'settings': settings.toMap()});

  /// Carries on in the voice [voiceId] from the next sentence not yet started (what was spoken ahead in the old
  /// voice is dropped). The voice is made on the reader's thread, so this returns at once; a failure to make it
  /// shows in [ReaderPosition.error] and the old voice carries on.
  Future<void> setVoice(String voiceId) => _call('setVoice', {'voiceId': voiceId});

  /// Stops playing and frees the native reader and audio output. The reader cannot be used afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _readers.remove(_id);
    try {
      await _methods.invokeMethod<void>('dispose', {'id': _id});
    } finally {
      await _controller.close();
    }
  }

  Future<void> _call(String method, [Map<String, Object?> arguments = const {}]) async {
    if (_disposed) throw StateError('The reader has been disposed');
    final position = await _methods.invokeMapMethod<Object?, Object?>(method, {'id': _id, ...arguments});
    if (position != null) _update(position);
  }

  void _update(Map<Object?, Object?> map) {
    if (_disposed) return;
    _position = ReaderPosition.fromMap(map);
    _controller.add(_position);
  }

  // One subscription to the platform's events for every reader, which each event names.
  static final Map<int, VoiceReader> _readers = {};
  static StreamSubscription<Object?>? _subscription;

  static void _ensureListening() {
    _subscription ??= _events.receiveBroadcastStream().listen((event) {
      final map = event! as Map<Object?, Object?>;
      _readers[map['reader']]?._update(map);
    });
  }
}
