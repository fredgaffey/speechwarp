using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace Speechwarp.Voice;

/// <summary>How a <see cref="VoicedText"/> reads: its output, how far ahead it speaks, and where it keeps what slow voices say.</summary>
public sealed class VoicedTextOptions
{
    /// <summary>
    /// The sample rate of what <see cref="VoicedText.Read"/> returns. Default: the first voice's. Voices that speak
    /// at another rate are converted to it.
    /// </summary>
    public int? SampleRate { get; init; }

    /// <summary>
    /// Whether the audio goes through a <see cref="SpeechwarpStream"/>, so that <see cref="VoicedText.Speed"/> and
    /// <see cref="VoicedText.Configure"/> work. Default true. False gives the voices' audio as spoken, for a player
    /// that speeds it up itself.
    /// </summary>
    public bool SpeedUp { get; init; } = true;

    /// <summary>Seconds of listening to keep spoken ahead of what is being read, for a fast voice. Default 30.</summary>
    public double Lookahead { get; init; } = 30;

    /// <summary>
    /// Seconds of listening to keep spoken ahead for a slow voice (<see cref="ISentenceVoice.KeepsSpoken"/>), which
    /// needs longer to catch up after a pause. Default 120.
    /// </summary>
    public double KeptLookahead { get; init; } = 120;

    /// <summary>
    /// The pace of the timeline: a character of the text is this many seconds long, whatever the voice, so that a
    /// place (<see cref="VoicedText.TimeAt"/>, <see cref="VoicedText.Seek(TimeSpan)"/>) is the same character in
    /// every voice. Default 1/17, about the pace of Apple's voices at their normal rate.
    /// </summary>
    public double SecondsPerCharacter { get; init; } = 1 / 17.0;

    /// <summary>
    /// Where a slow voice's sentences are kept (see <see cref="VoiceCache"/>; <see cref="VoiceCache.DefaultDirectory"/>
    /// is the usual place). Null, the default, keeps nothing on disk.
    /// </summary>
    public string? CacheDirectory { get; init; }

    /// <summary>
    /// Asked when everything within the lookahead is spoken: true lets a slow voice carry on speaking whole blocks
    /// into the cache beyond it (an app might say true while the device is charging). Needs
    /// <see cref="CacheDirectory"/>. Called on the reader's thread. Default: never.
    /// </summary>
    public Func<bool>? SpeakAheadToDisk { get; init; }
}

/// <summary>
/// A text read aloud by any <see cref="ISentenceVoice"/> (Apple's voices, Kokoro, eSpeak NG ...), sentence by sentence,
/// spoken on a thread of its own ahead of what is being read, optionally sped up by speechwarp. The voice can change
/// between sentences.
/// </summary>
/// <example>
/// <code>
/// using var book = new VoicedText(text, new AppleSentenceVoice("com.apple.eloquence.en-US.Reed")) { Speed = 3 };
/// book.Configure(s => s.SetHeardPause(0.03f, 3));
/// // on the audio thread:
/// int frames = book.Read(buffer);                  // mono, book.SampleRate; never waits
/// // for the display:
/// int at = book.CharacterPosition;                 // index into the text
/// // from the next sentence on, another voice:
/// book.SetVoice(new AppleSentenceVoice("com.apple.eloquence.en-US.Flo"));
/// </code>
/// </example>
/// <remarks>
/// <para>
/// Sentences are spoken on the reader's own background thread, one at a time, until <see cref="Lookahead"/> seconds
/// of listening are ready (<see cref="KeptLookahead"/> for a slow voice). <see cref="Read"/> never waits: if the
/// next sentence is not spoken yet it returns what there is, and <see cref="IsWaiting"/> says so. A slow voice's
/// sentences are kept on disk in a <see cref="VoiceCache"/> when <see cref="VoicedTextOptions.CacheDirectory"/> is
/// given, and read from there next time. Everything is safe to call from any thread.
/// </para>
/// <para>
/// Two clocks: the frames <see cref="Read"/> returns, counted from the frame the last seek returned; and the
/// timeline, the text's characters at <see cref="SecondsPerCharacter"/> each, which is the same whatever the voice
/// and the speed. <see cref="TimeAt"/> maps the first to the second. Character positions are indices into the
/// string (UTF-16), as everywhere in .NET.
/// </para>
/// <para>
/// The reader owns its voices: it disposes each one when it is replaced and when the reader is disposed.
/// </para>
/// </remarks>
public sealed class VoicedText : IDisposable
{
    private readonly object _lock = new();
    private readonly AutoResetEvent _wake = new(false);
    private readonly Thread _worker;
    private readonly Func<string, ISentenceVoice>? _factory;
    private readonly string? _cacheDirectory;
    private readonly Func<bool>? _speakAheadToDisk;
    private readonly SpeechwarpStream? _stream;

