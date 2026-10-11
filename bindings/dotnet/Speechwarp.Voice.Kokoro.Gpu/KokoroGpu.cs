using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Foundation;
using ObjCRuntime;
using Speechwarp.Voice.Kokoro;
using UIKit;

namespace Speechwarp.Voice.Kokoro.Gpu;

/// <summary>The GPU cannot be used just now (the app is not on screen, or the GPU stopped answering): use the CPU.</summary>
public sealed class GpuUnavailableException : Exception
{
    /// <summary>The GPU cannot be used just now.</summary>
    public GpuUnavailableException() : base("Kokoro cannot use the GPU just now.") { }

    /// <summary>The GPU cannot be used just now, for the reason in <paramref name="message"/>.</summary>
    public GpuUnavailableException(string message) : base(message) { }

    /// <summary>The GPU cannot be used just now, because of <paramref name="inner"/>.</summary>
    public GpuUnavailableException(string message, Exception inner) : base(message, inner) { }
}

/// <summary>
/// Kokoro-82M on the iPhone's GPU through Apple's MLX (mlalma/kokoro-ios), with misaki's English pronunciations: faster
/// than ONNX Runtime on the CPU (its author measured about 3.3x real time on an iPhone 13 Pro, against 2.2x). One model
/// for the whole app; calls are serialised. Most apps use it through <see cref="KokoroGpuAccelerator"/>.
/// </summary>
/// <remarks>
/// <para>
/// It runs only where all of these hold, which <see cref="IsAvailable"/> checks: a real device (not the simulator) on
/// iOS 18 or later; an app built for devices with this package (its framework, SpeechwarpKokoroGPU, is embedded only in
/// ios-arm64 builds); the model <see cref="ModelFileName"/> downloaded into the model directory, beside the voices the
/// CPU engine uses (voices/NAME.bin); the app on screen; and, until it has been shown to work on phones, a file named
/// <see cref="OptInFileName"/> in the model directory. Without that file nothing here touches the GPU.
/// </para>
/// <para>
/// The app must be on screen because iOS refuses GPU work from an app in the background, and MLX ends the process when
/// refused. Call <see cref="WatchAppState"/> once at launch: from then on no sentence starts while the app is not
/// active, and when the app is about to leave the screen the main thread waits (up to <see cref="ResignWait"/>) for
/// the sentence under way to finish.
/// </para>
/// <para>
/// Only English: misaki makes American and British English phonemes. Voices of other languages stay on the CPU.
/// </para>
/// </remarks>
public static unsafe class KokoroGpu
{
    /// <summary>The model's file name in the model directory: "kokoro-v1_0.safetensors".</summary>
    public const string ModelFileName = "kokoro-v1_0.safetensors";

    /// <summary>
    /// The opt-in file's name, "use-gpu": the GPU is used only while a file of this name is in the model directory.
    /// Its contents do not matter.
    /// </summary>
    public const string OptInFileName = "use-gpu";

    /// <summary>The embedded framework that holds MLX and Kokoro: "SpeechwarpKokoroGPU".</summary>
    public const string FrameworkName = "SpeechwarpKokoroGPU";

    /// <summary>Frames a second of what <see cref="Speak"/> returns: 24,000, mono.</summary>
    public const int SampleRate = 24000;

    /// <summary>The Hugging Face repository the model comes from (Kokoro-82M v1.0 converted for MLX, Apache-2.0).</summary>
    public const string Repository = "prince-canuma/Kokoro-82M";

    /// <summary>The repository's revision <see cref="Model"/> is pinned to.</summary>
    public const string Revision = "e02c9eada7ce7416798af36b190a8a2dd2ecd566";

    /// <summary>
    /// Where to download the model (327 MB, float32 weights for MLX) and its SHA-256. The same file is in
    /// mlx-community/Kokoro-82M-bf16 and in mlalma/KokoroTestApp. This package never uses the network.
    /// </summary>
    public static KokoroFile Model { get; } = new(ModelFileName, 327_115_152,
        "https://huggingface.co/" + Repository + "/resolve/" + Revision + "/" + ModelFileName,
        "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8");

