// main.m - RTMPDaemon
// 后台守护进程: RTMP接收 (手机作服务器) + 本地视频 + 帧缓冲共享内存
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
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import "../SharedFrame.h"

// ============================================================
// 全局状态
// ============================================================

static volatile BOOL g_running = YES;
static volatile int g_currentSource = RTMPVideoSourceRealCamera; // 默认真实摄像头
static char g_rtmpURL[MAX_RTMP_URL_LENGTH] = "";
static char g_localVideoPath[MAX_VIDEO_PATH_LENGTH] = "";
static volatile uint32_t g_videoInjectionEnabled = 1;  // 默认开启视频注入
static volatile uint32_t g_audioInjectionEnabled = 0;  // 默认关闭音频注入
static volatile uint32_t g_loopEnabled = 1;            // 默认循环
static int g_sharedFrameFD = -1;
static int g_controlFD = -1;
static SharedMemoryLayout *g_sharedMemory = NULL;
static SharedControlData *g_controlMemory = NULL;
static int g_logFD = -1;
static SharedLogBuffer *g_logBuffer = NULL;
static pthread_mutex_t g_frameMutex = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_frameIndex = 0;

// ============================================================
// 信号处理
// ============================================================


// ============================================================
// 日志写入 (共享内存)
// ============================================================
static void writeLog(const char *format, ...) {
    if (g_logBuffer == NULL) return;
    char msg[MAX_LOG_MSG_LEN];
    va_list args;
    va_start(args, format);
    vsnprintf(msg, MAX_LOG_MSG_LEN, format, args);
    va_end(args);
    
    uint32_t idx = g_logBuffer->writeIndex % MAX_LOG_ENTRIES;
    g_logBuffer->entries[idx].timestamp = mach_absolute_time();
    g_logBuffer->entries[idx].source = 0; // Daemon
    strncpy(g_logBuffer->entries[idx].message, msg, MAX_LOG_MSG_LEN - 1);
    g_logBuffer->entries[idx].message[MAX_LOG_MSG_LEN - 1] = '\0';
    g_logBuffer->writeIndex++;
    g_logBuffer->totalCount++;
    
    NSLog(@"[RTMPDaemon] %s", msg);
}
(int sig) {
    NSLog(@"[RTMPDaemon] 收到信号 %d, 准备退出", sig);
    g_running = NO;
}

// ============================================================
// 共享内存初始化
// ============================================================

static BOOL initSharedMemory(void) {
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

    memset(g_sharedMemory, 0, SHARED_MEMORY_TOTAL_SIZE);
    g_sharedMemory->frameHeader.magic = 0x524D5046;
    g_sharedMemory->frameHeader.version = 1;
    g_sharedMemory->frameHeader.sourceType = RTMPVideoSourceRealCamera;
    g_sharedMemory->frameHeader.width = 640;
    g_sharedMemory->frameHeader.height = 480;
    g_sharedMemory->frameHeader.bytesPerRow = 640 * 4;
    g_sharedMemory->frameHeader.videoInjectionEnabled = 1;
    g_sharedMemory->frameHeader.audioInjectionEnabled = 0;
    g_sharedMemory->frameHeader.loopEnabled = 1;

    // 控制共享内存
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
            g_controlMemory->sourceType = RTMPVideoSourceRealCamera;
            g_controlMemory->videoInjectionEnabled = 1;
            g_controlMemory->audioInjectionEnabled = 0;
            g_controlMemory->loopEnabled = 1;
        } else {
            g_controlMemory = NULL;
        }
    }

        // 日志共享内存
    g_logFD = shm_open(LOG_MEMORY_NAME, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (g_logFD >= 0) {
        ftruncate(g_logFD, sizeof(SharedLogBuffer));
        g_logBuffer = (SharedLogBuffer *)mmap(NULL, sizeof(SharedLogBuffer), PROT_READ | PROT_WRITE, MAP_SHARED, g_logFD, 0);
        if (g_logBuffer != MAP_FAILED) {
            memset(g_logBuffer, 0, sizeof(SharedLogBuffer));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincompatible-function-pointer-types"
            writeLog("Daemon 启动 v1.0.2");
#pragma clang diagnostic pop
        } else { g_logBuffer = NULL; }
    }
     (默认: 真实摄像头, 视频注入=开)");
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
    if (dataSize > FRAME_BUFFER_SIZE) dataSize = FRAME_BUFFER_SIZE;

    memcpy(g_sharedMemory->frameData, bgraData, dataSize);

    g_sharedMemory->frameHeader.frameIndex = g_frameIndex++;
    g_sharedMemory->frameHeader.width = (uint32_t)width;
    g_sharedMemory->frameHeader.height = (uint32_t)height;
    g_sharedMemory->frameHeader.bytesPerRow = (uint32_t)bytesPerRow;
    g_sharedMemory->frameHeader.timestamp = mach_absolute_time();
    g_sharedMemory->frameHeader.sourceType = (uint32_t)g_currentSource;
    g_sharedMemory->frameHeader.dataSize = (uint32_t)dataSize;
    g_sharedMemory->frameHeader.videoInjectionEnabled = g_videoInjectionEnabled;
    g_sharedMemory->frameHeader.audioInjectionEnabled = g_audioInjectionEnabled;
    g_sharedMemory->frameHeader.loopEnabled = g_loopEnabled;

    pthread_mutex_unlock(&g_frameMutex);
}

