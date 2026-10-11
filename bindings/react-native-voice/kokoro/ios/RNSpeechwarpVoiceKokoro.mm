#import "RNSpeechwarpVoiceKokoro.h"

#if __has_include(<SpeechwarpVoiceKokoro/SpeechwarpVoiceKokoro-Swift.h>)
#import <SpeechwarpVoiceKokoro/SpeechwarpVoiceKokoro-Swift.h>
#else
#import "SpeechwarpVoiceKokoro-Swift.h"
#endif

@implementation RNSpeechwarpVoiceKokoro {
  SpeechwarpVoiceKokoroBridge *_bridge;
}

- (instancetype)init
{
  if (self = [super init]) {
    _bridge = [SpeechwarpVoiceKokoroBridge new];
  }
  return self;
}

+ (NSString *)moduleName
{
  return @"SpeechwarpVoiceKokoro";
}

- (NSDictionary *)catalogue
{
  return [_bridge catalogue];
}

- (NSString *)directory
{
  return [_bridge directory];
}

- (NSString *)setDirectory:(NSString *)path
{
  [_bridge setDirectory:path];
  return path;
}

- (NSString *)modelFile
{
  return [_bridge modelFile];
}

- (NSString *)setModelFile:(NSString *)fileName
{
  if (![_bridge setModelFile:fileName]) {
    @throw [NSException exceptionWithName:@"speechwarp_kokoro"
                                   reason:[NSString stringWithFormat:@"%@ is not one of Kokoro's models", fileName]
                                 userInfo:nil];
  }
  return fileName;
}

- (NSArray<NSDictionary *> *)missingFiles:(NSString *)voice
{
  return (NSArray<NSDictionary *> *)[_bridge missingFiles:voice];
}

- (NSNumber *)isInstalled:(NSString *)voice
{
  return @([_bridge isInstalled:voice]);
}

- (NSNumber *)hasPhonemizer
{
  return @([_bridge hasPhonemizer]);
}

- (NSNumber *)engineIncluded
{
  return @([_bridge engineIncluded]);
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeSpeechwarpVoiceKokoroSpecJSI>(params);
}

@end
