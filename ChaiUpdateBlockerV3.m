// ChaiUpdateBlocker V3 - experimental per-IPA version-check probe.
//
// Installed Chai version (observed in the supplied IPA): 20260911.0.0.
// Intercepts only package_info_plus / getAll, returning an experimental
// version override. It DOES NOT modify the IPA or network traffic.
// If the popup is enforced by a different version check, it will remain.
// Diagnostics: Documents/ChaiUpdateBlockerV3.log
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

typedef void (^V3Result)(id);
typedef void (*V3OriginalHandler)(id, SEL, id, V3Result);

static V3OriginalHandler originalHandler = NULL;
static BOOL installedHook = NO;
static BOOL enabledSemantics = NO;
static BOOL sawFlutter = NO;
static BOOL sawPopup = NO;
static BOOL finished = NO;
static NSUInteger tickCount = 0;

static NSString *const expectedOldVersion = @"20260911.0.0";
static NSString *const experimentalVersion = @"20991231.0.0";

static void V3Log(NSString *message) {
  NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
  [[NSFileManager defaultManager] createDirectoryAtPath:documents
                            withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *logPath = [documents stringByAppendingPathComponent:@"ChaiUpdateBlockerV3.log"];
  NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
  @synchronized ([NSFileManager defaultManager]) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
      [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (handle) {
      [handle seekToEndOfFile];
      [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
      [handle closeFile];
    }
  }
}

static void V3HandleMethodCall(id target, SEL command, id call, V3Result reply) {
  NSString *methodName = nil;
  if ([call respondsToSelector:@selector(method)]) {
    methodName = ((id (*)(id, SEL))objc_msgSend)(call, @selector(method));
  }

  if (!originalHandler) {
    V3Log(@"Plugin handler not available, cannot respond.");
    return;
  }

  if (![methodName isEqualToString:@"getAll"] || !reply) {
    originalHandler(target, command, call, reply);
    return;
  }

  V3Log(@"package_info_plus getAll invoked.");
  originalHandler(target, command, call, ^(id value) {
    if (![value isKindOfClass:[NSDictionary class]]) {
      V3Log(@"getAll returned non-dictionary result; unchanged.");
      reply(value);
      return;
    }

    NSDictionary *info = (NSDictionary *)value;
    NSString *version = info[@"version"];
    V3Log([NSString stringWithFormat:@"getAll original version: %@", version ?: @"(none)"]);

    if ([version isKindOfClass:[NSString class]] && [version isEqualToString:expectedOldVersion]) {
      NSMutableDictionary *edited = [info mutableCopy];
      edited[@"version"] = experimentalVersion;
      V3Log([NSString stringWithFormat:@"Version override applied: %@ -> %@",
            version, experimentalVersion]);
      reply([edited copy]);
    } else {
      V3Log(@"Original app version did not match expected IPA; no override.");
      reply(value);
    }
  });
}

static void InstallHookIfPossible(void) {
  if (installedHook) return;
  Class cls = NSClassFromString(@"FPPPackageInfoPlusPlugin");
  if (!cls) return;
  Method method = class_getInstanceMethod(cls, @selector(handleMethodCall:result:));
  if (!method) {
    V3Log(@"Found plugin class, but handleMethodCall:result: method unavailable.");
    return;
  }
  V3OriginalHandler previous = (V3OriginalHandler)method_setImplementation(method, (IMP)V3HandleMethodCall);
  if (previous) {
    originalHandler = previous;
    installedHook = YES;
    V3Log(@"package_info_plus method hook installed.");
  }
}

static BOOL IncludesTargetText(id value) {
  if (![value isKindOfClass:[NSString class]]) return NO;
  NSString *lower = [(NSString *)value lowercaseString];
  return [lower containsString:@"let's get you up to date"] ||
    [lower containsString:@"we want you to have the best experience on chai"];
}

static BOOL SearchSemantics(id node, NSMutableSet<NSValue *> *visited, NSUInteger *budget) {
  if (!node || !*budget) return NO;
  NSValue *key = [NSValue valueWithNonretainedObject:node];
  if ([visited containsObject:key]) return NO;
  [visited addObject:key];
  (*budget)--;
  @try {
    if ([node respondsToSelector:@selector(accessibilityLabel)] &&
        IncludesTargetText([node accessibilityLabel])) return YES;
    if ([node respondsToSelector:@selector(accessibilityValue)] &&
        IncludesTargetText([node accessibilityValue])) return YES;
    if ([node respondsToSelector:@selector(accessibilityElements)]) {
      id children = [node accessibilityElements];
      if ([children isKindOfClass:[NSArray class]]) {
        for (id child in children) {
          if (SearchSemantics(child, visited, budget)) return YES;
        }
      }
    }
    if ([node respondsToSelector:@selector(accessibilityElementCount)] &&
        [node respondsToSelector:@selector(accessibilityElementAtIndex:)]) {
      NSInteger n = (NSInteger)[node accessibilityElementCount];
      for (NSInteger i = 0; i < MIN(n, 100); i++) {
        id child = [node accessibilityElementAtIndex:i];
        if (SearchSemantics(child, visited, budget)) return YES;
      }
    }
    if ([node isKindOfClass:[UIView class]]) {
      for (UIView *child in [(UIView *)node subviews]) {
        if (SearchSemantics(child, visited, budget)) return YES;
      }
    }
  } @catch (NSException *ex) {}
  return NO;
}

static UIViewController *FindFlutter(UIViewController *controller, NSUInteger depth) {
  if (!controller || depth > 16) return nil;
  Class cls = NSClassFromString(@"FlutterViewController");
  if (cls && [controller isKindOfClass:cls]) return controller;
  UIViewController *result = FindFlutter(controller.presentedViewController, depth + 1);
  if (result) return result;
  for (UIViewController *child in controller.childViewControllers) {
    result = FindFlutter(child, depth + 1);
    if (result) return result;
  }
  return nil;
}

static UIViewController *ActiveFlutterVC(void) {
  for (UIWindow *window in [UIApplication sharedApplication].windows) {
    if (window.hidden) continue;
    UIViewController *found = FindFlutter(window.rootViewController, 0);
    if (found) return found;
  }
  return nil;
}

static void CheckOnce(void) {
  if (finished) return;
  tickCount++;
  InstallHookIfPossible();

  UIViewController *flutterVC = ActiveFlutterVC();
  if (flutterVC) {
    if (!sawFlutter) {
      sawFlutter = YES;
      V3Log(@"FlutterViewController found.");
    }
    if (!enabledSemantics && [flutterVC respondsToSelector:@selector(engine)]) {
      id engine = ((id (*)(id, SEL))objc_msgSend)(flutterVC, @selector(engine));
      if (engine && [engine respondsToSelector:@selector(ensureSemanticsEnabled)]) {
        ((void (*)(id, SEL))objc_msgSend)(engine, @selector(ensureSemanticsEnabled));
        enabledSemantics = YES;
        V3Log(@"Flutter semantics enabled.");
      }
    }
    NSUInteger budget = 1200;
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    BOOL visible = SearchSemantics(flutterVC.view, visited, &budget);
    if (visible && !sawPopup) {
      sawPopup = YES;
      V3Log(@"Specific Chai update popup is STILL VISIBLE after V3 version interception attempt.");
    }
  }

  if (tickCount >= 120) {
    if (!installedHook) V3Log(@"Plugin hook not installed during 60s test.");
    if (!sawPopup) V3Log(@"Popup label was not detected during 60s test.");
    V3Log(@"V3 check finished. No more actions will be taken.");
    finished = YES;
  }
}

__attribute__((constructor))
static void StartV3(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    V3Log(@"ChaiUpdateBlocker V3 loaded.");
    InstallHookIfPossible();
    [NSTimer scheduledTimerWithTimeInterval:0.5
                                    repeats:YES
                                      block:^(NSTimer *timer) {
      CheckOnce();
      if (finished) [timer invalidate];
    }];
  });
}
