using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Speechwarp.Voice.Espeak;

/// <summary>
/// eSpeak NG, linked into the app: speech in its own formant voices, and text to phonemes (IPA) for neural voices
/// such as Kokoro.
/// </summary>
/// <remarks>
/// eSpeak keeps its state in globals and is not thread-safe, so every call here takes one lock: calls from several
/// threads take turns. eSpeak starts on the first call that needs it, with its data at <see cref="DataPath"/>.
/// eSpeak NG is licensed under the GPL-3.0-or-later; so is this package, and an app that uses it.
/// </remarks>
public static unsafe partial class Espeak
{
    /// <summary>The default speaking rate, in words a minute.</summary>
    public const int DefaultWordsPerMinute = 175;

    /// <summary>The default pitch, 0 to 100.</summary>
    public const int DefaultPitch = 50;

    private const string Library = "__Internal";

    // espeak_ng_OUTPUT_MODE ENOUTPUT_MODE_SYNCHRONOUS: sound handed back through the callback, never played.
    private const int OutputSynchronous = 1;
    // espeakCHARS_UTF8.
    private const int CharsUtf8 = 1;
    // espeakPHONEMES_IPA.
    private const int PhonemesIpa = 2;
    // espeak_PARAMETER espeakRATE and espeakPITCH.
    private const int Rate = 1, Pitch = 3;
    // espeak_POSITION_TYPE POS_CHARACTER.
    private const int PositionCharacter = 1;

    private static readonly Lock locker = new();
    private static bool started;
    private static string? dataPath;
    private static string? voice;
    private static List<short>? synthesized;

    /// <summary>
    /// The folder of eSpeak's data, espeak-ng-data. By default the one the package puts in the app bundle
    /// (English, in each of eSpeak's accents, and every voice variant).
    /// </summary>
    /// <remarks>Set it before the first call that uses eSpeak; once eSpeak has started, setting it throws.</remarks>
    /// <exception cref="InvalidOperationException">eSpeak has already started.</exception>
    public static string DataPath
    {
        get
        {
            lock (locker)
                return dataPath ?? Path.Combine(Foundation.NSBundle.MainBundle.ResourcePath ?? "", "espeak-ng-data");
        }
        set
        {
            ArgumentNullException.ThrowIfNull(value);
            lock (locker)
            {
                if (started && value != dataPath)
                    throw new InvalidOperationException("eSpeak has started; set its data path before using it.");
                dataPath = value;
            }
        }
    }

    /// <summary>eSpeak NG's version, such as "1.52.0".</summary>
    public static string Version => Marshal.PtrToStringUTF8((nint)espeak_Info(null)) ?? "";

    /// <summary>Frames a second of what <see cref="Speak"/> returns: 22,050.</summary>
    /// <exception cref="InvalidOperationException">eSpeak could not start (its data is missing).</exception>
    public static int SampleRate
    {
        get
        {
            lock (locker)
            {
                Start();
                return espeak_ng_GetSampleRate();
            }
        }
    }

