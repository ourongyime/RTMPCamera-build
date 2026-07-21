// GreenCam-Swizzle: Proxy-Delegate approach (based on DiCoy)
// Hooks AVCaptureVideoDataOutput.setSampleBufferDelegate:queue:
// Swizzles the delegate to intercept and replace frames with green
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

static BOOL gsw_enabled = YES;
static int gsw_frameCount = 0;

// --- Green CMSampleBuffer generator ---
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
    uint8_t shade = (uint8_t)(200 + (gsw_frameCount % 56));
    for (size_t y = 0; y < (size_t)dims.height; y++) {
        uint8_t *row = base + y * bpr;
        for (size_t x = 0; x < (size_t)dims.width; x++) {
            row[x*4 + 0] = 0x00;
            row[x*4 + 1] = shade;
            row[x*4 + 2] = 0x00;
            row[x*4 + 3] = 0xFF;
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    
    CMVideoFormatDescriptionRef newFmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &newFmt);
    if (!newFmt) { CVPixelBufferRelease(pb); return NULL; }
    
    CMSampleTimingInfo timing = {0};
    CMSampleBufferGetSampleTimingInfo(original, 0, &timing);
    timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
    
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, YES, NULL, NULL, newFmt, &timing, &sb);
    
    CFRelease(newFmt);
    CVPixelBufferRelease(pb);
    
    if (sb) gsw_frameCount++;
    return sb;
}

// ============================================================================
// Simple approach: hook AVCaptureVideoDataOutput and method-swizzle the delegate
// on the fly when setSampleBufferDelegate:queue: is called
// ============================================================================

static void GSW_InterceptCaptureOutput(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection);

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate && queue && gsw_enabled) {
        Class delegateClass = [delegate class];
        SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        Method m = class_getInstanceMethod(delegateClass, sel);
        if (m) {
            // Store original IMP on the delegate instance
            IMP origIMP = method_getImplementation(m);
            objc_setAssociatedObject(delegate, @selector(setSampleBufferDelegate:queue:),
                                     [NSValue valueWithPointer:origIMP], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // Replace with our intercept
            method_setImplementation(m, (IMP)GSW_InterceptCaptureOutput);
        }
    }
    %orig;
}
%end

static void GSW_InterceptCaptureOutput(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
    if (gsw_enabled && sampleBuffer) {
        CMSampleBufferRef greenFrame = GSW_CreateGreenFrame(sampleBuffer);
        if (greenFrame) {
            NSValue *origVal = objc_getAssociatedObject(self, @selector(setSampleBufferDelegate:queue:));
            IMP origIMP = [origVal pointerValue];
            if (origIMP) {
                ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))origIMP)(
                    self, _cmd, output, greenFrame, connection);
            }
            CFRelease(greenFrame);
            return;
        }
    }
    
    NSValue *origVal = objc_getAssociatedObject(self, @selector(setSampleBufferDelegate:queue:));
    IMP origIMP = [origVal pointerValue];
    if (origIMP) {
        ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))origIMP)(
            self, _cmd, output, sampleBuffer, connection);
    }
}

%ctor {
    @autoreleasepool {
        %init;
        NSLog(@"[GreenCam-Swizzle] Loaded - Proxy-Delegate camera hook active");
    }
}