    /// <summary>The model's path in <paramref name="directory"/>.</summary>
    public static string ModelPath(string directory)
    {
        ArgumentNullException.ThrowIfNull(directory);
        return Path.Combine(directory, ModelFileName);
    }

    /// <summary>The opt-in file's path in <paramref name="directory"/>.</summary>
    public static string OptInPath(string directory)
    {
        ArgumentNullException.ThrowIfNull(directory);
        return Path.Combine(directory, OptInFileName);
    }

    /// <summary>
    /// How long a sentence may take before the GPU is given up on for the rest of the run (the call returns, the CPU
    /// takes over, and the stuck native call is left behind). The first sentence also loads the model. Default 90 s.
    /// </summary>
    public static TimeSpan Timeout { get; set; } = TimeSpan.FromSeconds(90);

    /// <summary>
    /// How long the main thread waits, when the app is about to leave the screen, for the sentence under way to
    /// finish. iOS ends an app whose main thread is stuck for much longer. Default 8 s.
    /// </summary>
    public static TimeSpan ResignWait { get; set; } = TimeSpan.FromSeconds(8);

    /// <summary>
    /// Receives one line of diagnostics for each event: the model loaded and how long it took, each sentence's time and
    /// audio length, failures. Null (the default) for none. Called on the thread that spoke.
    /// </summary>
    public static Action<string>? Log { get; set; }

    // Looked up when first used, rather than imported, so that builds without the framework (the simulator's) still
    // link and run.
    private static delegate* unmanaged<byte*, byte*, int, IntPtr> _open;
    private static delegate* unmanaged<IntPtr, byte*, byte*, int, float, float**, int*, byte*, int, int> _speak;
    private static delegate* unmanaged<float*, void> _free;
    private static delegate* unmanaged<IntPtr, void> _close;

    private const int MessageCapacity = 1024;

    // Serialises use of the model: one sentence at a time, the worker thread only.
    private static readonly object _gate = new();
    private static IntPtr _engine;
    private static string? _engineModel;

    private static volatile bool _active;
    private static volatile bool _hung;
    private static readonly ManualResetEventSlim _idle = new(true);
    // Kept so the observers live as long as the app.
    private static NSObject[]? _observers;

    /// <summary>
    /// Follows whether the app is on screen; until it is called, <see cref="IsAppActive"/> is false and the GPU is
    /// never used. Call once, at launch, on the main thread.
    /// </summary>
    public static void WatchAppState()
    {
        if (!NSThread.IsMain)
            throw new InvalidOperationException("Call KokoroGpu.WatchAppState on the main thread.");
        if (_observers is not null)
            return;
        _active = UIApplication.SharedApplication.ApplicationState == UIApplicationState.Active;
        _observers =
        [
            UIApplication.Notifications.ObserveDidBecomeActive((_, _) => _active = true),
            // Leaving the screen: no new GPU work, and the sentence under way finishes before the app goes, unless the
            // GPU has stopped answering, when waiting would only freeze the app.
            UIApplication.Notifications.ObserveWillResignActive((_, _) =>
            {
                _active = false;
                // Pairs with the barrier in SpeakNow: either that sees the app inactive, or this sees it busy.
                Interlocked.MemoryBarrier();
                if (!_hung)
                    _idle.Wait(ResignWait);
            }),
            UIApplication.Notifications.ObserveDidEnterBackground((_, _) => _active = false),
        ];
    }

    /// <summary>The app is on screen, as far as <see cref="WatchAppState"/> knows (false until it is called).</summary>
    public static bool IsAppActive => _active;

    /// <summary>A sentence on the GPU took longer than <see cref="Timeout"/>; the GPU is not used again this run.</summary>
    public static bool HasStopped => _hung;

