#import "BesAuthFlutterPlugin.h"
#if __has_include(<bes_auth_flutter/bes_auth_flutter-Swift.h>)
#import <bes_auth_flutter/bes_auth_flutter-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "bes_auth_flutter-Swift.h"
#endif

@implementation BesAuthFlutterPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftBesAuthFlutterPlugin registerWithRegistrar:registrar];
}
@end
