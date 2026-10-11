using System;
using System.Diagnostics;
using System.Linq;

namespace Speechwarp.Voice.Kokoro.Bench;

/// <summary>
/// Phonemes from the espeak-ng command (Homebrew's, a Linux package's), for trying Kokoro on a desktop. Apps use
/// Speechwarp.Voice.Espeak's EspeakPhonemizer instead, which links eSpeak NG in; this starts a process per call.
/// </summary>
public sealed class EspeakCommandPhonemizer(string command = "espeak-ng") : IPhonemizer
{
    /// <summary>The command can be run.</summary>
    public static bool IsAvailable(string command = "espeak-ng")
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(command, "--version")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            });
            process?.WaitForExit();
            return process?.ExitCode == 0;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    /// <inheritdoc />
    public string Phonemize(string text, string language)
    {
        var start = new ProcessStartInfo(command)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardInputEncoding = new System.Text.UTF8Encoding(false),
        };
        foreach (var argument in new[] { "-q", "--ipa", "-b", "1", "-v", language })
            start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException($"{command} did not start.");
        process.StandardInput.Write(text);
        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"{command} failed: {process.StandardError.ReadToEnd()}");
        // A line a clause, as the library's clause-by-clause phonemes are joined.
        return string.Join(' ', output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
    }
}