// ============================================================
// RTMP 接收服务器 (手机作为 RTMP 服务器，接收 OBS 推流)
// 监听端口 1935，等待 OBS 连接并推流
// 使用 socket + 简易 FLV 解析
// ============================================================

static void *rtmpReceiveThread(void *arg) {
    writeLog("RTMP 接收服务器启动 - 端口 1935") - 端口 1935");

    int listenFD = socket(AF_INET, SOCK_STREAM, 0);
    if (listenFD < 0) {
        NSLog(@"[RTMPDaemon] socket 创建失败: %s", strerror(errno));
        return NULL;
    }

    int reuse = 1;
    setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(1935);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(listenFD, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[RTMPDaemon] bind 失败: %s", strerror(errno));
        close(listenFD);
        return NULL;
    }

    if (listen(listenFD, 5) < 0) {
        NSLog(@"[RTMPDaemon] listen 失败: %s", strerror(errno));
        close(listenFD);
        return NULL;
    }

    writeLog("RTMP 服务器已就绪, 等待 OBS 推流..."), 等待 OBS 推流...");

    // 设置非阻塞
    int flags = fcntl(listenFD, F_GETFL, 0);
    fcntl(listenFD, F_SETFL, flags | O_NONBLOCK);

    const int frameWidth = 640;
    const int frameHeight = 480;
    const int bytesPerRow = frameWidth * 4;
    uint8_t *frameBuffer = (uint8_t *)malloc(frameHeight * bytesPerRow);
    memset(frameBuffer, 0, frameHeight * bytesPerRow);

    struct timeval tv;
    BOOL clientConnected = NO;
    int clientFD = -1;
    uint8_t *recvBuf = (uint8_t *)malloc(1024 * 64);
    int tickColor = 0;

    while (g_running && g_currentSource == RTMPVideoSourceRTMPStream) {
        @autoreleasepool {
            // 接受连接
            if (!clientConnected) {
                fd_set rfds;
                FD_ZERO(&rfds);
                FD_SET(listenFD, &rfds);
                tv.tv_sec = 0;
                tv.tv_usec = 500000;

                if (select(listenFD + 1, &rfds, NULL, NULL, &tv) > 0) {
                    struct sockaddr_in clientAddr;
                    socklen_t addrLen = sizeof(clientAddr);
                    clientFD = accept(listenFD, (struct sockaddr *)&clientAddr, &addrLen);
                    if (clientFD >= 0) {
                        clientConnected = YES;
                        writeLog("OBS 已连接: %s", inet_ntoa(clientAddr.sin_addr)): %s", inet_ntoa(clientAddr.sin_addr));
                        // 设置客户端为非阻塞
                        int cflags = fcntl(clientFD, F_GETFL, 0);
                        fcntl(clientFD, F_SETFL, cflags | O_NONBLOCK);
                    }
                }
            } else {
                // 读取数据 (FLV 格式)
                ssize_t n = recv(clientFD, recvBuf, 1024 * 64, 0);
                if (n <= 0) {
                    if (n == 0 || errno != EAGAIN) {
                        // 断开
                        writeLog("OBS 已断开")");
                        close(clientFD);
                        clientFD = -1;
                        clientConnected = NO;
                    }
                } else {
                    // 简单的数据接收指示帧
                    // 实际应解析 RTMP/FLV 协议提取 H.264 并解码
                    // 此处用动态指示色表示数据正在接收
                }
            }

            // 生成接收状态帧
            for (int y = 0; y < frameHeight; y++) {
                for (int x = 0; x < frameWidth; x++) {
                    int idx = y * bytesPerRow + x * 4;
                    if (clientConnected) {
                        // 绿色脉冲 = 正在接收数据
                        float pulse = (float)((tickColor + x / 4) % 128) / 128.0f;
                        frameBuffer[idx + 0] = (uint8_t)(30 + pulse * 40);   // B
                        frameBuffer[idx + 1] = (uint8_t)(100 + pulse * 80);  // G
                        frameBuffer[idx + 2] = (uint8_t)(pulse * 60);        // R
                        frameBuffer[idx + 3] = 255;
                    } else {
                        // 暗色 = 等待连接
                        frameBuffer[idx + 0] = 40;  frameBuffer[idx + 1] = 40;
                        frameBuffer[idx + 2] = 60;  frameBuffer[idx + 3] = 255;
                    }
                }
            }

            writeFrameToSharedMemory(frameBuffer, frameWidth, frameHeight, bytesPerRow);
            tickColor++;
            usleep(33000);
        }
    }

    if (clientFD >= 0) close(clientFD);
    close(listenFD);
    free(frameBuffer);
    free(recvBuf);

    NSLog(@"[RTMPDaemon] RTMP 接收服务器已停止");
    return NULL;
}