    // Spoken sentences at SampleRate, by index; empty for one with nothing to say (or that failed).
    private readonly Dictionary<int, float[]> _ready = [];
    // Sentences of blocks not yet complete, to be kept once they are.
    private readonly Dictionary<int, float[]?[]> _building = [];
    // Where each sentence's audio sits in what has been read since the last seek (before any speed-up).
    private readonly List<(long InputStart, int Sentence, int Frames, int Total)> _segments = [];
    // Frames returned by Read, and the character there.
    private readonly List<(long Frame, double Character)> _marks = [];
    private readonly List<ISentenceVoice> _retired = [];

    private ISentenceVoice _voice;
    private string _voiceId;
    private VoiceCache? _cache;
    private string? _pendingId;
    private int _generation; // raised by a new voice: what was being spoken before it is not used
    private double _lookahead;
    private double _keptLookahead;
    private int _feeding; // the sentence being read (or written into the stream)
    private int _fed; // frames of it taken
    private long _input; // frames of speech taken since the last seek
    private long _frame; // frames returned, counted from the frame the last seek returned
    private bool _flushed;
    private bool _waiting;
    private Exception? _failure;
    private volatile bool _disposed;

    /// <summary>The text being read.</summary>
    public string Text { get; }

    /// <summary>The text cut into sentences (by <see cref="SpokenText.Split"/>).</summary>
    public IReadOnlyList<SpokenText.Sentence> Sentences { get; }

    /// <summary>The sample rate of what <see cref="Read"/> returns.</summary>
    public int SampleRate { get; }

    /// <summary>Channels of what <see cref="Read"/> returns: always 1.</summary>
    public int Channels => 1;

    /// <summary>The timeline's pace: seconds a character.</summary>
    public double SecondsPerCharacter { get; }

    /// <summary>The length of the timeline: every character at <see cref="SecondsPerCharacter"/>.</summary>
    public TimeSpan Duration => TimeSpan.FromSeconds(Text.Length * SecondsPerCharacter);

    /// <summary>Whether the audio goes through speechwarp (see <see cref="VoicedTextOptions.SpeedUp"/>).</summary>
    public bool SpeedsUp => _stream is not null;

    /// <summary>
    /// Reads <paramref name="text"/> with <paramref name="voice"/>, starting to speak the first sentences at once.
    /// </summary>
    public VoicedText(string text, ISentenceVoice voice, VoicedTextOptions? options = null)
        : this(text, voice ?? throw new ArgumentNullException(nameof(voice)), voice.Id, null, options)
    {
    }

    /// <summary>
    /// Reads <paramref name="text"/> with the voice <paramref name="voiceFactory"/> makes for
    /// <paramref name="voiceId"/> (made now, on this thread). <see cref="SetVoice(string)"/> makes later voices the
    /// same way, on the reader's thread.
    /// </summary>
    public VoicedText(string text, string voiceId, Func<string, ISentenceVoice> voiceFactory, VoicedTextOptions? options = null)
        : this(text, (voiceFactory ?? throw new ArgumentNullException(nameof(voiceFactory)))(voiceId), voiceId, voiceFactory, options)
    {
    }

