/* The JNI layer between io.github.fredgaffey.speechwarp.voice.espeak.EspeakNative and eSpeak NG.
 *
 * eSpeak keeps its state in globals and is not thread-safe; the Kotlin side holds one lock around every call
 * here, so neither does this file need one. Text crosses as UTF-8 byte arrays rather than Java strings, because
 * JNI's "modified UTF-8" is not what eSpeak reads (characters outside the BMP, and NUL, differ).
 *
 * eSpeak NG is GPL-3.0-or-later, and so is this library. */
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <espeak-ng/espeak_ng.h>
#include <espeak-ng/speak_lib.h>

#define FUNCTION(name) JNICALL Java_io_github_fredgaffey_speechwarp_voice_espeak_EspeakNative_##name

/* The samples of the sentence being spoken, gathered by the callback. */
static short *samples;
static size_t sample_count, sample_capacity;
static int out_of_memory;

static int on_synth(short *wav, int count, espeak_EVENT *events) {
    (void)events;
    if (wav == NULL || count <= 0 || out_of_memory)
        return 0;
    if (sample_count + (size_t)count > sample_capacity) {
        size_t capacity = sample_capacity ? sample_capacity * 2 : 65536;
        while (capacity < sample_count + (size_t)count)
            capacity *= 2;
        short *grown = realloc(samples, capacity * sizeof(short));
        if (grown == NULL) {
            out_of_memory = 1;
            return 1; /* stop */
        }
        samples = grown;
        sample_capacity = capacity;
    }
    memcpy(samples + sample_count, wav, (size_t)count * sizeof(short));
    sample_count += (size_t)count;
    return 0;
}

static void throw_new(JNIEnv *env, const char *class_name, const char *message) {
    jclass type = (*env)->FindClass(env, class_name);
    if (type != NULL)
        (*env)->ThrowNew(env, type, message);
}

/* A NUL-terminated copy of a Java byte array, or NULL (with an exception pending). The caller frees it. */
static char *c_string(JNIEnv *env, jbyteArray bytes) {
    jsize length = (*env)->GetArrayLength(env, bytes);
    char *text = malloc((size_t)length + 1);
    if (text == NULL) {
        throw_new(env, "java/lang/OutOfMemoryError", "No memory for the text");
        return NULL;
    }
    (*env)->GetByteArrayRegion(env, bytes, 0, length, (jbyte *)text);
    text[length] = 0;
    return text;
}

static jbyteArray java_bytes(JNIEnv *env, const char *text, size_t length) {
    jbyteArray result = (*env)->NewByteArray(env, (jsize)length);
    if (result != NULL)
        (*env)->SetByteArrayRegion(env, result, 0, (jsize)length, (const jbyte *)text);
    return result;
}

/* Starts eSpeak with its data in path (the espeak-ng-data folder, or the folder holding it). Returns eSpeak's
   status: 0 when it started. On purpose the espeak_ng_ calls, which report errors: the older espeak_Initialize ends
   the whole process when it cannot find its data. */
JNIEXPORT jint FUNCTION(initialize)(JNIEnv *env, jclass type, jbyteArray path) {
    (void)type;
    char *data = c_string(env, path);
    if (data == NULL)
        return -1;
    espeak_ng_InitializePath(data);
    free(data);
    espeak_ng_STATUS status = espeak_ng_Initialize(NULL);
    if (status != ENS_OK)
        return (jint)status;
    /* Synchronous: the sound is handed back through the callback, never played. */
    status = espeak_ng_InitializeOutput(ENOUTPUT_MODE_SYNCHRONOUS, 0, NULL);
    if (status != ENS_OK)
        return (jint)status;
    espeak_SetSynthCallback(on_synth);
    return 0;
}

JNIEXPORT jstring FUNCTION(version)(JNIEnv *env, jclass type) {
    (void)type;
    return (*env)->NewStringUTF(env, espeak_Info(NULL));
}

JNIEXPORT jint FUNCTION(sampleRate)(JNIEnv *env, jclass type) {
    (void)env;
    (void)type;
    return espeak_ng_GetSampleRate();
}

/* Chooses a voice by its name or file, such as "en-us" or "gmw/en", with any variant ("en-us+klatt"). Returns
   eSpeak's status: 0 when it has that voice. */
JNIEXPORT jint FUNCTION(setVoiceByName)(JNIEnv *env, jclass type, jbyteArray name) {
    (void)type;
    char *voice = c_string(env, name);
    if (voice == NULL)
        return -1;
    espeak_ng_STATUS status = espeak_ng_SetVoiceByName(voice);
    free(voice);
    return (jint)status;
}

/* The file of the voice that suits a language best (UTF-8), as eSpeak's own command chooses it, or null. */
JNIEXPORT jbyteArray FUNCTION(bestVoiceFor)(JNIEnv *env, jclass type, jbyteArray language) {
    (void)type;
    char *name = c_string(env, language);
    if (name == NULL)
        return NULL;
    espeak_VOICE spec;
    memset(&spec, 0, sizeof spec);
    spec.languages = name;
    const espeak_VOICE **list = espeak_ListVoices(&spec);
    free(name);
    if (list == NULL || list[0] == NULL || list[0]->identifier == NULL)
        return NULL;
    return java_bytes(env, list[0]->identifier, strlen(list[0]->identifier));
}

