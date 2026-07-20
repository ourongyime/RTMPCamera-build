// Tweak.x - RTMPCameraTweak v1.0.39
// Deep fix: retroactive VDO hooking + PreviewLayer overlay
// iOS 16.1 + Dopamine RootHide + ElleKit

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <substrate.h>
#import <objc/runtime.h>

static NSString *kDir = @"/var/mobile/Documents/rtmpcamera";
static NSString *kLoadedFlag = @"/var/mobile/Documents/rtmpcamera/tweak_loaded";
static NSString *kLogFile = @"/var/mobile/Documents/rtmpcamera/tweak.log";
static NSString *kCfgFile = @"/var/mobile/Documents/rtmpcamera/config.plist";
static NSString *kVideoFile = @"/var/mobile/Documents/rtmpcamera/current_video.mp4";

static AVAssetReader *g_reader = nil;
static AVAssetReaderTrackOutput *g_output = nil;
static BOOL g_loop = YES;
static BOOL g_injectVideo = YES;
static NSInteger g_sourceType = 0;
static CVPixelBufferRef g_lastPB = NULL;
static NSObject *g_lock = nil;
static NSDate *g_lastCfg = nil;

// Logging
static void tlog(NSString *s) {
    NSLog(@"[RTMPCam] %@", s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];
           [l writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

// Config
static void reloadCfg(void) {
    if (g_lastCfg && -[g_lastCfg timeIntervalSinceNow] < 0.5) return;
    g_lastCfg = [NSDate date];
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
    if (!c) return;
    g_sourceType = [c[@"sourceType"] integerValue];
    g_injectVideo = [c[@"videoInjectionEnabled"] boolValue];
    g_loop = [c[@"loopEnabled"] boolValue];
}
static BOOL shouldInject(void) { reloadCfg(); return g_injectVideo && g_sourceType != 0; }

// Video player
static void stopVideo(void) {
    [g_reader cancelReading]; g_reader = nil; g_output = nil;
    @synchronized(g_lock) { if (g_lastPB) { CVPixelBufferRelease(g_lastPB); g_lastPB = NULL; } }
}
static BOOL startVideo(void) {
    stopVideo(); reloadCfg();
    if (g_sourceType != 2) return NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:kVideoFile]) { tlog(@"Video file missing"); return NO; }
    AVAsset *a = [AVAsset assetWithURL:[NSURL fileURLWithPath:kVideoFile]];
    NSArray *tracks = [a tracksWithMediaType:AVMediaTypeVideo];
    if (!tracks.count) { tlog(@"No video track"); return NO; }
    NSError *err = nil;
    g_reader = [[AVAssetReader alloc] initWithAsset:a error:&err];
    if (err) { tlog([NSString stringWithFormat:@"Reader error: %@", err]); return NO; }
    g_output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0] outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    if (![g_reader canAddOutput:g_output]) { tlog(@"Cannot add output"); g_reader = nil; return NO; }
    [g_reader addOutput:g_output];
    [g_reader startReading];
    tlog(@"Video playback started");
    return YES;
}
static CVPixelBufferRef nextFrame(void) {
    if (!shouldInject() || g_sourceType != 2) return NULL;
    if (!g_reader || g_reader.status == AVAssetReaderStatusCompleted || g_reader.status == AVAssetReaderStatusFailed) {
        if (g_loop) startVideo();
        if (!g_reader) return NULL;
    }
    CMSampleBufferRef sb = [g_output copyNextSampleBuffer];
    if (!sb) { if (g_loop) { startVideo(); sb = [g_output copyNextSampleBuffer]; } if (!sb) return NULL; }
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb); if (pb) CVPixelBufferRetain(pb); CFRelease(sb);
    @synchronized(g_lock) {
        if (g_lastPB) CVPixelBufferRelease(g_lastPB);
        g_lastPB = pb ? CVPixelBufferRetain(pb) : NULL;
    }
    return pb;
}

