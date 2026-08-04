#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <substrate.h>

// ===================================================================
// Logger
// ===================================================================
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

// ===================================================================
// Config
// ===================================================================
static NSString *g_cfgPath = @"/var/mobile/Documents/rtmpcamera/config.plist";
static NSString *g_videoPath = @"/var/mobile/Documents/rtmpcamera/current_video.mp4";
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

// ===================================================================
// Video Reader (AVAssetReader)
// ===================================================================
@interface RCVideoReader : NSObject { @public os_unfair_lock _lock; }
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *output;
- (CMSampleBufferRef)nextFrame CF_RETURNS_RETAINED;
- (void)reload;
- (void)stop;
@end

@implementation RCVideoReader
- (instancetype)init { self=[super init]; if(self){_lock=OS_UNFAIR_LOCK_INIT;[self reload];} return self; }
- (void)reload {
    os_unfair_lock_lock(&_lock); [_reader cancelReading]; _reader=nil; _output=nil;
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
    twlog(@"Reader OK: %@", [url lastPathComponent]);
}
- (void)stop { os_unfair_lock_lock(&_lock); [_reader cancelReading]; _reader=nil; _output=nil; os_unfair_lock_unlock(&_lock); }
- (CMSampleBufferRef)nextFrame {
    os_unfair_lock_lock(&_lock);
    if(!_reader||_reader.status!=AVAssetReaderStatusReading){ os_unfair_lock_unlock(&_lock); return NULL; }
    CMSampleBufferRef sb=[_output copyNextSampleBuffer];
    if(!sb){ if(g_loop){ os_unfair_lock_unlock(&_lock); [self reload]; return [self nextFrame]; } [self stop]; os_unfair_lock_unlock(&_lock); return NULL; }
    os_unfair_lock_unlock(&_lock); return sb;
}
@end

static RCVideoReader *g_reader;
static RCVideoReader *getReader(void) { static dispatch_once_t o; dispatch_once(&o,^{g_reader=[[RCVideoReader alloc] init];}); return g_reader; }

// ===================================================================
// CMSampleBufferGetImageBuffer Hook (universal fallback)
// ===================================================================
static CVImageBufferRef (*orig_GetImageBuffer)(CMSampleBufferRef);
static CVImageBufferRef hooked_GetImageBuffer(CMSampleBufferRef sb) {
    CVImageBufferRef buf = orig_GetImageBuffer(sb);
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

// ===================================================================
// Proxy Delegate (AVCaptureVideoDataOutput)
// ===================================================================
@interface RCVideoProxy : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic,weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> real;
@end
@implementation RCVideoProxy
- (instancetype)initWithDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)d { self.real=d; return self; }
- (BOOL)respondsToSelector:(SEL)s {
    if(s==@selector(captureOutput:didOutputSampleBuffer:fromConnection:)) return YES;
    if(s==@selector(captureOutput:didDropSampleBuffer:fromConnection:)) return YES;
    return [self.real respondsToSelector:s] || [super respondsToSelector:s];
}
- (NSMethodSignature*)methodSignatureForSelector:(SEL)s { id t=(id)self.real?:(id)[NSObject class]; return [t methodSignatureForSelector:s]; }
- (void)forwardInvocation:(NSInvocation*)i { if(self.real)[i invokeWithTarget:self.real]; }
- (void)captureOutput:(AVCaptureOutput*)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection*)c {
    if(g_vid&&g_src!=RCSrcReal){ CMSampleBufferRef inj=[getReader() nextFrame]; if(inj){ if([self.real respondsToSelector:_cmd])[self.real captureOutput:o didOutputSampleBuffer:inj fromConnection:c]; CFRelease(inj); return; } }
    if([self.real respondsToSelector:_cmd])[self.real captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
- (void)captureOutput:(AVCaptureOutput*)o didDropSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection*)c {
    if([self.real respondsToSelector:_cmd])[self.real captureOutput:o didDropSampleBuffer:s fromConnection:c];
}
@end

// ===================================================================
// PreviewLayer Overlay (for Camera.app viewfinder)
// ===================================================================
@interface AVCaptureVideoPreviewLayer (RCExt)
- (void)_rcInstall;
- (void)_rcStep:(CADisplayLink*)s;
@end
static const void *kOverlayK=&kOverlayK,*kLinkK=&kLinkK;

// ===================================================================
// %hook blocks
// ===================================================================
static const char kPKey;
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)d queue:(dispatch_queue_t)q {
    if(d&&![d isKindOfClass:[RCVideoProxy class]]){ RCVideoProxy *p=[[RCVideoProxy alloc] initWithDelegate:d]; objc_setAssociatedObject(d,&kPKey,p,OBJC_ASSOCIATION_RETAIN_NONATOMIC); twlog(@"[Proxy] installed: %@",NSStringFromClass([d class])); %orig(p,q); }
    else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
%new - (void)_rcInstall {
    if(objc_getAssociatedObject(self,kOverlayK)) return;
    AVSampleBufferDisplayLayer *dl=[AVSampleBufferDisplayLayer new]; dl.frame=self.bounds; dl.videoGravity=AVLayerVideoGravityResizeAspectFill; dl.opacity=1.0f; dl.zPosition=9999;
    [self addSublayer:dl]; objc_setAssociatedObject(self,kOverlayK,dl,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CADisplayLink *lk=[CADisplayLink displayLinkWithTarget:self selector:@selector(_rcStep:)]; [lk addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(self,kLinkK,lk,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%new - (void)_rcStep:(CADisplayLink*)s {
    AVSampleBufferDisplayLayer *dl=objc_getAssociatedObject(self,kOverlayK); if(!dl)return; dl.frame=self.bounds;
    if(g_src==RCSrcReal||!g_vid){ dl.opacity=0.0f; return; } if(!dl.readyForMoreMediaData)return;
    CMSampleBufferRef f=[getReader() nextFrame]; if(f){ dl.opacity=1.0f; [dl flush]; [dl enqueueSampleBuffer:f]; CFRelease(f); }
}
- (instancetype)initWithSession:(AVCaptureSession*)s { self=%orig; dispatch_async(dispatch_get_main_queue(),^{[self _rcInstall];}); return self; }
- (void)setSession:(AVCaptureSession*)s { %orig; dispatch_async(dispatch_get_main_queue(),^{[self _rcInstall];}); }
- (void)layoutSublayers { %orig; [self _rcInstall]; }
%end

// ===================================================================
// %ctor
// ===================================================================
%ctor {
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/rtmpcamera" withIntermediateDirectories:YES attributes:nil error:nil];
    loadCfg(); %init;
    MSHookFunction((void*)CMSampleBufferGetImageBuffer,(void*)hooked_GetImageBuffer,(void**)&orig_GetImageBuffer);
    NSString *bid=NSBundle.mainBundle.bundleIdentifier?:@"?",*pn=NSProcessInfo.processInfo.processName?:@"?";
    twlog(@"LOADED v1.0.73 bid=%@ proc=%@ src=%ld vid=%d",bid,pn,(long)g_src,g_vid);
}