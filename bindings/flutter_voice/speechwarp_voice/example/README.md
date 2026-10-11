# speechwarp_voice example

Reads a passage aloud with any voice the device has (and Kokoro's and eSpeak's, whose packages it includes), highlights
the sentence being heard, jumps to a sentence when it is tapped, and has a speed slider.

`flutter run --dart-define=AUTOPLAY=true` starts reading as soon as the voices are listed. `integration_test/` is the
plugin's test on a device; see the plugin's README for how to run it.

It includes `speechwarp_voice_espeak`, so a build of it is under the GPL-3.0-or-later. It is source only.
