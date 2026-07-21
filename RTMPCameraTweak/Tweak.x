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

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        tlog(@"=== v1.0.57 LOADED ===");

        // Wait 1 second for SpringBoard to fully initialize
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // Get SpringBoard's key window
            UIWindow *sbWindow = [[UIApplication sharedApplication] keyWindow];
            tlog([NSString stringWithFormat:@"SB window: %@ frame=%@ level=%.0f subviews=%lu",
                  sbWindow ? @"YES" : @"NO",
                  sbWindow ? NSStringFromCGRect(sbWindow.frame) : @"N/A",
                  sbWindow ? sbWindow.windowLevel : 0.0,
                  sbWindow ? (unsigned long)sbWindow.subviews.count : 0]);

            if (sbWindow) {
                // Add a red semi-transparent overlay to test visibility
                UIView *testView = [[UIView alloc] initWithFrame:sbWindow.bounds];
                testView.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.5];
                testView.tag = 99957; // identifiable tag
                
                // Add a white label in center
                UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 300, 50)];
                label.center = testView.center;
                label.text = @"RTMPCamera v1.0.57 TEST";
                label.textColor = [UIColor whiteColor];
                label.textAlignment = NSTextAlignmentCenter;
                label.font = [UIFont boldSystemFontOfSize:20];
                [testView addSubview:label];
                
                [sbWindow addSubview:testView];
                [sbWindow bringSubviewToFront:testView];
                tlog(@"RED TEST VIEW ADDED to SB window");
                
                // Also list all windows for debugging
                for (UIWindow *w in [[UIApplication sharedApplication] windows]) {
                    tlog([NSString stringWithFormat:@"Window: level=%.0f hidden=%d class=%@", w.windowLevel, w.hidden, [w class]]);
                }
            }
        });
    }
}

%dtor {
    // Remove test view
    UIWindow *sbWindow = [[UIApplication sharedApplication] keyWindow];
    UIView *testView = [sbWindow viewWithTag:99957];
    if (testView) { [testView removeFromSuperview]; tlog(@"Test view removed"); }
    tlog(@"Unloaded");
}