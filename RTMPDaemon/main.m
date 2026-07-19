// main.m - RTMPDaemon
// 后台守护进程: RTMP拉流 + 本地视频 + 测试帧 + 帧缓冲共享内存
// 适配 iOS 16.1 + RootHide 无根越狱

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <UIKit/UIKit.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <pthread.h>
#import <signal.h>
#import <dlfcn.h>
#import "../SharedFrame.h"

// ============================================================
// 全局状态
// ============================================================

static volatile BOOL g_running = YES;
static volatile int g_currentSource = RTMPVideoSourceTestPattern; // 默认测试帧
static char g_rtmpURL[MAX_RTMP_URL_LENGTH] = "rtmp://127.0.0.1/live/stream";
static char g_localVideoPath[MAX_VIDEO_PATH_LENGTH] = "";
static int g_sharedFrameFD = -1;
static int g_controlFD = -1;
static SharedMemoryLayout *g_sharedMemory = NULL;
static SharedControlData *g_controlMemory = NULL;
static pthread_mutex_t g_frameMutex = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_frameIndex = 0;

// ============================================================
// 信号处理
// ============================================================

static void signalHandler(int sig) {
    NSLog(@"[RTMPDaemon] 收到信号 %d, 准备退出", sig);
    g_running = NO;
}

// ============================================================
// 共享内存初始化
// ============================================================

static BOOL initSharedMemory(void) {
    // 创建帧共享内存
    g_sharedFrameFD = shm_open(SHARED_MEMORY_NAME, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (g_sharedFrameFD < 0) {
        NSLog(@"[RTMPDaemon] shm_open 帧缓冲区失败: %s", strerror(errno));
        return NO;
    }

    if (ftruncate(g_sharedFrameFD, SHARED_MEMORY_TOTAL_SIZE) < 0) {
        NSLog(@"[RTMPDaemon] ftruncate 失败: %s", strerror(errno));
        return NO;
    }

    g_sharedMemory = (SharedMemoryLayout *)mmap(
        NULL, SHARED_MEMORY_TOTAL_SIZE,
        PROT_READ | PROT_WRITE, MAP_SHARED,
        g_sharedFrameFD, 0
    );

    if (g_sharedMemory == MAP_FAILED) {
        NSLog(@"[RTMPDaemon] mmap 帧缓冲区失败");
        g_sharedMemory = NULL;
        return NO;
    }

    // 初始化帧头
    memset(g_sharedMemory, 0, SHARED_MEMORY_TOTAL_SIZE);
    g_sharedMemory->frameHeader.magic = 0x524D5046;
    g_sharedMemory->frameHeader.version = 1;
    g_sharedMemory->frameHeader.sourceType = RTMPVideoSourceTestPattern;
    g_sharedMemory->frameHeader.width = 640;
    g_sharedMemory->frameHeader.height = 480;
    g_sharedMemory->frameHeader.bytesPerRow = 640 * 4;

    // 创建控制共享内存
    g_controlFD = shm_open(CONTROL_MEMORY_NAME, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (g_controlFD >= 0) {
        ftruncate(g_controlFD, sizeof(SharedControlData));
        g_controlMemory = (SharedControlData *)mmap(
            NULL, sizeof(SharedControlData),
            PROT_READ | PROT_WRITE, MAP_SHARED,
            g_controlFD, 0
        );

        if (g_controlMemory != MAP_FAILED) {
            memset(g_controlMemory, 0, sizeof(SharedControlData));
            g_controlMemory->command = RTMPControlNone;
            g_controlMemory->sourceType = RTMPVideoSourceTestPattern;
        } else {
            g_controlMemory = NULL;
        }
    }

    NSLog(@"[RTMPDaemon] 共享内存初始化完成");
    return YES;
}

// ============================================================
// 帧写入函数
// ============================================================

static void writeFrameToSharedMemory(uint8_t *bgraData, size_t width, size_t height, size_t bytesPerRow) {
    pthread_mutex_lock(&g_frameMutex);

    if (g_sharedMemory == NULL) {
        pthread_mutex_unlock(&g_frameMutex);
        return;
    }

    size_t dataSize = height * bytesPerRow;
    if (dataSize > FRAME_BUFFER_SIZE) {
        dataSize = FRAME_BUFFER_SIZE;
    }

    // 写入帧数据
    memcpy(g_sharedMemory->frameData, bgraData, dataSize);

    // 更新帧头
    g_sharedMemory->frameHeader.frameIndex = g_frameIndex++;
    g_sharedMemory->frameHeader.width = (uint32_t)width;
    g_sharedMemory->frameHeader.height = (uint32_t)height;
    g_sharedMemory->frameHeader.bytesPerRow = (uint32_t)bytesPerRow;
    g_sharedMemory->frameHeader.timestamp = mach_absolute_time();
    g_sharedMemory->frameHeader.sourceType = (uint32_t)g_currentSource;
    g_sharedMemory->frameHeader.dataSize = (uint32_t)dataSize;

    pthread_mutex_unlock(&g_frameMutex);
}

// ============================================================
// 测试帧生成器
// ============================================================

static void *testPatternThread(void *arg) {
    NSLog(@"[RTMPDaemon] 测试帧线程启动");

    const int width = 640;
    const int height = 480;
    const int bytesPerRow = width * 4;
    uint8_t *buffer = (uint8_t *)malloc(height * bytesPerRow);

    int colorPhase = 0;
    CFAbsoluteTime lastTime = CFAbsoluteTimeGetCurrent();
    int frameCount = 0;

    while (g_running && g_currentSource == RTMPVideoSourceTestPattern) {
        @autoreleasepool {
            // 生成渐变彩色测试帧
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    int idx = y * bytesPerRow + x * 4;
                    float fx = (float)x / width;
                    float fy = (float)y / height;
                    float phase = (float)colorPhase / 256.0f;

                    // 彩色渐变 + 移动条纹
                    uint8_t b = (uint8_t)((fx * 255.0f + phase * 50.0f));
                    uint8_t g = (uint8_t)((fy * 255.0f + phase * 80.0f));
                    uint8_t r = (uint8_t)(((1.0f - fx - fy) / 2.0f * 255.0f + phase * 120.0f));
                    uint8_t a = 255;

                    buffer[idx + 0] = b; // B
                    buffer[idx + 1] = g; // G
                    buffer[idx + 2] = r; // R
                    buffer[idx + 3] = a; // A
                }
            }

            // 在画面上绘制帧号和时间戳
            // (简化处理，不绘制文字)

            writeFrameToSharedMemory(buffer, width, height, bytesPerRow);

            frameCount++;
            colorPhase = (colorPhase + 1) % 256;

            // 目标 30fps
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            CFAbsoluteTime elapsed = now - lastTime;
            if (elapsed < 1.0 / 30.0) {
                usleep((useconds_t)((1.0 / 30.0 - elapsed) * 1000000));
            }
            lastTime = CFAbsoluteTimeGetCurrent();
        }
    }

    free(buffer);
    NSLog(@"[RTMPDaemon] 测试帧线程退出");
    return NULL;
}

