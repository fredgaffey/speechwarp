using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AudioToolbox;
using AVFoundation;
using Foundation;

namespace Speechwarp.Voice;

/// <summary>
/// Sentences a slow voice (one whose <see cref="ISentenceVoice.KeepsSpoken"/> is true, such as Kokoro) has already
/// spoken, kept on disk so that they need not be spoken again.
/// </summary>
/// <remarks>
/// <para>
/// The sentences of a text (as <see cref="SpokenText.Split"/> cuts it) are kept in blocks of
/// <see cref="BlockSize"/>: each block is an AAC file (32 kbit/s, mono, at the voice's rate) with the length of
/// each sentence in a small JSON file beside it, which is written last, so a block is there only once both are.
/// About 150 MB for a ten-hour book.
/// </para>
/// <para>
/// Each text and voice has a folder of its own: <c>directory/TEXT/VOICE/</c>, where TEXT is the first 16 hex digits
/// of the SHA-256 of the text (UTF-8) and VOICE is the voice id with characters a file name cannot hold replaced
/// by '-'. The default directory, <see cref="DefaultDirectory"/>, is under Library/Caches, which iOS may clear when
/// space runs short; a block that has gone, or cannot be read, is simply spoken again.
/// </para>
/// <para>
/// Safe to use from several threads and processes at once, as far as the file system is: a block is written to a
/// temporary file and moved into place.
/// </para>
/// </remarks>
public sealed class VoiceCache
{
    /// <summary>Sentences in a block.</summary>
    public const int BlockSize = 40;

    private const int BitRate = 32000;

    /// <summary>The folder kept for this text and voice.</summary>
    public string Directory { get; }

    /// <summary>The voice id the sentences are kept for.</summary>
    public string VoiceId { get; }