    private VoicedText(string text, ISentenceVoice voice, string voiceId, Func<string, ISentenceVoice>? factory, VoicedTextOptions? options)
    {
        ArgumentNullException.ThrowIfNull(text);
        options ??= new VoicedTextOptions();
        if (options.SecondsPerCharacter <= 0)
            throw new ArgumentOutOfRangeException(nameof(options), "SecondsPerCharacter must be more than 0.");
        Text = text;
        Sentences = SpokenText.Split(text);
        _voice = voice;
        _voiceId = voiceId;
        _factory = factory;
        _cacheDirectory = options.CacheDirectory;
        _speakAheadToDisk = options.SpeakAheadToDisk;
        _lookahead = Math.Max(1, options.Lookahead);
        _keptLookahead = Math.Max(1, options.KeptLookahead);
        SecondsPerCharacter = options.SecondsPerCharacter;
        SampleRate = options.SampleRate ?? voice.SampleRate;
        if (SampleRate <= 0)
            throw new ArgumentOutOfRangeException(nameof(options), "The sample rate must be more than 0.");
        _stream = options.SpeedUp ? new SpeechwarpStream(SampleRate, 1) : null;
        _cache = CacheFor(voice);
        _marks.Add((0, 0));
        _worker = new Thread(Work) { IsBackground = true, Name = "Speechwarp.Voice reader", Priority = ThreadPriority.AboveNormal };
        _worker.Start();
    }

    /// <summary>The voice reading now (until one asked for by <see cref="SetVoice(string)"/> has been made).</summary>
    public ISentenceVoice Voice { get { lock (_lock) return _voice; } }

    /// <summary>
    /// The id of the voice reading, or of the voice asked for if it has not taken over yet: the id given to the
    /// factory for a voice it made, otherwise <see cref="ISentenceVoice.Id"/>.
    /// </summary>
    public string VoiceId { get { lock (_lock) return _pendingId ?? _voiceId; } }

    /// <summary>
    /// speechwarp's speed: 2 plays twice as fast as the voice speaks. Default 1.
    /// </summary>
    /// <exception cref="InvalidOperationException">Set when the reader does not speed up (<see cref="SpeedsUp"/>).</exception>
    public float Speed
    {
        get { lock (_lock) return _stream is null || _disposed ? 1 : _stream.Speed; }
        set
        {
            lock (_lock)
            {
                if (_stream is null)
                    throw new InvalidOperationException("This reader does not speed up (VoicedTextOptions.SpeedUp is false).");
                ObjectDisposedException.ThrowIf(_disposed, this);
                _stream.Speed = value;
            }
            _wake.Set();
        }
    }

    /// <summary>Seconds of listening to keep spoken ahead for a fast voice. At least 1.</summary>
    public double Lookahead
    {
        get { lock (_lock) return _lookahead; }
        set
        {
            lock (_lock) _lookahead = Math.Max(1, value);
            _wake.Set();
        }
    }

    /// <summary>Seconds of listening to keep spoken ahead for a slow voice (<see cref="ISentenceVoice.KeepsSpoken"/>). At least 1.</summary>
    public double KeptLookahead
    {
        get { lock (_lock) return _keptLookahead; }
        set
        {
            lock (_lock) _keptLookahead = Math.Max(1, value);
            _wake.Set();
        }
    }

    /// <summary>The index in the text of what <see cref="Read"/> has reached (approximate within a sentence).</summary>
    public int CharacterPosition { get { lock (_lock) return (int)Reached(); } }

    /// <summary>The place on the timeline of what <see cref="Read"/> has reached.</summary>
    public TimeSpan Position => TimeSpan.FromSeconds(CharacterPositionExact * SecondsPerCharacter);

    private double CharacterPositionExact { get { lock (_lock) return Reached(); } }

    /// <summary>The sentence <see cref="Read"/> has reached.</summary>
    public int SentenceIndex { get { lock (_lock) return SentenceAt((int)Reached()); } }

    /// <summary>The last <see cref="Read"/> returned less than asked because the next sentence was still being spoken.</summary>
    public bool IsWaiting { get { lock (_lock) return _waiting; } }

    /// <summary>The same as <see cref="IsWaiting"/>.</summary>
    public bool IsBuffering => IsWaiting;

    /// <summary>Everything has been read.</summary>
    public bool IsFinished
    {
        get
        {
            lock (_lock)
                return _stream is null ? _feeding >= Sentences.Count : _flushed && (_disposed || _stream.FramesAvailable == 0);
        }
    }

    /// <summary>The most recent failure to speak a sentence (which is then skipped) or to make a voice, if any.</summary>
    public Exception? LastError { get { lock (_lock) return _failure; } }