// ============================================================
// 本地视频读取器
// ============================================================

static void *localVideoThread(void *arg) {
    NSLog(@"[RTMPDaemon] 本地视频线程启动: %s", g_localVideoPath);

    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:g_localVideoPath];
        NSURL *url = [NSURL fileURLWithPath:path];

        AVAsset *asset = [AVAsset assetWithURL:url];
        if (!asset) {
            NSLog(@"[RTMPDaemon] 无法创建 AVAsset");
            return NULL;
        }

        NSError *error = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (!reader) {
            NSLog(@"[RTMPDaemon] AVAssetReader 创建失败: %@", error);
            return NULL;
        }

        AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (!videoTrack) {
            NSLog(@"[RTMPDaemon] 没有视频轨道");
            return NULL;
        }

        // 配置输出为 BGRA 格式
        NSDictionary *outputSettings = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(640),
            (id)kCVPixelBufferHeightKey: @(480),
        };

        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
            initWithTrack:videoTrack outputSettings:outputSettings];

        if (![reader canAddOutput:output]) {
            NSLog(@"[RTMPDaemon] 无法添加读取输出");
            return NULL;
        }
        [reader addOutput:output];

        if (![reader startReading]) {
            NSLog(@"[RTMPDaemon] 读取器启动失败: %@", reader.error);
            return NULL;
        }

        NSLog(@"[RTMPDaemon] 本地视频读取器已启动");

        while (g_running && g_currentSource == RTMPVideoSourceLocalVideo &&
               reader.status == AVAssetReaderStatusReading) {
            @autoreleasepool {
                CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
                if (!sampleBuffer) {
                    // 视频结束，循环播放
                    [reader cancelReading];
                    reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
                    output = [[AVAssetReaderTrackOutput alloc]
                        initWithTrack:videoTrack outputSettings:outputSettings];
                    [reader addOutput:output];
                    [reader startReading];
                    continue;
                }

                CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                if (pixelBuffer) {
                    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

                    size_t width = CVPixelBufferGetWidth(pixelBuffer);
                    size_t height = CVPixelBufferGetHeight(pixelBuffer);
                    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
                    uint8_t *baseAddr = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);

                    writeFrameToSharedMemory(baseAddr, width, height, bytesPerRow);

                    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                }

                CFRelease(sampleBuffer);

                // 30fps 节流
                usleep(33000);
            }
        }

        [reader cancelReading];
    }

    NSLog(@"[RTMPDaemon] 本地视频线程退出");
    return NULL;
}

