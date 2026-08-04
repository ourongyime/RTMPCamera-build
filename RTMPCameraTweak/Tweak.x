#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <substrate.h>

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
    if (![[NSFileManager defaultManager] fileExistsAtPath:g_videoPath]) { os_unfair_lock_unlock(&_lock); return; }
    NSURL *url=[NSURL fileURLWithPath:g_videoPath];
    AVAsset *asset=[AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    AVAssetTrack *track=[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if(!track){ os_unfair_lock_unlock(&_lock); return; }
    _output=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    _output.alwaysCopiesSampleData=NO;
    _reader=[[AVAssetReader alloc] initWithAsset:asset error:nil];
    [_reader addOutput:_output]; [_reader startReading];
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
static RCVideoReader *getReader(void) { static dispatch_once_t o; dispatch_once(&o,^{g_reader=[[RCVideoReader alloc] init]; [g_reader reload];}); return g_reader; }

static int g_frameCount = 0;
static CVImageBufferRef (*orig_GetImageBuffer)(CMSampleBufferRef);
static CVImageBufferRef hooked_GetImageBuffer(CMSampleBufferRef sb) {
    CVImageBufferRef buf = orig_GetImageBuffer(sb);
    g_frameCount++;
    if (g_frameCount % 100 == 0) loadCfg();
    if(!buf||g_src==RCSrcReal||!g_vid) return buf;
    CVPixelBufferRef pb=(CVPixelBufferRef)buf;
    if(CVPixelBufferGetPixelFormatType(pb)==0) return buf;
    CVPixelBufferLockBaseAddress(pb,0);
    size_t w=CVPixelBufferGetWidth(pb),h=CVPixelBufferGetHeight(pb),bpr=CVPixelBufferGetBytesPerRow(pb);
    uint8_t *base=CVPixelBufferGetBaseAddress(pb);
    if(!base){ CVPixelBufferUnlockBaseAddress(pb,0); return buf; }
    CMSampleBufferRef vsb=[getReader() nextFrame];
    if(vsb){
        CVImageBufferRef vbuf=CMSampleBufferGetImageBuffer(vsb);
        if(vbuf){ CVPixelBufferLockBaseAddress(vbuf,0);
            size_t vw=CVPixelBufferGetWidth(vbuf),vh=CVPixelBufferGetHeight(vbuf),vbpr=CVPixelBufferGetBytesPerRow(vbuf);
            uint8_t *vbase=CVPixelBufferGetBaseAddress(vbuf);
            if(vbase){ for(size_t y=0;y<h&&y<vh;y++){ size_t cp=((w<vw?w:vw)*4); if(cp>bpr)cp=bpr; if(cp>vbpr)cp=vbpr; memcpy(base+y*bpr,vbase+(y*vh/h)*vbpr,cp); } }
            CVPixelBufferUnlockBaseAddress(vbuf,0);
        }
        CFRelease(vsb);
    }
    CVPixelBufferUnlockBaseAddress(pb,0);
    return buf;
}

%ctor { %init;
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/rtmpcamera" withIntermediateDirectories:YES attributes:nil error:nil];
    loadCfg();
    MSHookFunction((void*)CMSampleBufferGetImageBuffer, (void*)hooked_GetImageBuffer, (void**)&orig_GetImageBuffer);
    twlog(@"LOADED v1.0.77 src=%ld vid=%d aud=%d loop=%d", (long)g_src, g_vid, g_aud, g_loop);
}