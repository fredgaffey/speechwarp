import 'package:flutter/foundation.dart';

/// A voice that a [VoiceReader] can read with.
@immutable
class VoiceInfo {
  const VoiceInfo({
    required this.id,
    required this.name,
    required this.language,
    required this.engine,
    this.isInstalled = true,
    this.keepsSpoken = false,
    this.details = const {},
  });

  /// Builds one from what the platform sends.
  factory VoiceInfo.fromMap(Map<Object?, Object?> map) => VoiceInfo(
        id: map['id']! as String,
        name: map['name'] as String? ?? map['id']! as String,
        language: map['language'] as String? ?? '',
        engine: map['engine'] as String? ?? '',
        isInstalled: map['installed'] as bool? ?? true,
        keepsSpoken: map['keepsSpoken'] as bool? ?? false,
        details: Map<String, Object?>.unmodifiable(
            (map['details'] as Map<Object?, Object?>? ?? const {}).map((k, v) => MapEntry(k! as String, v))),
      );

  /// What to give [VoiceReader.create] and [VoiceReader.setVoice]: "apple:com.apple.voice.compact.en-US.Samantha",
  /// "android:en-us-x-iol-local", "kokoro:af_heart", "espeak:en-gb". Stable across runs. Apple's, Android's and
  /// eSpeak's ids may carry a rate (and pitch) after a slash; Kokoro's a pace ("kokoro:af_heart/1.2").
  final String id;

  /// A name to show: "Samantha", "en-us-x-iol-local", "af_heart", "English (Great Britain)".
  final String name;

  /// A BCP 47 language tag, such as "en-US" (as the engine reports it; Kokoro's and eSpeak's are lower case).
  final String language;

  /// "apple", "android", "kokoro" or "espeak".
  final String engine;

  /// Whether it can speak now. False for an Android voice whose data is not downloaded yet, and for a Kokoro voice
  /// whose files are not in the model directory (see `speechwarp_voice_kokoro`).
  final bool isInstalled;

  /// The engine is slower than listening (Kokoro): what it speaks is kept on disk in the cache directory.
  final bool keepsSpoken;

  /// Whatever else the engine says about it, such as Android's "quality" and "requiresNetwork", Apple's
  /// "isEloquence", Kokoro's "isFemale" or eSpeak's "gender".
  final Map<String, Object?> details;

  @override
  String toString() => 'VoiceInfo($id, $name, $language)';

  @override
  bool operator ==(Object other) => other is VoiceInfo && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// How a [VoiceReader] reads. Everything has a sensible default.
@immutable
class ReaderOptions {
  const ReaderOptions({
    this.speed = 1,
    this.speedUp = const SpeedUpSettings(),
    this.cache = true,
    this.cacheDirectory,
    this.lookahead = 30,
    this.keptLookahead = 120,
    this.secondsPerCharacter = 1 / 17,
    this.kokoroDirectory,
    this.kokoroModelFile,
  });

  /// speechwarp's speed: 2 plays twice as fast as the voice speaks. 0.05 to 20.
  final double speed;

  /// speechwarp's other settings (see [SpeedUpSettings]).
  final SpeedUpSettings speedUp;

  /// Keep what a slow voice (Kokoro) says on disk, and read it from there next time. Voices quicker than listening
  /// are never kept.
  final bool cache;

  /// Where to keep it. Null: the platform's usual place (Library/Caches on iOS, the app's cache directory on
  /// Android), which the system may clear when space is short.
  final String? cacheDirectory;

  /// Seconds of listening to keep spoken ahead of what is being heard, for a quick voice.
  final double lookahead;

  /// Seconds of listening to keep spoken ahead for a slow voice ([VoiceInfo.keepsSpoken]).
  final double keptLookahead;

  /// The pace of the timeline ([ReaderPosition.time]): every character of the text is this long, whatever the
  /// voice and the speed, so that a time is the same place in every voice.
  final double secondsPerCharacter;

  /// The folder holding Kokoro's model files, for "kokoro:" voices (needs `speechwarp_voice_kokoro`).
  final String? kokoroDirectory;

  /// Kokoro's model file in that folder. Null: the platform's default ("model.onnx", fp32, on Android;
  /// "model_fp16.onnx" on iOS).
  final String? kokoroModelFile;

  /// What is sent to the platform.
  Map<String, Object?> toMap() => {
        'speed': speed,
        'speedUp': speedUp.toMap(),
        'cache': cache,
        'cacheDirectory': cacheDirectory,
        'lookahead': lookahead,
        'keptLookahead': keptLookahead,
        'secondsPerCharacter': secondsPerCharacter,
        'kokoroDirectory': kokoroDirectory,
        'kokoroModelFile': kokoroModelFile,
      };
}

/// speechwarp's settings besides the speed, as on a `SpeechwarpStream` (see speechwarp's API documentation for
/// each). Null leaves a setting as it is; a new reader starts with speechwarp's defaults (nonlinear 1, everything
/// else off).
@immutable
class SpeedUpSettings {
  const SpeedUpSettings({
    this.nonlinear,
    this.pauseCap,
    this.keepSpeed,
    this.speedFloor,
    this.rhythmGap,
    this.rhythmRate,
    this.heardPause,
    this.heardPauseFromSpeed,
    this.floorBlend,
    this.floorBlendFromSpeed,
    this.floorBlendFullSpeed,
  });

