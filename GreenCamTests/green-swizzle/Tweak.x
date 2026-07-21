// GreenCam-Swizzle: Proxy-Delegate approach (based on DiCoy)
// Hooks AVCaptureVideoDataOutput.setSampleBufferDelegate:queue:
// Creates a proxy that intercepts captureOutput:didOutputSampleBuffer:fromConnection:
// and replaces the frame with green before forwarding to the original delegate
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

static BOOL gsw_enabled = YES;

// --- Green frame generator ---
static CMSampleBufferRef GSW_CreateGreenFrame(CMSampleBufferRef original) {
    if (!original) return NULL;
    
    CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(original);
    if (!fmtDesc) return NULL;
    
    CMMediaType mediaType = CMFormatDescriptionGetMediaType(fmtDesc);
    if (mediaType != kCMMediaType_Video) return NULL;
    
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmtDesc);
    if (dims.width == 0 || dims.height == 0) return NULL;
    
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(dims.width),
        (id)kCVPixelBufferHeightKey: @(dims.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, dims.width, dims.height,
                                          kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pb);
    if (status != kCVReturnSuccess || !pb) return NULL;
    
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    for (size_t y = 0; y < (size_t)dims.height; y++) {
        uint8_t *row = base + y * bpr;
        for (size_t x = 0; x < (size_t)dims.width; x++) {
            row[x*4 + 0] = 0x00; // B
            row[x*4 + 1] = 0xFF; // G
            row[x*4 + 2] = 0x00; // R
            row[x*4 + 3] = 0xFF; // A
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    
    CMVideoFormatDescriptionRef newFmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &newFmt);
    
    CMSampleTimingInfo timing = {0};
    CMSampleBufferGetSampleTimingInfo(original, 0, &timing);
    
    CMSampleBufferRef sb = NULL;
    CMAttachmentMode attachmentMode;
    CFDictionaryRef attachments = CMSampleBufferGetSampleAttachments(original, false, &attachmentMode);
    
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, YES, NULL, NULL, newFmt, &timing, &sb);
    
    if (sb && attachments) {
        CMSampleBufferSetSampleAttachments(sb, attachments, attachmentMode);
    }
    
    if (newFmt) CFRelease(newFmt);
    CVPixelBufferRelease(pb);
    return sb;
}

// --- Proxy class ---
@interface GSWDelegateProxy : NSObject
@property (nonatomic, weak) id originalDelegate;
@property (nonatomic, assign) SEL originalSelector;
@property (nonatomic, assign) IMP originalIMP;
@end

@implementation GSWDelegateProxy

static void GSW_InterceptCaptureOutput(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
    GSWDelegateProxy *proxy = objc_getAssociatedObject(self, @selector(originalDelegate));
    
    if (gsw_enabled && sampleBuffer) {
        CMSampleBufferRef greenFrame = GSW_CreateGreenFrame(sampleBuffer);
        if (greenFrame) {
            if (proxy && proxy.originalIMP) {
                ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))proxy.originalIMP)(
                    proxy.originalDelegate, proxy.originalSelector, output, greenFrame, connection);
            }
            CFRelease(greenFrame);
            return;
        }
    }
    
    if (proxy && proxy.originalIMP) {
        ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))proxy.originalIMP)(
            proxy.originalDelegate, proxy.originalSelector, output, sampleBuffer, connection);
    }
}

@end

// Store original delegates
static NSMapTable *gsw_delegateMap = nil;

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (!gsw_delegateMap) {
        gsw_delegateMap = [NSMapTable weakToStrongObjectsMapTable];
    }
    
    if (sampleBufferDelegate && sampleBufferCallbackQueue) {
        // Store original delegate
        [gsw_delegateMap setObject:sampleBufferDelegate forKey:(__bridge id)self];
        
        // Create proxy
        GSWDelegateProxy *proxy = [[GSWDelegateProxy alloc] init];
        proxy.originalDelegate = sampleBufferDelegate;
        proxy.originalSelector = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        
        // Get original IMP
        Method origMethod = class_getInstanceMethod([sampleBufferDelegate class],
            @selector(captureOutput:didOutputSampleBuffer:fromConnection:));
        if (origMethod) {
            proxy.originalIMP = method_getImplementation(origMethod);
        }
        
        objc_setAssociatedObject(sampleBufferDelegate, @selector(originalDelegate),
                                 proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // Swizzle the delegate's captureOutput method
        Class delegateClass = [sampleBufferDelegate class];
        SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        Method m = class_getInstanceMethod(delegateClass, sel);
        if (m) {
            method_setImplementation(m, (IMP)GSW_InterceptCaptureOutput);
        }
    }
    
    NSLog(@"[GreenCam-Swizzle] Hooked delegate: %@", sampleBufferDelegate);
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        %init;
        NSLog(@"[GreenCam-Swizzle] Loaded - Proxy-Delegate camera hook active");
    }
}
