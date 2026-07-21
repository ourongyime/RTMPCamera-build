// Tweak.x - RTMPCameraTweak v1.0.50
// SpringBoard global overlay - fixed reload + max window level
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
static NSString *g_lastVideo = nil;

static void tlog(NSString *s) {
    NSLog(@"[RTMPCam][SB] %@", s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@][SB] %@\n", [df stringFromDate:[NSDate date]], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];
           [l writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

static void setupPlayer(void) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:kVideoFile]) { tlog(@"No video file"); return; }
    
    // Check if file actually has video track
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:kVideoFile]];
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (!tracks.count) { tlog(@"No video track in file, skipping"); return; }
    
    // Only recreate if file changed
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kVideoFile error:nil];
    NSString *fileId = [NSString stringWithFormat:@"%@_%lld", attrs[NSFileModificationDate], [attrs[NSFileSize] longLongValue]];
    if ([fileId isEqualToString:g_lastVideo] && g_player) { return; }
    g_lastVideo = fileId;
    
    if (g_playerLayer) { [g_playerLayer removeFromSuperlayer]; g_playerLayer = nil; }
    if (g_loopObserver) { [[NSNotificationCenter defaultCenter] removeObserver:g_loopObserver]; g_loopObserver = nil; }
    [g_player pause]; g_player = nil;
    
    g_player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:kVideoFile]];
    g_player.muted = YES;
    g_playerLayer = [AVPlayerLayer playerLayerWithPlayer:g_player];
    g_playerLayer.frame = [UIScreen mainScreen].bounds;
    g_playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    
    if (g_overlayWindow) {
        [g_overlayWindow.layer addSublayer:g_playerLayer];
        [g_player play];
        tlog(@"Player setup OK");
    }
    
    // Loop
    __weak AVPlayer *wp = g_player;
    g_loopObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        [wp seekToTime:kCMTimeZero]; [wp play];
    }];
}

static void showOverlay(void) {
    if (g_overlayWindow) { g_overlayWindow.hidden = NO; g_active = YES; return; }
    
    CGRect frame = [UIScreen mainScreen].bounds;
    g_overlayWindow = [[UIWindow alloc] initWithFrame:frame];
    g_overlayWindow.windowLevel = 2000; // Above everything
    g_overlayWindow.backgroundColor = [UIColor blackColor];
    g_overlayWindow.userInteractionEnabled = YES;
    
    UIViewController *vc = [[UIViewController alloc] init];
    g_overlayWindow.rootViewController = vc;
    
    // Close button
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(frame.size.width - 55, 55, 44, 44);
    [close setTitle:@"X" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
    close.layer.cornerRadius = 22;
    [close addTarget:[vc class] action:NSSelectorFromString(@"hideOverlaySB") forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:close];
    
    g_overlayWindow.hidden = NO;
    g_active = YES;
    tlog(@"Overlay window created");
}

static void hideOverlay(void) {
    if (g_overlayWindow) g_overlayWindow.hidden = YES;
    g_active = NO;
    [g_player pause];
    tlog(@"Overlay hidden");
}

// Global C function for button target
void hideOverlaySB(void) { hideOverlay(); }

static void reloadAndApply(void) {
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
    if (!c) return;
    BOOL inj = [c[@"videoInjectionEnabled"] boolValue];
    NSInteger src = [c[@"sourceType"] integerValue];
    BOOL shouldShow = inj && src == 2;
    
    if (shouldShow) {
        if (!g_active) showOverlay();
        setupPlayer();
    } else {
        if (g_active) hideOverlay();
    }
}

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        tlog(@"=== v1.0.50 LOADED [SB] ===");
        
        static dispatch_source_t t;
        t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), 1*NSEC_PER_SEC, 0.2*NSEC_PER_SEC);
        dispatch_source_set_event_handler(t, ^{ reloadAndApply(); });
        dispatch_resume(t);
        tlog(@"Polling started (1s)");
    }
}
%dtor {
    if (g_loopObserver) [[NSNotificationCenter defaultCenter] removeObserver:g_loopObserver];
    [g_player pause]; g_player = nil;
    if (g_overlayWindow) { g_overlayWindow.hidden = YES; g_overlayWindow = nil; }
    tlog(@"Unloaded");
}