  /// 1 for Speedy's nonlinear speed-up (the default), 0 for plain, even speed-up, or anything between.
  final double? nonlinear;

  /// Shorten every pause to at most this many seconds (0 off; 0.01 to 1).
  final double? pauseCap;

  /// Hold the overall speed at the speed asked for despite pauses cut and gaps added. Default true.
  final bool? keepSpeed;

  /// No part of the speech slower than this fraction of the speed (0 off, to 1).
  final double? speedFloor;

  /// A silence of this many seconds, [rhythmRate] times a second (0 off; 0.005 to 0.2).
  final double? rhythmGap;

  /// Gaps a second for [rhythmGap] (1 to 16, default 5).
  final double? rhythmRate;

  /// Pauses as heard: [heardPause] seconds once the speed is [heardPauseFromSpeed] or more. Both or neither.
  final double? heardPause;
  final double? heardPauseFromSpeed;

  /// The speed floor blended in: none below [floorBlendFromSpeed], all of [floorBlend] from [floorBlendFullSpeed].
  /// All three or none.
  final double? floorBlend;
  final double? floorBlendFromSpeed;
  final double? floorBlendFullSpeed;

  /// What is sent to the platform: only the settings given.
  Map<String, Object?> toMap() => {
        if (nonlinear != null) 'nonlinear': nonlinear,
        if (pauseCap != null) 'pauseCap': pauseCap,
        if (keepSpeed != null) 'keepSpeed': keepSpeed,
        if (speedFloor != null) 'speedFloor': speedFloor,
        if (rhythmGap != null) 'rhythmGap': rhythmGap,
        if (rhythmRate != null) 'rhythmRate': rhythmRate,
        if (heardPause != null && heardPauseFromSpeed != null) ...{
          'heardPause': heardPause,
          'heardPauseFrom': heardPauseFromSpeed,
        },
        if (floorBlend != null && floorBlendFromSpeed != null && floorBlendFullSpeed != null) ...{
          'floorBlend': floorBlend,
          'floorBlendFrom': floorBlendFromSpeed,
          'floorBlendFull': floorBlendFullSpeed,
        },
      };
}

/// Where a [VoiceReader] is: what is being heard, and whether it is playing.
@immutable
class ReaderPosition {
  const ReaderPosition({
    this.character = 0,
    this.sentence = 0,
    this.time = 0,
    this.isPlaying = false,
    this.isWaiting = false,
    this.isFinished = false,
    this.voiceId = '',
    this.error,
  });

  /// Builds one from what the platform sends.
  factory ReaderPosition.fromMap(Map<Object?, Object?> map) => ReaderPosition(
        character: (map['character'] as num?)?.toInt() ?? 0,
        sentence: (map['sentence'] as num?)?.toInt() ?? 0,
        time: (map['time'] as num?)?.toDouble() ?? 0,
        isPlaying: map['playing'] as bool? ?? false,
        isWaiting: map['waiting'] as bool? ?? false,
        isFinished: map['finished'] as bool? ?? false,
        voiceId: map['voiceId'] as String? ?? '',
        error: map['error'] as String?,
      );

  /// The index in the text (UTF-16, as Dart's String indices) of what is being heard; approximate within a
  /// sentence.
  final int character;

  /// The index in [VoiceReader.sentences] of the sentence being heard.
  final int sentence;

  /// [character] on the timeline, in seconds: characters x [ReaderOptions.secondsPerCharacter].
  final double time;

  /// Audio is playing (or waiting for the next sentence to be spoken, see [isWaiting]).
  final bool isPlaying;

  /// The next sentence is not spoken yet, so there is silence until it is. Common for a slow voice (Kokoro) just
  /// after starting, seeking or changing voice.
  final bool isWaiting;

  /// Everything has been heard.
  final bool isFinished;

  /// The voice reading, or the one asked for by [VoiceReader.setVoice] until it takes over.
  final String voiceId;

  /// The most recent failure to speak a sentence (which is then skipped) or to make a voice, if any.
  final String? error;

  @override
  String toString() => 'ReaderPosition(character: $character, sentence: $sentence, playing: $isPlaying, '
      'waiting: $isWaiting, finished: $isFinished${error == null ? '' : ', error: $error'})';
}

/// A sentence of the text: where it starts and how long it is, in UTF-16 units (as Dart's String indices).
@immutable
class SentenceRange {
  const SentenceRange(this.start, this.length);

  final int start;
  final int length;

  /// The index just past it.
  int get end => start + length;

  @override
  String toString() => 'SentenceRange($start, $length)';
}
