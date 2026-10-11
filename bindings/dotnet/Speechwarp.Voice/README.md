# Speechwarp.Voice

Text read aloud by Apple's voices, Eloquence among them, or by any other engine, and sped up by speechwarp, for
iOS 16 and later. See the repository README.

## Text to speech with any engine

An engine is an `ISentenceVoice`: it speaks one sentence at a time at its own sample rate. This package has
Apple's voices (`AppleSentenceVoice`, ids "apple:<identifier>"); Kokoro is in `Speechwarp.Voice.Kokoro` (and
`Speechwarp.Voice.Kokoro.Gpu`), eSpeak NG in `Speechwarp.Voice.Espeak` (GPL-3.0).

`VoicedText` reads a text with any of them. It speaks sentences on a thread of its own ahead of what is being
read (30 s of listening, 120 s for a slow engine whose `KeepsSpoken` is true), converts every voice to one sample
rate, can change voice between sentences, and optionally speeds the audio up through a `SpeechwarpStream`.
`Read` never waits.

```csharp
using Speechwarp.Voice;

using var book = new VoicedText(text, new AppleSentenceVoice("com.apple.eloquence.en-US.Reed")) { Speed = 3 };
book.Configure(s => s.SetHeardPause(0.03f, 3));
int frames = book.Read(buffer);          // on the audio thread: mono, book.SampleRate
int at = book.CharacterPosition;         // for the display: index into the text
book.SetVoice(new AppleSentenceVoice("com.apple.eloquence.en-US.Flo"));   // from the next sentence
book.Seek(TimeSpan.FromMinutes(3));      // or book.Seek(characterIndex)
```

Its timeline is the text's characters at `SecondsPerCharacter` each (default 1/17 s), the same whatever the voice
and speed, so a place saved in one voice is the same place in another. `TimeAt(frame)` gives the place of a frame
`Read` returned, counted from the frame the last `Seek` returned; `Duration` is the whole text.

A player that speeds audio up itself, and makes voices from ids, as an audiobook player does:

```csharp
ISentenceVoice Make(string id) => id switch
{
    _ when id.StartsWith("kokoro:") => new KokoroSentenceVoice(/* ... */),
    _ => new AppleSentenceVoice(id),
};
var reader = new VoicedText(text, voiceId, Make, new VoicedTextOptions
{
    SpeedUp = false,                                   // the voices' audio as spoken
    SecondsPerCharacter = 1 / 17.0,
    CacheDirectory = VoiceCache.DefaultDirectory,      // keep what slow voices say
    SpeakAheadToDisk = () => UIDevice.CurrentDevice.BatteryState is UIDeviceBatteryState.Charging or UIDeviceBatteryState.Full,
});
reader.SetVoice("kokoro:af_heart");                    // made on the reader's thread; VoiceId says so at once
```

`SampleRate`, `Channels`, `Duration`, `Read`, `Seek(TimeSpan)` (returns the frame), `IsWaiting`, `TimeAt`,
`VoiceId` and `SetVoice(string)` are what such a player's source needs, so wrapping it takes a few lines.

`VoiceCache` keeps a slow voice's sentences on disk: blocks of 40 sentences, each an AAC file (32 kbit/s) with the
sentences' lengths beside it, in `directory/TEXT/VOICE/` (TEXT is the first 16 hex digits of the text's SHA-256).
The default directory is Library/Caches/speechwarp-voice, which iOS may clear; what is gone is spoken again. A
reader uses it for `KeepsSpoken` voices when `CacheDirectory` is given; background work (speaking a book ahead
overnight) can use it directly with `SpokenText.Split`, `VoiceCache.BlockOf`, `Has` and `Save`.

`AppleSentenceVoice.Speak` waits for the system, which delivers speech on the main thread: call it from a
background thread (the reader does). On the main thread it runs the main run loop while it waits rather than
deadlocking. `SpokenText`, the earlier Apple-only reader, is now a thin wrapper over `VoicedText`.

## Speech to text with Apple's recogniser

`AppleTranscriber` is Apple's on-device speech recogniser behind the engine-independent `ITranscriber` interface
of the `Speechwarp` package (namespace `Speechwarp.Transcription`), so the same calls work with any engine. It
uses `SFSpeechRecognizer` with on-device recognition required: nothing leaves the device. Long input (a book, a
microphone left on) is given to the recogniser in requests of 20 to 50 s, cut in pauses; times are from the
start of the session. Apple's newer `SpeechAnalyzer` (iOS 26) is Swift-only and not bound for .NET; the Swift
package uses it.

```csharp
using Speechwarp.Transcription;
using Speechwarp.Voice;

using var transcriber = new AppleTranscriber(AppleTranscriber.ModelFor("en-GB"));
await transcriber.PrepareAsync();                        // asks the user's permission the first time

// A passage given at once: a sentence said back, a clip.
var transcript = await transcriber.TranscribeAsync(samples, 16000);

// Anything long or live: a session fed in pieces.
using var session = transcriber.StartSession(16000);
session.Write(chunk);                                    // as often as you like; never waits
var done = session.TakeSegments();                       // finished since the last call; Partial is the live guess
var rest = await session.FinishAsync();

// The microphone, into a session of any engine.
using var microphone = new MicrophoneSource(16000);
await microphone.StartAsync(session);                    // microphone.Level for a meter
microphone.Stop();
```

`AppleTranscriber.Models` lists a model per language the device recognises on the device; each has the id
`apple-<language>`, size 0 and no download URL, because the system manages them. Failures throw
`AppleTranscriberException`, whose `Error` says what went wrong (not authorised, unsupported language, ...).

The app's Info.plist needs these keys, or iOS ends the app when permission is asked for (the library checks
first and throws instead):

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Recognises what you say, on this device.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Listens to what you say.</string>
```

The iOS simulator has no on-device recogniser ("Failed to initialize recognizer"); use a device.