// ============================================================
// RTMP 拉流线程 (使用 VideoToolbox 进行软件解码模拟)
// 注意: 实际使用需要 libRTMP/ffmpeg 静态链接
// 这里提供完整的框架代码，RTMP 连接逻辑取决于编译环境
// ============================================================

// RTMP 拉流回调 - 收到视频帧时调用
static void rtmpVideoFrameCallback(uint8_t *frameData, size_t width, size_t height, size_t bytesPerRow) {
    if (!g_running || g_currentSource != RTMPVideoSourceRTMPStream) return;
    writeFrameToSharedMemory(frameData, width, height, bytesPerRow);
}

static void *rtmpPullThread(void *arg) {
    NSLog(@"[RTMPDaemon] RTMP 拉流线程启动: %s", g_rtmpURL);

    // RTMP 拉流框架代码
    // 编译环境需要 libRTMP.a (librtmp) 和 ffmpeg 库
    // 以下代码展示了完整的拉流和解码框架

    @autoreleasepool {
        // 1. 初始化 RTMP 连接
        // RTMP *rtmp = RTMP_Alloc();
        // RTMP_Init(rtmp);
        // rtmp->Link.timeout = 10;
        // RTMP_SetupURL(rtmp, g_rtmpURL);
        // RTMP_EnableWrite(rtmp);
        //
        // if (!RTMP_Connect(rtmp, NULL)) {
        //     NSLog(@"[RTMPDaemon] RTMP 连接失败");
        //     // 重试逻辑
        // }
        //
        // if (!RTMP_ConnectStream(rtmp, 0)) {
        //     NSLog(@"[RTMPDaemon] RTMP 连接流失败");
        // }

        // 2. 使用 VideoToolbox 解码 H.264 流
        // VTDecompressionSessionRef decompSession;
        // 创建 decompression session...
        //
        // 3. 读取 FLV 包, 提取 H.264 NAL units
        //
        // 4. 解码 → BGRA pixel buffer
        //
        // 5. 调用 rtmpVideoFrameCallback()

        // 占位: 当 RTMP 不可用时，生成占位测试帧
        NSLog(@"[RTMPDaemon] RTMP 库未链接, 使用模拟测试帧");
        const int width = 640;
        const int height = 480;
        const int bytesPerRow = width * 4;
        uint8_t *buffer = (uint8_t *)malloc(height * bytesPerRow);

        int tick = 0;
        while (g_running && g_currentSource == RTMPVideoSourceRTMPStream) {
            @autoreleasepool {
                // 生成"等待 RTMP 流"提示画面
                for (int y = 0; y < height; y++) {
                    for (int x = 0; x < width; x++) {
                        int idx = y * bytesPerRow + x * 4;
                        buffer[idx + 0] = 50;  // B
                        buffer[idx + 1] = 50;  // G
                        buffer[idx + 2] = 100 + (uint8_t)(sin(0.01 * (x + tick)) * 50); // R
                        buffer[idx + 3] = 255; // A
                    }
                }
                writeFrameToSharedMemory(buffer, width, height, bytesPerRow);
                tick++;
                usleep(33000); // ~30fps
            }
        }

        free(buffer);

        // RTMP_Free(rtmp);
    }

    NSLog(@"[RTMPDaemon] RTMP 拉流线程退出");
    return NULL;
}

// ============================================================
// 控制命令监听线程
// ============================================================