// --- VDO Proxy ---
@interface Pxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic,weak) id o;
@end
@implementation Pxy
- (instancetype)initWith:(id)d { if(self=[super init])_o=d; return self; }
- (void)captureOutput:(AVCaptureOutput *)oo didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection *)c {
    CVPixelBufferRef pb = nextFrame();
    if (pb) {
        CMFormatDescriptionRef fd = NULL; CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fd);
        CMSampleTimingInfo ti = {.duration=CMTimeMake(1,30),.presentationTimeStamp=CMSampleBufferGetPresentationTimeStamp(s),.decodeTimeStamp=kCMTimeInvalid};
        CMSampleBufferRef vs = NULL; CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fd, &ti, &vs);
        if (vs && [_o respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)])
            [_o captureOutput:oo didOutputSampleBuffer:vs fromConnection:c];
        if (vs) CFRelease(vs); if (fd) CFRelease(fd); CVPixelBufferRelease(pb);
    } else {
        if ([_o respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)])
            [_o captureOutput:oo didOutputSampleBuffer:s fromConnection:c];
    }
}
- (void)captureOutput:(AVCaptureOutput *)o didDropSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection *)c {
    if ([_o respondsToSelector:_cmd]) [_o captureOutput:o didDropSampleBuffer:s fromConnection:c];
}
- (id)forwardingTargetForSelector:(SEL)a { return [_o respondsToSelector:a]?_o:[super forwardingTargetForSelector:a]; }
- (BOOL)respondsToSelector:(SEL)a { return [super respondsToSelector:a]||[_o respondsToSelector:a]; }
@end

static const char k='p';
static void(*orig_setDelegate)(id,SEL,id,dispatch_queue_t);
static void ovr_setDelegate(id s,SEL _c,id d,dispatch_queue_t q) {
    if(d&&[d conformsToProtocol:@protocol(AVCaptureVideoDataOutputSampleBufferDelegate)]){
        Pxy*p=objc_getAssociatedObject(d,&k);if(!p){p=[[Pxy alloc]initWith:d];objc_setAssociatedObject(d,&k,p,OBJC_ASSOCIATION_RETAIN);}
        orig_setDelegate(s,_c,p,q);
    } else orig_setDelegate(s,_c,d,q);
}

// Retroactive: proxy delegates on existing VDO outputs
static void proxyExistingVDO(AVCaptureSession *session) {
    if (!session) return;
    NSArray *outputs = [session outputs];
    for (AVCaptureOutput *output in outputs) {
        if (![output isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")]) continue;
        id delegate = [output performSelector:@selector(sampleBufferDelegate)];
        dispatch_queue_t queue = (__bridge dispatch_queue_t)[output performSelector:@selector(sampleBufferCallbackQueue)];
        if (delegate && [delegate conformsToProtocol:@protocol(AVCaptureVideoDataOutputSampleBufferDelegate)]) {
            Pxy *p = objc_getAssociatedObject(delegate, &k);
            if (!p) { p = [[Pxy alloc] initWith:delegate]; objc_setAssociatedObject(delegate, &k, p, OBJC_ASSOCIATION_RETAIN); }
            [output setSampleBufferDelegate:p queue:queue];
            tlog(@"Retroactively hooked VDO delegate");
        }
    }
}

// --- Hook AVCaptureSession startRunning ---
static void(*orig_startRunning)(id,SEL);
static void ovr_startRunning(id self,SEL _c) {
    orig_startRunning(self,_c);
    if (shouldInject()) {
        proxyExistingVDO(self);
        tlog(@"Session started - hooked outputs");
    }
}

// --- Hook AVCaptureSession addOutput ---
static void(*orig_addOutput)(id,SEL,id);
static void ovr_addOutput(id self,SEL _c,id output) {
    orig_addOutput(self,_c,output);
    if (!shouldInject()) return;
    if ([output isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")]) {
        // Delay to let the app set the delegate
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            id delegate = [output performSelector:@selector(sampleBufferDelegate)];
            dispatch_queue_t queue = (__bridge dispatch_queue_t)[output performSelector:@selector(sampleBufferCallbackQueue)];
            if (delegate) {
                Pxy *p = objc_getAssociatedObject(delegate, &k);
                if (!p) { p = [[Pxy alloc] initWith:delegate]; objc_setAssociatedObject(delegate, &k, p, OBJC_ASSOCIATION_RETAIN); }
                [output setSampleBufferDelegate:p queue:queue];
                tlog(@"New VDO output hooked");
            }
        });
    }
}

// --- PreviewLayer overlay ---
static NSMutableSet *g_overlayLayers = nil;

static AVPlayer *g_overlayPlayer = nil;
static AVPlayerLayer *g_overlayPlayerLayer = nil;
static id g_overlayObserver = nil;

static void setupOverlayPlayer(void) {
    if (g_overlayPlayer) return;
    NSURL *url = [NSURL fileURLWithPath:kVideoFile];
    if (![[NSFileManager defaultManager] fileExistsAtPath:kVideoFile]) return;
    g_overlayPlayer = [AVPlayer playerWithURL:url];
    g_overlayPlayer.muted = YES;
    g_overlayPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:g_overlayPlayer];
    g_overlayPlayerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    g_overlayPlayerLayer.hidden = YES;
    // Loop
    __weak AVPlayer *wp = g_overlayPlayer;
    g_overlayObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        if (g_loop && wp) { [wp seekToTime:kCMTimeZero]; [wp play]; }
    }];
    tlog(@"Overlay player created");
}

