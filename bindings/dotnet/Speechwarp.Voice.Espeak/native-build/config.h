/* eSpeak NG's config.h for build-espeak.sh, in place of the one its CMake or autotools build writes from
   src/libespeak-ng/config.h.in. The library alone: no audio output, MBROLA, Sonic or speech player (the caller
   takes the samples and speeds them up with speechwarp); Klatt voices kept. Keep PACKAGE_VERSION in step with
   the submodule's tag. */
#define HAVE_MKSTEMP 1
#define USE_ASYNC 0
#define USE_KLATT 1
#define USE_LIBPCAUDIO 0
#define USE_LIBSONIC 0
#define USE_MBROLA 0
#define USE_SPEECHPLAYER 0
#define PACKAGE_VERSION "1.52.0"
