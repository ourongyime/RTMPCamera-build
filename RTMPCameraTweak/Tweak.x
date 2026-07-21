// Tweak.x - RTMPCameraTweak v1.0.49
// SpringBoard global overlay approach
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>

static NSString *kDir = @"/var/mobile/Documents/rtmpcamera";
static NSString *kCfgFile = @"/var/mobile/Documents/rtmpcamera/config.plist";
static NSString *kVideoFile = @"/var/mobile/Documents/rtmpcamera/current_video.mp4";
static NSString *kLogFile = @"/var/mobile/Documents/rtmpcamera/tweak.log";
static NSString *kLoadedFlag = @"/var/mobile/Documents/rtmpcamera/tweak_loaded";

static UIWindow *g_overlayWindow = nil;
static AVPlayer *g_player = nil;
static AVPlayerLayer *g_playerLayer = nil;
static BOOL g_active = NO;
static id g_loopObserver = nil;

static void tlog(NSString *s) {
    NSLog(@"[RTMPCam][SpringBoard] %@", s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@][SpringBoard] %@\n", [df stringFromDate:[NSDate date]], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];
           [l writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

static void reloadAndApply(void) {
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
    if (!c) return;
    BOOL inj = [c[@"videoInjectionEnabled"] boolValue];
    NSInteger src = [c[@"sourceType"] integerValue];
    BOOL loop = [c[@"loopEnabled"] boolValue];
    BOOL shouldShow = inj && src == 2;
    
    if (shouldShow && !g_active) {
        // Show overlay
        if (![[NSFileManager defaultManager] fileExistsAtPath:kVideoFile]) { tlog(@"No video file"); return; }
        if (g_overlayWindow) { g_overlayWindow.hidden = NO; [g_player play]; g_active = YES; tlog(@"Overlay shown"); return; }
        
        CGRect frame = [UIScreen mainScreen].bounds;
        g_overlayWindow = [[UIWindow alloc] initWithFrame:frame];
        g_overlayWindow.windowLevel = UIWindowLevelAlert + 100;
        g_overlayWindow.backgroundColor = [UIColor blackColor];
        g_overlayWindow.rootViewController = [[UIViewController alloc] init];
        
        g_player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:kVideoFile]];
        g_player.muted = YES;
        g_playerLayer = [AVPlayerLayer playerLayerWithPlayer:g_player];
        g_playerLayer.frame = frame;
        g_playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [g_overlayWindow.layer addSublayer:g_playerLayer];
        
        // Close button
        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(frame.size.width-60, 50, 50, 50);
        [close setTitle:@"X" forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont boldSystemFontOfSize:24];
        [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        close.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
        close.layer.cornerRadius = 25;
        [close addTarget:[g_overlayWindow.rootViewController class] action:@selector(hideOverlay) forControlEvents:UIControlEventTouchUpInside];
        [g_overlayWindow.rootViewController.view addSubview:close];
        
        g_overlayWindow.hidden = NO;
        [g_player play];
        g_active = YES;
        
        if (loop) {
            __weak AVPlayer *wp = g_player;
            g_loopObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
                [wp seekToTime:kCMTimeZero]; [wp play];
            }];
        }
        tlog(@"Overlay window created");
    } else if (!shouldShow && g_active) {
        [g_player pause]; g_overlayWindow.hidden = YES; g_active = NO;
        tlog(@"Overlay hidden");
    }
}

@interface OverlayController : UIViewController
@end
@implementation OverlayController
+ (void)hideOverlay {
    if (g_overlayWindow) { g_overlayWindow.hidden = YES; g_active = NO; [g_player pause]; tlog(@"User closed overlay"); }
}
@end

// Monitor for config changes via file (polling)
%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        tlog(@"=== v1.0.49 LOADED [SpringBoard] ===");
        
        // Poll config every 2 seconds
        static dispatch_source_t t;
        t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), 2*NSEC_PER_SEC, 0.5*NSEC_PER_SEC);
        dispatch_source_set_event_handler(t, ^{ reloadAndApply(); });
        dispatch_resume(t);
        tlog(@"Polling started");
    }
}
%dtor {
    if (g_overlayWindow) { g_overlayWindow.hidden = YES; g_overlayWindow = nil; }
    if (g_loopObserver) [[NSNotificationCenter defaultCenter] removeObserver:g_loopObserver];
    [g_player pause]; g_player = nil;
    tlog(@"Unloaded");
}