// ============================================================
// 本地视频读取器 (支持循环)
// ============================================================

static void *localVideoThread(void *arg) {
    writeLog("本地视频线程启动 (循环=%d): %s", g_loopEnabled, g_localVideoPath) (循环=%d): %s", g_loopEnabled, g_localVideoPath);

    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:g_localVideoPath];
        if (!path || path.length == 0) {
            // 无文件，生成占位帧
            const int w = 640, h = 480, bpr = w * 4;
            uint8_t *buf = (uint8_t *)malloc(h * bpr);
            while (g_running && g_currentSource == RTMPVideoSourceLocalVideo) {
                @autoreleasepool {
                    for (int y = 0; y < h; y++)
                        for (int x = 0; x < w; x++) {
                            int idx = y * bpr + x * 4;
                            buf[idx+0]=60; buf[idx+1]=60; buf[idx+2]=80; buf[idx+3]=255;
                        }
                    writeFrameToSharedMemory(buf, w, h, bpr);
                    usleep(33000);
                }
            }
            free(buf);
            return NULL;
        }

        NSURL *url = [NSURL fileURLWithPath:path];
        AVAsset *asset = [AVAsset assetWithURL:url];
        if (!asset) { NSLog(@"[RTMPDaemon] 无法创建 AVAsset"); return NULL; }

        while (g_running && g_currentSource == RTMPVideoSourceLocalVideo) {
            @autoreleasepool {
                NSError *error = nil;
                AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
                if (!reader) { NSLog(@"[RTMPDaemon] reader失败: %@", error); break; }

                AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
                if (!videoTrack) { NSLog(@"[RTMPDaemon] 无视频轨道"); break; }

                NSDictionary *settings = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                    (id)kCVPixelBufferWidthKey: @(640),
                    (id)kCVPixelBufferHeightKey: @(480),
                };

                AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
                    initWithTrack:videoTrack outputSettings:settings];

                if (![reader canAddOutput:output] || ![reader startReading]) {
                    NSLog(@"[RTMPDaemon] 启动读取失败"); break;
                }
                [reader addOutput:output];

                while (g_running && g_currentSource == RTMPVideoSourceLocalVideo &&
                       reader.status == AVAssetReaderStatusReading) {
                    @autoreleasepool {
                        CMSampleBufferRef sb = [output copyNextSampleBuffer];
                        if (!sb) break;

                        CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sb);
                        if (px) {
                            CVPixelBufferLockBaseAddress(px, kCVPixelBufferLock_ReadOnly);
                            writeFrameToSharedMemory(
                                (uint8_t *)CVPixelBufferGetBaseAddress(px),
                                CVPixelBufferGetWidth(px),
                                CVPixelBufferGetHeight(px),
                                CVPixelBufferGetBytesPerRow(px)
                            );
                            CVPixelBufferUnlockBaseAddress(px, kCVPixelBufferLock_ReadOnly);
                        }
                        CFRelease(sb);
                        usleep(33000);
                    }
                }
                [reader cancelReading];
            }

            // 检查循环
            if (!g_loopEnabled || g_currentSource != RTMPVideoSourceLocalVideo) break;
            NSLog(@"[RTMPDaemon] 循环播放: 重新开始");
        }
    }

    NSLog(@"[RTMPDaemon] 本地视频线程退出");
    return NULL;
}

// ============================================================
// 控制命令监听线程
// ============================================================

