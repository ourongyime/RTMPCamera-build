#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/lock.h>

// =========================================================================
// Logger
// =========================================================================
static NSString *g_logPath = @"/var/mobile/Documents/rtmpcamera/tweak.log";

static void twlog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *ts = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", ts, msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/rtmpcamera"
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [line writeToFile:g_logPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
}

// =========================================================================
// Config Manager
// =========================================================================
static NSString *g_cfgPath = @"/var/mobile/Documents/rtmpcamera/config.plist";
static NSString *g_videoPath = @"/var/mobile/Documents/rtmpcamera/current_video.mp4";

typedef NS_ENUM(NSInteger, RCSource) {
    RCSourceReal = 0,
    RCSourceRTMP = 1,
    RCSourceLocal = 2
};

static RCSource     g_source       = RCSourceLocal;
static BOOL         g_videoOn      = YES;
static BOOL         g_audioOn      = YES;
static BOOL         g_loopOn       = YES;

static void reloadConfig(void) {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:g_cfgPath];
    if (!cfg || ![cfg isKindOfClass:[NSDictionary class]]) {
        twlog(@"Config: defaulting to local/video=on");
        g_source = RCSourceLocal;
        g_videoOn = YES;
        g_audioOn = YES;
        g_loopOn = YES;
        return;
    }
    NSString *src = cfg[@"source"] ?: @"local";
    if ([src isEqualToString:@"rtmp"])       g_source = RCSourceRTMP;
    else if ([src isEqualToString:@"local"]) g_source = RCSourceLocal;
    else                                      g_source = RCSourceReal;
    g_videoOn = [cfg[@"videoInjection"] boolValue];
    g_audioOn = [cfg[@"audioInjection"] boolValue];
    g_loopOn  = [cfg[@"loop"] boolValue];
    twlog(@"Config loaded: source=%ld video=%@ audio=%@ loop=%@", (long)g_source,
          g_videoOn ? @"ON" : @"OFF", g_audioOn ? @"ON" : @"OFF", g_loopOn ? @"ON" : @"OFF");
}

// =========================================================================
// Video Frame Manager (AVAssetReader)
// =========================================================================
@interface RCVideoManager : NSObject {
@public
    os_unfair_lock _lock;
}
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *output;
@property (nonatomic, assign) CMTime lastTime;
- (CMSampleBufferRef)nextFrame CF_RETURNS_RETAINED;
- (void)reload;
- (void)stop;
@end

@implementation RCVideoManager
- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _lastTime = kCMTimeInvalid;
        [self reload];
    }
    return self;
}

- (void)reload {
    os_unfair_lock_lock(&_lock);
    [_reader cancelReading];
    _reader = nil;
    _output = nil;
    _lastTime = kCMTimeInvalid;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:g_videoPath];
    if (!exists) {
        os_unfair_lock_unlock(&_lock);
        twlog(@"Video file missing: %@", g_videoPath);
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:g_videoPath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) {
        os_unfair_lock_unlock(&_lock);
        twlog(@"No video track found");
        return;
    }
    NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    _output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    _output.alwaysCopiesSampleData = NO;
    _reader = [[AVAssetReader alloc] initWithAsset:asset error:nil];
    [_reader addOutput:_output];
    [_reader startReading];
    os_unfair_lock_unlock(&_lock);
    twlog(@"Reader started: %@", [url lastPathComponent]);
}

- (void)stop {
    os_unfair_lock_lock(&_lock);
    [_reader cancelReading];
    _reader = nil;
    _output = nil;
    _lastTime = kCMTimeInvalid;
    os_unfair_lock_unlock(&_lock);
}

- (CMSampleBufferRef)nextFrame {
    os_unfair_lock_lock(&_lock);
    if (!_reader || _reader.status != AVAssetReaderStatusReading) {
        os_unfair_lock_unlock(&_lock);
        return NULL;
    }
    CMSampleBufferRef sb = [_output copyNextSampleBuffer];
    if (!sb) {
        if (g_loopOn) {
            os_unfair_lock_unlock(&_lock);
            [self reload];
            return [self nextFrame];
        }
        [self stop];
        os_unfair_lock_unlock(&_lock);
        return NULL;
    }
    _lastTime = CMSampleBufferGetPresentationTimeStamp(sb);
    os_unfair_lock_unlock(&_lock);
    return sb;
}
@end

// =========================================================================
// Video Proxy (AVCaptureVideoDataOutputSampleBufferDelegate)
// =========================================================================
@interface RCVideoProxy : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@property (nonatomic, strong) RCVideoManager *videoManager;
@end

