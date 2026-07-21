// GreenCam-NSObject: Direct captureOutput hook (simplest, broadest coverage)
// Hooks NSObject's captureOutput:didOutputSampleBuffer:fromConnection:
// Replaces video frames with green before forwarding to original
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import <substrate.h>

static BOOL gno_enabled = YES;
static int gno_frameCount = 0;

// --- Green CMSampleBuffer generator ---
static CMSampleBufferRef GNO_CreateGreenSampleBuffer(CMSampleBufferRef original) {
    if (!original) return NULL;
    
    CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(original);
    if (!fmtDesc) return NULL;
    
    CMMediaType mediaType = CMFormatDescriptionGetMediaType(fmtDesc);
    if (mediaType != kCMMediaType_Video) return NULL;
    
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmtDesc);
    if (dims.width == 0 || dims.height == 0) {
        // Use 640x480 default for unusual buffers
        dims.width = 640;
        dims.height = 480;
    }
    
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(dims.width),
        (id)kCVPixelBufferHeightKey: @(dims.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          (size_t)dims.width, (size_t)dims.height,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attrs, &pb);
    if (status != kCVReturnSuccess || !pb) return NULL;
    
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    
    // Draw animated green (shade varies slightly for visibility)
    uint8_t shade = (uint8_t)(200 + (gno_frameCount % 56)); // 200-255 green
    for (size_t y = 0; y < (size_t)dims.height; y++) {
        uint8_t *row = base + y * bpr;
        for (size_t x = 0; x < (size_t)dims.width; x++) {
            row[x*4 + 0] = 0x00;   // B
            row[x*4 + 1] = shade;  // G (animated)
            row[x*4 + 2] = 0x00;   // R
            row[x*4 + 3] = 0xFF;   // A
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    
    CMVideoFormatDescriptionRef newFmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &newFmt);
    if (!newFmt) {
        CVPixelBufferRelease(pb);
        return NULL;
    }
    
    // Copy timing from original
    CMSampleTimingInfo timing = {0};
    CMSampleBufferGetSampleTimingInfo(original, 0, &timing);
    // Update PTS to now
    timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
    
    CMSampleBufferRef sb = NULL;
    OSStatus err = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, newFmt, &timing, &sb);
    
    if (err != noErr || !sb) {
        // Fallback: create manually
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, YES, NULL, NULL, newFmt, &timing, &sb);
    }
    
    CFRelease(newFmt);
    CVPixelBufferRelease(pb);
    
    if (sb) {
        gno_frameCount++;
        if (gno_frameCount % 30 == 0) {
            NSLog(@"[GreenCam-NSObject] Injected %d green frames", gno_frameCount);
        }
    }
    
    return sb;
}

// ============================================================================
// Hook NSObject's captureOutput:didOutputSampleBuffer:fromConnection:
// This catches ALL AVCaptureVideoDataOutputSampleBufferDelegate callbacks
// regardless of which class implements them
// ============================================================================

%hook NSObject
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    
    if (gno_enabled && sampleBuffer) {
        CMSampleBufferRef greenFrame = GNO_CreateGreenSampleBuffer(sampleBuffer);
        if (greenFrame) {
            %orig(output, greenFrame, connection);
            CFRelease(greenFrame);
            return;
        }
    }
    
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        %init;
        NSLog(@"[GreenCam-NSObject] Loaded - Direct NSObject captureOutput hook active");
        [[NSString stringWithFormat:@"loaded at %@\n", [NSDate date]]
         writeToFile:@"/var/tmp/greencam_nsobject_loaded.txt"
         atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
