/// Kokoro-82M for `speechwarp_voice`: with this package in the app, `VoiceReader` reads "kokoro:" voices (such as
/// "kokoro:af_heart") and `VoiceReader.listVoices` lists them. This library is the catalogue of the model files to
/// download, which the package itself never does.
///
/// ```dart
/// final missing = await Kokoro.missingFiles(directory, voice: 'af_heart');
/// for (final file in missing) {
///   // download file.url to '$directory/${file.relativePath}' and check its SHA-256 against file.sha256
/// }
/// final reader = await VoiceReader.create(text, voiceId: 'kokoro:af_heart',
///     options: ReaderOptions(kokoroDirectory: directory));
/// ```
///
/// Kokoro needs a phonemizer. The only one speechwarp ships is eSpeak NG's (`speechwarp_voice_espeak`, licensed
/// under the GPL-3.0-or-later). An app that cannot be GPL sets its own, natively: `SpeechwarpVoicePlugin.phonemizer`
/// in Kotlin or Swift.
library;

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('speechwarp_voice_kokoro');

/// A file to download: where it goes in the model directory, how big it is, where it is and its SHA-256.
class KokoroFile {
  const KokoroFile(this.relativePath, this.sizeBytes, this.url, this.sha256);

  factory KokoroFile.fromMap(Map<Object?, Object?> map) => KokoroFile(map['relativePath']! as String,
      (map['sizeBytes']! as num).toInt(), map['url']! as String, map['sha256']! as String);

  /// Its path in the model directory, such as "model.onnx" or "voices/af_heart.bin".
  final String relativePath;
  final int sizeBytes;

  /// On Hugging Face, at a fixed revision, so that the hash always matches.
  final String url;

  /// Lower-case hex.
  final String sha256;

  @override
  String toString() => 'KokoroFile($relativePath, $sizeBytes bytes)';
}

/// A variant of the model, such as fp32 ("model") or fp16 ("model_fp16").
class KokoroModel {
  const KokoroModel(this.id, this.name, this.description, this.file);

  factory KokoroModel.fromMap(Map<Object?, Object?> map) => KokoroModel(map['id']! as String, map['name']! as String,
      map['description']! as String, KokoroFile.fromMap(map['file']! as Map<Object?, Object?>));

  final String id;
  final String name;
  final String description;
  final KokoroFile file;
}

/// One of Kokoro's voices: "af_heart" is American English, female.
class KokoroVoice {
  const KokoroVoice(this.name, this.language, this.isFemale, this.file);

  factory KokoroVoice.fromMap(Map<Object?, Object?> map) => KokoroVoice(map['name']! as String,
      map['language']! as String, map['isFemale']! as bool, KokoroFile.fromMap(map['file']! as Map<Object?, Object?>));

  final String name;

  /// As the phonemizer takes it, such as "en-us".
  final String language;
  final bool isFemale;
  final KokoroFile file;

  /// The voice id for `VoiceReader`: "kokoro:" and the name.
  String get id => 'kokoro:$name';
}

/// Everything there is to download, as the native library lists it.
class KokoroCatalogue {
  const KokoroCatalogue({
    required this.repository,
    required this.revision,
    required this.defaultModelFile,
    required this.defaultVoice,
    required this.tokenizer,
    required this.models,
    required this.voices,
  });

  factory KokoroCatalogue.fromMap(Map<Object?, Object?> map) => KokoroCatalogue(
        repository: map['repository']! as String,
        revision: map['revision']! as String,
        defaultModelFile: map['defaultModelFile']! as String,
        defaultVoice: map['defaultVoice']! as String,
        tokenizer: KokoroFile.fromMap(map['tokenizer']! as Map<Object?, Object?>),
        models: [for (final m in map['models']! as List<Object?>) KokoroModel.fromMap(m! as Map<Object?, Object?>)],
        voices: [for (final v in map['voices']! as List<Object?>) KokoroVoice.fromMap(v! as Map<Object?, Object?>)],
      );

  /// The Hugging Face repository and the revision every URL is pinned to.
  final String repository;
  final String revision;

  /// The model file used when `ReaderOptions.kokoroModelFile` is null: "model.onnx" (fp32, 326 MB) on Android,
  /// "model_fp16.onnx" (163 MB) on iOS. See docs/voices.md in the repository for why they differ.
  final String defaultModelFile;
  final String defaultVoice;

  /// Every model needs it.
  final KokoroFile tokenizer;
  final List<KokoroModel> models;
  final List<KokoroVoice> voices;
}

/// Kokoro's model files.
abstract final class Kokoro {
  /// Every file there is to download.
  static Future<KokoroCatalogue> catalogue() async =>
      KokoroCatalogue.fromMap((await _channel.invokeMapMethod<Object?, Object?>('catalogue'))!);

  /// The files [directory] still needs for [voice] with [modelFile] (null: the platform's default): download each
  /// to `directory/relativePath` and check its hash.
  static Future<List<KokoroFile>> missingFiles(String directory, {String voice = 'af_heart', String? modelFile}) async {
    final list = await _channel.invokeListMethod<Object?>('missingFiles', {
      'directory': directory,
      'voice': voice,
      'modelFile': modelFile,
    });
    return [for (final f in list ?? const []) KokoroFile.fromMap(f! as Map<Object?, Object?>)];
  }

  /// Whether [directory] has everything [voice] needs.
  static Future<bool> isInstalled(String directory, {String voice = 'af_heart', String? modelFile}) async =>
      (await missingFiles(directory, voice: voice, modelFile: modelFile)).isEmpty;
}
