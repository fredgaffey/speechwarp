#import "RNSpeechwarpVoiceEspeak.h"

#if __has_include(<SpeechwarpVoiceEspeak/SpeechwarpVoiceEspeak-Swift.h>)
#import <SpeechwarpVoiceEspeak/SpeechwarpVoiceEspeak-Swift.h>
#else
#import "SpeechwarpVoiceEspeak-Swift.h"
#endif

@implementation RNSpeechwarpVoiceEspeak {
  SpeechwarpVoiceEspeakBridge *_bridge;
}

- (instancetype)init
{
  if (self = [super init]) {
    _bridge = [SpeechwarpVoiceEspeakBridge new];
  }
  return self;
}

+ (NSString *)moduleName
{
  return @"SpeechwarpVoiceEspeak";
}

- (NSString *)version
{
  return [_bridge version];
}

- (void)variants:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    resolve([self->_bridge variants]);
  });
}

- (void)phonemize:(NSString *)text
         language:(NSString *)language
          resolve:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    NSString *phonemes = [self->_bridge phonemize:text language:language error:&error];
    if (phonemes) {
      resolve(phonemes);
    } else {
      reject(@"speechwarp_espeak", error.localizedDescription, error);
    }
  });
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeSpeechwarpVoiceEspeakSpecJSI>(params);
}

@end