static void findAndOverlayPreviewLayers(void) {
    if (!shouldInject() || g_sourceType != 2) return;
    if (!g_overlayLayers) g_overlayLayers = [NSMutableSet set];
    setupOverlayPlayer();
    
    NSSet *scenes = [UIApplication sharedApplication].connectedScenes;
    for (id scene in scenes) {
        if (![scene respondsToSelector:@selector(windows)]) continue;
        for (UIWindow *w in [scene valueForKey:@"windows"]) {
            scanLayerForPreview(w.layer, 0);
        }
    }
}

static void scanLayerForPreview(CALayer *layer, int depth) {
    if (!layer || depth > 20) return;
    if ([layer isKindOfClass:NSClassFromString(@"AVCaptureVideoPreviewLayer")]) {
        if (![g_overlayLayers containsObject:layer]) {
            [g_overlayLayers addObject:layer];
            // Add our player layer on top
            g_overlayPlayerLayer.frame = layer.bounds;
            g_overlayPlayerLayer.hidden = NO;
            [layer addSublayer:g_overlayPlayerLayer];
            [g_overlayPlayer play];
            tlog(@"PreviewLayer overlay added");
        }
    }
    for (CALayer *s in layer.sublayers) scanLayerForPreview(s, depth+1);
}

// --- Constructor ---
%ctor {
    @autoreleasepool {
        g_lock = [NSObject new];
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        tlog(@"=== v1.0.39 LOADED ===");

        BOOL dirOk = [[NSFileManager defaultManager] fileExistsAtPath:kDir];
        BOOL cfgOk = [[NSFileManager defaultManager] fileExistsAtPath:kCfgFile];
        BOOL vidOk = [[NSFileManager defaultManager] fileExistsAtPath:kVideoFile];
        tlog([NSString stringWithFormat:@"STATUS: dir=%d cfg=%d video=%d", dirOk, cfgOk, vidOk]);

        // Hook VDO setDelegate
        Class vdo = NSClassFromString(@"AVCaptureVideoDataOutput");
        if (vdo) {
            MSHookMessageEx(vdo, @selector(setSampleBufferDelegate:queue:), (IMP)&ovr_setDelegate, (IMP*)&orig_setDelegate);
            tlog(@"VDO setDelegate hooked");
        } else { tlog(@"ERROR: VDO class not found"); }

        // Hook AVCaptureSession startRunning
        Class sess = NSClassFromString(@"AVCaptureSession");
        if (sess) {
            MSHookMessageEx(sess, @selector(startRunning), (IMP)&ovr_startRunning, (IMP*)&orig_startRunning);
            MSHookMessageEx(sess, @selector(addOutput:), (IMP)&ovr_addOutput, (IMP*)&orig_addOutput);
            tlog(@"AVCaptureSession hooked");
        }

        // Load config and start video
        reloadCfg();
        if (g_sourceType == 2 && g_injectVideo) { startVideo(); }

        // Preview overlay timer
        static dispatch_source_t t;
        t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), (int64_t)(1.0*NSEC_PER_SEC), (int64_t)(0.1*NSEC_PER_SEC));
        dispatch_source_set_event_handler(t, ^{
            if (!shouldInject()) { return; }
            if (g_sourceType == 2 && !g_reader) startVideo();
            findAndOverlayPreviewLayers();
            // Also update frame buffer for VDO injection
            nextFrame();
        });
        dispatch_resume(t);
        tlog(@"=== READY ===");
    }
}

%dtor {
    stopVideo();
    if (g_overlayObserver) [[NSNotificationCenter defaultCenter] removeObserver:g_overlayObserver];
    [g_overlayPlayer pause]; g_overlayPlayer = nil;
    [g_overlayPlayerLayer removeFromSuperlayer]; g_overlayPlayerLayer = nil;
    tlog(@"Unloaded");
}