#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <substrate.h>

// Logger
static NSString *g_logPath = @"/var/mobile/Documents/rtmpcamera/tweak.log";
static void twlog(NSString *fmt, ...) __attribute__((format(NSString, 1, 2)));
static void twlog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args]; va_end(args);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@][%@] %@\n", [df stringFromDate:[NSDate date]], NSProcessInfo.processInfo.processName ?: @"?", msg];
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/rtmpcamera" withIntermediateDirectories:YES attributes:nil error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [line writeToFile:g_logPath atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

// Config
static NSString *g_cfgPath = @"/var/mobile/Documents/rtmpcamera/config.plist";
static NSString *g_videoPath = @"/var/mobile/Documents/rtmpcamera/current_video.mp4";
typedef NS_ENUM(NSInteger, RCSrc) { RCSrcReal=0, RCSrcLocal=2 };
static RCSrc g_src = RCSrcLocal;
static BOOL g_vid = YES, g_aud = YES, g_loop = YES;

static void loadCfg(void) {
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:g_cfgPath];
    if (!c) { g_src=RCSrcLocal; g_vid=YES; g_aud=YES; g_loop=YES; return; }
    NSNumber *st = c[@"sourceType"];
    if (st) { NSInteger v = [st integerValue]; g_src = (v == 2) ? RCSrcLocal : RCSrcReal; }
    else {
        NSString *s = c[@"source"] ?: @"local";
        if ([s isEqual:@"local"]) g_src=RCSrcLocal; else g_src=RCSrcReal;
    }
    NSNumber *vi = c[@"videoInjectionEnabled"] ?: c[@"videoInjection"];
    if (vi) g_vid = [vi boolValue];
    NSNumber *ai = c[@"audioInjectionEnabled"] ?: c[@"audioInjection"];
    if (ai) g_aud = [ai boolValue];
    NSNumber *lp = c[@"loopEnabled"] ?: c[@"loop"];
    if (lp) g_loop = [lp boolValue];
}

// Video Reader (outputs 420v bi-planar to match camera native format)
@interface RCVideoReader : NSObject { @public os_unfair_lock _lock; }
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *output;
@property (nonatomic, assign) BOOL stopped;
- (CMSampleBufferRef)nextFrame CF_RETURNS_RETAINED;
- (void)reload;
- (void)stop;
@end

@implementation RCVideoReader
- (instancetype)init { self=[super init]; if(self){_lock=OS_UNFAIR_LOCK_INIT; _stopped=NO;} return self; }
- (void)reload {
    os_unfair_lock_lock(&_lock); _stopped=NO; [_reader cancelReading]; _reader=nil; _output=nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:g_videoPath]) { os_unfair_lock_unlock(&_lock); twlog(@"reload: no video file"); return; }
    NSURL *url=[NSURL fileURLWithPath:g_videoPath];
    AVAsset *asset=[AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    AVAssetTrack *track=[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if(!track){ os_unfair_lock_unlock(&_lock); twlog(@"reload: no video track"); return; }
    // Prefer 420v VideoRange (H.264 native), fallback to FullRange, then BGRA
    NSArray *fmts = @[@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                       @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                       @(kCVPixelFormatType_32BGRA)];
    BOOL ok=NO;
    for (NSNumber *fmtObj in fmts) {
        NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey:fmtObj};
        _output=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
        _output.alwaysCopiesSampleData=NO;
        _reader=[[AVAssetReader alloc] initWithAsset:asset error:nil];
        if(_reader && _output) { [_reader addOutput:_output]; if([_reader startReading]) { ok=YES; twlog(@"reload: ok fmt=%d", [fmtObj intValue]); break; } }
        _reader=nil; _output=nil;
    }
    if (!ok) twlog(@"reload: FAILED all formats");
    os_unfair_lock_unlock(&_lock);
}
- (void)stop { os_unfair_lock_lock(&_lock); _stopped=YES; [_reader cancelReading]; _reader=nil; _output=nil; os_unfair_lock_unlock(&_lock); }
- (CMSampleBufferRef)nextFrame {
    os_unfair_lock_lock(&_lock);
    if(_stopped||!_reader||_reader.status!=AVAssetReaderStatusReading){ os_unfair_lock_unlock(&_lock); return NULL; }
    CMSampleBufferRef sb=[_output copyNextSampleBuffer];
    os_unfair_lock_unlock(&_lock);
    if(!sb && g_loop) { [self reload]; return NULL; }
    return sb;
}
@end

static RCVideoReader *g_reader;
static RCVideoReader *getReader(void) {
    static dispatch_once_t o; dispatch_once(&o,^{g_reader=[[RCVideoReader alloc] init]; [g_reader reload];});
    return g_reader;
}

