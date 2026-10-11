#import "RNSpeechwarpVoice.h"

#if __has_include(<SpeechwarpVoice/SpeechwarpVoice-Swift.h>)
#import <SpeechwarpVoice/SpeechwarpVoice-Swift.h>
#else
#import "SpeechwarpVoice-Swift.h"
#endif

namespace {
// Optional fields of the spec's structs, as NSDictionary entries for the Swift side.
void put(NSMutableDictionary *dict, NSString *key, std::optional<double> value)
{
  if (value.has_value()) dict[key] = @(*value);
}

void put(NSMutableDictionary *dict, NSString *key, std::optional<bool> value)
{
  if (value.has_value()) dict[key] = @(*value);
}

void put(NSMutableDictionary *dict, NSString *key, NSString *value)
{
  if (value != nil) dict[key] = value;
}
} // namespace

@implementation RNSpeechwarpVoice {
  SpeechwarpVoiceBridge *_bridge;
}

- (instancetype)init
{
  if (self = [super init]) {
    _bridge = [SpeechwarpVoiceBridge new];
    __weak RNSpeechwarpVoice *weakSelf = self;
    _bridge.onState = ^(NSDictionary *state) {
      [weakSelf emitOnState:state];
    };
    _bridge.onError = ^(NSDictionary *error) {
      [weakSelf emitOnError:error];
    };
  }
  return self;
}

+ (NSString *)moduleName
{
  return @"SpeechwarpVoice";
}

- (void)invalidate
{
  [_bridge invalidate];
}

- (void)listVoices:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_bridge listVoicesWithResolve:^(NSArray *voices) { resolve(voices); }
                          reject:^(NSString *message) { reject(@"speechwarp_voices", message, nil); }];
}

- (void)createReader:(NSString *)text
             voiceId:(NSString *)voiceId
             options:(JS::NativeSpeechwarpVoice::ReaderOptions &)options
             resolve:(RCTPromiseResolveBlock)resolve
              reject:(RCTPromiseRejectBlock)reject
{
  NSMutableDictionary *dict = [NSMutableDictionary new];
  put(dict, @"speed", options.speed());
  put(dict, @"speedUp", options.speedUp());
  put(dict, @"lookahead", options.lookahead());
  put(dict, @"keptLookahead", options.keptLookahead());
  put(dict, @"secondsPerCharacter", options.secondsPerCharacter());
  put(dict, @"cache", options.cache());
  put(dict, @"cacheDirectory", options.cacheDirectory());
  put(dict, @"speakAheadToDisk", options.speakAheadToDisk());
  put(dict, @"sampleRate", options.sampleRate());
  put(dict, @"positionInterval", options.positionInterval());
  put(dict, @"manageAudioSession", options.manageAudioSession());
  put(dict, @"language", options.language());
  [_bridge createReader:text
                voiceId:voiceId
                options:dict
                resolve:^(NSDictionary *info) { resolve(info); }
                 reject:^(NSString *message) { reject(@"speechwarp_reader", message, nil); }];
}

- (void)play:(double)handle
{
  [_bridge play:(NSInteger)handle];
}

- (void)pause:(double)handle
{
  [_bridge pause:(NSInteger)handle];
}

- (void)seekToCharacter:(double)handle character:(double)character
{
  [_bridge seek:(NSInteger)handle toCharacter:(NSInteger)character];
}

- (void)seekToTime:(double)handle seconds:(double)seconds
{
  [_bridge seek:(NSInteger)handle toTime:seconds];
}

- (void)setSpeed:(double)handle speed:(double)speed
{
  [_bridge setSpeed:(NSInteger)handle speed:speed];
}

- (void)setVoice:(double)handle voiceId:(NSString *)voiceId
{
  [_bridge setVoice:(NSInteger)handle voiceId:voiceId];
}

- (void)configure:(double)handle settings:(JS::NativeSpeechwarpVoice::StreamSettings &)settings
{
  NSMutableDictionary *dict = [NSMutableDictionary new];
  put(dict, @"nonlinear", settings.nonlinear());
  put(dict, @"pauseCap", settings.pauseCap());
  put(dict, @"keepSpeed", settings.keepSpeed());
  put(dict, @"speedFloor", settings.speedFloor());
  put(dict, @"rhythmGap", settings.rhythmGap());
  put(dict, @"rhythmRate", settings.rhythmRate());
  put(dict, @"heardPause", settings.heardPause());
  put(dict, @"heardPauseFrom", settings.heardPauseFrom());
  put(dict, @"floorBlend", settings.floorBlend());
  put(dict, @"floorBlendFrom", settings.floorBlendFrom());
  put(dict, @"floorBlendFull", settings.floorBlendFull());
  [_bridge configure:(NSInteger)handle settings:dict];
}

- (void)setSpeakAheadToDisk:(double)handle enabled:(BOOL)enabled
{
  [_bridge setSpeakAheadToDisk:(NSInteger)handle enabled:enabled];
}

- (NSDictionary *)getState:(double)handle
{
  return [_bridge state:(NSInteger)handle];
}

- (NSArray<NSDictionary *> *)getSentences:(double)handle
{
  return (NSArray<NSDictionary *> *)[_bridge sentences:(NSInteger)handle];
}

- (void)releaseReader:(double)handle
{
  [_bridge releaseReader:(NSInteger)handle];
}

- (NSString *)defaultCacheDirectory
{
  return [_bridge defaultCacheDirectory];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeSpeechwarpVoiceSpecJSI>(params);
}

@end
