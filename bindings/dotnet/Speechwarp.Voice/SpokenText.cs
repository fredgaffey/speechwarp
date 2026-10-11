using System;
using System.Collections.Generic;
using Foundation;
using NaturalLanguage;

namespace Speechwarp.Voice;

/// <summary>
/// A text read aloud by a system voice and sped up by speechwarp, rendered sentence by sentence a little ahead of
/// playback. A convenience over <see cref="VoicedText"/> with an <see cref="AppleSentenceVoice"/>; use
/// <see cref="VoicedText"/> itself for other engines, changing voice, a cache or seeking by time.
/// </summary>
/// <example>
/// <code>
/// var voice = SpeechVoice.Eloquence("en-US").First(v => v.Name == "Reed");
/// using var book = new SpokenText(text, voice) { Speed = 5 };     // on top of the voice's own rate
/// book.Configure(s => s.SetHeardPause(0.03f, 3));
/// // on the audio thread:
/// int frames = book.Read(buffer);                                // mono, book.SampleRate
/// // for the display:
/// int at = book.CharacterPosition;                               // index into the text
/// </code>
/// </example>
/// <remarks>
/// Rendering runs on the main thread (where the system delivers speech), waited for on the reader's own thread;
/// everything else is safe from any thread. <see cref="Read"/> never waits: if the next sentence is not rendered yet
/// it returns what there is, and <see cref="IsBuffering"/> says so. Character positions are indices into the string
/// (UTF-16), as everywhere in .NET.
/// </remarks>
public sealed class SpokenText : IDisposable
{
    /// <summary>A sentence: where it starts in the text, how long it is, and its text.</summary>
    public sealed record Sentence(int Start, int Length, string Text);

    private const int MaxSentence = 400;

    private readonly object _lock = new();
    private float _rate;

    /// <summary>The text being read.</summary>
    public string Text => Reader.Text;
    /// <summary>The voice reading it.</summary>
    public SpeechVoice Voice { get; }
    /// <summary>The text cut into sentences.</summary>
    public IReadOnlyList<Sentence> Sentences => Reader.Sentences;
    /// <summary>The sample rate of what <see cref="Read"/> returns. Mono.</summary>
    public int SampleRate => Reader.SampleRate;
    /// <summary>The reader doing the work, for what this class does not offer (seeking by time, say).</summary>
    public VoicedText Reader { get; }

    /// <summary>
    /// Splits <paramref name="text"/> into sentences and starts rendering the first ones.
    /// <paramref name="voiceRate"/> is the system rate (see <see cref="SpeechRate"/>); <see cref="Speed"/>
    /// multiplies it.
    /// </summary>
    /// <exception cref="ArgumentException">The voice is not installed.</exception>
    public SpokenText(string text, SpeechVoice voice, float? voiceRate = null)
    {
        Voice = voice;
        _rate = voiceRate ?? SpeechRate.Normal;
        var first = new AppleSentenceVoice(voice, _rate);
        Reader = new VoicedText(text, first, new VoicedTextOptions { SampleRate = first.SampleRate, Lookahead = 30 });
    }

    /// <summary>The system rate the voice speaks at. Applies to sentences rendered afterwards.</summary>
    public float VoiceRate
    {
        get { lock (_lock) return _rate; }
        set
        {
            lock (_lock)
            {
                _rate = value;
                Reader.SetVoice(new AppleSentenceVoice(Voice, value));
            }
        }
    }

    /// <summary>speechwarp's speed on top of the voice's own rate: 2 plays twice as fast again.</summary>
    public float Speed
    {
        get => Reader.Speed;
        set => Reader.Speed = value;
    }

    /// <summary>Seconds of listening to keep rendered ahead of what is being heard. Default 30.</summary>
    public double Lookahead
    {
        get => Reader.Lookahead;
        set => Reader.Lookahead = value;
    }

    /// <summary>The index in the text of what is being heard now (approximate within a sentence).</summary>
    public int CharacterPosition => Reader.CharacterPosition;

    /// <summary>The sentence being heard now.</summary>
    public int SentenceIndex => Reader.SentenceIndex;

    /// <summary>The last <see cref="Read"/> returned less than asked because the next sentence was being rendered.</summary>
    public bool IsBuffering => Reader.IsWaiting;

    /// <summary>Everything has been read.</summary>
    public bool IsFinished => Reader.IsFinished;

    /// <summary>The most recent rendering failure, if any. A sentence that fails is skipped.</summary>
    public Exception? LastError => Reader.LastError;

    /// <summary>
    /// Changes the speechwarp stream's other settings (nonlinear amount, heard pause, floor blend, rhythm ...)
    /// safely. Do not keep the stream.
    /// </summary>
    public void Configure(Action<SpeechwarpStream> change) => Reader.Configure(change);

    /// <summary>Fills <paramref name="samples"/> with what to play next; returns the frames written. Never waits.</summary>
    public int Read(Span<float> samples) => Reader.Read(samples);

    /// <summary>Continues from the start of the sentence containing character <paramref name="index"/>.</summary>
    public void Seek(int index) => Reader.Seek(index);

    /// <summary>
    /// Sentences by the system's tokenizer; any longer than 400 characters are cut at the last comma, semicolon or
    /// space before that, so that rendering never stalls on one enormous sentence.
    /// </summary>
    public static IReadOnlyList<Sentence> Split(string text)
    {
        var result = new List<Sentence>();
        using var tokenizer = new NLTokenizer(NLTokenUnit.Sentence) { String = text };
        foreach (var value in tokenizer.GetTokens(new NSRange(0, text.Length)))
        {
            var range = value.RangeValue;
            int start = (int)range.Location, end = (int)(range.Location + range.Length);
            while (end - start > MaxSentence)
            {
                var limit = start + MaxSentence;
                var cut = text.LastIndexOfAny([',', ';', ':'], limit - 1, MaxSentence);
                cut = cut > start ? cut + 1 : text.LastIndexOf(' ', limit - 1, MaxSentence) is var space && space > start ? space : limit;
                result.Add(new Sentence(start, cut - start, text[start..cut]));
                start = cut;
            }
            if (!string.IsNullOrWhiteSpace(text[start..end]))
                result.Add(new Sentence(start, end - start, text[start..end]));
        }
        return result;
    }

    /// <summary>Stops rendering and releases the stream and the synthesiser.</summary>
    public void Dispose() => Reader.Dispose();
}
