#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Test-build-only probe for the XCTest automation-overlay lifecycle.
///
/// It deliberately does NOT synthesize input, reinitialize XCTest, reset
/// authorization, or attempt recovery. The existing iCTRL RPCs remain the
/// probes for tap/swipe/type/page_source/screenshot after the lifecycle call.
@interface XCTestOverlayExperiment : NSObject

+ (BOOL)sharedSessionAvailable;
+ (BOOL)finishInitializationAvailable;
+ (BOOL)daemonProxyAvailable;
+ (BOOL)wasAttempted;

/// Calls -[XCTRunnerDaemonSession finishInitializationForUIAutomation] once.
/// Returns nil only when the selector was actually invoked without an Obj-C
/// exception. Any unsupported/unsafe shape is returned as a diagnostic string.
+ (nullable NSString *)invokeFinishInitializationAndReturnError;

@end

NS_ASSUME_NONNULL_END