    /// <summary>Library/Caches/speechwarp-voice, the default place for every text and voice.</summary>
    public static string DefaultDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.InternetCache), "speechwarp-voice");

    /// <summary>
    /// The cache of <paramref name="text"/> spoken by the voice <paramref name="voiceId"/>, under
    /// <paramref name="directory"/> (default <see cref="DefaultDirectory"/>). Nothing is created until a block is
    /// saved.
    /// </summary>
    public VoiceCache(string text, string voiceId, string? directory = null)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentException.ThrowIfNullOrEmpty(voiceId);
        VoiceId = voiceId;
        Directory = Path.Combine(directory ?? DefaultDirectory, TextKey(text), FileName(voiceId));
    }

    /// <summary>The folder name for a text: the first 16 hex digits of its SHA-256.</summary>
    public static string TextKey(string text) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)))[..16].ToLowerInvariant();

    /// <summary>The block holding sentence <paramref name="sentence"/>.</summary>
    public static int BlockOf(int sentence) => sentence / BlockSize;

    /// <summary>The number of blocks for <paramref name="sentences"/> sentences.</summary>
    public static int BlockCount(int sentences) => (sentences + BlockSize - 1) / BlockSize;

    private string AudioPath(int block) => Path.Combine(Directory, block.ToString("00000", CultureInfo.InvariantCulture) + ".m4a");
    private string LengthsPath(int block) => Path.Combine(Directory, block.ToString("00000", CultureInfo.InvariantCulture) + ".json");

    /// <summary>Whether block <paramref name="block"/> is kept.</summary>
    public bool Has(int block) => File.Exists(LengthsPath(block)) && File.Exists(AudioPath(block));

    /// <summary>
    /// Block <paramref name="block"/>'s sentences, converted to <paramref name="sampleRate"/>; null if it is not kept
    /// or cannot be read (then it is deleted, to be spoken again).
    /// </summary>
    public float[][]? Load(int block, int sampleRate)
    {
        if (!Has(block))
            return null;
        try
        {
            var lengths = ParseLengths(File.ReadAllText(LengthsPath(block)));
            using var file = new AVAudioFile(NSUrl.FromFilename(AudioPath(block)), AVAudioCommonFormat.PCMFloat32, false, out var error);
            if (error is not null)
                throw new IOException(error.LocalizedDescription);
            var rate = (int)file.ProcessingFormat.SampleRate;
            var total = (uint)Math.Max(1, file.Length);
            using var buffer = new AVAudioPcmBuffer(file.ProcessingFormat, total);
            file.ReadIntoBuffer(buffer, out error);
            if (error is not null)
                throw new IOException(error.LocalizedDescription);
            var all = AudioSamples.Mono(buffer);
            var sentences = new float[lengths.Length][];
            var at = 0;
            for (var i = 0; i < lengths.Length; i++)
            {
                var take = Math.Clamp(lengths[i], 0, all.Length - at);
                sentences[i] = AudioResampling.Linear(all.AsSpan(at, take), rate, sampleRate);
                at += take;
            }
            return sentences;
        }
        catch (Exception)
        {
            Remove(block);
            return null;
        }
    }

    /// <summary>
    /// Keeps block <paramref name="block"/>'s sentences, spoken at <paramref name="sampleRate"/> (one array for each
    /// sentence of the block, empty for one with nothing to say).
    /// </summary>
    /// <exception cref="IOException">The block could not be written.</exception>
    public void Save(int block, IReadOnlyList<float[]> sentences, int sampleRate)
    {
        ArgumentNullException.ThrowIfNull(sentences);
        System.IO.Directory.CreateDirectory(Directory);
        var temp = AudioPath(block) + "." + Guid.NewGuid().ToString("N") + ".part.m4a";
        try
        {
            var settings = new AudioSettings
            {
                Format = AudioFormatType.MPEG4AAC,
                SampleRate = sampleRate,
                NumberChannels = 1,
                EncoderBitRate = BitRate,
            };
            using (var file = new AVAudioFile(NSUrl.FromFilename(temp), settings, AVAudioCommonFormat.PCMFloat32, false, out var error))
            {
                if (error is not null)
                    throw new IOException(error.LocalizedDescription);
                var total = sentences.Sum(s => s.Length);
                if (total > 0)
                {
                    var all = new float[total];
                    var at = 0;
                    foreach (var sentence in sentences)
                    {
                        sentence.CopyTo(all, at);
                        at += sentence.Length;
                    }
                    using var buffer = AudioSamples.Buffer(all, file.ProcessingFormat)!;
                    file.WriteFromBuffer(buffer, out error);
                    if (error is not null)
                        throw new IOException(error.LocalizedDescription);
                }
            }
            File.Move(temp, AudioPath(block), overwrite: true);
            File.WriteAllText(LengthsPath(block), "[" + string.Join(",", sentences.Select(s => s.Length.ToString(CultureInfo.InvariantCulture))) + "]");
        }
        finally
        {
            if (File.Exists(temp))
                File.Delete(temp);
        }
    }

    /// <summary>Forgets block <paramref name="block"/>.</summary>
    public void Remove(int block)
    {
        try
        {
            File.Delete(LengthsPath(block));
            File.Delete(AudioPath(block));
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    /// <summary>Forgets every block of this text in this voice.</summary>
    public void Clear()
    {
        if (System.IO.Directory.Exists(Directory))
            System.IO.Directory.Delete(Directory, recursive: true);
    }

    private static int[] ParseLengths(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.EnumerateArray().Select(e => e.GetInt32()).ToArray();
    }

    /// <summary>A voice id as a folder name: letters, digits, '.', '_' and '-' kept, anything else '-' (and a leading '.').</summary>
    private static string FileName(string voiceId)
    {
        var name = new StringBuilder(voiceId.Length);
        foreach (var c in voiceId)
            name.Append(char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-' ? c : '-');
        if (name[0] == '.')
            name[0] = '-'; // never "." or "..", nor hidden
        return name.ToString();
    }
}