    /// <summary>
    /// <paramref name="text"/> spoken by eSpeak in the voice <paramref name="language"/>: mono samples, -1 to 1, at
    /// <see cref="SampleRate"/>, empty for nothing to say. The defaults, 175 words a minute and pitch 50, are eSpeak's own and those of the
    /// HSC library's "Eloquence" tracks.
    /// </summary>
    /// <param name="text">The text, plain (not SSML).</param>
    /// <param name="language">
    /// A voice: a language such as "en-us", "en-gb", "en-gb-x-rp" or "en-029" (see <see cref="Voices"/>),
    /// optionally with a variant, such as "en-us+klatt" (see <see cref="Variants"/>).
    /// </param>
    /// <param name="wordsPerMinute">Speaking rate, 80 to 450 (eSpeak keeps it within those).</param>
    /// <param name="pitch">Pitch, 0 to 100.</param>
    /// <exception cref="ArgumentException">eSpeak has no voice <paramref name="language"/>.</exception>
    /// <exception cref="InvalidOperationException">eSpeak could not start, or failed to speak.</exception>
    public static float[] Speak(string text, string language, int wordsPerMinute = DefaultWordsPerMinute, int pitch = DefaultPitch)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(language);
        lock (locker)
        {
            Start();
            Use(language);
            if (string.IsNullOrWhiteSpace(text))
                return [];
            espeak_SetParameter(Rate, wordsPerMinute, 0);
            espeak_SetParameter(Pitch, Math.Clamp(pitch, 0, 100), 0);
            var bytes = Encoding.UTF8.GetBytes(text + "\0");
            synthesized = [];
            try
            {
                int status;
                fixed (byte* start = bytes)
                    status = espeak_Synth(start, (nuint)bytes.Length, 0, PositionCharacter, 0, CharsUtf8, null, null);
                if (status != 0)
                    throw new InvalidOperationException($"eSpeak failed to speak (error {status}).");
                var result = new float[synthesized.Count];
                for (var i = 0; i < result.Length; i++)
                    result[i] = synthesized[i] / 32768f;
                return result;
            }
            finally
            {
                synthesized = null;
            }
        }
    }

    /// <summary>
    /// The phonemes of <paramref name="text"/> in IPA, with eSpeak's stress marks, clause by clause (clauses are
    /// separated by a space), for the voice <paramref name="language"/> ("en-us", "en-gb" and the rest).
    /// </summary>
    /// <exception cref="ArgumentException">eSpeak has no voice <paramref name="language"/>.</exception>
    /// <exception cref="InvalidOperationException">eSpeak could not start.</exception>
    public static string Phonemes(string text, string language = "en-us")
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(language);
        lock (locker)
        {
            Start();
            Use(language);
            var bytes = Encoding.UTF8.GetBytes(text + "\0");
            var result = new StringBuilder();
            fixed (byte* start = bytes)
            {
                // eSpeak moves the pointer past each clause it translates, and sets it to null at the end.
                var at = start;
                while (at != null)
                {
                    var clause = espeak_TextToPhonemes(&at, CharsUtf8, PhonemesIpa);
                    if (clause == null || *clause == 0)
                        continue;
                    if (result.Length > 0)
                        result.Append(' ');
                    result.Append(Marshal.PtrToStringUTF8((nint)clause));
                }
            }
            return result.ToString();
        }
    }

    /// <summary>
    /// The voices in eSpeak's data, one per language and accent, sorted by name. The data the package bundles has
    /// English only: America, New York, Britain, Received Pronunciation, Scotland, Lancaster, West Midlands, the
    /// Caribbean and Shavian.
    /// </summary>
    /// <exception cref="InvalidOperationException">eSpeak could not start.</exception>
    public static IReadOnlyList<EspeakVoice> Voices
    {
        get
        {
            lock (locker)
            {
                Start();
                var voices = new List<EspeakVoice>();
                var list = espeak_ListVoices(null);
                for (var i = 0; list != null && list[i] != null; i++)
                    voices.Add(EspeakVoice.From(list[i]));
                return voices;
            }
        }
    }

    /// <summary>
    /// The voice variants in eSpeak's data, such as "klatt", "f3" or "m1": added to a voice after a '+'
    /// ("en-us+klatt"), they change its sound (the Klatt variants use a different synthesiser).
    /// </summary>
    public static IReadOnlyList<string> Variants
    {
        get
        {
            var folder = Path.Combine(DataPath, "voices", "!v");
            if (!Directory.Exists(folder))
                return [];
            var names = new List<string>();
            foreach (var file in Directory.EnumerateFiles(folder))
                names.Add(Path.GetFileName(file));
            names.Sort(StringComparer.OrdinalIgnoreCase);
            return names;
        }
    }

    // Called with the lock held.
    private static void Start()
    {
        if (started)
            return;
        var path = dataPath ?? Path.Combine(Foundation.NSBundle.MainBundle.ResourcePath ?? "", "espeak-ng-data");
        // On purpose the espeak_ng_ calls, which report errors: the older espeak_Initialize ends the whole app when
        // it cannot find its data.
        espeak_ng_InitializePath(path);
        var status = espeak_ng_Initialize(null);
        if (status != 0)
            throw new InvalidOperationException($"eSpeak could not start with its data at {path} (status 0x{status:X}).");
        status = espeak_ng_InitializeOutput(OutputSynchronous, 0, null);
        if (status != 0)
            throw new InvalidOperationException($"eSpeak could not prepare its output (status 0x{status:X}).");
        espeak_SetSynthCallback(&OnSynth);
        dataPath = path;
        started = true;
    }

    // Called with the lock held.
    private static void Use(string language)
    {
        if (voice == language)
            return;
        // eSpeak finds a voice by its name or file name ("en-us" is lang/gmw/en-US), but not by a language that names
        // no file: "en-gb" is lang/gmw/en. Then ask it for the voice that suits the language best, as its own
        // command does, and keep any variant ("en-gb+klatt").
        if (espeak_ng_SetVoiceByName(language) != 0
            && (BestVoiceFor(language) is not { } identifier || espeak_ng_SetVoiceByName(identifier) != 0))
        {
            throw new ArgumentException($"eSpeak has no voice '{language}'.", nameof(language));
        }
        voice = language;
    }

    // The file of the voice that suits a language best, with the language's variant, or null. Called with the lock held.
    private static string? BestVoiceFor(string language)
    {
        var plus = language.IndexOf('+');
        var name = plus < 0 ? language : language[..plus];
        var variant = plus < 0 ? "" : language[plus..];
        if (name.Length == 0)
            return null;
        var bytes = Encoding.UTF8.GetBytes(name + "\0");
        fixed (byte* languages = bytes)
        {
            var spec = new EspeakVoice.Native { Languages = (nint)languages };
            var list = espeak_ListVoices(&spec);
            if (list == null || list[0] == null)
                return null;
            return Marshal.PtrToStringUTF8(list[0]->Identifier) + variant;
        }
    }

    // Called by espeak_Synth on the calling thread, which holds the lock, with each piece of sound.
    [UnmanagedCallersOnly]
    private static int OnSynth(short* wav, int samples, void* events)
    {
        if (wav != null && samples > 0)
            synthesized?.AddRange(new ReadOnlySpan<short>(wav, samples));
        return 0;
    }

    // ---- eSpeak NG's C interface (espeak-ng/speak_lib.h and espeak-ng/espeak_ng.h)

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    private static partial void espeak_ng_InitializePath(string path);

    [LibraryImport(Library)]
    private static partial int espeak_ng_Initialize(void* context);

    [LibraryImport(Library)]
    private static partial int espeak_ng_InitializeOutput(int mode, int bufferLength, byte* device);

    [LibraryImport(Library)]
    private static partial int espeak_ng_GetSampleRate();

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    private static partial int espeak_ng_SetVoiceByName(string name);

    [LibraryImport(Library)]
    private static partial int espeak_SetParameter(int parameter, int value, int relative);

    [LibraryImport(Library)]
    private static partial void espeak_SetSynthCallback(delegate* unmanaged<short*, int, void*, int> callback);

    [LibraryImport(Library)]
    private static partial int espeak_Synth(byte* text, nuint size, uint position, int positionType, uint endPosition,
        uint flags, uint* uniqueIdentifier, void* userData);

    [LibraryImport(Library)]
    private static partial byte* espeak_TextToPhonemes(byte** textptr, int textmode, int phonememode);

    [LibraryImport(Library)]
    internal static partial EspeakVoice.Native** espeak_ListVoices(EspeakVoice.Native* voiceSpec);

    [LibraryImport(Library)]
    private static partial byte* espeak_Info(byte** pathData);
}
