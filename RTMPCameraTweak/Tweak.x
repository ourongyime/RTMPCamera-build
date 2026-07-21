// Tweak.x - RTMPCameraTweak v1.0.52
// SpringBoard global overlay - max window level + robust video handling
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
static NSInteger g_pollCount = 0;

static void tlog(NSString *s) {
    NSLog(@"[SB] %@", s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@][SB] %@\n", [df stringFromDate:[NSDate date]], s];
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

static void setupPlayer(void) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:kVideoFile]) {
        tlog(@"No video file at tweak path");
        return;
    }

    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:kVideoFile]];
    if (!asset) {
        tlog(@"Cannot create AVAsset from video file");
        return;
    }
    
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (!videoTracks.count) {
        tlog(@"No video track in file");
        NSArray *allTracks = [asset tracks];
        tlog([NSString stringWithFormat:@"Total tracks: %lu", (unsigned long)allTracks.count]);
        return;
    }
    
    AVAssetTrack *vt = videoTracks.firstObject;
    tlog([NSString stringWithFormat:@"Video track: size=%.0fx%.0f duration=%.1fs",
          vt.naturalSize.width, vt.naturalSize.height,
          CMTimeGetSeconds(asset.duration)]);

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kVideoFile error:nil];
    NSString *fileId = [NSString stringWithFormat:@"%@_%lld", attrs[NSFileModificationDate], [attrs[NSFileSize] longLongValue]];
    if ([fileId isEqualToString:g_lastVideo] && g_player && g_player.currentItem) {
        return;
    }
    g_lastVideo = fileId;

    if (g_playerLayer) { [g_playerLayer removeFromSuperlayer]; g_playerLayer = nil; }
    if (g_loopObserver) { [[NSNotificationCenter defaultCenter] removeObserver:g_loopObserver]; g_loopObserver = nil; }
    [g_player pause];
    g_player = nil;

    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    if (!item) {
        tlog(@"Cannot create AVPlayerItem");
        return;
    }
    
    g_player = [AVPlayer playerWithPlayerItem:item];
    g_player.muted = NO;
    g_playerLayer = [AVPlayerLayer playerLayerWithPlayer:g_player];
    g_playerLayer.frame = [UIScreen mainScreen].bounds;
    g_playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    g_playerLayer.backgroundColor = [UIColor blackColor].CGColor;

    if (g_overlayWindow) {
        [g_overlayWindow.layer addSublayer:g_playerLayer];
        [g_player play];
        tlog(@"Player started - video playing");
    }

    __weak AVPlayer *wp = g_player;
    g_loopObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                        object:item
                                                                         queue:[NSOperationQueue mainQueue]
                                                                    usingBlock:^(NSNotification *n) {
        NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
        BOOL shouldLoop = c ? [c[@"loopEnabled"] boolValue] : YES;
        if (shouldLoop) {
            [wp seekToTime:kCMTimeZero];
            [wp play];
        }
    }];
}

static void showOverlay(void) {
    if (g_overlayWindow) {
        if (g_overlayWindow.hidden) {
            g_overlayWindow.hidden = NO;
            tlog(@"Overlay unhidden");
        }
        g_active = YES;
        return;
    }

    CGRect frame = [UIScreen mainScreen].bounds;
    g_overlayWindow = [[UIWindow alloc] initWithFrame:frame];
    g_overlayWindow.windowLevel = UIWindowLevelStatusBar + 10000;
    g_overlayWindow.backgroundColor = [UIColor blackColor];
    g_overlayWindow.userInteractionEnabled = YES;
    g_overlayWindow.opaque = YES;

    UIViewController *vc = [[UIViewController alloc] init];
    g_overlayWindow.rootViewController = vc;
    
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(frame.size.width - 55, 55, 44, 44);
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
    tlog([NSString stringWithFormat:@"Overlay window created at level=%.0f", g_overlayWindow.windowLevel]);
}

static void hideOverlay(void) {
    if (g_overlayWindow) {
        g_overlayWindow.hidden = YES;
    }
    g_active = NO;
    [g_player pause];
    tlog(@"Overlay hidden");
}

void hideOverlaySB(void) {
    hideOverlay();
}

static void reloadAndApply(void) {
    g_pollCount++;
    if (g_pollCount % 30 == 0) {
        tlog([NSString stringWithFormat:@"Poll #%ld - active=%d window=%@",
              (long)g_pollCount, g_active,
              g_overlayWindow ? (g_overlayWindow.hidden ? @"hidden" : @"visible") : @"nil"]);
    }

    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
    if (!c) return;

    BOOL videoInj = [c[@"videoInjectionEnabled"] boolValue];
    BOOL audioInj = [c[@"audioInjectionEnabled"] boolValue];
    NSInteger src = [c[@"sourceType"] integerValue];

    // sourceType: 0=RealCamera, 1=RTMP, 2=LocalVideo
    BOOL shouldShow = videoInj && src == 2;

    if (shouldShow) {
        if (!g_active) showOverlay();
        setupPlayer();
        if (g_player) {
            g_player.muted = !audioInj;
        }
    } else {
        if (g_active) hideOverlay();
    }
}

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions:@0777}
                                                        error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        tlog(@"=== v1.0.52 LOADED [SB] ===");
        tlog([NSString stringWithFormat:@"STATUS: dir=%d cfg=%d video=%d",
              [[NSFileManager defaultManager] fileExistsAtPath:kDir],
              [[NSFileManager defaultManager] fileExistsAtPath:kCfgFile],
              [[NSFileManager defaultManager] fileExistsAtPath:kVideoFile]]);

        static dispatch_source_t timer;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                                  1 * NSEC_PER_SEC,
                                  0.2 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            reloadAndApply();
        });
        dispatch_resume(timer);
        tlog(@"Polling timer started (1s interval)");
    }
}

%dtor {
    if (g_loopObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:g_loopObserver];
        g_loopObserver = nil;
    }
    [g_player pause];
    g_player = nil;
    if (g_overlayWindow) {
        g_overlayWindow.hidden = YES;
        g_overlayWindow = nil;
    }
    tlog(@"Unloaded");
}