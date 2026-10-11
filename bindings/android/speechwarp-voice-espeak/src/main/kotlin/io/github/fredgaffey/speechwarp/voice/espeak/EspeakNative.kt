package io.github.fredgaffey.speechwarp.voice.espeak

/**
 * libspeechwarp_espeak's functions (src/main/cpp/espeak_jni.c). Text crosses as UTF-8 bytes. Every call must hold
 * [Espeak]'s lock: eSpeak keeps its state in globals.
 */
internal object EspeakNative {
    init {
        System.loadLibrary("speechwarp_espeak")
    }

    @JvmStatic external fun initialize(path: ByteArray): Int
    @JvmStatic external fun version(): String
    @JvmStatic external fun sampleRate(): Int
    @JvmStatic external fun setVoiceByName(name: ByteArray): Int
    @JvmStatic external fun bestVoiceFor(language: ByteArray): ByteArray?
    @JvmStatic external fun synthesize(text: ByteArray, wordsPerMinute: Int, pitch: Int): FloatArray
    @JvmStatic external fun textToPhonemes(text: ByteArray): ByteArray
    @JvmStatic external fun listVoices(): ByteArray
}
