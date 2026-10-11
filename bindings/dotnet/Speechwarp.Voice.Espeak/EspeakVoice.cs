using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Speechwarp.Voice.Espeak;

/// <summary>Whom an eSpeak voice is meant to sound like.</summary>
public enum EspeakGender
{
    /// <summary>Not given.</summary>
    Unknown = 0,
    /// <summary>A man.</summary>
    Male = 1,
    /// <summary>A woman.</summary>
    Female = 2,
}

/// <summary>A voice in eSpeak's data: one language or accent.</summary>
/// <param name="Name">eSpeak's name for it, such as "English (Great Britain)".</param>
/// <param name="Identifier">Its file in the data, such as "gmw/en".</param>
/// <param name="Languages">
/// The languages it speaks, the most particular first, such as "en-gb-x-rp", "en-gb" and "en": the first is what
/// to give
/// <see cref="Espeak.Speak"/>, <see cref="Espeak.Phonemes"/> or <see cref="EspeakSentenceVoice"/>.
/// </param>
/// <param name="Gender">Whom it is meant to sound like.</param>
public sealed record EspeakVoice(string Name, string Identifier, IReadOnlyList<string> Languages, EspeakGender Gender)
{
    /// <summary>The language to ask for this voice by, such as "en-gb".</summary>
    public string Language => Languages.Count > 0 ? Languages[0] : Identifier;

    // espeak_VOICE in espeak-ng/speak_lib.h.
    [StructLayout(LayoutKind.Sequential)]
    internal struct Native
    {
        public nint Name;
        // Pairs of a priority byte and a zero-terminated language, ended by a zero priority.
        public nint Languages;
        public nint Identifier;
        public byte Gender;
        public byte Age;
        public byte Variant;
        public byte Xx1;
        public int Score;
        public nint Spare;
    }

    internal static unsafe EspeakVoice From(Native* voice)
    {
        var languages = new List<(int Priority, string Language)>();
        var at = (byte*)voice->Languages;
        while (at != null && *at != 0)
        {
            var priority = *at++;
            var language = Marshal.PtrToStringUTF8((nint)at) ?? "";
            languages.Add((priority, language));
            while (*at != 0)
                at++;
            at++;
        }
        return new EspeakVoice(
            Marshal.PtrToStringUTF8(voice->Name) ?? "",
            Marshal.PtrToStringUTF8(voice->Identifier) ?? "",
            // In the voice file's order, the most particular first: "en-gb-x-rp", then "en-gb" and "en". The
            // priorities only rank voices for a language.
            languages.ConvertAll(l => l.Language),
            voice->Gender is 1 or 2 ? (EspeakGender)voice->Gender : EspeakGender.Unknown);
    }
}
