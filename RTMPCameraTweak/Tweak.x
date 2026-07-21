// Tweak.x - RTMPCameraTweak v1.0.56
// Multi-process: SpringBoard overlay + per-app camera hook
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>

static NSString *kDir = @"/var/mobile/Documents/rtmpcamera";
static NSString *kCfgFile = @"/var/mobile/Documents/rtmpcamera/config.plist";
static NSString *kVideoFile = @"/var/mobile/Documents/rtmpcamera/current_video.mp4";
static NSString *kLogFile = @"/var/mobile/Documents/rtmpcamera/tweak.log";
static NSString *kLoadedFlag = @"/var/mobile/Documents/rtmpcamera/tweak_loaded";

static void vtlog(NSString *tag, NSString *s) {
    NSLog(@"[%@] %@", tag, s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@][%@] %@\n", [df stringFromDate:[NSDate date]], tag, s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [l writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
}

// ========== SpringBoard Overlay ==========
static UIWindow *g_overlayWindow = nil;
static AVPlayer *g_player = nil;
static AVPlayerLayer *g_playerLayer = nil;
static BOOL g_active = NO;
static id g_loopObserver = nil;
static NSString *g_lastVideo = nil;
static NSInteger g_pollCount = 0;

static void setupPlayer(void) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:kVideoFile]) return;
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:kVideoFile]];
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (!videoTracks.count) return;
    
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kVideoFile error:nil];
    NSString *fileId = attrs ? [NSString stringWithFormat:@"%@_%lld", attrs[NSFileModificationDate], [attrs[NSFileSize] longLongValue]] : @"none";
    if ([fileId isEqualToString:g_lastVideo] && g_player && g_player.currentItem && g_playerLayer.superlayer) return;
    g_lastVideo = fileId;

    [g_player pause];
    if (g_playerLayer) { [g_playerLayer removeFromSuperlayer]; g_playerLayer = nil; }
    if (g_loopObserver) { [[NSNotificationCenter defaultCenter] removeObserver:g_loopObserver]; g_loopObserver = nil; }
    g_player = nil;

    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    g_player = [AVPlayer playerWithPlayerItem:item];
    g_player.muted = NO;
    g_playerLayer = [AVPlayerLayer playerLayerWithPlayer:g_player];
    g_playerLayer.frame = [UIScreen mainScreen].bounds;
    g_playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

    if (g_overlayWindow && g_overlayWindow.rootViewController) {
        UIView *rootView = g_overlayWindow.rootViewController.view;
        rootView.backgroundColor = [UIColor blackColor];
        [rootView.layer insertSublayer:g_playerLayer atIndex:0];
        [g_player play];
    }

    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
    BOOL loop = c ? [c[@"loopEnabled"] boolValue] : YES;
    __weak AVPlayer *wp = g_player;
    g_loopObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        if (loop) { [wp seekToTime:kCMTimeZero]; [wp play]; }
    }];
}

static void showOverlay(void) {
    if (g_overlayWindow) { if (g_overlayWindow.hidden) g_overlayWindow.hidden = NO; g_active = YES; return; }
    CGRect frame = [UIScreen mainScreen].bounds;
    g_overlayWindow = [[UIWindow alloc] initWithFrame:frame];
    g_overlayWindow.windowLevel = UIWindowLevelStatusBar + 5000;
    g_overlayWindow.backgroundColor = [UIColor blackColor];
    g_overlayWindow.userInteractionEnabled = YES;
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor blackColor];
    g_overlayWindow.rootViewController = vc;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(frame.size.width - 55, 50, 44, 44);
    [close setTitle:@"X" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
    close.layer.cornerRadius = 22;
    [close addTarget:vc action:NSSelectorFromString(@"hideOverlaySB") forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:close];
    g_overlayWindow.hidden = NO;
    [g_overlayWindow makeKeyAndVisible];
    g_active = YES;
    vtlog(@"SB", @"Overlay created level=6000");
}

static void hideOverlay(void) {
    if (g_overlayWindow) g_overlayWindow.hidden = YES;
    g_active = NO; [g_player pause];
}

void hideOverlaySB(void) { hideOverlay(); }

static void sbReload(void) {
    g_pollCount++;
    if (g_pollCount % 60 == 0) {
        vtlog(@"SB", [NSString stringWithFormat:@"Poll #%ld active=%d playerLayer=%@", (long)g_pollCount, g_active, (g_playerLayer && g_playerLayer.superlayer) ? @"YES" : @"NO"]);
    }
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
    if (!c) return;
    BOOL videoInj = [c[@"videoInjectionEnabled"] boolValue];
    NSInteger src = [c[@"sourceType"] integerValue];
    BOOL shouldShow = videoInj && src == 2;
    if (shouldShow) { if (!g_active) showOverlay(); setupPlayer(); if (g_player) g_player.muted = ![c[@"audioInjectionEnabled"] boolValue]; }
    else { if (g_active) hideOverlay(); if (g_playerLayer) { [g_playerLayer removeFromSuperlayer]; g_playerLayer = nil; } [g_player pause]; g_player = nil; }
}

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        
        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            // SpringBoard: overlay mode
            vtlog(@"SB", @"=== v1.0.56 LOADED ===");
            static dispatch_source_t timer;
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), 1*NSEC_PER_SEC, 0.2*NSEC_PER_SEC);
            dispatch_source_set_event_handler(timer, ^{ sbReload(); });
            dispatch_resume(timer);
            
        } else {
            // Per-app: camera hook mode
            vtlog(bundleID, @"=== v1.0.56 INJECTED ===");
            // Hook will be added below via %hook
        }
    }
}

// ========== Per-App Camera Hook ==========
// Only compiled for non-SpringBoard processes
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    vtlog(bid, [NSString stringWithFormat:@"VDO setDelegate: %@", [sampleBufferDelegate class]]);
    %orig;
}
%end

%hook AVCaptureSession
- (void)startRunning {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    vtlog(bid, @"AVCaptureSession startRunning");
    %orig;
}
%end

%dtor {
    if (g_loopObserver) { [[NSNotificationCenter defaultCenter] removeObserver:g_loopObserver]; g_loopObserver = nil; }
    if (g_playerLayer) { [g_playerLayer removeFromSuperlayer]; g_playerLayer = nil; }
    [g_player pause]; g_player = nil;
    if (g_overlayWindow) { g_overlayWindow.hidden = YES; g_overlayWindow = nil; }
}