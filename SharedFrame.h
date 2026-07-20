// SharedFrame.h - 共享内存帧结构定义
// 在 RTMPDaemon 和 RTMPCameraTweak 之间传递视频帧

#ifndef SharedFrame_h
#define SharedFrame_h

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

// 最大帧宽度和高度
#define MAX_FRAME_WIDTH  1920
#define MAX_FRAME_HEIGHT 1080
// 每像素 4 字节 (BGRA)
#define FRAME_BUFFER_SIZE (MAX_FRAME_WIDTH * MAX_FRAME_HEIGHT * 4)
// 共享内存名称
#define SHARED_MEMORY_NAME "/tmp/rtmpcamera_shared_frame"

// 视频源类型 (移除测试帧)
typedef NS_ENUM(NSInteger, RTMPVideoSource) {
    RTMPVideoSourceRealCamera = 0,  // 真实摄像头
    RTMPVideoSourceRTMPStream,      // RTMP 接收 (手机作服务器)
    RTMPVideoSourceLocalVideo,      // 本地视频文件
};

// 控制指令
typedef NS_ENUM(NSInteger, RTMPControlCommand) {
    RTMPControlNone = 0,
    RTMPControlSwitchSource,         // 切换视频源
    RTMPControlSetRTMPURL,           // 设置 RTMP 地址
    RTMPControlSetLocalVideoPath,    // 设置本地视频路径
    RTMPControlStart,                // 开始
    RTMPControlStop,                 // 停止
    RTMPControlSetInjection,         // 设置注入开关
    RTMPControlSetLoop,              // 设置循环播放
    RTMPControlReset,                // 还原默认设置
};

// 共享内存中的帧元数据
typedef struct {
    uint32_t magic;                // 魔数 0x524D5046 ("RMPF")
    uint32_t version;              // 版本号
    uint32_t frameIndex;           // 帧序号 (单调递增)
    uint32_t width;                // 帧宽度
    uint32_t height;               // 帧高度
    uint32_t bytesPerRow;          // 每行字节数
    uint64_t timestamp;            // 时间戳 (mach_absolute_time)
    uint32_t sourceType;           // 视频源类型 (RTMPVideoSource)
    uint32_t dataSize;             // 实际数据大小
    uint32_t videoInjectionEnabled; // 视频注入开关 (0=关, 1=开)
    uint32_t audioInjectionEnabled; // 音频注入开关 (0=关, 1=开)
    uint32_t loopEnabled;           // 循环播放 (0=关, 1=开)
    uint8_t  reserved[20];         // 保留字段
} SharedFrameHeader;

// 共享内存布局:
// [SharedFrameHeader] + [frame data (BGRA)]

// 共享内存总大小
#define SHARED_MEMORY_TOTAL_SIZE (sizeof(SharedFrameHeader) + FRAME_BUFFER_SIZE)

// 共享内存控制结构 (用于 daemon <-> tweak 双向通信)
typedef struct {
    SharedFrameHeader frameHeader;  // 帧元数据
    uint8_t frameData[FRAME_BUFFER_SIZE]; // 帧数据 (BGRA)
} SharedMemoryLayout;

// 控制命令结构 (通过另一个共享内存段传递)
#define CONTROL_MEMORY_NAME "/tmp/rtmpcamera_control"
#define MAX_RTMP_URL_LENGTH  512
#define MAX_VIDEO_PATH_LENGTH 1024

typedef struct {
    uint32_t command;              // 控制指令 (RTMPControlCommand)
    uint32_t sourceType;           // 目标视频源类型
    uint32_t videoInjectionEnabled; // 视频注入开关
    uint32_t audioInjectionEnabled; // 音频注入开关
    uint32_t loopEnabled;           // 循环播放
    char     rtmpURL[MAX_RTMP_URL_LENGTH];        // RTMP 地址
    char     localVideoPath[MAX_VIDEO_PATH_LENGTH]; // 本地视频路径
    uint8_t  reserved[64];         // 保留
} SharedControlData;

// 默认 RTMP 接收端口
#define DEFAULT_RTMP_PORT 1935

#endif /* SharedFrame_h */
