// Tweak.x - RTMPCameraTweak v1.0.58
// Red test overlay with persistent timer
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>

static NSString *kLogFile = @"/var/mobile/Documents/rtmpcamera/tweak.log";
static NSString *kDir = @"/var/mobile/Documents/rtmpcamera";
static NSString *kLoadedFlag = @"/var/mobile/Documents/rtmpcamera/tweak_loaded";
static UIView *g_testView = nil;
static NSInteger g_count = 0;

static void tlog(NSString *s) {
    NSLog(@"[SB58] %@", s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@][SB58] %@\n", [df stringFromDate:[NSDate date]], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil]; [l writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

static UIWindow *getSBWindow(void) {
    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }
    }
    return nil;
}

static void ensureOverlay(void) {
    g_count++;
    UIWindow *sbWindow = getSBWindow();
    if (!sbWindow) return;
    
    UIView *existing = [sbWindow viewWithTag:99958];
    if (!existing) {
        // Create fresh overlay
        UIView *v = [[UIView alloc] initWithFrame:sbWindow.bounds];
        v.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.5];
        v.tag = 99958;
        
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 300, 50)];
        label.center = CGPointMake(sbWindow.bounds.size.width/2, sbWindow.bounds.size.height/2);
        label.text = @"RTMPCamera OK";
        label.textColor = [UIColor whiteColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont boldSystemFontOfSize:24];
        [v addSubview:label];
        
        [sbWindow addSubview:v];
        [sbWindow bringSubviewToFront:v];
        g_testView = v;
        
        if (g_count <= 3) tlog([NSString stringWithFormat:@"Overlay created (attempt #%ld)", (long)g_count]);
    } else if (existing.superview != sbWindow) {
        // Was removed, re-add
        [sbWindow addSubview:existing];
        [sbWindow bringSubviewToFront:existing];
        if (g_count <= 5) tlog(@"Overlay re-added");
    }
    
    if (g_count % 30 == 0) {
        tlog([NSString stringWithFormat:@"Timer #%ld overlay=%@", (long)g_count, g_testView.superview ? @"ON" : @"OFF"]);
    }
}

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        tlog(@"=== v1.0.58 LOADED ===");

        // Timer every 0.5 seconds to ensure overlay persists
        static dispatch_source_t timer;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), 0.5*NSEC_PER_SEC, 0.1*NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{ ensureOverlay(); });
        dispatch_resume(timer);
    }
}

%dtor {
    if (g_testView) { [g_testView removeFromSuperview]; g_testView = nil; }
    tlog(@"Unloaded");
}