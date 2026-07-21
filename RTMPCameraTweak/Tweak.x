// Tweak.x - RTMPCameraTweak v1.0.57
// Minimal test: add colored overlay to SpringBoard's existing window
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>

static NSString *kLogFile = @"/var/mobile/Documents/rtmpcamera/tweak.log";
static NSString *kDir = @"/var/mobile/Documents/rtmpcamera";
static NSString *kLoadedFlag = @"/var/mobile/Documents/rtmpcamera/tweak_loaded";

static void tlog(NSString *s) {
    NSLog(@"[SB57] %@", s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@][SB57] %@\n", [df stringFromDate:[NSDate date]], s];
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

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        tlog(@"=== v1.0.57 LOADED ===");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            UIWindow *sbWindow = getSBWindow();
            tlog([NSString stringWithFormat:@"SB window: %@ frame=%@ level=%.0f",
                  sbWindow ? @"YES" : @"NO",
                  sbWindow ? NSStringFromCGRect(sbWindow.frame) : @"N/A",
                  sbWindow ? sbWindow.windowLevel : 0.0]);

            if (sbWindow) {
                UIView *testView = [[UIView alloc] initWithFrame:sbWindow.bounds];
                testView.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.5];
                testView.tag = 99957;
                
                UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 300, 50)];
                label.center = CGPointMake(sbWindow.bounds.size.width/2, sbWindow.bounds.size.height/2);
                label.text = @"RTMPCamera v1.0.57 TEST";
                label.textColor = [UIColor whiteColor];
                label.textAlignment = NSTextAlignmentCenter;
                label.font = [UIFont boldSystemFontOfSize:20];
                [testView addSubview:label];
                
                [sbWindow addSubview:testView];
                [sbWindow bringSubviewToFront:testView];
                tlog(@"RED TEST VIEW ADDED");
            }
        });
    }
}

%dtor {
    UIWindow *sbWindow = getSBWindow();
    UIView *testView = [sbWindow viewWithTag:99957];
    if (testView) { [testView removeFromSuperview]; tlog(@"Test view removed"); }
    tlog(@"Unloaded");
}