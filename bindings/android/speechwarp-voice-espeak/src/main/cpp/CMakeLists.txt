# Builds libspeechwarp_espeak: eSpeak NG (GPL-3.0-or-later) from the third_party/espeak-ng submodule and the JNI
# layer, in one shared library. Gradle runs this for each Android ABI, and once more for this computer, where it
# also builds upstream's espeak-ng command (to compile eSpeak's data) and, when a JDK is found, the JNI library for
# the unit tests.
#
# The library alone, as bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh builds it (see
# config.h): no audio output, MBROLA, Sonic or speech player; Klatt kept; a 1,024-byte data path. Every eSpeak
# symbol is hidden, so only the JNI functions are exported and nothing clashes with another copy of eSpeak.
cmake_minimum_required(VERSION 3.16)
project(speechwarp_espeak C)

set(root ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../..)
set(espeak ${root}/third_party/espeak-ng)
if(NOT EXISTS ${espeak}/src/libespeak-ng/speech.c)
  message(FATAL_ERROR "eSpeak NG's source is missing. Fetch it with:\n"
    "  git submodule update --init --checkout third_party/espeak-ng")
endif()

# The library's sources, as listed in upstream's Makefile.am, less the asynchronous mode, audio output, MBROLA,
# Sonic and the speech player.
set(library common mnemonics error ieee80 compiledata compiledict dictionary encoding intonation langopts numbers
  phoneme phonemelist readclause setlengths soundicon spect ssml synthdata synthesize tr_languages translate
  translateword voices wavegen speech espeak_api klatt)
set(ucd case categories ctype proplist scripts tostring)
list(TRANSFORM library PREPEND ${espeak}/src/libespeak-ng/)
list(TRANSFORM library APPEND .c)
list(TRANSFORM ucd PREPEND ${espeak}/src/ucd-tools/src/)
list(TRANSFORM ucd APPEND .c)

add_library(espeak_ng STATIC ${library} ${ucd})
target_include_directories(espeak_ng
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} ${espeak}/src/include/compat ${espeak}/src/ucd-tools/src/include
          ${espeak}/src/libespeak-ng
  PUBLIC ${espeak}/src/include)
target_compile_definitions(espeak_ng PRIVATE NDEBUG N_PATH_HOME=1024 "PATH_ESPEAK_DATA=\"\"")
# Upstream's code is not warning-free; -fwrapv as upstream builds it.
target_compile_options(espeak_ng PRIVATE -w -fwrapv)
set_target_properties(espeak_ng PROPERTIES C_VISIBILITY_PRESET hidden POSITION_INDEPENDENT_CODE ON)

if(ANDROID)
  add_library(speechwarp_espeak SHARED espeak_jni.c)
  target_link_libraries(speechwarp_espeak PRIVATE espeak_ng m)
  set_target_properties(speechwarp_espeak PROPERTIES C_VISIBILITY_PRESET hidden)
  # Android 15 devices may use 16 KB pages; NDK 27 and older need to be told.
  target_link_options(speechwarp_espeak PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,--exclude-libs,ALL")
else()
  # Upstream's command, to compile the data on this computer.
  add_executable(espeak-ng ${espeak}/src/espeak-ng.c)
  target_include_directories(espeak-ng PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_compile_options(espeak-ng PRIVATE -w)
  target_link_libraries(espeak-ng PRIVATE espeak_ng m)

  find_package(JNI)
  if(JNI_FOUND)
    add_library(speechwarp_espeak SHARED espeak_jni.c)
    target_include_directories(speechwarp_espeak PRIVATE ${JNI_INCLUDE_DIRS})
    target_link_libraries(speechwarp_espeak PRIVATE espeak_ng m)
    set_target_properties(speechwarp_espeak PROPERTIES C_VISIBILITY_PRESET hidden)
  endif()
endif()
