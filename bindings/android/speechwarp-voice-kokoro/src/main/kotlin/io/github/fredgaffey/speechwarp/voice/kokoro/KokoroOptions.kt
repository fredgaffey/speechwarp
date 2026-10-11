package io.github.fredgaffey.speechwarp.voice.kokoro

/**
 * How a [KokoroEngine] loads the model. Every setting has a sensible default.
 *
 * Kokoro runs on the CPU only: ONNX Runtime's accelerators on Android (NNAPI, QNN, the GPU) are not used.
 *
 * @property modelFile The model's file name in the model directory; [KokoroModels.DEFAULT_MODEL_FILE] by default.
 * @property threads CPU threads for one sentence; 0 (the default) for one a core, at most four.
 * @property xnnpack Also use ONNX Runtime's XNNPACK kernels, which run on the CPU too. Off by default: on the arm64
 * emulator they made every model slower, fp32 by 2.5 times (docs/voices.md, "Which model on Android").
 */
data class KokoroOptions @JvmOverloads constructor(
    val modelFile: String = KokoroModels.DEFAULT_MODEL_FILE,
    val threads: Int = 0,
    val xnnpack: Boolean = false,
) {
    init {
        require(threads >= 0) { "threads must be 0 (one a core) or more." }
    }
}