/* Speaks text (UTF-8) in the voice chosen last: mono samples, -1 to 1, at sampleRate(). */
JNIEXPORT jfloatArray FUNCTION(synthesize)(JNIEnv *env, jclass type, jbyteArray text, jint words_per_minute,
                                           jint pitch) {
    (void)type;
    char *input = c_string(env, text);
    if (input == NULL)
        return NULL;
    espeak_SetParameter(espeakRATE, words_per_minute, 0);
    espeak_SetParameter(espeakPITCH, pitch, 0);
    sample_count = 0;
    out_of_memory = 0;
    espeak_ERROR status = espeak_Synth(input, strlen(input) + 1, 0, POS_CHARACTER, 0, espeakCHARS_UTF8, NULL, NULL);
    free(input);
    if (out_of_memory) {
        throw_new(env, "java/lang/OutOfMemoryError", "No memory for eSpeak's samples");
        return NULL;
    }
    if (status != EE_OK) {
        char message[64];
        snprintf(message, sizeof message, "eSpeak failed to speak (error %d).", (int)status);
        throw_new(env, "java/lang/IllegalStateException", message);
        return NULL;
    }
    jfloatArray result = (*env)->NewFloatArray(env, (jsize)sample_count);
    if (result == NULL)
        return NULL;
    float *floats = (*env)->GetPrimitiveArrayCritical(env, result, NULL);
    if (floats == NULL)
        return NULL;
    for (size_t i = 0; i < sample_count; i++)
        floats[i] = samples[i] / 32768.0f;
    (*env)->ReleasePrimitiveArrayCritical(env, result, floats, 0);
    /* Keep a modest buffer for the next sentence rather than all a long one needed. */
    if (sample_capacity > (1u << 20)) {
        free(samples);
        samples = NULL;
        sample_capacity = 0;
    }
    sample_count = 0;
    return result;
}

/* The phonemes of text (UTF-8) in IPA, with eSpeak's stress marks, clause by clause separated by a space, in the
   voice chosen last. UTF-8. */
JNIEXPORT jbyteArray FUNCTION(textToPhonemes)(JNIEnv *env, jclass type, jbyteArray text) {
    (void)type;
    char *input = c_string(env, text);
    if (input == NULL)
        return NULL;
    size_t length = 0, capacity = 256;
    char *result = malloc(capacity);
    if (result == NULL) {
        free(input);
        throw_new(env, "java/lang/OutOfMemoryError", "No memory for the phonemes");
        return NULL;
    }
    /* eSpeak moves the pointer past each clause it translates, and sets it to null at the end. */
    const void *at = input;
    while (at != NULL) {
        const char *clause = espeak_TextToPhonemes(&at, espeakCHARS_UTF8, espeakPHONEMES_IPA);
        if (clause == NULL || *clause == 0)
            continue;
        size_t size = strlen(clause);
        if (length + size + 2 > capacity) {
            while (length + size + 2 > capacity)
                capacity *= 2;
            char *grown = realloc(result, capacity);
            if (grown == NULL) {
                free(result);
                free(input);
                throw_new(env, "java/lang/OutOfMemoryError", "No memory for the phonemes");
                return NULL;
            }
            result = grown;
        }
        if (length > 0)
            result[length++] = ' ';
        memcpy(result + length, clause, size);
        length += size;
    }
    jbyteArray phonemes = java_bytes(env, result, length);
    free(result);
    free(input);
    return phonemes;
}

/* Every voice in the data, UTF-8, one a line: name, identifier, gender (0 unknown, 1 male, 2 female) and the
   languages (the most particular first, separated by commas), separated by tabs. */
JNIEXPORT jbyteArray FUNCTION(listVoices)(JNIEnv *env, jclass type) {
    (void)type;
    const espeak_VOICE **list = espeak_ListVoices(NULL);
    size_t length = 0, capacity = 4096;
    char *result = malloc(capacity);
    if (result == NULL) {
        throw_new(env, "java/lang/OutOfMemoryError", "No memory for the voices");
        return NULL;
    }
    for (int i = 0; list != NULL && list[i] != NULL; i++) {
        const espeak_VOICE *voice = list[i];
        /* The longest a line can be: the name, the identifier, the gender and the languages, with separators. */
        size_t languages = 0;
        for (const char *at = voice->languages; at != NULL && *at != 0;) {
            size_t size = strlen(at + 1);
            languages += size + 1;
            at += size + 2;
        }
        size_t need = strlen(voice->name ? voice->name : "") + strlen(voice->identifier ? voice->identifier : "") +
                      languages + 16;
        if (length + need > capacity) {
            while (length + need > capacity)
                capacity *= 2;
            char *grown = realloc(result, capacity);
            if (grown == NULL) {
                free(result);
                throw_new(env, "java/lang/OutOfMemoryError", "No memory for the voices");
                return NULL;
            }
            result = grown;
        }
        length += (size_t)snprintf(result + length, capacity - length, "%s\t%s\t%d\t",
                                   voice->name ? voice->name : "", voice->identifier ? voice->identifier : "",
                                   voice->gender == 1 || voice->gender == 2 ? voice->gender : 0);
        /* Pairs of a priority byte and a NUL-terminated language, ended by a zero priority. */
        int first = 1;
        for (const char *at = voice->languages; at != NULL && *at != 0;) {
            const char *language = at + 1;
            size_t size = strlen(language);
            if (!first)
                result[length++] = ',';
            memcpy(result + length, language, size);
            length += size;
            first = 0;
            at = language + size + 1;
        }
        result[length++] = '\n';
    }
    jbyteArray voices = java_bytes(env, result, length);
    free(result);
    return voices;
}