static void *controlListenerThread(void *arg) {
    NSLog(@"[RTMPDaemon] 控制监听线程启动");

    uint32_t lastCommand = RTMPControlNone;
    uint32_t lastSourceType = RTMPVideoSourceRealCamera;

    while (g_running) {
        if (g_controlMemory == NULL) { usleep(500000); continue; }

        uint32_t cmd = g_controlMemory->command;
        uint32_t srcType = g_controlMemory->sourceType;

        if (cmd != lastCommand || srcType != lastSourceType) {
            lastCommand = cmd;
            lastSourceType = srcType;

            NSLog(@"[RTMPDaemon] 控制命令: cmd=%u src=%u vidInj=%u audInj=%u loop=%u",
                  cmd, srcType,
                  g_controlMemory->videoInjectionEnabled,
                  g_controlMemory->audioInjectionEnabled,
                  g_controlMemory->loopEnabled);

            switch (cmd) {
                case 1: // RTMPControlSwitchSource
                    g_currentSource = (int)srcType;
                    g_videoInjectionEnabled = g_controlMemory->videoInjectionEnabled;
                    g_audioInjectionEnabled = g_controlMemory->audioInjectionEnabled;
                    g_loopEnabled = g_controlMemory->loopEnabled;

                    if (srcType == RTMPVideoSourceRTMPStream) {
                        strncpy(g_rtmpURL, g_controlMemory->rtmpURL, MAX_RTMP_URL_LENGTH - 1);
                    }
                    if (srcType == RTMPVideoSourceLocalVideo) {
                        strncpy(g_localVideoPath, g_controlMemory->localVideoPath, MAX_VIDEO_PATH_LENGTH - 1);
                    }
                    break;

                case 8: // RTMPControlReset
                    g_currentSource = RTMPVideoSourceRealCamera;
                    g_videoInjectionEnabled = 1;
                    g_audioInjectionEnabled = 0;
                    g_loopEnabled = 1;
                    memset(g_localVideoPath, 0, MAX_VIDEO_PATH_LENGTH);
                    break;

                case 6: // RTMPControlSetInjection
                    g_videoInjectionEnabled = g_controlMemory->videoInjectionEnabled;
                    g_audioInjectionEnabled = g_controlMemory->audioInjectionEnabled;
                    break;

                case 7: // RTMPControlSetLoop
                    g_loopEnabled = g_controlMemory->loopEnabled;
                    break;
            }

            g_controlMemory->command = RTMPControlNone;

            // 同步更新帧头
            if (g_sharedMemory) {
                g_sharedMemory->frameHeader.videoInjectionEnabled = g_videoInjectionEnabled;
                g_sharedMemory->frameHeader.audioInjectionEnabled = g_audioInjectionEnabled;
                g_sharedMemory->frameHeader.loopEnabled = g_loopEnabled;
            }
        }

        usleep(100000);
    }

    return NULL;
}

// ============================================================
// 主循环调度
// ============================================================

static void startVideoSourceThread(pthread_t *thread, int sourceType) {
    switch (sourceType) {
        case RTMPVideoSourceRTMPStream:
            pthread_create(thread, NULL, rtmpReceiveThread, NULL);
            break;
        case RTMPVideoSourceLocalVideo:
            pthread_create(thread, NULL, localVideoThread, NULL);
            break;
        case RTMPVideoSourceRealCamera:
        default:
            // 真实摄像头: 不写帧, Tweak 端 sees sourceType==0 → 不注入
            break;
    }
}

// ============================================================
// 主函数
// ============================================================

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"[RTMPDaemon] ===============================");
        NSLog(@"[RTMPDaemon] RTMPCamera 守护进程 v1.0.1");
        NSLog(@"[RTMPDaemon] ===============================");

        signal(SIGTERM, signalHandler);
        signal(SIGINT, signalHandler);
        signal(SIGQUIT, signalHandler);

        if (!initSharedMemory()) {
            NSLog(@"[RTMPDaemon] 初始化失败");
            return 1;
        }

        pthread_t controlThread;
        pthread_create(&controlThread, NULL, controlListenerThread, NULL);

        int currentSource = g_currentSource;
        pthread_t videoThread = 0;

        NSLog(@"[RTMPDaemon] 启动, 初始源=真摄像头");
        startVideoSourceThread(&videoThread, currentSource);

        while (g_running) {
            @autoreleasepool {
                if (g_currentSource != currentSource) {
                    int oldSource = currentSource;
                    currentSource = g_currentSource;

                    if (videoThread) { pthread_join(videoThread, NULL); videoThread = 0; }
                    startVideoSourceThread(&videoThread, currentSource);
                }
                usleep(500000);
            }
        }

        if (videoThread) { pthread_cancel(videoThread); pthread_join(videoThread, NULL); }
        pthread_join(controlThread, NULL);

        if (g_sharedMemory) { munmap(g_sharedMemory, SHARED_MEMORY_TOTAL_SIZE); }
        if (g_controlMemory) { munmap(g_controlMemory, sizeof(SharedControlData)); }
        if (g_sharedFrameFD >= 0) { close(g_sharedFrameFD); shm_unlink(SHARED_MEMORY_NAME); }
        if (g_logBuffer && g_logBuffer != MAP_FAILED) { munmap(g_logBuffer, sizeof(SharedLogBuffer)); } if (g_logFD >= 0) { close(g_logFD); shm_unlink(LOG_MEMORY_NAME); } if (g_controlFD >= 0) { close(g_controlFD); shm_unlink(CONTROL_MEMORY_NAME); }

        NSLog(@"[RTMPDaemon] 已退出");
    }
    return 0;
}

