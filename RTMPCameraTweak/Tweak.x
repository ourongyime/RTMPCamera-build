// Tweak.x - RTMPCameraTweak v1.0.66
// Based on DiCoy: inject into com.apple.AVFoundation + proxy delegate + preview layer hook
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <substrate.h>

static NSString *kDir = @"/var/mobile/Documents/rtmpcamera";
static NSString *kLogFile = @"/var/mobile/Documents/rtmpcamera/tweak.log";
static NSString *kLoadedFlag = @"/var/mobile/Documents/rtmpcamera/tweak_loaded";
static NSString *kCfgFile = @"/var/mobile/Documents/rtmpcamera/config.plist";
static NSString *kVideoFile = @"/var/mobile/Documents/rtmpcamera/current_video.mp4";

static void tlog(NSString *s) {
    NSString *tag = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    NSLog(@"[%@] %@", tag, s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@][%@] %@\n", [df stringFromDate:[NSDate date]], tag, s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil]; [l writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

// Generate green test frame
static CMSampleBufferRef makeGreenFrame(CMSampleBufferRef match) {
    CMFormatDescriptionRef fmt = match ? CMSampleBufferGetFormatDescription(match) : NULL;
    int w = 640, h = 480;
    if (fmt) {
        CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fmt);
        if (dim.width > 0) { w = dim.width; h = dim.height; }
    }
    
    NSDictionary *attrs = @{(id)kCVPixelBufferWidthKey:@(w), (id)kCVPixelBufferHeightKey:@(h),
        (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pb);
    if (!pb) return NULL;
    
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    for (int y = 0; y < h; y++) {
        uint8_t *row = base + y * bpr;
        for (int x = 0; x < w; x++) {
            uint8_t *p = row + x * 4;
            p[0] = 0; p[1] = (uint8_t)(128 + (y * 128 / h)); p[2] = 0; p[3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    
    CMSampleTimingInfo ti = {.duration=CMTimeMake(1,30), .presentationTimeStamp=CMTimeMake(1,30), .decodeTimeStamp=kCMTimeInvalid};
    CMVideoFormatDescriptionRef fd = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fd);
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fd, &ti, &sb);
    if (fd) CFRelease(fd);
    CVPixelBufferRelease(pb);
    return sb;
}

// ===== DiCoy-style proxy delegate for AVCaptureVideoDataOutput =====

@interface DiCoyVideoProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@property (nonatomic, assign) dispatch_queue_t realQueue;
@end

@implementation DiCoyVideoProxy
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CMSampleBufferRef fake = makeGreenFrame(sampleBuffer);
    if (fake && self.realDelegate && [self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [self.realDelegate captureOutput:output didOutputSampleBuffer:fake fromConnection:connection];
        CFRelease(fake);
        return;
    }
    if (self.realDelegate && [self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [self.realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (self.realDelegate && [self.realDelegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [self.realDelegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}
@end

static DiCoyVideoProxy *g_videoProxy = nil;

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:[DiCoyVideoProxy class]]) {
        if (!g_videoProxy) g_videoProxy = [[DiCoyVideoProxy alloc] init];
        g_videoProxy.realDelegate = delegate;
        g_videoProxy.realQueue = queue;
        tlog([NSString stringWithFormat:@"Proxy installed for %@", NSStringFromClass([delegate class])]);
        %orig(g_videoProxy, queue);
        return;
    }
    %orig;
}
%end

// ===== Preview layer hook (for apps like Camera that use preview layer) =====
static const void *kPreviewLayerKey = &kPreviewLayerKey;

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    AVSampleBufferDisplayLayer *dl = objc_getAssociatedObject(self, kPreviewLayerKey);
    if (!dl) {
        dl = [AVSampleBufferDisplayLayer new];
        dl.frame = self.bounds;
        dl.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self addSublayer:dl];
        objc_setAssociatedObject(self, kPreviewLayerKey, dl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{
            dl.opacity = 1.0f;
            CMSampleBufferRef frame = makeGreenFrame(NULL);
            if (frame) { [dl flush]; [dl enqueueSampleBuffer:frame]; CFRelease(frame); }
        });
        tlog(@"Preview layer hooked - green frame injected");
    }
}
%end

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        NSString *pname = [[NSProcessInfo processInfo] processName] ?: @"?";
        tlog([NSString stringWithFormat:@"=== v1.0.66 LOADED [%@] proc=%@ ===", bid, pname]);
        %init;
    }
}