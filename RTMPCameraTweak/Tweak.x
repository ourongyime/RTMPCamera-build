// Tweak.x - RTMPCameraTweak v1.0.21
// File-based frame injection: AVCaptureVideoDataOutput + AVCaptureVideoPreviewLayer
// iOS 16.1 + Dopamine RootHide + ElleKit

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// ============================================================
// Paths & state
// ============================================================
static NSString *kFrameFile = @"/var/mobile/Documents/rtmpcamera/current_frame.raw";
static NSString *kMetaFile  = @"/var/mobile/Documents/rtmpcamera/meta.plist";
static NSString *kLogFile   = @"/var/mobile/Documents/rtmpcamera/tweak.log";

static NSDictionary *g_cachedMeta = nil;
static NSDate *g_lastMetaRead = nil;

// ============================================================
// Logging
// ============================================================
static void tweakLog(NSString *msg) {
    NSLog(@"[RTMPCamera] %@", msg);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [[NSFileManager defaultManager] createDirectoryAtPath:[kLogFile stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [line writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
}

// ============================================================
// Meta config (cached for 0.3s)
// ============================================================
static NSDictionary *readMeta(void) {
    if (g_lastMetaRead && [[NSDate date] timeIntervalSinceDate:g_lastMetaRead] < 0.3 && g_cachedMeta) {
        return g_cachedMeta;
    }
    g_cachedMeta = [NSDictionary dictionaryWithContentsOfFile:kMetaFile];
    g_lastMetaRead = [NSDate date];
    return g_cachedMeta;
}

static BOOL shouldInjectVideo(void) {
    NSDictionary *m = readMeta();
    if (!m) return NO;
    if (![m[@"videoInjectionEnabled"] boolValue]) return NO;
    if ([m[@"sourceType"] integerValue] == 0) return NO;
    return YES;
}

// ============================================================
// Create CMSampleBuffer from file (for AVCaptureVideoDataOutput path)
// ============================================================
static CMSampleBufferRef createFrameFromFile(CMTime timestamp) {
    if (!shouldInjectVideo()) return NULL;
    
    NSDictionary *m = readMeta();
    NSInteger w = [m[@"frameWidth"] integerValue] ?: 640;
    NSInteger h = [m[@"frameHeight"] integerValue] ?: 480;
    NSInteger bpr = [m[@"frameBytesPerRow"] integerValue] ?: (w * 4);
    
    NSData *raw = [NSData dataWithContentsOfFile:kFrameFile];
    if (!raw || raw.length == 0) return NULL;
    
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferBytesPerRowAlignmentKey: @(64),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)w, (size_t)h,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb)
        return NULL;
    
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t dstBPR = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t *src = raw.bytes;
    size_t copyBPR = MIN(dstBPR, (size_t)bpr);
    for (size_t r = 0; r < (size_t)h; r++) {
        memcpy(dst + r * dstBPR, src + r * (size_t)bpr, copyBPR);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    
    CMVideoFormatDescriptionRef fd = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fd);
    
    CMSampleTimingInfo ti = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = timestamp,
        .decodeTimeStamp = kCMTimeInvalid
    };
    
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fd, &ti, &sb);
    
    if (fd) CFRelease(fd);
    CVPixelBufferRelease(pb);
    return sb;
}

// ============================================================
// Create CGImage from file (for PreviewLayer path)
// ============================================================
static CGImageRef createCGImageFromFile(void) {
    NSDictionary *m = readMeta();
    NSInteger w = [m[@"frameWidth"] integerValue] ?: 640;
    NSInteger h = [m[@"frameHeight"] integerValue] ?: 480;
    NSInteger bpr = [m[@"frameBytesPerRow"] integerValue] ?: (w * 4);
    
    NSData *raw = [NSData dataWithContentsOfFile:kFrameFile];
    if (!raw || raw.length == 0) return NULL;
    
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    // BGRA: kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little = [B,G,R,skip]
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)raw);
    CGImageRef img = CGImageCreate(
        (size_t)w, (size_t)h, 8, 32, (size_t)bpr,
        cs,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
        provider,
        NULL, NO, kCGRenderingIntentDefault
    );
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    return img;
}

// ============================================================
// PreviewLayer tracker (GCD timer updates all preview layers)
// ============================================================
static NSHashTable *g_previewLayers = nil;
static dispatch_source_t g_previewTimer = NULL;
static BOOL g_previewTimerStarted = NO;