// Hook CMSampleBufferGetImageBuffer
static int g_frameCount = 0;
static CVImageBufferRef (*orig_GetImageBuffer)(CMSampleBufferRef);

static BOOL is420v(OSType fmt) {
    return fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

static BOOL isBGRA(OSType fmt) {
    return fmt == kCVPixelFormatType_32BGRA;
}

static CVImageBufferRef hooked_GetImageBuffer(CMSampleBufferRef sb) {
    CVImageBufferRef buf = orig_GetImageBuffer(sb);
    g_frameCount++;
    if (g_frameCount % 150 == 0) loadCfg();
    if(!buf||g_src==RCSrcReal||!g_vid) return buf;

    CVPixelBufferRef pb=(CVPixelBufferRef)buf;
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    if(fmt==0) return buf;

    CMSampleBufferRef vsb=[getReader() nextFrame];
    if(!vsb) return buf;
    CVImageBufferRef vbuf=orig_GetImageBuffer(vsb);
    if(!vbuf){ CFRelease(vsb); return buf; }

    if(is420v(fmt)) {
        // 420v: copy plane data directly
        CVPixelBufferLockBaseAddress(pb, 0);
        CVPixelBufferLockBaseAddress(vbuf, kCVPixelBufferLock_ReadOnly);
        size_t w=CVPixelBufferGetWidth(pb), h=CVPixelBufferGetHeight(pb);
        size_t vw=CVPixelBufferGetWidth(vbuf), vh=CVPixelBufferGetHeight(vbuf);

        // Plane 0 (Y)
        uint8_t *yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        uint8_t *ySrc = CVPixelBufferGetBaseAddressOfPlane(vbuf, 0);
        size_t yBprDst = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        size_t yBprSrc = CVPixelBufferGetBytesPerRowOfPlane(vbuf, 0);
        if(yDst && ySrc) {
            for(size_t y=0; y<h && y<vh; y++) {
                size_t cp = w < vw ? w : vw;
                if(cp > yBprDst) cp = yBprDst;
                if(cp > yBprSrc) cp = yBprSrc;
                memcpy(yDst + y*yBprDst, ySrc + (y*vh/h)*yBprSrc, cp);
            }
        }

        // Plane 1 (CbCr)
        uint8_t *uvDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        uint8_t *uvSrc = CVPixelBufferGetBaseAddressOfPlane(vbuf, 1);
        size_t uvBprDst = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
        size_t uvBprSrc = CVPixelBufferGetBytesPerRowOfPlane(vbuf, 1);
        size_t h2 = h/2, vh2 = vh/2;
        if(uvDst && uvSrc) {
            for(size_t y=0; y<h2 && y<vh2; y++) {
                size_t cp = (w/2)*2 < (vw/2)*2 ? (w/2)*2 : (vw/2)*2;
                if(cp > uvBprDst) cp = uvBprDst;
                if(cp > uvBprSrc) cp = uvBprSrc;
                memcpy(uvDst + y*uvBprDst, uvSrc + (y*vh2/h2)*uvBprSrc, cp);
            }
        }

        CVPixelBufferUnlockBaseAddress(vbuf, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(pb, 0);
    }
    else if(isBGRA(fmt)) {
        // 32BGRA fallback
        CVPixelBufferLockBaseAddress(pb, 0);
        CVPixelBufferLockBaseAddress(vbuf, kCVPixelBufferLock_ReadOnly);
        size_t w=CVPixelBufferGetWidth(pb), h=CVPixelBufferGetHeight(pb);
        size_t bpr=CVPixelBufferGetBytesPerRow(pb);
        size_t vw=CVPixelBufferGetWidth(vbuf), vh=CVPixelBufferGetHeight(vbuf);
        size_t vbpr=CVPixelBufferGetBytesPerRow(vbuf);
        uint8_t *base=CVPixelBufferGetBaseAddress(pb);
        uint8_t *vbase=CVPixelBufferGetBaseAddress(vbuf);
        if(base && vbase) {
            for(size_t y=0; y<h && y<vh; y++) {
                size_t cp = (w<vw?w:vw)*4;
                if(cp>bpr) cp=bpr; if(cp>vbpr) cp=vbpr;
                memcpy(base+y*bpr, vbase+(y*vh/h)*vbpr, cp);
            }
        }
        CVPixelBufferUnlockBaseAddress(vbuf, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(pb, 0);
    }

    CFRelease(vsb);
    return buf;
}

%ctor { %init;
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/rtmpcamera" withIntermediateDirectories:YES attributes:nil error:nil];
    loadCfg();
    MSHookFunction((void*)CMSampleBufferGetImageBuffer, (void*)hooked_GetImageBuffer, (void**)&orig_GetImageBuffer);
    twlog(@"LOADED v1.0.80 src=%ld vid=%d aud=%d loop=%d", (long)g_src, g_vid, g_aud, g_loop);
}