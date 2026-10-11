// Runs in the real app on a device or simulator: the native readers speak, the platform plays the audio, and the
// position comes back to Dart.
//
//   flutter test integration_test -d <device>
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:speechwarp_voice/speechwarp_voice.dart';
import 'package:speechwarp_voice_espeak/speechwarp_voice_espeak.dart';
import 'package:speechwarp_voice_kokoro/speechwarp_voice_kokoro.dart';

const text = 'The quick brown fox jumps over the lazy dog. A second sentence follows the first. And then a third.';

/// Plays [reader] until the position reaches [character] (or it finishes), and returns the positions seen. A
/// character at the end of the text waits for the end itself: the position gets there a moment before it is over.
Future<List<ReaderPosition>> playUntil(VoiceReader reader, int character, {Duration timeout = const Duration(seconds: 60)}) async {
  final seen = <ReaderPosition>[];
  final done = Completer<void>();
  final subscription = reader.positions.listen((p) {
    seen.add(p);
    final reached = character < reader.text.length ? p.character >= character : p.isFinished;
    if ((reached || p.isFinished) && !done.isCompleted) done.complete();
  });
  await reader.play();
  await done.future.timeout(timeout, onTimeout: () {});
  await subscription.cancel();
  return seen;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late List<VoiceInfo> voices;

  setUpAll(() async {
    voices = await VoiceReader.listVoices();
    // ignore: avoid_print
    print('${voices.length} voices: ${voices.map((v) => v.engine).toSet()}; '
        'system: ${voices.where((v) => v.engine == 'apple' || v.engine == 'android').take(5).toList()}');
  });

  // Installed and on the device: Android lists network voices too, which never answer on a machine with no Google
  // services account, such as CI.
  bool isSystem(VoiceInfo v) =>
      (v.engine == 'apple' || v.engine == 'android') && v.isInstalled && !v.id.contains('network');
  bool isEnglish(VoiceInfo v) => v.language.toLowerCase().startsWith('en');

  // An English system voice, or any; null on a device with no text-to-speech engine (some emulator images).
  VoiceInfo? systemVoice() {
    final system = voices.where(isSystem);
    return system.where(isEnglish).firstOrNull ?? system.firstOrNull;
  }

  testWidgets('the system voice reads the text aloud and the position follows it', (tester) async {
    final voice = systemVoice();
    if (voice == null) {
      markTestSkipped('no system voice on this device');
      return;
    }
    final reader = await VoiceReader.create(text, voiceId: voice.id, options: const ReaderOptions(speed: 2));
    expect(reader.sentences.length, 3);
    expect(reader.sentences[1].start, text.indexOf('A second'));
    expect(reader.sampleRate, greaterThan(0));

    final seen = await playUntil(reader, reader.sentences[1].start);
    final last = seen.last;
    // ignore: avoid_print
    print('${voice.id}: ${seen.length} positions, last $last');
    expect(last.error, isNull);
    expect(last.character, greaterThanOrEqualTo(reader.sentences[1].start), reason: 'the reader got past the first sentence');
    expect(last.sentence, greaterThanOrEqualTo(1));
    expect(seen.any((p) => p.isPlaying), isTrue);
    expect(last.voiceId, voice.id);

    await reader.pause();
    expect(reader.position.isPlaying, isFalse);

    await reader.seekToSentence(2);
    expect(reader.position.sentence, 2);
    await reader.setSpeed(3);
    await reader.configure(const SpeedUpSettings(nonlinear: 0.5, pauseCap: 0.1));
    final end = await playUntil(reader, text.length);
    expect(end.last.isFinished, isTrue, reason: 'the reader read to the end: ${end.last}');
    await reader.dispose();
    expect(() => reader.play(), throwsStateError);
  });

  testWidgets('the voice can change while reading', (tester) async {
    // Two English voices when there are, as a voice in another language may need data the device lacks.
    final english = voices.where((v) => isSystem(v) && isEnglish(v)).toList();
    final system = english.length >= 2 ? english : voices.where(isSystem).toList();
    if (system.length < 2) {
      markTestSkipped('fewer than two system voices on this device');
      return;
    }
    final reader = await VoiceReader.create(text, voiceId: system.first.id, options: const ReaderOptions(speed: 2));
    await reader.setVoice(system.last.id);
    final seen = await playUntil(reader, text.length);
    expect(seen.last.error, isNull);
    expect(seen.last.voiceId, system.last.id);
    expect(seen.last.isFinished, isTrue);
    await reader.dispose();
  });

  testWidgets('an unknown voice fails with a PlatformException', (tester) async {
    await expectLater(VoiceReader.create(text, voiceId: 'nobody:nothing'),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'voice')));
  });

  testWidgets("Kokoro's catalogue is there, and Kokoro without a model directory says so", (tester) async {
    final catalogue = await Kokoro.catalogue();
    expect(catalogue.voices.length, 54);
    expect(catalogue.models.map((m) => m.file.relativePath), contains(catalogue.defaultModelFile));
    final missing = await Kokoro.missingFiles('/nonexistent');
    expect(missing.map((f) => f.relativePath), containsAll([catalogue.defaultModelFile, 'tokenizer.json', 'voices/af_heart.bin']));
    expect(voices.where((v) => v.engine == 'kokoro'), hasLength(54));
    await expectLater(VoiceReader.create(text, voiceId: 'kokoro:af_heart'),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'kokoro')));
  });

  // Needs Kokoro's files on the device: --dart-define=KOKORO_DIR=<folder> (and KOKORO_MODEL=<file> for a model other
  // than the platform's default). With eSpeak NG as the phonemizer.
  testWidgets('Kokoro reads the text aloud, given a model', (tester) async {
    const directory = String.fromEnvironment('KOKORO_DIR');
    const model = String.fromEnvironment('KOKORO_MODEL');
    if (directory.isEmpty) {
      markTestSkipped('no Kokoro model (--dart-define=KOKORO_DIR=...)');
      return;
    }
    final modelFile = model.isEmpty ? null : model;
    expect(await Kokoro.missingFiles(directory, modelFile: modelFile), isEmpty);
    final listed = await VoiceReader.listVoices(kokoroDirectory: directory, kokoroModelFile: modelFile);
    expect(listed.firstWhere((v) => v.id == 'kokoro:af_heart').isInstalled, isTrue);
    final reader = await VoiceReader.create(text,
        voiceId: 'kokoro:af_heart',
        options: ReaderOptions(kokoroDirectory: directory, kokoroModelFile: modelFile, cache: false, speed: 1.5));
    final started = DateTime.now();
    final seen = await playUntil(reader, reader.sentences[1].start, timeout: const Duration(minutes: 3));
    // ignore: avoid_print
    print('kokoro:af_heart: ${seen.length} positions in ${DateTime.now().difference(started)}, last ${seen.last}');
    expect(seen.last.error, isNull);
    expect(seen.last.character, greaterThanOrEqualTo(reader.sentences[1].start));
    await reader.dispose();
  });

  testWidgets('eSpeak NG reads the text aloud, where it is built in', (tester) async {
    final espeak = voices.where((v) => v.engine == 'espeak').toList();
    if (espeak.isEmpty) {
      // iOS without the eSpeak framework built: the package is there but eSpeak is not.
      await expectLater(Espeak.version(), throwsA(isA<PlatformException>()));
      markTestSkipped('eSpeak NG is not built into this app');
      return;
    }
    expect(await Espeak.version(), startsWith('1.'));
    expect(await Espeak.phonemes('hello'), isNotEmpty);
    final voice = espeak.firstWhere((v) => v.id == 'espeak:en-gb', orElse: () => espeak.first);
    final reader = await VoiceReader.create(text, voiceId: voice.id, options: const ReaderOptions(speed: 2));
    final seen = await playUntil(reader, text.length);
    // ignore: avoid_print
    print('${voice.id}: ${seen.length} positions, last ${seen.last}');
    expect(seen.last.error, isNull);
    expect(seen.last.isFinished, isTrue);
    await reader.dispose();
  });
}
