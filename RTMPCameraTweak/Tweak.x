// Tweak.x - RTMPCameraTweak v1.0.22
// /tmp/ based: global writable path, window-scanning preview injection
// iOS 16.1 + Dopamine RootHide + ElleKit

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// ============================================================
// Paths in /tmp/ (global writable on iOS)
// ============================================================
static NSString *kDir       = @"/tmp/rtmpcamera";
static NSString *kFrameFile = @"/tmp/rtmpcamera/frame.raw";
static NSString *kMetaFile  = @"/tmp/rtmpcamera/meta.plist";
static NSString *kLogFile   = @"/tmp/rtmpcamera/tweak.log";
static NSString *kLoadedFlag= @"/tmp/rtmpcamera/tweak_loaded";

// ============================================================
// Logging (writes to /tmp/)
// ============================================================
static void tlog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[RTMPCam] %@", msg);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];
        [line writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
}

// ============================================================
// Meta (cached)
// ============================================================
static NSDictionary *g_meta = nil;
static NSDate *g_metaTime = nil;

static NSDictionary *readMeta(void) {
    if (g_metaTime && [[NSDate date] timeIntervalSinceDate:g_metaTime] < 0.3 && g_meta) return g_meta;
    g_meta = [NSDictionary dictionaryWithContentsOfFile:kMetaFile];
    g_metaTime = [NSDate date];
    return g_meta;
}

static BOOL shouldInject(void) {
    NSDictionary *m = readMeta();
    if (!m) return NO;
    if (![m[@"videoInjectionEnabled"] boolValue]) return NO;
    if ([m[@"sourceType"] integerValue] == 0) return NO;
    return YES;
}

// ============================================================
// Create CGImage from /tmp/rtmpcamera/frame.raw
// ============================================================
static CGImageRef createCGImage(void) {
    NSDictionary *m = readMeta();
    NSInteger w = [m[@"frameWidth"] integerValue] ?: 640;
    NSInteger h = [m[@"frameHeight"] integerValue] ?: 480;
    NSInteger bpr = [m[@"frameBytesPerRow"] integerValue] ?: (w * 4);
    
    NSData *raw = [NSData dataWithContentsOfFile:kFrameFile];
    if (!raw || raw.length == 0) return NULL;
    
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)raw);
    CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)bpr,
        cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
        dp, NULL, NO, kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    return img;
}

// ============================================================
// Window/layer scanner: find all AVCaptureVideoPreviewLayer
// ============================================================
static void scanAndInjectLayers(CALayer *layer, CGImageRef img) {
    if (!layer) return;
    if ([layer isKindOfClass:NSClassFromString(@"AVCaptureVideoPreviewLayer")]) {
        layer.contents = (__bridge id)img;
    }
    for (CALayer *sub in layer.sublayers) {
        scanAndInjectLayers(sub, img);
    }
}

static void updateAllPreviews(CGImageRef img) {
    // Get all windows from all scenes
    NSArray *scenes = nil;
    if (@available(iOS 13.0, *)) {
        NSSet *ss = [UIApplication sharedApplication].connectedScenes;
        NSMutableArray *ws = [NSMutableArray array];
        for (id scene in ss) {
            if ([scene respondsToSelector:@selector(windows)]) {
                [ws addObjectsFromArray:[scene valueForKey:@"windows"]];
            }
        }
        for (UIWindow *w in ws) {
            scanAndInjectLayers(w.layer, img);
        }
    }
    // Fallback
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        scanAndInjectLayers(w.layer, img);
    }
}

// ============================================================
// Create CMSampleBuffer from file (VideoDataOutput path)
// ============================================================
static CMSampleBufferRef createFrameFromFile(CMTime ts) {
    if (!shouldInject()) return NULL;
    NSDictionary *m = readMeta();
    NSInteger w = [m[@"frameWidth"] integerValue] ?: 640;
    NSInteger h = [m[@"frameHeight"] integerValue] ?: 480;
    NSInteger bpr = [m[@"frameBytesPerRow"] integerValue] ?: (w * 4);
    NSData *raw = [NSData dataWithContentsOfFile:kFrameFile];
    if (!raw || raw.length == 0) return NULL;
    
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferBytesPerRowAlignmentKey: @(64),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)w, (size_t)h,
        kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst = CVPixelBufferGetBaseAddress(pb);
    size_t dstBPR = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t *src = raw.bytes;
    size_t cp = MIN(dstBPR, (size_t)bpr);
    for (size_t r = 0; r < (size_t)h; r++) memcpy(dst + r*dstBPR, src + r*(size_t)bpr, cp);
    CVPixelBufferUnlockBaseAddress(pb, 0);
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
    CMTime ts = CMSampleBufferGetPresentationTimeStamp(s);
    CMSampleBufferRef v = createFrameFromFile(ts);
    if (v) { if ([_orig respondsToSelector:_cmd]) [_orig captureOutput:o didOutputSampleBuffer:v fromConnection:c]; CFRelease(v); }
    else { if ([_orig respondsToSelector:_cmd]) [_orig captureOutput:o didOutputSampleBuffer:s fromConnection:c]; }
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
// %ctor - INIT
// ============================================================
%ctor {
    @autoreleasepool {
        // Load indicator (touch this file if tweak loads)
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        
        tlog(@"=== v1.0.22 loading pid=%d ===", getpid());
        
        // Hook VideoDataOutput
        Class vdo = NSClassFromString(@"AVCaptureVideoDataOutput");
        if (vdo) {
            MSHookMessageEx(vdo, @selector(setSampleBufferDelegate:queue:), (IMP)&ovr_vdo, (IMP*)&orig_vdo);
            tlog(@"Hooked VideoDataOutput OK");
        }
        
        // Preview injection timer: scan windows every 1/30s
        static dispatch_source_t timer;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), 
                                  (int64_t)(1.0/30.0*NSEC_PER_SEC), (int64_t)(0.005*NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            if (!shouldInject()) return;
            CGImageRef img = createCGImage();
            if (!img) return;
            updateAllPreviews(img);
            CGImageRelease(img);
        });
        dispatch_resume(timer);
        tlog(@"Preview timer started");
        tlog(@"=== v1.0.22 ready ===");
    }
}

%dtor { tlog(@"Unloading"); }