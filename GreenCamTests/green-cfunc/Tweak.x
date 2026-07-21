// GreenCam-CFunc: MSHookFunction approach (based on VCAMClone)
// Hooks the C function CMSampleBufferGetImageBuffer and fills with green
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import <substrate.h>

static CVImageBufferRef (*orig_CMSampleBufferGetImageBuffer)(CMSampleBufferRef);

static CVImageBufferRef hooked_CMSampleBufferGetImageBuffer(CMSampleBufferRef sb) {
    CVImageBufferRef buf = orig_CMSampleBufferGetImageBuffer(sb);
    if (!buf) return buf;
    
    // Only modify video buffers
    CVPixelBufferRef pb = (CVPixelBufferRef)buf;
    OSType format = CVPixelBufferGetPixelFormatType(pb);
    if (format == 0) return buf; // Not a pixel buffer
    
    CVPixelBufferLockBaseAddress(pb, 0);
    
    size_t width = CVPixelBufferGetWidth(pb);
    size_t height = CVPixelBufferGetHeight(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    
    if (!base) {
        CVPixelBufferUnlockBaseAddress(pb, 0);
        return buf;
    }
    
    // Fill with green: RGB=(0,255,0) -> BGRA=(0,255,0,255)
    // Handle both 32BGRA and 420v/420f
    if (format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32RGBA) {
        for (size_t y = 0; y < height; y++) {
            uint32_t *row = (uint32_t *)(base + y * bpr);
            for (size_t x = 0; x < width; x++) {
                row[x] = 0xFF00FF00; // BGRA: B=0xFF G=0x00 R=0xFF A=0x00 → wait, that's magenta
                // Correct green BGRA: A=0xFF R=0x00 G=0xFF B=0x00 → 0xFF00FF00 is actually A=FF B=00 G=FF R=00
                // Wait let me recheck: BGRA = [B][G][R][A] in memory
                // So 0xAARRGGBB in hex = [BB][GG][RR][AA] in little-endian uint32
                // Green RGB=(0,255,0): in memory as BGRA: B=0x00 G=0xFF R=0x00 A=0xFF
                // As little-endian uint32: 0xFF0000FF... no.
                // Let me just set bytes directly:
            }
        }
        // Direct byte approach for BGRA:
        for (size_t y = 0; y < height; y++) {
            uint8_t *row = base + y * bpr;
            for (size_t x = 0; x < width; x++) {
                row[x*4 + 0] = 0x00; // B
                row[x*4 + 1] = 0xFF; // G
                row[x*4 + 2] = 0x00; // R
                row[x*4 + 3] = 0xFF; // A
            }
        }
    } else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
               format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        // YUV 420: Green is approximately Y=149, U=43, V=21 (BT.601)
        // Luma plane
        void *yPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        size_t yBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        size_t yH = CVPixelBufferGetHeightOfPlane(pb, 0);
        if (yPlane) memset(yPlane, 149, yBpr * yH);
        
        // Chroma plane
        void *uvPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        size_t uvBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
        size_t uvH = CVPixelBufferGetHeightOfPlane(pb, 1);
        if (uvPlane) {
            // Interleaved CbCr: set Cb=43, Cr=21
            for (size_t y = 0; y < uvH; y++) {
                uint8_t *row = (uint8_t *)uvPlane + y * uvBpr;
                for (size_t x = 0; x < uvBpr; x += 2) {
                    row[x] = 43;   // Cb
                    row[x+1] = 21; // Cr
                }
            }
        }
    }
    
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return buf;
}

%ctor {
    @autoreleasepool {
        MSHookFunction(
            (void *)CMSampleBufferGetImageBuffer,
            (void *)hooked_CMSampleBufferGetImageBuffer,
            (void **)&orig_CMSampleBufferGetImageBuffer
        );
        NSLog(@"[GreenCam-CFunc] MSHookFunction installed on CMSampleBufferGetImageBuffer");
        [[NSString stringWithFormat:@"loaded at %@\n", [NSDate date]]
         writeToFile:@"/var/tmp/greencam_cfunc_loaded.txt"
         atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
