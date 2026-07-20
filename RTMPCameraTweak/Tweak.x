// Tweak.x - RTMPCameraTweak v1.0.23
// Tweak handles video playback directly - no IPC frame transfer needed
// App is just the control panel (writes config plist + copies video)
// iOS 16.1 + Dopamine RootHide + ElleKit

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <CoreImage/CoreImage.h>
#import <pthread.h>

// ============================================================
// Paths
// ============================================================
static NSString *kDir        = @"/tmp/rtmpcamera";
static NSString *kCfgFile    = @"/tmp/rtmpcamera/config.plist";
static NSString *kVideoFile  = @"/tmp/rtmpcamera/current_video.mp4";
static NSString *kLoadedFlag = @"/tmp/rtmpcamera/tweak_loaded";
static NSString *kLogFile    = @"/tmp/rtmpcamera/tweak.log";

// ============================================================
// State
// ============================================================
static AVAssetReader        *g_reader = nil;
static AVAssetReaderTrackOutput *g_output = nil;
static BOOL                  g_loop = YES;
static BOOL                  g_injectVideo = YES;
static BOOL                  g_injectAudio = NO;
static NSInteger             g_sourceType = 0; // 0=real, 1=rtmp, 2=local
static CVPixelBufferRef      g_lastPixelBuffer = NULL;
static pthread_mutex_t       g_pbMutex = PTHREAD_MUTEX_INITIALIZER;
static NSDate               *g_lastCfgCheck = nil;

// ============================================================
// Logging
// ============================================================
static void tlog(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSLog(@"[RTMPCam] %@", m);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *l = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], m];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];
           [l writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

// ============================================================
// Config reader
// ============================================================
static void reloadConfig(void) {
    if (g_lastCfgCheck && [[NSDate date] timeIntervalSinceDate:g_lastCfgCheck] < 0.5) return;
    g_lastCfgCheck = [NSDate date];
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
    if (!c) return;
    g_sourceType   = [c[@"sourceType"] integerValue];
    g_injectVideo  = [c[@"videoInjectionEnabled"] boolValue];
    g_injectAudio  = [c[@"audioInjectionEnabled"] boolValue];
    g_loop         = [c[@"loopEnabled"] boolValue];
}

static BOOL shouldInject(void) {
    reloadConfig();
    return g_injectVideo && g_sourceType != 0;
}

// ============================================================
// Video playback (tweak handles this directly!)
// ============================================================
static void stopVideoPlayback(void) {
    [g_reader cancelReading];
    g_reader = nil; g_output = nil;
    pthread_mutex_lock(&g_pbMutex);
    if (g_lastPixelBuffer) { CVPixelBufferRelease(g_lastPixelBuffer); g_lastPixelBuffer = NULL; }
    pthread_mutex_unlock(&g_pbMutex);
}

static BOOL startVideoPlayback(void) {
    stopVideoPlayback();
    reloadConfig();
    
    if (g_sourceType != 2) return NO; // only local video mode
    
    NSURL *url = [NSURL fileURLWithPath:kVideoFile];
    if (![[NSFileManager defaultManager] fileExistsAtPath:kVideoFile]) {
        tlog(@"Video file not found: %@", kVideoFile);
        return NO;
    }
    
    NSError *err = nil;
    AVAsset *asset = [AVAsset assetWithURL:url];
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (!tracks.count) { tlog(@"No video track"); return NO; }
    
    g_reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (!g_reader || err) { tlog(@"Reader init failed: %@", err); return NO; }
    
    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    g_output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0] outputSettings:settings];
    if (![g_reader canAddOutput:g_output]) { tlog(@"Cannot add output"); stopVideoPlayback(); return NO; }
    [g_reader addOutput:g_output];
    
    if (![g_reader startReading]) { tlog(@"Start reading failed: %@", g_reader.error); stopVideoPlayback(); return NO; }
    
    tlog(@"Video playback started: %@", [kVideoFile lastPathComponent]);
    return YES;
}

static CVPixelBufferRef copyNextVideoFrame(void) {
    reloadConfig();
    if (!g_injectVideo || g_sourceType != 2) return NULL;
    
    if (!g_reader || g_reader.status == AVAssetReaderStatusCompleted || g_reader.status == AVAssetReaderStatusFailed) {
        if (g_loop && g_sourceType == 2) {
            tlog(@"Looping video...");
            if (!startVideoPlayback()) return NULL;
        } else {
            return NULL;
        }
    }
    
    if (!g_output) return NULL;
    
    CMSampleBufferRef sb = [g_output copyNextSampleBuffer];
    if (!sb) {
        if (g_reader.status == AVAssetReaderStatusCompleted && g_loop) {
            tlog(@"Video ended, looping...");
            if (startVideoPlayback()) {
                sb = [g_output copyNextSampleBuffer];
            }
        }
        if (!sb) return NULL;
    }
    
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (pb) CVPixelBufferRetain(pb);
    CFRelease(sb);
    
    // Cache latest frame for preview layer
    pthread_mutex_lock(&g_pbMutex);
    if (g_lastPixelBuffer) CVPixelBufferRelease(g_lastPixelBuffer);
    g_lastPixelBuffer = pb ? CVPixelBufferRetain(pb) : NULL;
    pthread_mutex_unlock(&g_pbMutex);
    
    return pb; // caller must release
}

