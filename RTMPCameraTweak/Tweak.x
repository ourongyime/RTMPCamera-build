// Tweak.x - RTMPCameraTweak
// Hook AVFoundation 将共享内存中的视频帧注入为系统摄像头画面
// 使用代理模式拦截 AVCaptureVideoDataOutput delegate 回调
// 支持视频/音频注入独立开关
// 适配 iOS 16.1 + Dopamine RootHide + ElleKit

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <dlfcn.h>
#import <pthread.h>
#import "../SharedFrame.h"

// ============================================================
// 共享内存操作
// ============================================================

static int g_sharedFrameFD = -1;
static SharedMemoryLayout *g_sharedMemory = NULL;
static pthread_mutex_t g_frameMutex = PTHREAD_MUTEX_INITIALIZER;

static BOOL initSharedMemory(void) {
    if (g_sharedMemory != NULL) return YES;

    g_sharedFrameFD = shm_open(SHARED_MEMORY_NAME, O_RDWR | O_CREAT, 0644);
    if (g_sharedFrameFD < 0) return NO;

    g_sharedMemory = (SharedMemoryLayout *)mmap(
        NULL, SHARED_MEMORY_TOTAL_SIZE,
        PROT_READ | PROT_WRITE, MAP_SHARED,
        g_sharedFrameFD, 0
    );

    if (g_sharedMemory == MAP_FAILED) {
        g_sharedMemory = NULL;
        close(g_sharedFrameFD);
        g_sharedFrameFD = -1;
        return NO;
    }

    return YES;
}

// 检查视频注入是否启用
static BOOL isVideoInjectionEnabled(void) {
    if (g_sharedMemory == NULL) return YES; // 默认开启
    if (g_sharedMemory->frameHeader.magic != 0x524D5046) return YES;
    if (g_sharedMemory->frameHeader.videoInjectionEnabled == 0) return NO;
    return YES;
}

// 检查音频注入是否启用
static BOOL isAudioInjectionEnabled(void) {
    if (g_sharedMemory == NULL) return NO;
    if (g_sharedMemory->frameHeader.magic != 0x524D5046) return NO;
    return g_sharedMemory->frameHeader.audioInjectionEnabled != 0;
}

static BOOL copyLatestFrame(uint8_t *dstBuffer, size_t dstSize, SharedFrameHeader *outHeader) {
    pthread_mutex_lock(&g_frameMutex);

    if (g_sharedMemory == NULL) {
        if (!initSharedMemory()) {
            pthread_mutex_unlock(&g_frameMutex);
            return NO;
        }
    }

    if (g_sharedMemory->frameHeader.magic != 0x524D5046) {
        pthread_mutex_unlock(&g_frameMutex);
        return NO;
    }

    // 检查注入开关
    if (g_sharedMemory->frameHeader.videoInjectionEnabled == 0) {
        pthread_mutex_unlock(&g_frameMutex);
        return NO;
    }

    // sourceType == 0 表示真实摄像头模式
    if (g_sharedMemory->frameHeader.sourceType == 0) {
        pthread_mutex_unlock(&g_frameMutex);
        return NO;
    }

    uint32_t dataSize = g_sharedMemory->frameHeader.dataSize;
    if (dataSize == 0 || dataSize > dstSize) {
        pthread_mutex_unlock(&g_frameMutex);
        return NO;
    }

    memcpy(dstBuffer, g_sharedMemory->frameData, dataSize);
    if (outHeader) {
        memcpy(outHeader, &g_sharedMemory->frameHeader, sizeof(SharedFrameHeader));
    }

    pthread_mutex_unlock(&g_frameMutex);
    return YES;
}

// ============================================================
// 从共享内存创建 CMSampleBuffer
// ============================================================

static CMSampleBufferRef createSampleBufferFromSharedMemory(CMTime timestamp) {
    SharedFrameHeader header = {0};
    size_t maxSize = MAX_FRAME_WIDTH * MAX_FRAME_HEIGHT * 4;
    uint8_t *frameBuffer = (uint8_t *)malloc(maxSize);

    BOOL gotFrame = copyLatestFrame(frameBuffer, maxSize, &header);
    if (!gotFrame || header.dataSize == 0) {
        free(frameBuffer);
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(header.width),
        (id)kCVPixelBufferHeightKey: @(header.height),
        (id)kCVPixelBufferBytesPerRowAlignmentKey: @(64),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        header.width, header.height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &pixelBuffer
    );

    if (status != kCVReturnSuccess) {
        free(frameBuffer);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *baseAddr = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bufBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    size_t bufHeight = CVPixelBufferGetHeight(pixelBuffer);

    for (size_t row = 0; row < header.height && row < bufHeight; row++) {
        memcpy(baseAddr + row * bufBytesPerRow,
               frameBuffer + row * header.bytesPerRow,
               MIN(header.bytesPerRow, bufBytesPerRow));
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    free(frameBuffer);

    CMVideoFormatDescriptionRef formatDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);

    if (!formatDesc) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    CMSampleTimingInfo timingInfo;
    timingInfo.duration = CMTimeMake(1, 30);
    timingInfo.presentationTimeStamp = timestamp;
    timingInfo.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sampleBuffer = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault, pixelBuffer, formatDesc, &timingInfo, &sampleBuffer
    );

    CFRelease(formatDesc);
    CVPixelBufferRelease(pixelBuffer);

    return sampleBuffer;
}

