require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# eSpeak NG for react-native-speechwarp-voice. GPL-3.0-or-later, as eSpeak NG is.
Pod::Spec.new do |s|
  s.name         = "SpeechwarpVoiceEspeak"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/fredgaffey/speechwarp.git", :tag => "v#{s.version}" }
  s.swift_version = "5.9"

  # ios/vendor holds the Swift package's eSpeak sources, eSpeak NG's library and its data, copied in by
  # scripts/vendor.sh.
  s.source_files = "ios/*.{h,mm,swift}", "ios/vendor/*.swift"
  s.private_header_files = "ios/*.h"
  s.vendored_frameworks = "ios/vendor/Frameworks/espeak_ng.xcframework"
  s.resource_bundles = { "SpeechwarpVoiceEspeakData" => ["ios/vendor/espeak-ng-data"] }
  s.dependency "SpeechwarpVoice"

  s.pod_target_xcconfig = {
    # The framework's headers hold the module map that makes eSpeak NG's C interface the module CEspeakNG.
    "SWIFT_INCLUDE_PATHS" => "\"${PODS_XCFRAMEWORKS_BUILD_DIR}/SpeechwarpVoiceEspeak/Headers\""
  }

  install_modules_dependencies(s)
end
