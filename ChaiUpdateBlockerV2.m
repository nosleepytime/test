// ChaiUpdateBlocker V2
// Experimental: detect a specific Flutter update dialog in the iOS
// accessibility semantics tree and ask Flutter to pop its active route.
// No modification of billing, account data, networking or other alerts.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static BOOL didEnableSemantics = NO;
static BOOL didAttemptPop = NO;
static BOOL didLogFlutter = NO;
static BOOL didFinish = NO;
static NSUInteger ticks = 0;
static NSTimer *checkTimer = nil;

static void ChaiLog(NSString *message) {
  NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
  [[NSFileManager defaultManager] createDirectoryAtPath:documents
                            withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *path = [documents stringByAppendingPathComponent:@"ChaiUpdateBlockerV2.log"];
  NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
  @synchronized ([NSFileManager defaultManager]) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
      [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle) {
      [handle seekToEndOfFile];
      [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
      [handle closeFile];
    }
  }
}

static BOOL ContainsUpdateText(NSString *text) {
  if (![text isKindOfClass:[NSString class]]) return NO;
  NSString *lower = [text lowercaseString];
  if ([lower containsString:@"let's get you up to date"]) return YES;
  if ([lower containsString:@"we want you to have the best experience on chai"]) return YES;
  return NO;
}

// Traverse Flutter's accessibility tree (including semantics objects,
// accessibility containers, and the backing Flutter view).
static BOOL FindUpdateLabel(id object, NSMutableSet<NSValue *> *seen, NSInteger *remaining) {
  if (!object || *remaining <= 0) return NO;
  NSValue *key = [NSValue valueWithNonretainedObject:object];
  if ([seen containsObject:key]) return NO;
  [seen addObject:key];
  (*remaining)--;

  @try {
    if ([object respondsToSelector:@selector(accessibilityLabel)]) {
      NSString *label = [object accessibilityLabel];
      if (ContainsUpdateText(label)) return YES;
    }
    if ([object respondsToSelector:@selector(accessibilityValue)]) {
      NSString *value = [object accessibilityValue];
      if (ContainsUpdateText(value)) return YES;
    }

    if ([object respondsToSelector:@selector(accessibilityElements)]) {
      id elements = [object accessibilityElements];
      if ([elements isKindOfClass:[NSArray class]]) {
        for (id element in (NSArray *)elements) {
          if (FindUpdateLabel(element, seen, remaining)) return YES;
        }
      }
    }

    if ([object respondsToSelector:@selector(accessibilityElementCount)] &&
        [object respondsToSelector:@selector(accessibilityElementAtIndex:)]) {
      NSInteger count = (NSInteger)[object accessibilityElementCount];
      for (NSInteger i = 0; i < MIN(count, 100); i++) {
        id child = [object accessibilityElementAtIndex:i];
        if (FindUpdateLabel(child, seen, remaining)) return YES;
      }
    }

    if ([object isKindOfClass:[UIView class]]) {
      for (UIView *child in [(UIView *)object subviews]) {
        if (FindUpdateLabel(child, seen, remaining)) return YES;
      }
    }

    if ([object respondsToSelector:@selector(children)]) {
      id children = [object performSelector:@selector(children)];
      if ([children isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)children) {
          if (FindUpdateLabel(child, seen, remaining)) return YES;
        }
      }
    }
  } @catch (NSException *ex) {
    // Avoid disrupting the application if an unsupported semantics getter throws.
  }
  return NO;
}

static UIViewController *FindFlutterVC(UIViewController *controller, NSInteger depth) {
  if (!controller || depth > 18) return nil;
  Class klass = NSClassFromString(@"FlutterViewController");
  if (klass && [controller isKindOfClass:klass]) return controller;
  UIViewController *found = FindFlutterVC(controller.presentedViewController, depth + 1);
  if (found) return found;
  for (UIViewController *child in controller.childViewControllers) {
    found = FindFlutterVC(child, depth + 1);
    if (found) return found;
  }
  return nil;
}

static UIViewController *ActiveFlutterVC(void) {
  UIApplication *app = [UIApplication sharedApplication];
  for (UIWindow *window in app.windows) {
    if (window.hidden || !window.rootViewController) continue;
    UIViewController *found = FindFlutterVC(window.rootViewController, 0);
    if (found) return found;
  }
  return nil;
}

static void StopChecking(void) {
  didFinish = YES;
  [checkTimer invalidate];
  checkTimer = nil;
}

static void CheckDialog(void) {
  if (didFinish) return;
  ticks++;
  if (ticks > 160) {
    ChaiLog(@"Stopped after timeout; no further navigation attempted.");
    StopChecking();
    return;
  }
  UIViewController *flutterVC = ActiveFlutterVC();
  if (!flutterVC) return;

  if (!didLogFlutter) {
    didLogFlutter = YES;
    ChaiLog(@"FlutterViewController found.");
  }

  if (!didEnableSemantics) {
    // Ensure Flutter publishes accessibility nodes even without VoiceOver.
    id engine = nil;
    if ([flutterVC respondsToSelector:@selector(engine)]) {
      engine = ((id (*)(id, SEL))objc_msgSend)(flutterVC, @selector(engine));
    }
    if (engine && [engine respondsToSelector:@selector(ensureSemanticsEnabled)]) {
      ((void (*)(id, SEL))objc_msgSend)(engine, @selector(ensureSemanticsEnabled));
      didEnableSemantics = YES;
      ChaiLog(@"Requested Flutter semantics tree.");
    }
  }

  NSInteger budget = 1800;
  NSMutableSet<NSValue *> *seen = [NSMutableSet set];
  BOOL visible = FindUpdateLabel(flutterVC.view, seen, &budget);
  if (visible && !didAttemptPop) {
    didAttemptPop = YES;
    ChaiLog(@"Specific Chai update dialog detected. Sending Flutter popRoute once.");
    if ([flutterVC respondsToSelector:@selector(popRoute)]) {
      ((void (*)(id, SEL))objc_msgSend)(flutterVC, @selector(popRoute));
    } else {
      ChaiLog(@"FlutterViewController popRoute selector unavailable.");
      StopChecking();
    }
  } else if (didAttemptPop) {
    if (!visible) {
      ChaiLog(@"Update dialog label disappeared after popRoute.");
    } else {
      ChaiLog(@"Update dialog still present after popRoute; stop to protect navigation.");
    }
    StopChecking();
  }
}

__attribute__((constructor))
static void ChaiUpdateBlockerStart(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    ChaiLog(@"ChaiUpdateBlocker V2 loaded.");
    // Install a passive check; never pop any route without matching the alert text.
    checkTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                 repeats:YES
                                                   block:^(__unused NSTimer *timer) {
      CheckDialog();
    }];
  });
}
