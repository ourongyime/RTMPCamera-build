// SharedFrame.h v1.0.2 - 共享内存帧结构定义
// 新增: 日志系统 + 状态反馈

#ifndef SharedFrame_h
#define SharedFrame_h

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

#define MAX_FRAME_WIDTH  1920
#define MAX_FRAME_HEIGHT 1080
#define FRAME_BUFFER_SIZE (MAX_FRAME_WIDTH * MAX_FRAME_HEIGHT * 4)
#define SHARED_MEMORY_NAME "/tmp/rtmpcamera_shared_frame"

typedef NS_ENUM(NSInteger, RTMPVideoSource) {
    RTMPVideoSourceRealCamera = 0,
    RTMPVideoSourceRTMPStream,
    RTMPVideoSourceLocalVideo,
};

typedef NS_ENUM(NSInteger, RTMPControlCommand) {
    RTMPControlNone = 0,
    RTMPControlSwitchSource,
    RTMPControlSetRTMPURL,
    RTMPControlSetLocalVideoPath,
    RTMPControlStart,
    RTMPControlStop,
    RTMPControlSetInjection,
    RTMPControlSetLoop,
    RTMPControlReset,
};

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t frameIndex;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint64_t timestamp;
    uint32_t sourceType;
    uint32_t dataSize;
    uint32_t videoInjectionEnabled;
    uint32_t audioInjectionEnabled;
    uint32_t loopEnabled;
    uint8_t  reserved[20];
} SharedFrameHeader;

#define SHARED_MEMORY_TOTAL_SIZE (sizeof(SharedFrameHeader) + FRAME_BUFFER_SIZE)

typedef struct {
    SharedFrameHeader frameHeader;
    uint8_t frameData[FRAME_BUFFER_SIZE];
} SharedMemoryLayout;

// 日志系统
#define LOG_MEMORY_NAME "/tmp/rtmpcamera_log"
#define MAX_LOG_ENTRIES 100
#define MAX_LOG_MSG_LEN 256

typedef struct {
    uint32_t writeIndex;                    // 当前写入位置
    uint32_t totalCount;                    // 总日志条数
    struct LogEntry {
        uint64_t timestamp;                 // mach_absolute_time
        uint32_t source;                    // 0=Daemon, 1=Tweak, 2=App
        char     message[MAX_LOG_MSG_LEN];  // 日志消息
    } entries[MAX_LOG_ENTRIES];
} SharedLogBuffer;

// 控制命令结构
#define CONTROL_MEMORY_NAME "/tmp/rtmpcamera_control"
#define MAX_RTMP_URL_LENGTH  512
#define MAX_VIDEO_PATH_LENGTH 1024

typedef struct {
    uint32_t command;
    uint32_t sourceType;
    uint32_t videoInjectionEnabled;
    uint32_t audioInjectionEnabled;
    uint32_t loopEnabled;
    uint32_t daemonStatus;           // 0=stopped, 1=running, 2=error
    uint32_t frameFPS;               // 当前帧率
    char     rtmpURL[MAX_RTMP_URL_LENGTH];
    char     localVideoPath[MAX_VIDEO_PATH_LENGTH];
    uint8_t  reserved[48];
} SharedControlData;

#define DEFAULT_RTMP_PORT 1935

#endif
