/// eSpeak NG for `speechwarp_voice`. **Licensed under the GPL-3.0-or-later**, unlike the rest of speechwarp: an app
/// that includes this package must be distributed under the GPL-3.0, with its complete source.
///
/// With this package in the app, `VoiceReader` reads "espeak:" voices (such as "espeak:en-gb", or
/// "espeak:en-gb/220/50" at 220 words a minute and pitch 50), `VoiceReader.listVoices` lists them, and Kokoro
/// (`speechwarp_voice_kokoro`) uses eSpeak NG as its phonemizer. Nothing needs calling here; this library only lets
/// an app check that eSpeak NG is there.
library;

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('speechwarp_voice_espeak');

/// eSpeak NG itself.
abstract final class Espeak {
  /// eSpeak NG's version, such as "1.52.0". Throws a [PlatformException] (code "espeak") when it cannot start, which
  /// on iOS means the package was built without the eSpeak framework (see the README).
  static Future<String> version() async => (await _channel.invokeMethod<String>('version'))!;

  /// The IPA eSpeak NG makes of [text] in [language] ("en-us", "en-gb"): what Kokoro is given.
  static Future<String> phonemes(String text, {String language = 'en-us'}) async =>
      (await _channel.invokeMethod<String>('phonemes', {'text': text, 'language': language}))!;
}