static void *controlListenerThread(void *arg) {
    NSLog(@"[RTMPDaemon] 控制监听线程启动");

    uint32_t lastCommand = RTMPControlNone;
    uint32_t lastSourceType = RTMPVideoSourceTestPattern;

    while (g_running) {
        if (g_controlMemory == NULL) {
            usleep(500000); // 500ms
            continue;
        }

        uint32_t cmd = g_controlMemory->command;
        uint32_t srcType = g_controlMemory->sourceType;

        if (cmd != lastCommand || srcType != lastSourceType) {
            lastCommand = cmd;
            lastSourceType = srcType;

            NSLog(@"[RTMPDaemon] 收到控制命令: cmd=%u, sourceType=%u", cmd, srcType);

            if (cmd == 3) { // RTMPControlSwitchSource
                g_currentSource = (int)srcType;

                if (srcType == RTMPVideoSourceRTMPStream) {
                    // 复制 RTMP URL
                    strncpy(g_rtmpURL, g_controlMemory->rtmpURL, MAX_RTMP_URL_LENGTH - 1);
                    g_rtmpURL[MAX_RTMP_URL_LENGTH - 1] = '\0';
                }

                if (srcType == RTMPVideoSourceLocalVideo) {
                    strncpy(g_localVideoPath, g_controlMemory->localVideoPath, MAX_VIDEO_PATH_LENGTH - 1);
                    g_localVideoPath[MAX_VIDEO_PATH_LENGTH - 1] = '\0';
                }

                // 清除命令
                g_controlMemory->command = RTMPControlNone;
            }
        }

        usleep(100000); // 100ms 轮询
    }

    NSLog(@"[RTMPDaemon] 控制监听线程退出");
    return NULL;
}

// ============================================================
// 主循环 - 视频源调度
// ============================================================

static void startVideoSourceThread(pthread_t *thread, int sourceType) {
    switch (sourceType) {
        case RTMPVideoSourceTestPattern:
            pthread_create(thread, NULL, testPatternThread, NULL);
            break;
        case RTMPVideoSourceRTMPStream:
            pthread_create(thread, NULL, rtmpPullThread, NULL);
            break;
        case RTMPVideoSourceLocalVideo:
            pthread_create(thread, NULL, localVideoThread, NULL);
            break;
        case RTMPVideoSourceRealCamera:
        default:
            // 真实摄像头模式: 不清除帧缓冲，Tweak 端判断 sourceType==0 时不注入
            break;
    }
}

// ============================================================
// 主函数
// ============================================================

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"[RTMPDaemon] ===============================");
        NSLog(@"[RTMPDaemon] RTMPCamera 守护进程启动");
        NSLog(@"[RTMPDaemon] 版本 1.0.0");
        NSLog(@"[RTMPDaemon] ===============================");

        // 注册信号处理
        signal(SIGTERM, signalHandler);
        signal(SIGINT, signalHandler);
        signal(SIGQUIT, signalHandler);

        // 初始化共享内存
        if (!initSharedMemory()) {
            NSLog(@"[RTMPDaemon] 共享内存初始化失败, 退出");
            return 1;
        }

        // 启动控制监听线程
        pthread_t controlThread;
        pthread_create(&controlThread, NULL, controlListenerThread, NULL);

        // 初始视频源
        __block int currentSource = g_currentSource;
        pthread_t videoThread = 0;

        NSLog(@"[RTMPDaemon] 主循环开始, 初始源=%d", currentSource);
        startVideoSourceThread(&videoThread, currentSource);

        // 主调度循环
        while (g_running) {
            @autoreleasepool {
                if (g_currentSource != currentSource) {
                    NSLog(@"[RTMPDaemon] 切换视频源: %d -> %d", currentSource, g_currentSource);

                    int oldSource = currentSource;
                    currentSource = g_currentSource;

                    // 等待旧线程退出
                    if (videoThread) {
                        pthread_join(videoThread, NULL);
                        videoThread = 0;
                    }

                    // 启动新线程
                    startVideoSourceThread(&videoThread, currentSource);
                }

                usleep(500000); // 500ms
            }
        }

        // 清理
        NSLog(@"[RTMPDaemon] 正在清理...");

        if (videoThread) {
            pthread_cancel(videoThread);
            pthread_join(videoThread, NULL);
        }
        pthread_join(controlThread, NULL);

        if (g_sharedMemory != NULL) {
            memset(g_sharedMemory, 0, SHARED_MEMORY_TOTAL_SIZE);
            munmap(g_sharedMemory, SHARED_MEMORY_TOTAL_SIZE);
            g_sharedMemory = NULL;
        }

        if (g_controlMemory != NULL) {
            munmap(g_controlMemory, sizeof(SharedControlData));
            g_controlMemory = NULL;
        }

        if (g_sharedFrameFD >= 0) {
            close(g_sharedFrameFD);
            shm_unlink(SHARED_MEMORY_NAME);
        }

        if (g_controlFD >= 0) {
            close(g_controlFD);
            shm_unlink(CONTROL_MEMORY_NAME);
        }

        NSLog(@"[RTMPDaemon] 守护进程已退出");
    }

    return 0;
}