@implementation RCVideoProxy
- (instancetype)initWithDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate {
    self.realDelegate = delegate;
    self.videoManager = [[RCVideoManager alloc] init];
    return self;
}
- (BOOL)respondsToSelector:(SEL)sel {
    if (sel == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) return YES;
    if (sel == @selector(captureOutput:didDropSampleBuffer:fromConnection:)) return YES;
    if ([self.realDelegate respondsToSelector:sel]) return YES;
    return [super respondsToSelector:sel];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    id target = (id)self.realDelegate ?: (id)[NSObject class];
    return [target methodSignatureForSelector:sel];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    if (self.realDelegate) [inv invokeWithTarget:self.realDelegate];
}
- (void)captureOutput:(AVCaptureOutput *)output
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
    if (!g_videoOn || g_source == RCSourceReal) {
        if ([self.realDelegate respondsToSelector:_cmd])
            [self.realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        return;
    }
    CMSampleBufferRef injected = [self.videoManager nextFrame];
    if (injected) {
        if ([self.realDelegate respondsToSelector:_cmd])
            [self.realDelegate captureOutput:output didOutputSampleBuffer:injected fromConnection:connection];
        CFRelease(injected);
    } else {
        if ([self.realDelegate respondsToSelector:_cmd])
            [self.realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}
- (void)captureOutput:(AVCaptureOutput *)output
   didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection {
    if ([self.realDelegate respondsToSelector:_cmd])
        [self.realDelegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
}
@end

// =========================================================================
// AVCaptureVideoDataOutput Hook
// =========================================================================
static const char kProxyKey;

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate && ![sampleBufferDelegate isKindOfClass:[RCVideoProxy class]]) {
        RCVideoProxy *proxy = [[RCVideoProxy alloc] initWithDelegate:sampleBufferDelegate];
        objc_setAssociatedObject(sampleBufferDelegate, &kProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        twlog(@"[VideoProxy] installed for %@", NSStringFromClass([sampleBufferDelegate class]));
        %orig(proxy, sampleBufferCallbackQueue);
    } else {
        %orig;
    }
}
%end

// =========================================================================
// Forward-declare
// =========================================================================
@interface AVCaptureVideoPreviewLayer (RCExt)
- (void)_rcInstallDisplayLayer;
- (void)_rcStep:(CADisplayLink *)sender;
@end

// =========================================================================
// AVCaptureVideoPreviewLayer Hook
// =========================================================================
static const void *kDisplayLayerKey = &kDisplayLayerKey;
static const void *kDisplayLinkKey  = &kDisplayLinkKey;

%hook AVCaptureVideoPreviewLayer

%new
- (void)_rcInstallDisplayLayer {
    if (objc_getAssociatedObject(self, kDisplayLayerKey)) return;
    AVSampleBufferDisplayLayer *dl = [AVSampleBufferDisplayLayer new];
    dl.frame = self.bounds;
    dl.opacity = 0.0f;
    dl.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self addSublayer:dl];
    objc_setAssociatedObject(self, kDisplayLayerKey, dl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(_rcStep:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(self, kDisplayLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    twlog(@"[PreviewLayer] display layer installed");
}

%new
- (void)_rcStep:(CADisplayLink *)sender {
    if (g_source == RCSourceReal || !g_videoOn) {
        AVSampleBufferDisplayLayer *dl = objc_getAssociatedObject(self, kDisplayLayerKey);
        if (dl) dl.opacity = 0.0f;
        return;
    }
    AVSampleBufferDisplayLayer *dl = objc_getAssociatedObject(self, kDisplayLayerKey);
    if (!dl) return;
    dl.frame = self.bounds;
    if (!dl.readyForMoreMediaData) return;
    static RCVideoManager *sharedVM = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sharedVM = [[RCVideoManager alloc] init]; });
    CMSampleBufferRef frame = [sharedVM nextFrame];
    if (frame) {
        dl.opacity = 1.0f;
        [dl flush];
        [dl enqueueSampleBuffer:frame];
        CFRelease(frame);
    }
}

- (instancetype)initWithSession:(AVCaptureSession *)session {
    self = %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ [self _rcInstallDisplayLayer]; });
    return self;
}

- (void)setSession:(AVCaptureSession *)session {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ [self _rcInstallDisplayLayer]; });
}

- (void)layoutSublayers {
    %orig;
    [self _rcInstallDisplayLayer];
}
%end

// =========================================================================
// Darwin Notification + %ctor
// =========================================================================
static void cfgChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    reloadConfig();
    twlog(@"Config change notification received");
}

%ctor {
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/rtmpcamera"
                              withIntermediateDirectories:YES attributes:nil error:nil];
    reloadConfig();
    %init;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    NSString *pn  = [[NSProcessInfo processInfo] processName] ?: @"?";
    twlog(@"RTMPCamera INJECTED bid=%@ proc=%@ src=%ld", bid, pn, (long)g_source);
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL, cfgChanged,
        CFSTR("com.rtmpcamera.configChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}
