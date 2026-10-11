/// Text read aloud on iOS and Android, sentence by sentence, sped up by speechwarp, with the character being
/// spoken. A wrapper over speechwarp's native voice readers (Swift `SpeechwarpVoice`, Kotlin `speechwarp-voice`):
/// the reading, the speed-up and the playback all happen natively, and Dart sees the position.
///
/// ```dart
/// final voices = await VoiceReader.listVoices();
/// final reader = await VoiceReader.create(text, voiceId: voices.first.id);
/// reader.positions.listen((p) => highlight(p.character));
/// await reader.setSpeed(2.5);
/// await reader.play();
/// ```
library;

export 'src/reader.dart';
export 'src/types.dart';