    /// <summary>
    /// The GPU path is in this app on this device: a real device on iOS 18 or later, with the framework and MLX's
    /// shaders embedded (device builds that reference this package).
    /// </summary>
    public static bool IsIncluded =>
        Runtime.Arch == Arch.DEVICE && OperatingSystem.IsIOSVersionAtLeast(18)
        && NSBundle.MainBundle.PathForResource("mlx-swift_Cmlx", "bundle") is not null
        && File.Exists(FrameworkBinary);

    /// <summary>
    /// The GPU can speak now: <see cref="IsIncluded"/>, the app on screen, the GPU not stopped, and in
    /// <paramref name="directory"/> both the model and the opt-in file.
    /// </summary>
    public static bool IsAvailable(string directory)
    {
        ArgumentNullException.ThrowIfNull(directory);
        return _active && !_hung && File.Exists(OptInPath(directory)) && IsIncluded && File.Exists(ModelPath(directory));
    }

    private static string FrameworkBinary =>
        Path.Combine(NSBundle.MainBundle.PrivateFrameworksPath ?? "", FrameworkName + ".framework", FrameworkName);

    /// <summary>
    /// Speaks <paramref name="text"/> in the voice whose style file is <paramref name="voiceFile"/> (voices/NAME.bin),
    /// with the model in <paramref name="directory"/>. Waits for any sentence already under way. Does not check the
    /// opt-in file or the model; <see cref="IsAvailable"/> does.
    /// </summary>
    /// <param name="directory">The model directory, holding <see cref="ModelFileName"/>.</param>
    /// <param name="voiceFile">The voice's style file: 510 x 256 float32, as ONNX Runtime uses.</param>
    /// <param name="text">A sentence or a few; text too long for the model at once is spoken in parts.</param>
    /// <param name="british">British English pronunciations (voices whose names start with b); otherwise American.</param>
    /// <param name="speed">1 for the voice's own pace.</param>
    /// <returns>Mono samples at 24 kHz, -1 to 1.</returns>
    /// <exception cref="GpuUnavailableException">
    /// The app is not on screen (or <see cref="WatchAppState"/> was never called), the GPU path is not in this app, or the
    /// GPU stopped answering: speak on the CPU instead.
    /// </exception>
    /// <exception cref="InvalidOperationException">The model could not be loaded, or the text not spoken.</exception>
    public static float[] Speak(string directory, string voiceFile, string text, bool british, float speed = 1)
    {
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(voiceFile);
        ArgumentNullException.ThrowIfNull(text);
        if (!_active)
            throw new GpuUnavailableException("The app is not on screen, and iOS refuses the GPU to apps in the background.");
        if (_hung)
            throw new GpuUnavailableException("The GPU stopped answering earlier in this run.");
        if (!IsIncluded)
            throw new GpuUnavailableException("The GPU path is not in this app or not on this device.");
        if (text.Trim().Length == 0)
            return [];

        // The native call runs on a thread of its own with a large stack, so that a call that never returns (as was
        // once seen on a phone and is not understood) costs that thread, not the caller: after Timeout the CPU takes
        // over. Only one runs at a time.
        float[]? result = null;
        Exception? failure = null;
        var done = new ManualResetEventSlim(false);
        var thread = new Thread(() =>
        {
            try
            {
                result = SpeakNow(directory, voiceFile, text, british, speed);
            }
            catch (Exception ex)
            {
                failure = ex;
            }
            finally
            {
                done.Set();
            }
        }, 16 * 1024 * 1024)
        { IsBackground = true, Name = "Kokoro GPU" };
        thread.Start();
        if (!done.Wait(Timeout))
        {
            _hung = true;
            Log?.Invoke($"Kokoro GPU: no answer after {Timeout.TotalSeconds:0} s; using the CPU for the rest of this run");
            throw new GpuUnavailableException("The GPU did not answer in time.");
        }
        if (failure is not null)
            throw failure is GpuUnavailableException or InvalidOperationException ? failure
                : new InvalidOperationException("Kokoro on the GPU failed.", failure);
        return result!;
    }