// ============================================================
// RTMPProxyDelegate - 代理拦截器
// ============================================================

@interface RTMPProxyDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> originalDelegate;
@property (nonatomic, assign) dispatch_queue_t sampleBufferQueue;
- (instancetype)initWithOriginalDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate;
@end

@implementation RTMPProxyDelegate

- (instancetype)initWithOriginalDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate {
    self = [super init];
    if (self) {
        _originalDelegate = delegate;
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    // 检查视频注入开关
    if (!isVideoInjectionEnabled()) {
        // 注入关闭，直接转发原始帧
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output
                         didOutputSampleBuffer:sampleBuffer
                                fromConnection:connection];
        }
        return;
    }

    // 尝试从共享内存获取虚拟帧
    CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMSampleBufferRef virtualBuffer = createSampleBufferFromSharedMemory(timestamp);

    if (virtualBuffer) {
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output
                         didOutputSampleBuffer:virtualBuffer
                                fromConnection:connection];
        }
        CFRelease(virtualBuffer);
    } else {
        // 没有虚拟帧，转发原始帧
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output
                         didOutputSampleBuffer:sampleBuffer
                                fromConnection:connection];
        }
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [self.originalDelegate captureOutput:output
                       didDropSampleBuffer:sampleBuffer
                             fromConnection:connection];
    }
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.originalDelegate respondsToSelector:aSelector]) {
        return self.originalDelegate;
    }
    return [super forwardingTargetForSelector:aSelector];
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    return [self.originalDelegate respondsToSelector:aSelector];
}

@end

// ============================================================
// 关联对象 Key
// ============================================================

static const char kProxyDelegateKey = 'p';

// ============================================================
// Hook: AVCaptureVideoDataOutput setSampleBufferDelegate:queue:
// ============================================================

static void (*orig_setSampleBufferDelegate)(id, SEL, id, dispatch_queue_t);

static void override_setSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    if (delegate && [delegate conformsToProtocol:@protocol(AVCaptureVideoDataOutputSampleBufferDelegate)]) {
        RTMPProxyDelegate *proxy = objc_getAssociatedObject(delegate, &kProxyDelegateKey);
        if (!proxy) {
            proxy = [[RTMPProxyDelegate alloc] initWithOriginalDelegate:delegate];
            proxy.sampleBufferQueue = queue;
            objc_setAssociatedObject(delegate, &kProxyDelegateKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        orig_setSampleBufferDelegate(self, _cmd, proxy, queue);
    } else {
        orig_setSampleBufferDelegate(self, _cmd, delegate, queue);
    }
}

// ============================================================
// Hook: AVCaptureDevice - 虚拟设备支持
// ============================================================

static NSArray *(*orig_formats)(id, SEL);
static NSArray *override_formats(id self, SEL _cmd) {
    return orig_formats(self, _cmd);
}

// ============================================================
// %ctor - Tweak 初始化
// ============================================================

%ctor {
    @autoreleasepool {
        NSLog(@"[RTMPCameraTweak] 正在初始化...");

        initSharedMemory();

        // Hook AVCaptureVideoDataOutput
        Class videoOutputClass = NSClassFromString(@"AVCaptureVideoDataOutput");
        if (videoOutputClass) {
            MSHookMessageEx(
                videoOutputClass,
                @selector(setSampleBufferDelegate:queue:),
                (IMP)&override_setSampleBufferDelegate,
                (IMP *)&orig_setSampleBufferDelegate
            );
            NSLog(@"[RTMPCameraTweak] 已 Hook AVCaptureVideoDataOutput");
        }

        // Hook AVCaptureDevice formats
        Class deviceClass = NSClassFromString(@"AVCaptureDevice");
        if (deviceClass) {
            MSHookMessageEx(
                deviceClass,
                @selector(formats),
                (IMP)&override_formats,
                (IMP *)&orig_formats
            );
            NSLog(@"[RTMPCameraTweak] 已 Hook AVCaptureDevice");
        }

        NSLog(@"[RTMPCameraTweak] 初始化完成");
    }
}

%dtor {
    NSLog(@"[RTMPCameraTweak] 正在卸载...");
    if (g_sharedMemory != NULL) {
        munmap(g_sharedMemory, SHARED_MEMORY_TOTAL_SIZE);
        g_sharedMemory = NULL;
    }
    if (g_sharedFrameFD >= 0) {
        close(g_sharedFrameFD);
        g_sharedFrameFD = -1;
    }
    NSLog(@"[RTMPCameraTweak] 已卸载");
}
