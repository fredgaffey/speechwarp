// The Dart side alone, against a stand-in for the platform: what is sent over the method channel and how answers
// and events are read. The native side is tested by example/integration_test on a device or simulator.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speechwarp_voice/speechwarp_voice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('speechwarp_voice');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  Map<String, Object?> position({int character = 0, bool playing = false}) =>
      {'reader': 7, 'character': character, 'sentence': character > 10 ? 1 : 0, 'time': character / 17,
        'playing': playing, 'waiting': false, 'finished': false, 'voiceId': 'apple:x'};

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'listVoices':
          return [
            {'id': 'apple:x', 'name': 'X', 'language': 'en-US', 'engine': 'apple', 'installed': true,
              'keepsSpoken': false, 'details': {'isEloquence': false}},
            {'id': 'kokoro:af_heart', 'name': 'af_heart', 'language': 'en-us', 'engine': 'kokoro',
              'installed': false, 'keepsSpoken': true},
          ];
        case 'create':
          return {'id': 7, 'sampleRate': 22050, 'sentences': [0, 11, 11, 9]};
        case 'play':
          return position(playing: true);
        case 'dispose':
          return null;
        default:
          return position(character: 12);
      }
    });
    // The event channel: nothing to send, but it must answer listen and cancel.
    messenger.setMockMethodCallHandler(const MethodChannel('speechwarp_voice/positions'), (call) async => null);
  });

  test('listVoices reads every voice', () async {
    final voices = await VoiceReader.listVoices(kokoroDirectory: '/models');
    expect(calls.single.arguments, {'kokoroDirectory': '/models', 'kokoroModelFile': null});
    expect(voices.map((v) => v.id), ['apple:x', 'kokoro:af_heart']);
    expect(voices[0].details['isEloquence'], isFalse);
    expect(voices[1].isInstalled, isFalse);
    expect(voices[1].keepsSpoken, isTrue);
  });

  test('a reader is made with its options and reports positions', () async {
    final reader = await VoiceReader.create('First one. Second.',
        voiceId: 'apple:x',
        options: const ReaderOptions(speed: 2, speedUp: SpeedUpSettings(nonlinear: 0.5), kokoroDirectory: '/m'));
    final created = calls.single.arguments as Map;
    expect(created['text'], 'First one. Second.');
    expect(created['voiceId'], 'apple:x');
    expect((created['options'] as Map)['speed'], 2);
    expect((created['options'] as Map)['speedUp'], {'nonlinear': 0.5});
    expect((created['options'] as Map)['kokoroDirectory'], '/m');
    expect(reader.sampleRate, 22050);
    expect(reader.sentences.map((s) => (s.start, s.end)), [(0, 11), (11, 20)]);

    final seen = <ReaderPosition>[];
    reader.positions.listen(seen.add);
    await reader.play();
    expect(reader.position.isPlaying, isTrue);
    await reader.seekToSentence(5); // past the end: the last sentence
    expect(calls.last.arguments, {'id': 7, 'character': 11});
    expect(reader.position.character, 12);
    expect(reader.position.sentence, 1);
    await reader.setSpeed(3);
    expect(calls.last.arguments, {'id': 7, 'speed': 3.0});
    await reader.setVoice('apple:y');
    expect(calls.last.arguments, {'id': 7, 'voiceId': 'apple:y'});
    await Future<void>.delayed(Duration.zero);
    expect(seen.length, 4);

    await reader.dispose();
    expect(calls.last.method, 'dispose');
    expect(() => reader.play(), throwsStateError);
  });

  test('speed-up settings send only what is given, and pairs only whole', () {
    expect(const SpeedUpSettings().toMap(), isEmpty);
    expect(const SpeedUpSettings(pauseCap: 0.06, keepSpeed: false, heardPause: 0.03).toMap(),
        {'pauseCap': 0.06, 'keepSpeed': false});
    expect(const SpeedUpSettings(heardPause: 0.03, heardPauseFromSpeed: 3).toMap(),
        {'heardPause': 0.03, 'heardPauseFrom': 3.0});
    expect(const SpeedUpSettings(floorBlend: 0.5, floorBlendFromSpeed: 2, floorBlendFullSpeed: 6).toMap(),
        {'floorBlend': 0.5, 'floorBlendFrom': 2.0, 'floorBlendFull': 6.0});
  });

  test('a platform error comes through as a PlatformException', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(code: 'voice', message: 'No engine for the voice nobody:x');
    });
    await expectLater(VoiceReader.create('Hi.', voiceId: 'nobody:x'),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'voice')));
  });
}
