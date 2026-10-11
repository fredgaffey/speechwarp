require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# Kokoro-82M for react-native-speechwarp-voice. ONNX Runtime is large (about 60 MB to download), so its engine is
# compiled only when the app asks for it: `SPEECHWARP_KOKORO=1 pod install` (or ENV['SPEECHWARP_KOKORO'] = '1' at the
# top of the Podfile). Without it the pod holds the catalogue of files only, as the Swift package does without its
# trait "Kokoro".
kokoro = ENV["SPEECHWARP_KOKORO"] == "1"

Pod::Spec.new do |s|
  s.name         = "SpeechwarpVoiceKokoro"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/fredgaffey/speechwarp.git", :tag => "v#{s.version}" }
  s.swift_version = "5.9"

  # ios/vendor holds the Swift package's Kokoro sources, copied in by scripts/vendor.sh.
  s.source_files = "ios/*.{h,mm,swift}", "ios/vendor/*.swift"
  s.private_header_files = "ios/*.h"
  s.dependency "SpeechwarpVoice"

  if kokoro
    # The release the Swift package uses (see Package.swift).
    s.dependency "onnxruntime-objc", "1.20.0"
    s.pod_target_xcconfig = { "SWIFT_ACTIVE_COMPILATION_CONDITIONS" => "$(inherited) Kokoro" }
  end

  install_modules_dependencies(s)
end