    private static float[] SpeakNow(string directory, string voiceFile, string text, bool british, float speed)
    {
        lock (_gate)
        {
            // Busy first, then check the app is still on screen, so that the main thread, about to leave the screen,
            // either stops this sentence starting or waits for it.
            _idle.Reset();
            Interlocked.MemoryBarrier();
            try
            {
                if (!_active)
                    throw new GpuUnavailableException("The app left the screen.");
                Bind();
                var model = ModelPath(directory);
                var message = stackalloc byte[MessageCapacity];
                message[0] = 0;
                if (_engine == IntPtr.Zero || _engineModel != model)
                {
                    CloseEngine();
                    var opening = Stopwatch.StartNew();
                    fixed (byte* path = Utf8(model))
                        _engine = _open(path, message, MessageCapacity);
                    if (_engine == IntPtr.Zero)
                        throw new InvalidOperationException(Message(message, "Kokoro's GPU model could not be loaded."));
                    _engineModel = model;
                    Log?.Invoke($"Kokoro GPU: model loaded in {opening.ElapsedMilliseconds} ms");
                }
                float* samples = null;
                int count = 0;
                var speaking = Stopwatch.StartNew();
                int status;
                fixed (byte* voice = Utf8(voiceFile))
                fixed (byte* words = Utf8(text))
                    status = _speak(_engine, voice, words, british ? 1 : 0, speed, &samples, &count, message, MessageCapacity);
                if (status != 0)
                    throw new InvalidOperationException(Message(message, "Kokoro on the GPU could not speak that."));
                try
                {
                    Log?.Invoke($"Kokoro GPU: {text.Length} characters, {count / (double)SampleRate:0.0} s of audio in {speaking.ElapsedMilliseconds} ms");
                    return new ReadOnlySpan<float>(samples, count).ToArray();
                }
                finally
                {
                    _free(samples);
                }
            }
            catch (Exception ex) when (ex is not GpuUnavailableException)
            {
                Log?.Invoke($"Kokoro GPU: {ex.Message}");
                throw;
            }
            finally
            {
                _idle.Set();
            }
        }
    }

    /// <summary>
    /// Frees the model and MLX's cached GPU memory (about 330 MB and more); the next sentence loads it again. Waits for
    /// a sentence under way. Does nothing once the GPU has stopped answering.
    /// </summary>
    public static void Close()
    {
        if (_hung)
            return;
        lock (_gate)
            CloseEngine();
    }

    private static void CloseEngine()
    {
        if (_engine == IntPtr.Zero)
            return;
        _close(_engine);
        _engine = IntPtr.Zero;
        _engineModel = null;
    }

    private static void Bind()
    {
        if (_open != null)
            return;
        var library = NativeLibrary.Load(FrameworkBinary);
        _speak = (delegate* unmanaged<IntPtr, byte*, byte*, int, float, float**, int*, byte*, int, int>)
            NativeLibrary.GetExport(library, "speechwarp_kokoro_gpu_speak");
        _free = (delegate* unmanaged<float*, void>)NativeLibrary.GetExport(library, "speechwarp_kokoro_gpu_free");
        _close = (delegate* unmanaged<IntPtr, void>)NativeLibrary.GetExport(library, "speechwarp_kokoro_gpu_close");
        // Last: it is what says the others are bound.
        _open = (delegate* unmanaged<byte*, byte*, int, IntPtr>)NativeLibrary.GetExport(library, "speechwarp_kokoro_gpu_open");
    }

    private static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text + "\0");

    private static string Message(byte* message, string fallback)
    {
        var text = Marshal.PtrToStringUTF8((IntPtr)message);
        return string.IsNullOrEmpty(text) ? fallback : text;
    }
}