static void startPreviewUpdater(void) {
    if (g_previewTimerStarted) return;
    g_previewTimerStarted = YES;
    tweakLog(@"Starting preview layer updater");
    
    g_previewTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_previewTimer, DISPATCH_TIME_NOW, (int64_t)(1.0/30.0 * NSEC_PER_SEC), (int64_t)(0.005 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(g_previewTimer, ^{
        if (!shouldInjectVideo()) return;
        @synchronized(g_previewLayers) {
            if (!g_previewLayers || g_previewLayers.count == 0) return;
            CGImageRef img = createCGImageFromFile();
            if (!img) return;
            for (id obj in g_previewLayers) {
                AVCaptureVideoPreviewLayer *layer = (AVCaptureVideoPreviewLayer *)obj;
                layer.contents = (__bridge id)img;
            }
            CGImageRelease(img);
        }
    });
    dispatch_resume(g_previewTimer);
}

// ============================================================
// Proxy Delegate (AVCaptureVideoDataOutput hook)
// ============================================================
@interface RTMPProxyDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id originalDelegate;
@property (nonatomic, weak) dispatch_queue_t sampleBufferQueue;
- (instancetype)initWithOriginalDelegate:(id)delegate;
@end

@implementation RTMPProxyDelegate

- (instancetype)initWithOriginalDelegate:(id)delegate {
    self = [super init];
    if (self) { _originalDelegate = delegate; }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)output
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    
    CMTime ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMSampleBufferRef virt = createFrameFromFile(ts);
    
    if (virt) {
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output didOutputSampleBuffer:virt fromConnection:connection];
        }
        CFRelease(virt);
    } else {
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        }
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [self.originalDelegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.originalDelegate respondsToSelector:aSelector]) return self.originalDelegate;
    return [super forwardingTargetForSelector:aSelector];
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    return [self.originalDelegate respondsToSelector:aSelector];
}

@end

// ============================================================
// Hook: AVCaptureVideoDataOutput
// ============================================================
static const char kProxyKey = 'p';
static void (*orig_setDelegate)(id, SEL, id, dispatch_queue_t);

static void override_setDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    if (delegate && [delegate conformsToProtocol:@protocol(AVCaptureVideoDataOutputSampleBufferDelegate)]) {
        RTMPProxyDelegate *proxy = objc_getAssociatedObject(delegate, &kProxyKey);
        if (!proxy) {
            proxy = [[RTMPProxyDelegate alloc] initWithOriginalDelegate:delegate];
            proxy.sampleBufferQueue = queue;
            objc_setAssociatedObject(delegate, &kProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        orig_setDelegate(self, _cmd, proxy, queue);
    } else {
        orig_setDelegate(self, _cmd, delegate, queue);
    }
}

// ============================================================
// Hook: AVCaptureVideoPreviewLayer (track instances + inject frames)
// ============================================================
static void (*orig_previewInitWithSession)(id, SEL, id);
static void (*orig_previewSetSession)(id, SEL, id);

static void override_previewInitWithSession(id self, SEL _cmd, id session) {
    orig_previewInitWithSession(self, _cmd, session);
    @synchronized(g_previewLayers) {
        if (!g_previewLayers) g_previewLayers = [NSHashTable weakObjectsHashTable];
        [g_previewLayers addObject:self];
        tweakLog([NSString stringWithFormat:@"PreviewLayer+ (total:%lu)", (unsigned long)g_previewLayers.count]);
    }
    startPreviewUpdater();
}

static void override_previewSetSession(id self, SEL _cmd, id session) {
    orig_previewSetSession(self, _cmd, session);
    if (session) {
        @synchronized(g_previewLayers) {
            if (!g_previewLayers) g_previewLayers = [NSHashTable weakObjectsHashTable];
            if (![g_previewLayers containsObject:self]) {
                [g_previewLayers addObject:self];
                tweakLog([NSString stringWithFormat:@"PreviewLayer session+ (total:%lu)", (unsigned long)g_previewLayers.count]);
            }
        }
        startPreviewUpdater();
    }
}

// ============================================================
// %ctor - Tweak initialization
// ============================================================
%ctor {
    @autoreleasepool {
        tweakLog(@"=== RTMPCamera v1.0.21 loading ===");
        
        // Hook AVCaptureVideoDataOutput
        Class vdoCls = NSClassFromString(@"AVCaptureVideoDataOutput");
        if (vdoCls) {
            MSHookMessageEx(vdoCls, @selector(setSampleBufferDelegate:queue:),
                            (IMP)&override_setDelegate, (IMP *)&orig_setDelegate);
            tweakLog(@"Hooked AVCaptureVideoDataOutput");
        } else {
            tweakLog(@"WARN: AVCaptureVideoDataOutput class not found");
        }
        
        // Hook AVCaptureVideoPreviewLayer
        Class pvlCls = NSClassFromString(@"AVCaptureVideoPreviewLayer");
        if (pvlCls) {
            MSHookMessageEx(pvlCls, @selector(initWithSession:),
                            (IMP)&override_previewInitWithSession, (IMP *)&orig_previewInitWithSession);
            MSHookMessageEx(pvlCls, @selector(setSession:),
                            (IMP)&override_previewSetSession, (IMP *)&orig_previewSetSession);
            tweakLog(@"Hooked AVCaptureVideoPreviewLayer");
        } else {
            tweakLog(@"WARN: AVCaptureVideoPreviewLayer class not found");
        }
        
        tweakLog(@"=== Initialized OK ===");
    }
}

%dtor {
    tweakLog(@"Unloading...");
    if (g_previewTimer) {
        dispatch_source_cancel(g_previewTimer);
    }
}