    /// <summary>
    /// Changes the speechwarp stream's other settings (nonlinear amount, heard pause, floor blend, rhythm ...) safely.
    /// Do not keep the stream.
    /// </summary>
    /// <exception cref="InvalidOperationException">The reader does not speed up (<see cref="SpeedsUp"/>).</exception>
    public void Configure(Action<SpeechwarpStream> change)
    {
        ArgumentNullException.ThrowIfNull(change);
        lock (_lock)
        {
            if (_stream is null)
                throw new InvalidOperationException("This reader does not speed up (VoicedTextOptions.SpeedUp is false).");
            ObjectDisposedException.ThrowIf(_disposed, this);
            change(_stream);
        }
        _wake.Set();
    }

    /// <summary>
    /// Carries on in the voice the factory makes for <paramref name="voiceId"/>. The voice is made on the reader's
    /// thread (it may take a while, a neural model say), so this returns at once; once it is made it reads from the
    /// next sentence not yet started. A failure to make it is reported in <see cref="LastError"/> and the old voice
    /// carries on.
    /// </summary>
    /// <exception cref="InvalidOperationException">The reader was made without a factory.</exception>
    public void SetVoice(string voiceId)
    {
        ArgumentNullException.ThrowIfNull(voiceId);
        if (_factory is null)
            throw new InvalidOperationException("This reader was made with a voice, not a factory: pass an ISentenceVoice.");
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _pendingId = voiceId;
        }
        _wake.Set();
    }

    /// <summary>
    /// Carries on in <paramref name="voice"/> from the next sentence not yet started (what is spoken in the old voice
    /// beyond that is dropped). The reader owns it from now on.
    /// </summary>
    public void SetVoice(ISentenceVoice voice)
    {
        ArgumentNullException.ThrowIfNull(voice);
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _pendingId = null; // this one wins over any still being made
            Install(voice, voice.Id);
        }
        _wake.Set();
    }

    /// <summary>
    /// Fills <paramref name="samples"/> with what to play next (mono); returns the frames written, fewer than asked
    /// when the next sentence is not spoken yet (<see cref="IsWaiting"/>) or at the end. Never waits.
    /// </summary>
    public int Read(Span<float> samples)
    {
        int frames;
        bool advanced;
        lock (_lock)
        {
            if (_disposed)
                return 0;
            var before = _feeding;
            if (_stream is not null)
            {
                Feed(samples.Length);
                frames = _stream.Read(samples);
                _waiting = frames < samples.Length && !_flushed;
            }
            else
            {
                frames = Copy(samples);
                _waiting = frames < samples.Length && _feeding < Sentences.Count;
            }
            advanced = _feeding != before;
            if (frames > 0)
            {
                _frame += frames;
                _marks.Add((_frame, Reached()));
                if (_marks.Count > 4000)
                    _marks.RemoveRange(0, 2000);
            }
        }
        if (advanced || frames < samples.Length)
            _wake.Set();
        return frames;
    }

    /// <summary>
    /// Continues from the start of the sentence containing character <paramref name="character"/>; returns the frame
    /// that start has on the timeline (its time × <see cref="SampleRate"/>), from which later frames are counted.
    /// </summary>
    public long Seek(int character)
    {
        long frame;
        lock (_lock)
        {
            character = Math.Clamp(character, 0, Text.Length);
            _feeding = SentenceAt(character);
            _fed = 0;
            if (!_disposed)
                _stream?.Reset();
            _flushed = false;
            _segments.Clear();
            _input = 0;
            var start = _feeding < Sentences.Count ? Sentences[_feeding].Start : Text.Length;
            _frame = frame = (long)Math.Round(start * SecondsPerCharacter * SampleRate);
            _marks.Clear();
            _marks.Add((_frame, start));
            // What is spoken from here on still serves; behind it does not.
            foreach (var behind in _ready.Keys.Where(k => k < _feeding).ToList())
                _ready.Remove(behind);
            _waiting = false;
        }
        _wake.Set();
        return frame;
    }

    /// <summary>Continues from the start of the sentence at <paramref name="time"/> on the timeline; returns its frame (see <see cref="Seek(int)"/>).</summary>
    public long Seek(TimeSpan time) => Seek((int)Math.Clamp(time.TotalSeconds / SecondsPerCharacter, 0, Text.Length));

    /// <summary>
    /// The place on the timeline of frame <paramref name="frame"/> of what <see cref="Read"/> returned, counted from
    /// the frame the last seek returned (0 before any). Recent frames only: it remembers the last few thousand reads.
    /// </summary>
    public TimeSpan TimeAt(long frame) => TimeSpan.FromSeconds(CharacterAt(frame) * SecondsPerCharacter);

    /// <summary>The character of the text at frame <paramref name="frame"/> (see <see cref="TimeAt"/>), fractional within a sentence.</summary>
    public double CharacterAt(long frame)
    {
        lock (_lock)
        {
            var i = _marks.FindLastIndex(m => m.Frame <= frame);
            if (i < 0)
                return _marks[0].Character;
            var (from, character) = _marks[i];
            if (i + 1 < _marks.Count && _marks[i + 1].Frame > from)
                character += (_marks[i + 1].Character - character) * (frame - from) / (_marks[i + 1].Frame - from);
            return character;
        }
    }

    // Reading (with the lock held).

    /// <summary>Writes spoken sentences into the stream until it has <paramref name="wanted"/> frames or the next is not spoken.</summary>
    private void Feed(int wanted)
    {
        var stream = _stream!;
        while (stream.FramesAvailable < wanted && !_flushed)
        {
            if (_feeding >= Sentences.Count)
            {
                stream.Flush();
                _flushed = true;
                return;
            }
            if (!_ready.TryGetValue(_feeding, out var audio))
                return; // not spoken yet
            var take = Math.Min(4096, audio.Length - _fed);
            if (take > 0)
            {
                stream.Write(audio.AsSpan(_fed, take));
                Taken(audio, take);
            }
            if (_fed >= audio.Length)
                Advance();
        }
    }

    /// <summary>Copies spoken sentences straight into <paramref name="samples"/>, for a reader that does not speed up.</summary>
    private int Copy(Span<float> samples)
    {
        var written = 0;
        while (written < samples.Length && _feeding < Sentences.Count && _ready.TryGetValue(_feeding, out var audio))
        {
            var take = Math.Min(samples.Length - written, audio.Length - _fed);
            if (take > 0)
            {
                audio.AsSpan(_fed, take).CopyTo(samples[written..]);
                written += take;
                Taken(audio, take);
            }
            if (_fed >= audio.Length)
                Advance();
        }
        return written;
    }

    private void Taken(float[] audio, int take)
    {
        if (_segments.Count > 0 && _segments[^1].Sentence == _feeding)
            _segments[^1] = _segments[^1] with { Frames = _segments[^1].Frames + take };
        else
            _segments.Add((_input, _feeding, take, audio.Length));
        _input += take;
        _fed += take;
        // Segments wholly behind what is heard are no longer needed.
        if (_segments.Count > 64)
        {
            var heard = Heard();
            var keep = _segments.FindLastIndex(s => s.InputStart <= heard);
            if (keep > 0)
                _segments.RemoveRange(0, keep);
        }
    }

    private void Advance()
    {
        _feeding++;
        _fed = 0;
        // A little is kept behind for short seeks.
        foreach (var old in _ready.Keys.Where(k => k < _feeding - 2).ToList())
            _ready.Remove(old);
    }

    /// <summary>Frames of speech (before any speed-up) heard since the last seek.</summary>
    private long Heard() => _stream is null ? _input : _disposed ? 0 : _stream.Position;

    /// <summary>The character reached, fractional within a sentence.</summary>
    private double Reached()
    {
        var heard = Heard();
        var index = _segments.FindLastIndex(s => s.InputStart <= heard);
        if (index < 0)
            return _feeding < Sentences.Count ? Sentences[_feeding].Start : Text.Length;
        var segment = _segments[index];
        var sentence = Sentences[segment.Sentence];
        var into = Math.Clamp((double)(heard - segment.InputStart) / Math.Max(1, segment.Total), 0, 1);
        return sentence.Start + into * sentence.Length;
    }

    private int SentenceAt(int character)
    {
        for (var i = Sentences.Count - 1; i >= 0; i--)
            if (Sentences[i].Start <= character)
                return i;
        return 0;
    }

    // Speaking ahead, on the reader's thread.

    private void Work()
    {
        while (!_disposed)
        {
            try
            {
                if (TakePendingVoice())
                    continue;
                DisposeRetired();
                if (!SpeakNext())
                    _wake.WaitOne(500);
            }
            catch (Exception e)
            {
                lock (_lock) _failure = e;
                _wake.WaitOne(500);
            }
        }
        // Disposed: the voices are let go here, where nothing can be speaking with them.
        List<ISentenceVoice> voices;
        lock (_lock)
        {
            voices = [.. _retired, _voice];
            _retired.Clear();
        }
        foreach (var voice in voices.Distinct())
            DisposeQuietly(voice);
        // The event is left to the finaliser: callers may still set it after this.
    }

    /// <summary>Makes the voice asked for by id and puts it in place. False when none was asked for.</summary>
    private bool TakePendingVoice()
    {
        string? id;
        lock (_lock)
        {
            id = _pendingId;
            if (id is null)
                return false;
        }
        ISentenceVoice next;
        try
        {
            next = _factory!(id);
        }
        catch (Exception e)
        {
            lock (_lock)
            {
                _failure = e;
                if (_pendingId == id)
                    _pendingId = null; // carry on in the old voice
            }
            return true;
        }
        lock (_lock)
        {
            if (_pendingId != id)
            {
                _retired.Add(next); // another voice was asked for meanwhile; that one wins
                return true;
            }
            _pendingId = null;
            Install(next, id);
        }
        return true;
    }

    /// <summary>Puts <paramref name="next"/> in place from the next sentence not yet started (with the lock held).</summary>
    private void Install(ISentenceVoice next, string id)
    {
        if (!ReferenceEquals(next, _voice))
            _retired.Add(_voice);
        _voice = next;
        _voiceId = id;
        _cache = CacheFor(next);
        _building.Clear();
        _generation++;
        foreach (var later in _ready.Keys.Where(k => k > _feeding || (k == _feeding && _fed == 0)).ToList())
            _ready.Remove(later);
    }

    /// <summary>Speaks (or loads from the cache) the next sentence missing within the lookahead. False when none is.</summary>
    private bool SpeakNext()
    {
        int index, generation;
        ISentenceVoice speaker;
        VoiceCache? cache;
        lock (_lock)
        {
            generation = _generation;
            speaker = _voice;
            cache = _cache;
            index = NextMissing(speaker.KeepsSpoken ? _keptLookahead : _lookahead);
        }
        if (index < 0)
            return cache is not null && _speakAheadToDisk is { } ask && ask() && SpeakAheadToDisk(speaker, cache, generation);

        var block = VoiceCache.BlockOf(index);
        if (cache?.Load(block, SampleRate) is { } kept)
        {
            lock (_lock)
            {
                if (generation != _generation)
                    return true;
                for (var i = 0; i < kept.Length; i++)
                {
                    var sentence = block * VoiceCache.BlockSize + i;
                    if (sentence >= _feeding && sentence < Sentences.Count)
                        _ready.TryAdd(sentence, kept[i]);
                }
                // A seek past it while it loaded leaves it unneeded, not short.
                if (_ready.ContainsKey(index) || index < _feeding)
                    return true;
            }
            cache.Remove(block); // shorter than it should be: speak it again
        }

        var spoken = Speak(speaker, index);
        lock (_lock)
        {
            if (generation != _generation)
                return true;
            if (index >= _feeding)
                _ready[index] = spoken ?? [];
        }
        if (cache is not null)
            Build(cache, index, spoken, generation);
        return true;
    }

    /// <summary>The first sentence from the one being read that is not spoken, within <paramref name="lookahead"/> s; -1 for none.</summary>
    private int NextMissing(double lookahead)
    {
        var speed = Math.Max(_stream is null || _disposed ? 1 : _stream.Speed, 0.05);
        var ahead = 0.0;
        for (var i = _feeding; i < Sentences.Count && ahead < lookahead; i++)
        {
            if (!_ready.TryGetValue(i, out var audio))
                return i;
            ahead += (audio.Length - (i == _feeding ? _fed : 0)) / (double)SampleRate / speed;
        }
        return -1;
    }

    /// <summary>The sentence spoken and converted to <see cref="SampleRate"/>; null if the voice failed.</summary>
    private float[]? Speak(ISentenceVoice speaker, int index)
    {
        try
        {
            var samples = speaker.Speak(Sentences[index].Text) ?? [];
            return speaker.SampleRate == SampleRate ? samples : AudioResampling.Linear(samples, speaker.SampleRate, SampleRate);
        }
        catch (Exception e)
        {
            lock (_lock) _failure = e;
            return null;
        }
    }

    /// <summary>Adds a sentence to its block, and keeps the block once every sentence of it is spoken.</summary>
    private void Build(VoiceCache cache, int index, float[]? spoken, int generation)
    {
        var block = VoiceCache.BlockOf(index);
        float[][]? complete = null;
        lock (_lock)
        {
            if (generation != _generation)
                return;
            if (spoken is null)
            {
                _building.Remove(block); // a failure is not kept: the block is spoken again another time
                return;
            }
            if (!_building.TryGetValue(block, out var parts))
                _building[block] = parts = new float[]?[Math.Min(VoiceCache.BlockSize, Sentences.Count - block * VoiceCache.BlockSize)];
            parts[index % VoiceCache.BlockSize] = spoken;
            if (parts.All(p => p is not null))
            {
                complete = parts!;
                _building.Remove(block);
            }
            // Blocks left part-spoken by a seek are let go.
            foreach (var stale in _building.Keys.Where(k => k < VoiceCache.BlockOf(_feeding)).ToList())
                _building.Remove(stale);
        }
        if (complete is not null)
            Keep(cache, block, complete);
    }

    /// <summary>
    /// The first block from the one being read that is not on disk, completed (with what is already spoken of it)
    /// and kept. False when there is none.
    /// </summary>
    private bool SpeakAheadToDisk(ISentenceVoice speaker, VoiceCache cache, int generation)
    {
        var blocks = VoiceCache.BlockCount(Sentences.Count);
        int first;
        lock (_lock)
            first = VoiceCache.BlockOf(_feeding);
        var block = Enumerable.Range(first, Math.Max(0, blocks - first)).FirstOrDefault(b => !cache.Has(b), -1);
        if (block < 0)
            return false;
        var start = block * VoiceCache.BlockSize;
        var parts = new float[]?[Math.Min(VoiceCache.BlockSize, Sentences.Count - start)];
        for (var i = 0; i < parts.Length; i++)
        {
            lock (_lock)
            {
                // Back to the sentences being read as soon as they are wanted.
                if (_disposed || generation != _generation || _pendingId is not null
                    || NextMissing((speaker.KeepsSpoken ? _keptLookahead : _lookahead) / 2) >= 0)
                    return true;
                if (_building.TryGetValue(block, out var built) && built[i] is { } done)
                    parts[i] = done;
            }
            if (parts[i] is null && (parts[i] = Speak(speaker, start + i)) is null)
                return true;
        }
        lock (_lock)
        {
            if (generation != _generation)
                return true;
            _building.Remove(block);
        }
        Keep(cache, block, parts!);
        return true;
    }

    private void Keep(VoiceCache cache, int block, IReadOnlyList<float[]> sentences)
    {
        try
        {
            cache.Save(block, sentences, SampleRate);
        }
        catch (Exception e)
        {
            lock (_lock) _failure = e;
        }
    }

    private VoiceCache? CacheFor(ISentenceVoice voice) =>
        voice.KeepsSpoken && _cacheDirectory is not null ? new VoiceCache(Text, voice.Id, _cacheDirectory) : null;

    private void DisposeRetired()
    {
        List<ISentenceVoice> retired;
        lock (_lock)
        {
            if (_retired.Count == 0)
                return;
            retired = [.. _retired.Where(v => !ReferenceEquals(v, _voice))];
            _retired.Clear();
        }
        foreach (var voice in retired)
            DisposeQuietly(voice);
    }

    private void DisposeQuietly(ISentenceVoice voice)
    {
        try
        {
            voice.Dispose();
        }
        catch (Exception e)
        {
            lock (_lock) _failure = e;
        }
    }

    /// <summary>
    /// Stops speaking and releases the stream. The voices are disposed on the reader's thread once it has finished
    /// the sentence it is speaking, so this never waits.
    /// </summary>
    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed)
                return;
            _disposed = true;
            _stream?.Dispose();
        }
        _wake.Set();
    }
}
