// Tweak.x - RTMPCameraTweak v1.0.60
// Clean approach: video as wallpaper replacement on SpringBoard
// Uses config.plist to control ON/OFF - does NOT auto-activate
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

static void tlog(NSString *s) {
    NSLog(@"[SB60] %@", s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@][SB60] %@\n", [df stringFromDate:[NSDate date]], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil]; [l writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

static UIWindow *getSBWindow(void) {
    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return nil;
}

static void removeOverlay(void) {
    if (g_playerLayer) { [g_playerLayer removeFromSuperlayer]; g_playerLayer = nil; }
    [g_player pause]; g_player = nil;
    if (g_overlayView) { [g_overlayView removeFromSuperview]; g_overlayView = nil; }
}

static void setupOverlay(void) {
    UIWindow *sbWindow = getSBWindow();
    if (!sbWindow) return;

    // Check config
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
    if (!c) return;
    BOOL videoInj = [c[@"videoInjectionEnabled"] boolValue];
    NSInteger src = [c[@"sourceType"] integerValue];
    if (!videoInj || src != 2) { removeOverlay(); return; }
    
    // Check video file
    if (![[NSFileManager defaultManager] fileExistsAtPath:kVideoFile]) return;
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:kVideoFile]];
    if (![asset tracksWithMediaType:AVMediaTypeVideo].count) return;

    // Create/restore overlay view
    UIView *v = [sbWindow viewWithTag:99960];
    if (!v) {
        v = [[UIView alloc] initWithFrame:sbWindow.bounds];
        v.backgroundColor = [UIColor blackColor];
        v.tag = 99960;
        v.userInteractionEnabled = NO;
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [sbWindow addSubview:v];
        g_overlayView = v;
        tlog(@"Overlay created");
    } else {
        g_overlayView = v;
        if (v.superview != sbWindow) { [sbWindow addSubview:v]; }
    }

    // Player management
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kVideoFile error:nil];
    NSString *fid = attrs ? [NSString stringWithFormat:@"%@_%lld", attrs[NSFileModificationDate], [attrs[NSFileSize] longLongValue]] : @"";
    
    if (![fid isEqualToString:g_lastVideo] || !g_player || !g_playerLayer.superlayer) {
        g_lastVideo = fid;
        if (g_playerLayer) { [g_playerLayer removeFromSuperlayer]; g_playerLayer = nil; }
        [g_player pause]; g_player = nil;
        
        AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
        g_player = [AVPlayer playerWithPlayerItem:item];
        g_player.muted = ![c[@"audioInjectionEnabled"] boolValue];
        g_playerLayer = [AVPlayerLayer playerLayerWithPlayer:g_player];
        g_playerLayer.frame = v.bounds;
        g_playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [v.layer insertSublayer:g_playerLayer atIndex:0];
        [g_player play];
        
        if ([c[@"loopEnabled"] boolValue]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
                [g_player seekToTime:kCMTimeZero]; [g_player play];
            }];
        }
        tlog(@"Video started");
    }
}

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        tlog(@"=== v1.0.60 LOADED ===");

        static dispatch_source_t timer;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), 1*NSEC_PER_SEC, 0.3*NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            g_count++;
            @try { setupOverlay(); }
            @catch (NSException *e) { tlog([NSString stringWithFormat:@"Error: %@", e.reason]); }
            if (g_count % 60 == 0) {
                tlog([NSString stringWithFormat:@"Timer #%ld overlay=%@ video=%@",
                    (long)g_count,
                    g_overlayView.superview ? @"ON" : @"OFF",
                    (g_playerLayer && g_playerLayer.superlayer) ? @"ON" : @"OFF"]);
            }
        });
        dispatch_resume(timer);
    }
}

%dtor {
    removeOverlay();
    tlog(@"Unloaded");
}