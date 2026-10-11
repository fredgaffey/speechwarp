require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# The pod is named SpeechwarpVoice so that its Swift module has the name the Swift package gives it: the engine pods
# (react-native-speechwarp-voice-espeak, -kokoro) compile the Swift package's own sources, which `import SpeechwarpVoice`.
Pod::Spec.new do |s|
  s.name         = "SpeechwarpVoice"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/fredgaffey/speechwarp.git", :tag => "v#{s.version}" }
  s.swift_version = "5.9"

  # ios/vendor holds the Swift package's sources (bindings/swift/Sources/Speechwarp and SpeechwarpVoice) and
  # cpp/speechwarp the C library's, both copied in by scripts/vendor.sh. Only the C library's src/ is compiled: those
  # files include the ones in third_party/ themselves.
  s.source_files = "ios/**/*.{h,m,mm,swift}", "cpp/speechwarp/src/*.{c,h}", "cpp/speechwarp/include/*.h"
  s.private_header_files = "ios/**/*.h", "cpp/speechwarp/**/*.h"
  s.preserve_paths = "cpp/speechwarp/include/module.modulemap", "cpp/speechwarp/third_party/**/*",
                     "cpp/speechwarp/licenses/*"
  s.frameworks = "AVFoundation", "NaturalLanguage", "CryptoKit"

  s.pod_target_xcconfig = {
    "HEADER_SEARCH_PATHS" => "\"$(PODS_TARGET_SRCROOT)/cpp/speechwarp/include\" \"$(PODS_TARGET_SRCROOT)/cpp/speechwarp/third_party/kissfft\"",
    # The C library is the module CSpeechwarp to Swift, as in Package.swift.
    "SWIFT_INCLUDE_PATHS" => "\"$(PODS_TARGET_SRCROOT)/cpp/speechwarp/include\"",
    # Upstream is full of assertions.
    "GCC_PREPROCESSOR_DEFINITIONS" => "$(inherited) NDEBUG=1"
  }
  install_modules_dependencies(s)
end
