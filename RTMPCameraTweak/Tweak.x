#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <substrate.h>

// Logger
static NSString *g_logPath = @"/var/mobile/Documents/rtmpcamera/tweak.log";
static void twlog(NSString *fmt, ...) __attribute__((format(NSString, 1, 2)));
static void twlog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/rtmpcamera" withIntermediateDirectories:YES attributes:nil error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [line writeToFile:g_logPath atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
    NSLog(@"[RTMPCamera] %@", msg);
}

// Config
static NSString *g_cfgPath = @"/var/mobile/Documents/rtmpcamera/config.plist";
typedef NS_ENUM(NSInteger, RCSrc) { RCSrcReal=0, RCSrcRTMP=1, RCSrcLocal=2 };
static RCSrc g_src = RCSrcLocal;
static BOOL g_vid = YES, g_aud = YES, g_loop = YES;
static void loadCfg(void) {
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:g_cfgPath];
    if (!c) { g_src=RCSrcLocal; g_vid=YES; g_aud=YES; g_loop=YES; return; }
    NSString *s = c[@"source"] ?: @"local";
    if ([s isEqual:@"rtmp"]) g_src=RCSrcRTMP;
    else if ([s isEqual:@"local"]) g_src=RCSrcLocal;
    else g_src=RCSrcReal;
    g_vid=[c[@"videoInjection"] boolValue]; g_aud=[c[@"audioInjection"] boolValue]; g_loop=[c[@"loop"] boolValue];
}

// Simple green frame generator
static CVPixelBufferRef makeGreenFrame(size_t w, size_t h) {
    NSDictionary *attrs = @{(id)kCVPixelBufferWidthKey:@(w), (id)kCVPixelBufferHeightKey:@(h),
        (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferBytesPerRowAlignmentKey:@(64)};
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    for (size_t y=0; y<h; y++) {
        uint8_t *row = base + y*bpr;
        for (size_t x=0; x<w; x++) { row[x*4+0]=0x00; row[x*4+1]=0xFF; row[x*4+2]=0x00; row[x*4+3]=0xFF; }
    }
    // Draw red cross to verify it's our frame
    for (size_t y=0; y<h; y++) { uint8_t *r=base+y*bpr; r[(y*w/h)*4+0]=0xFF; r[(y*w/h)*4+1]=0x00; r[(y*w/h)*4+2]=0x00; }
    for (size_t x=0; x<w; x++) { uint8_t *r=base+(h/2)*bpr; r[x*4+0]=0xFF; r[x*4+1]=0x00; r[x*4+2]=0x00; }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

// Hook CMSampleBufferGetImageBuffer
static CVImageBufferRef (*orig_GetImageBuffer)(CMSampleBufferRef);
static CVImageBufferRef hooked_GetImageBuffer(CMSampleBufferRef sb) {
    CVImageBufferRef buf = orig_GetImageBuffer(sb);
    if (!buf || g_src==RCSrcReal || !g_vid) return buf;
    CVPixelBufferRef pb = (CVPixelBufferRef)buf;
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    if (fmt==0) return buf;
    size_t w=CVPixelBufferGetWidth(pb), h=CVPixelBufferGetHeight(pb), bpr=CVPixelBufferGetBytesPerRow(pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    if (!base) { CVPixelBufferUnlockBaseAddress(pb,0); return buf; }
    if (fmt == kCVPixelFormatType_32BGRA) {
        for (size_t y=0; y<h; y++) { uint8_t *r=base+y*bpr; for (size_t x=0; x<w; x++) { r[x*4+0]=0x00; r[x*4+1]=0xFF; r[x*4+2]=0x00; r[x*4+3]=0xFF; } }
        for (size_t y=0; y<h; y++) { base[y*bpr + (y*w/h)*4 + 0]=0xFF; base[y*bpr + (y*w/h)*4 + 1]=0x00; }
        for (size_t x=0; x<w; x++) { base[(h/2)*bpr + x*4 + 0]=0xFF; base[(h/2)*bpr + x*4 + 1]=0x00; }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return buf;
}

%ctor {
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/rtmpcamera" withIntermediateDirectories:YES attributes:nil error:nil];
    loadCfg();
    %init;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    NSString *pn  = [[NSProcessInfo processInfo] processName] ?: @"?";
    twlog(@"LOADED v1.0.71 bid=%@ proc=%@ src=%ld vid=%d", bid, pn, (long)g_src, g_vid);
    MSHookFunction((void *)CMSampleBufferGetImageBuffer, (void *)hooked_GetImageBuffer, (void **)&orig_GetImageBuffer);
    twlog(@"Hook installed on CMSampleBufferGetImageBuffer");
}