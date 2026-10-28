#import "XCTestOverlayExperiment.h"
#import <objc/message.h>

@implementation XCTestOverlayExperiment

static BOOL sAttempted = NO;

+ (id)existingSharedSession {
    Class cls = NSClassFromString(@"XCTRunnerDaemonSession");
    if (!cls) { return nil; }

    // Prefer a lookup that cannot initiate a fresh session. Xcode 26.4 exposes
    // +sharedSessionIfInitiated. Older runtimes may not; by the time iCTRL's
    // testStartServer is running XCTest bootstrap is already complete, so the
    // normal +sharedSession fallback refers to that established runner session.
    SEL existing = NSSelectorFromString(@"sharedSessionIfInitiated");
    if ([cls respondsToSelector:existing]) {
        id (*sendId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id session = sendId(cls, existing);
        if (session) { return session; }
    }

    SEL shared = NSSelectorFromString(@"sharedSession");
    if (![cls respondsToSelector:shared]) { return nil; }
    id (*sendId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return sendId(cls, shared);
}

+ (BOOL)sharedSessionAvailable {
    @try {
        return [self existingSharedSession] != nil;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

+ (BOOL)finishInitializationAvailable {
    @try {
        id session = [self existingSharedSession];
        if (!session) { return NO; }
        return [session respondsToSelector:NSSelectorFromString(@"finishInitializationForUIAutomation")];
    } @catch (__unused NSException *e) {
        return NO;
    }
}

+ (BOOL)daemonProxyAvailable {
    @try {
        id session = [self existingSharedSession];
        if (!session) { return NO; }
        SEL sel = NSSelectorFromString(@"daemonProxy");
        if (![session respondsToSelector:sel]) { return NO; }
        id (*sendId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        return sendId(session, sel) != nil;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

+ (BOOL)wasAttempted {
    @synchronized(self) { return sAttempted; }
}

+ (nullable NSString *)invokeFinishInitializationAndReturnError {
    if (![NSThread isMainThread]) {
        return @"refused: overlay lifecycle experiment must run on the main thread";
    }

    @synchronized(self) {
        if (sAttempted) {
            return @"refused: finishInitializationForUIAutomation was already attempted in this runner process";
        }
        // One shot per runner process. Even an exception is recorded as an
        // attempt; the experiment must never silently retry or auto-recover.
        sAttempted = YES;
    }

    @try {
        id session = [self existingSharedSession];
        if (!session) { return @"shared XCTRunnerDaemonSession is unavailable"; }

        SEL sel = NSSelectorFromString(@"finishInitializationForUIAutomation");
        if (![session respondsToSelector:sel]) {
            return @"finishInitializationForUIAutomation is unavailable on this runtime";
        }

        // The Xcode 26.4 private header exposes this as a no-argument, void
        // instance method. Verify the live Objective-C ABI shape before calling
        // it; if Apple changes the signature, stop instead of guessing.
        NSMethodSignature *sig = [session methodSignatureForSelector:sel];
        if (!sig) { return @"method signature unavailable"; }
        if (sig.numberOfArguments != 2 || sig.methodReturnLength != 0) {
            return [NSString stringWithFormat:
                    @"refused: unexpected ABI for finishInitializationForUIAutomation (args=%lu returnLength=%lu)",
                    (unsigned long)sig.numberOfArguments, (unsigned long)sig.methodReturnLength];
        }

        void (*sendVoid)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
        sendVoid(session, sel);
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"Objective-C exception: %@ — %@",
                e.name ?: @"unknown", e.reason ?: @"no reason"];
    }
}

@end