// ============================================================
// Create CGImage from cached pixel buffer (for preview layer)
// ============================================================
static CGImageRef createCGImageFromLatestFrame(void) {
    pthread_mutex_lock(&g_pbMutex);
    if (!g_lastPixelBuffer) { pthread_mutex_unlock(&g_pbMutex); return NULL; }
    CVPixelBufferRetain(g_lastPixelBuffer);
    CVPixelBufferRef pb = g_lastPixelBuffer;
    pthread_mutex_unlock(&g_pbMutex);
    
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef img = [ctx createCGImage:ci fromRect:ci.extent];
    CVPixelBufferRelease(pb);
    return img;
}

// ============================================================
// Preview layer scanner
// ============================================================
static void scanLayers(CALayer *l, CGImageRef img) {
    if (!l) return;
    if ([l isKindOfClass:NSClassFromString(@"AVCaptureVideoPreviewLayer")]) {
        l.contents = (__bridge id)img;
    }
    for (CALayer *s in l.sublayers) scanLayers(s, img);
}

static void updatePreviews(CGImageRef img) {
    NSSet *scenes = [UIApplication sharedApplication].connectedScenes;
    for (id scene in scenes) {
        if ([scene respondsToSelector:@selector(windows)]) {
            for (UIWindow *w in [scene valueForKey:@"windows"]) {
                scanLayers(w.layer, img);
            }
        }
    }
}

// ============================================================
// Create CMSampleBuffer from video (for VideoDataOutput hook)
// ============================================================
static CMSampleBufferRef createFrameForVDO(CMTime ts) {
    CVPixelBufferRef pb = copyNextVideoFrame();
    if (!pb) return NULL;
    
    CMVideoFormatDescriptionRef fd = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fd);
    CMSampleTimingInfo ti = { .duration=CMTimeMake(1,30), .presentationTimeStamp=ts, .decodeTimeStamp=kCMTimeInvalid };
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fd, &ti, &sb);
    if (fd) CFRelease(fd);
    CVPixelBufferRelease(pb);
    return sb;
}

// ============================================================
// Proxy Delegate for AVCaptureVideoDataOutput
// ============================================================
@interface RTMPProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic,weak) id orig;
@end
@implementation RTMPProxy
- (instancetype)initWithOrig:(id)d { if(self=[super init])_orig=d; return self; }
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection *)c {
    if (!shouldInject()) { if ([_orig respondsToSelector:_cmd]) [_orig captureOutput:o didOutputSampleBuffer:s fromConnection:c]; return; }
    CMTime ts = CMSampleBufferGetPresentationTimeStamp(s);
    CMSampleBufferRef v = createFrameForVDO(ts);
    if (v) { if ([_orig respondsToSelector:_cmd]) [_orig captureOutput:o didOutputSampleBuffer:v fromConnection:c]; CFRelease(v); }
    else   { if ([_orig respondsToSelector:_cmd]) [_orig captureOutput:o didOutputSampleBuffer:s fromConnection:c]; }
}
- (void)captureOutput:(AVCaptureOutput *)o didDropSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection *)c {
    if ([_orig respondsToSelector:_cmd]) [_orig captureOutput:o didDropSampleBuffer:s fromConnection:c];
}
- (id)forwardingTargetForSelector:(SEL)a { return [_orig respondsToSelector:a] ? _orig : [super forwardingTargetForSelector:a]; }
- (BOOL)respondsToSelector:(SEL)a { return [super respondsToSelector:a] || [_orig respondsToSelector:a]; }
@end

// ============================================================
// VideoDataOutput hook
// ============================================================
static const char kP = 'p';
static void (*orig_vdo)(id,SEL,id,dispatch_queue_t);
static void ovr_vdo(id s,SEL _c,id d,dispatch_queue_t q) {
    if (d && [d conformsToProtocol:@protocol(AVCaptureVideoDataOutputSampleBufferDelegate)]) {
        RTMPProxy *p = objc_getAssociatedObject(d, &kP);
        if (!p) { p = [[RTMPProxy alloc] initWithOrig:d]; objc_setAssociatedObject(d, &kP, p, OBJC_ASSOCIATION_RETAIN); }
        orig_vdo(s,_c,p,q);
    } else orig_vdo(s,_c,d,q);
}

// ============================================================
// %ctor
// ============================================================
%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        tlog(@"=== v1.0.23 pid=%d ===", getpid());
        
        // Hook VDO
        Class vdo = NSClassFromString(@"AVCaptureVideoDataOutput");
        if (vdo) {
            MSHookMessageEx(vdo, @selector(setSampleBufferDelegate:queue:), (IMP)&ovr_vdo, (IMP*)&orig_vdo);
            tlog(@"Hooked VDO OK");
        }
        
        // Read config and start video if needed
        reloadConfig();
        if (g_sourceType == 2 && g_injectVideo) {
            startVideoPlayback();
        }
        
        // Preview timer
        static dispatch_source_t timer;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC),
                                  (int64_t)(1.0/30.0*NSEC_PER_SEC), (int64_t)(0.005*NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            if (!shouldInject()) return;
            CGImageRef img = createCGImageFromLatestFrame();
            if (!img) return;
            updatePreviews(img);
            CGImageRelease(img);
        });
        dispatch_resume(timer);
        tlog(@"Ready - VDO hooked + preview timer active");
    }
}

%dtor {
    stopVideoPlayback();
    tlog(@"Unloaded");
}