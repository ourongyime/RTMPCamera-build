// Tweak.x - RTMPCameraTweak v1.0.61
// Universal injection + static image camera replacement test
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>

static NSString *kLogFile = @"/var/mobile/Documents/rtmpcamera/tweak.log";
static NSString *kDir = @"/var/mobile/Documents/rtmpcamera";
static NSString *kLoadedFlag = @"/var/mobile/Documents/rtmpcamera/tweak_loaded";
static NSString *kCfgFile = @"/var/mobile/Documents/rtmpcamera/config.plist";
static NSString *kVideoFile = @"/var/mobile/Documents/rtmpcamera/current_video.mp4";

static NSString *g_bundleID = nil;
static BOOL g_cameraHooked = NO;

static void tlog(NSString *s) {
    NSString *tag = g_bundleID ?: @"?";
    NSLog(@"[%@] %@", tag, s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@][%@] %@\n", [df stringFromDate:[NSDate date]], tag, s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil]; [l writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

// Generate a static test image (green frame)
static CMSampleBufferRef createTestFrame(void) {
    static CVPixelBufferRef pixelBuffer = NULL;
    if (!pixelBuffer) {
        NSDictionary *attrs = @{
            (id)kCVPixelBufferWidthKey: @640,
            (id)kCVPixelBufferHeightKey: @480,
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferBytesPerRowAlignmentKey: @64
        };
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pixelBuffer);
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    
    // Fill with green gradient
    for (int y = 0; y < 480; y++) {
        uint8_t *row = base + y * bytesPerRow;
        for (int x = 0; x < 640; x++) {
            uint8_t *pixel = row + x * 4;
            pixel[0] = 0;                    // Blue
            pixel[1] = (uint8_t)(128 + y/4); // Green
            pixel[2] = 0;                    // Red
            pixel[3] = 255;                  // Alpha
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    CMSampleTimingInfo timing = { .duration = CMTimeMake(1, 30), .presentationTimeStamp = CMTimeMake(1, 30), .decodeTimeStamp = kCMTimeInvalid };
    CMVideoFormatDescriptionRef fmtDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &fmtDesc);
    
    CMSampleBufferRef sampleBuf = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, fmtDesc, &timing, &sampleBuf);
    if (fmtDesc) CFRelease(fmtDesc);
    return sampleBuf;
}

// ====== Camera replacement hooks ======
static id g_origDelegate = nil;
static dispatch_queue_t g_origQueue = nil;

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    g_origDelegate = delegate;
    g_origQueue = queue;
    g_cameraHooked = YES;
    tlog([NSString stringWithFormat:@"VDO delegate set: %@", [delegate class]]);
    %orig;
}
%end

// Hook the delegate's callback to replace frames
// We hook NSObject generically so it catches any delegate
%hook NSObject
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (g_cameraHooked) {
        CMSampleBufferRef fakeFrame = createTestFrame();
        if (fakeFrame) {
            %orig(output, fakeFrame, connection);
            CFRelease(fakeFrame);
            return;
        }
    }
    %orig;
}
%end

// ====== SpringBoard overlay (only for SB) ======
static UIView *g_overlayView = nil;
static AVPlayer *g_player = nil;
static AVPlayerLayer *g_playerLayer = nil;
static NSString *g_lastVideo = nil;
static NSInteger g_sbCount = 0;

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

static void sbSetupOverlay(void) {
    g_sbCount++;
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
    if (!c || ![c[@"videoInjectionEnabled"] boolValue] || [c[@"sourceType"] integerValue] != 2) {
        if (g_overlayView) { [g_overlayView removeFromSuperview]; g_overlayView = nil; }
        return;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:kVideoFile]) return;
    
    UIWindow *sbWindow = getSBWindow();
    if (!sbWindow) return;
    
    UIView *v = [sbWindow viewWithTag:99961];
    if (!v) {
        v = [[UIView alloc] initWithFrame:sbWindow.bounds];
        v.backgroundColor = [UIColor blackColor]; v.tag = 99961;
        v.userInteractionEnabled = NO;
        [sbWindow addSubview:v]; g_overlayView = v;
    } else { g_overlayView = v; if (v.superview != sbWindow) [sbWindow addSubview:v]; }
    
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kVideoFile error:nil];
    NSString *fid = attrs ? [NSString stringWithFormat:@"%@_%lld", attrs[NSFileModificationDate], [attrs[NSFileSize] longLongValue]] : @"";
    if (![fid isEqualToString:g_lastVideo] || !g_player || !g_playerLayer.superlayer) {
        g_lastVideo = fid;
        if (g_playerLayer) { [g_playerLayer removeFromSuperlayer]; g_playerLayer = nil; }
        [g_player pause]; g_player = nil;
        AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:kVideoFile]];
        if (![asset tracksWithMediaType:AVMediaTypeVideo].count) return;
        AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
        g_player = [AVPlayer playerWithPlayerItem:item];
        g_player.muted = ![c[@"audioInjectionEnabled"] boolValue];
        g_playerLayer = [AVPlayerLayer playerLayerWithPlayer:g_player];
        g_playerLayer.frame = v.bounds;
        g_playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [v.layer insertSublayer:g_playerLayer atIndex:0];
        [g_player play];
        if ([c[@"loopEnabled"] boolValue]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [g_player seekToTime:kCMTimeZero]; [g_player play]; }];
        }
    }
}

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        
        g_bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        tlog([NSString stringWithFormat:@"=== v1.0.61 INJECTED into %@ ===", g_bundleID]);
        
        if ([g_bundleID isEqualToString:@"com.apple.springboard"]) {
            static dispatch_source_t timer;
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), 1*NSEC_PER_SEC, 0.3*NSEC_PER_SEC);
            dispatch_source_set_event_handler(timer, ^{ @try { sbSetupOverlay(); } @catch(NSException *e) {} });
            dispatch_resume(timer);
        }
    }
}

%dtor {
    if (g_overlayView) { [g_overlayView removeFromSuperview]; g_overlayView = nil; }
    [g_player pause]; g_player = nil;
    if (g_playerLayer) { [g_playerLayer removeFromSuperlayer]; g_playerLayer = nil; }
    tlog(@"Unloaded");
}