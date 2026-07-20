// Tweak.x - RTMPCameraTweak v1.0.20
// File-based frame injection for iOS 16.1 + Dopamine RootHide + ElleKit
// Reads frames from /var/mobile/Documents/rtmpcamera/ (written by app)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// ============================================================
// Paths
// ============================================================
static NSString *kFrameFile = @"/var/mobile/Documents/rtmpcamera/current_frame.raw";
static NSString *kMetaFile  = @"/var/mobile/Documents/rtmpcamera/meta.plist";

// ============================================================
// Read meta plist
// ============================================================
static NSDictionary *readMeta(void) {
    return [NSDictionary dictionaryWithContentsOfFile:kMetaFile];
}

static BOOL shouldInjectVideo(void) {
    NSDictionary *m = readMeta();
    if (!m) return NO;
    if (![m[@"videoInjectionEnabled"] boolValue]) return NO;
    if ([m[@"sourceType"] integerValue] == 0) return NO; // real camera
    return YES;
}

// ============================================================
// Create CMSampleBuffer from file
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
// Proxy Delegate
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
// Hook
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

%ctor {
    @autoreleasepool {
        NSLog(@"[RTMPCamera] v1.0.20 file-based init");
        Class cls = NSClassFromString(@"AVCaptureVideoDataOutput");
        if (cls) {
            MSHookMessageEx(cls, @selector(setSampleBufferDelegate:queue:),
                            (IMP)&override_setDelegate, (IMP *)&orig_setDelegate);
            NSLog(@"[RTMPCamera] Hooked OK");
        }
    }
}

%dtor {
    NSLog(@"[RTMPCamera] Unloaded");
}