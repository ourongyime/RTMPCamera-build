// Tweak.x - RTMPCameraTweak v1.0.59
// Video overlay on SpringBoard window - touch passthrough
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>

static NSString *kDir = @"/var/mobile/Documents/rtmpcamera";
static NSString *kCfgFile = @"/var/mobile/Documents/rtmpcamera/config.plist";
static NSString *kVideoFile = @"/var/mobile/Documents/rtmpcamera/current_video.mp4";
static NSString *kLogFile = @"/var/mobile/Documents/rtmpcamera/tweak.log";
static NSString *kLoadedFlag = @"/var/mobile/Documents/rtmpcamera/tweak_loaded";

static UIView *g_overlayView = nil;
static AVPlayer *g_player = nil;
static AVPlayerLayer *g_playerLayer = nil;
static NSInteger g_count = 0;
static NSString *g_lastVideo = nil;
static BOOL g_wasPlaying = NO;

static void tlog(NSString *s) {
    NSLog(@"[SB59] %@", s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@][SB59] %@\n", [df stringFromDate:[NSDate date]], s];
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

static void setupPlayer(UIView *parent) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:kVideoFile]) return;
    
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:kVideoFile]];
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (!tracks.count) return;
    
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kVideoFile error:nil];
    NSString *fid = attrs ? [NSString stringWithFormat:@"%@_%lld", attrs[NSFileModificationDate], [attrs[NSFileSize] longLongValue]] : @"none";
    if ([fid isEqualToString:g_lastVideo] && g_player && g_playerLayer.superlayer) return;
    g_lastVideo = fid;

    [g_player pause];
    if (g_playerLayer) { [g_playerLayer removeFromSuperlayer]; g_playerLayer = nil; }
    g_player = nil;

    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    g_player = [AVPlayer playerWithPlayerItem:item];
    g_player.muted = NO;
    g_playerLayer = [AVPlayerLayer playerLayerWithPlayer:g_player];
    g_playerLayer.frame = parent.bounds;
    g_playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [parent.layer insertSublayer:g_playerLayer atIndex:0];
    [g_player play];
    
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
    BOOL loop = c ? [c[@"loopEnabled"] boolValue] : YES;
    BOOL audio = c ? [c[@"audioInjectionEnabled"] boolValue] : NO;
    g_player.muted = !audio;
    
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        if (loop) { [g_player seekToTime:kCMTimeZero]; [g_player play]; }
    }];
    
    tlog(@"Player started");
}

static void ensureOverlay(void) {
    g_count++;
    
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
    BOOL videoInj = c ? [c[@"videoInjectionEnabled"] boolValue] : YES;
    NSInteger src = c ? [c[@"sourceType"] integerValue] : 2;
    BOOL shouldShow = videoInj && src == 2; // sourceType 2 = local video
    
    UIWindow *sbWindow = getSBWindow();
    if (!sbWindow) return;
    
    if (!shouldShow) {
        if (g_overlayView) { [g_overlayView removeFromSuperview]; g_overlayView = nil; }
        [g_player pause];
        if (g_playerLayer) { [g_playerLayer removeFromSuperlayer]; g_playerLayer = nil; }
        g_wasPlaying = NO;
        return;
    }
    
    UIView *existing = [sbWindow viewWithTag:99959];
    if (!existing) {
        UIView *v = [[UIView alloc] initWithFrame:sbWindow.bounds];
        v.backgroundColor = [UIColor blackColor];
        v.tag = 99959;
        v.userInteractionEnabled = NO; // *** PASS THROUGH TOUCHES ***
        [sbWindow addSubview:v];
        [sbWindow bringSubviewToFront:v];
        g_overlayView = v;
        if (g_count <= 3) tlog(@"Overlay created");
    } else {
        g_overlayView = existing;
        if (existing.superview != sbWindow) {
            [sbWindow addSubview:existing];
            [sbWindow bringSubviewToFront:existing];
        }
    }
    
    // Update player if needed
    BOOL hasPlayer = g_playerLayer && g_playerLayer.superlayer;
    if (g_overlayView && !hasPlayer) {
        setupPlayer(g_overlayView);
    }
    
    if (g_count % 60 == 0) {
        tlog([NSString stringWithFormat:@"Timer #%ld overlay=%@ player=%@", (long)g_count,
              g_overlayView.superview ? @"ON" : @"OFF",
              (g_playerLayer && g_playerLayer.superlayer) ? @"ON" : @"OFF"]);
    }
}

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        tlog(@"=== v1.0.59 LOADED ===");

        static dispatch_source_t timer;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), 0.5*NSEC_PER_SEC, 0.1*NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{ ensureOverlay(); });
        dispatch_resume(timer);
    }
}

%dtor {
    if (g_overlayView) { [g_overlayView removeFromSuperview]; g_overlayView = nil; }
    [g_player pause]; g_player = nil;
    if (g_playerLayer) { [g_playerLayer removeFromSuperlayer]; g_playerLayer = nil; }
    tlog(@"Unloaded");
}