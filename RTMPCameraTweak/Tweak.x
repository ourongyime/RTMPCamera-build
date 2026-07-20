// Tweak.x - RTMPCameraTweak v1.0.38
// File-based frame injection: VDO hook + PreviewLayer scanner
// iOS 16.1 + Dopamine RootHide + ElleKit

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <substrate.h>

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

// --- Logging ---
static void tlog(NSString *s) {
    NSLog(@"[RTMPCam] %@", s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];
           [l writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

// --- Config ---
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

// --- Video player ---
static void stopVideo(void) {
    [g_reader cancelReading]; g_reader = nil; g_output = nil;
    @synchronized(g_lock) {
        if (g_lastPB) { CVPixelBufferRelease(g_lastPB); g_lastPB = NULL; }
    }
}

static BOOL startVideo(void) {
    stopVideo(); reloadCfg();
    if (g_sourceType != 2) return NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:kVideoFile]) { tlog(@"Video file missing"); return NO; }
    AVAsset *a = [AVAsset assetWithURL:[NSURL fileURLWithPath:kVideoFile]];
    NSArray *tracks = [a tracksWithMediaType:AVMediaTypeVideo];
    if (!tracks.count) { tlog(@"No video track"); return NO; }
    g_reader = [[AVAssetReader alloc] initWithAsset:a error:nil];
    g_output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0] outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
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

// --- VDO hook ---
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
        if (vs && [_o respondsToSelector:_cmd]) [_o captureOutput:oo didOutputSampleBuffer:vs fromConnection:c];
        if (vs) CFRelease(vs); if (fd) CFRelease(fd); CVPixelBufferRelease(pb);
    } else { if ([_o respondsToSelector:_cmd]) [_o captureOutput:oo didOutputSampleBuffer:s fromConnection:c]; }
}
- (void)captureOutput:(AVCaptureOutput *)o didDropSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection *)c {
    if ([_o respondsToSelector:_cmd]) [_o captureOutput:o didDropSampleBuffer:s fromConnection:c];
}
- (id)forwardingTargetForSelector:(SEL)a { return [_o respondsToSelector:a]?_o:[super forwardingTargetForSelector:a]; }
- (BOOL)respondsToSelector:(SEL)a { return [super respondsToSelector:a]||[_o respondsToSelector:a]; }
@end

static const char k='p';
static void(*orig)(id,SEL,id,dispatch_queue_t);
static void ovr(id s,SEL _c,id d,dispatch_queue_t q) {
    if(d&&[d conformsToProtocol:@protocol(AVCaptureVideoDataOutputSampleBufferDelegate)]){Pxy*p=objc_getAssociatedObject(d,&k);if(!p){p=[[Pxy alloc]initWith:d];objc_setAssociatedObject(d,&k,p,OBJC_ASSOCIATION_RETAIN);}orig(s,_c,p,q);}
    else orig(s,_c,d,q);
}

// --- Preview layer scanner ---
static void scanLayers(CALayer *l, CGImageRef img) {
    if(!l)return;
    if([l isKindOfClass:NSClassFromString(@"AVCaptureVideoPreviewLayer")])l.contents=(__bridge id)img;
    for(CALayer *s in l.sublayers)scanLayers(s,img);
}

%ctor {
    @autoreleasepool {
        g_lock = [NSObject new];
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        tlog(@"=== v1.0.38 LOADED ===");

        // Status
        BOOL dirOk = [[NSFileManager defaultManager] fileExistsAtPath:kDir];
        BOOL cfgOk = [[NSFileManager defaultManager] fileExistsAtPath:kCfgFile];
        BOOL vidOk = [[NSFileManager defaultManager] fileExistsAtPath:kVideoFile];
        tlog([NSString stringWithFormat:@"STATUS: dir=%d cfg=%d video=%d", dirOk, cfgOk, vidOk]);

        // Hook VDO
        Class vdo = NSClassFromString(@"AVCaptureVideoDataOutput");
        if(vdo){ MSHookMessageEx(vdo,@selector(setSampleBufferDelegate:queue:),(IMP)&ovr,(IMP*)&orig); tlog(@"VDO hooked"); }
        else { tlog(@"ERROR: VDO class not found"); }

        // Start video
        reloadCfg();
        if(g_sourceType==2&&g_injectVideo){ startVideo(); }

        // Preview timer
        static dispatch_source_t t;
        t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW,1*NSEC_PER_SEC), (int64_t)(1.0/30.0*NSEC_PER_SEC), (int64_t)(0.005*NSEC_PER_SEC));
        dispatch_source_set_event_handler(t, ^{
            if(!shouldInject())return; if(g_sourceType==2 && !g_reader) startVideo();
            CVPixelBufferRef pb = NULL;
            @synchronized(g_lock) {
                pb = g_lastPB;
                if (pb) CVPixelBufferRetain(pb);
            }
            if(!pb)return;
            CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
            CIContext *ctx = [CIContext contextWithOptions:nil];
            CGImageRef img = [ctx createCGImage:ci fromRect:ci.extent];
            CVPixelBufferRelease(pb);
            if(!img)return;
            NSSet *scenes = [UIApplication sharedApplication].connectedScenes;
            for(id scene in scenes){ if([scene respondsToSelector:@selector(windows)]){ for(UIWindow *w in [scene valueForKey:@"windows"]){ scanLayers(w.layer, img); } } }
            CGImageRelease(img);
        });
        dispatch_resume(t);
        tlog(@"Preview timer started");
        tlog(@"=== READY ===");
    }
}
%dtor { stopVideo(); tlog(@"Unloaded"); }