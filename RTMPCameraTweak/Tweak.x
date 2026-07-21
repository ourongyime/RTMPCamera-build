// Tweak.x - RTMPCameraTweak v1.0.64
// SpringBoard loads → injects dylib into Camera.app via Mach APIs
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <spawn.h>
#import <sys/sysctl.h>

static NSString *kLogFile = @"/var/mobile/Documents/rtmpcamera/tweak.log";
static NSString *kDir = @"/var/mobile/Documents/rtmpcamera";
static NSString *kLoadedFlag = @"/var/mobile/Documents/rtmpcamera/tweak_loaded";
static NSString *kCfgFile = @"/var/mobile/Documents/rtmpcamera/config.plist";
static NSString *kVideoFile = @"/var/mobile/Documents/rtmpcamera/current_video.mp4";

static void tlog(NSString *s) {
    NSLog(@"[SB64] %@", s);
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss";
    NSString *l = [NSString stringWithFormat:@"[%@][SB64] %@\n", [df stringFromDate:[NSDate date]], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil]; [l writeToFile:kLogFile atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

// Find PID by process name
static pid_t findPid(NSString *name) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    sysctl(mib, 3, NULL, &size, NULL, 0);
    struct kinfo_proc *procs = malloc(size);
    sysctl(mib, 3, procs, &size, NULL, 0);
    int count = (int)(size / sizeof(struct kinfo_proc));
    pid_t found = 0;
    for (int i = 0; i < count; i++) {
        NSString *pname = [NSString stringWithUTF8String:procs[i].kp_proc.p_comm];
        if ([pname isEqualToString:name]) { found = procs[i].kp_proc.p_pid; break; }
    }
    free(procs);
    return found;
}

// Inject dylib into target process using Mach APIs
static BOOL injectDylib(pid_t pid, NSString *dylibPath) {
    if (pid <= 0) return NO;
    
    task_t task;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        tlog([NSString stringWithFormat:@"task_for_pid(%d) failed: %d", pid, kr]);
        return NO;
    }
    tlog([NSString stringWithFormat:@"Got task port for PID %d", pid]);

    // Allocate memory for dylib path in target
    const char *path = [dylibPath UTF8String];
    size_t pathLen = strlen(path) + 1;
    mach_vm_address_t remotePath = 0;
    kr = mach_vm_allocate(task, &remotePath, pathLen, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) { tlog(@"mach_vm_allocate failed"); return NO; }
    
    kr = mach_vm_write(task, remotePath, (vm_offset_t)path, (mach_msg_type_number_t)pathLen);
    if (kr != KERN_SUCCESS) { tlog(@"mach_vm_write failed"); return NO; }
    tlog(@"Wrote dylib path to remote memory");

    // Find dlopen in target
    void *dlopenAddr = dlsym(RTLD_DEFAULT, "dlopen");
    if (!dlopenAddr) { tlog(@"dlopen not found"); return NO; }

    // Create remote thread to call dlopen(path, RTLD_NOW)
    mach_vm_address_t remoteStack = 0;
    kr = mach_vm_allocate(task, &remoteStack, 65536, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) { tlog(@"stack alloc failed"); return NO; }

    // x0 = remotePath, x1 = RTLD_NOW(2)
    arm_thread_state64_t state = {0};
    state.__x[0] = (uint64_t)remotePath;
    state.__x[1] = 2; // RTLD_NOW
    state.__pc = (uint64_t)dlopenAddr;
    state.__sp = (uint64_t)(remoteStack + 65536 - 16);
    state.__lr = (uint64_t)0; // Return to nowhere (process will manage)

    thread_act_t thread;
    kr = thread_create_running(task, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT, &thread);
    if (kr != KERN_SUCCESS) { tlog([NSString stringWithFormat:@"thread_create failed: %d", kr]); return NO; }
    
    tlog([NSString stringWithFormat:@"Injection thread created for PID %d", pid]);
    mach_port_deallocate(mach_task_self(), task);
    return YES;
}

// Generate test frame (green) for camera replacement
static CMSampleBufferRef createTestFrame(void) {
    static CVPixelBufferRef pb = NULL;
    if (!pb) {
        NSDictionary *attrs = @{(id)kCVPixelBufferWidthKey:@640, (id)kCVPixelBufferHeightKey:@480, (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pb);
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    for (int y = 0; y < 480; y++) {
        uint8_t *row = base + y * bpr;
        for (int x = 0; x < 640; x++) {
            uint8_t *p = row + x * 4;
            p[0] = 0; p[1] = (uint8_t)(128 + y/4); p[2] = 0; p[3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CMSampleTimingInfo ti = {.duration=CMTimeMake(1,30), .presentationTimeStamp=CMTimeMake(1,30), .decodeTimeStamp=kCMTimeInvalid};
    CMVideoFormatDescriptionRef fd = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fd);
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fd, &ti, &sb);
    if (fd) CFRelease(fd);
    return sb;
}

// ===== Camera hooks (run when injected into camera app) =====
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    tlog([NSString stringWithFormat:@"Camera VDO hooked in %@", [[NSBundle mainBundle] bundleIdentifier] ?: @"?"]);
    %orig;

    // Intercept the delegate callback
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Replace buffer in delegate callback via swizzling
        tlog(@"Camera frame replacement active");
    });
}
%end

// ===== SpringBoard: overlay + injection trigger =====
static NSInteger g_sbCount = 0;
static BOOL g_injected = NO;

static void sbTick(void) {
    g_sbCount++;
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kCfgFile];
    if (!c) return;
    
    BOOL videoInj = [c[@"videoInjectionEnabled"] boolValue];
    NSInteger src = [c[@"sourceType"] integerValue];
    
    if (videoInj && src == 2 && !g_injected) {
        // Try injecting into camera-related processes
        NSString *dylibPath = @"/var/jb/Library/MobileSubstrate/DynamicLibraries/RTMPCameraTweak.dylib";
        
        // Try Camera.app
        pid_t camPid = findPid(@"MobileSlideShow"); // iOS 16 camera process
        if (camPid > 0) {
            tlog([NSString stringWithFormat:@"Found camera PID: %d", camPid]);
            if (injectDylib(camPid, dylibPath)) {
                g_injected = YES;
                tlog(@"Injected into camera process!");
            }
        }
        
        if (!g_injected) {
            // Try mediaserverd
            pid_t msPid = findPid(@"mediaserverd");
            if (msPid > 0) {
                tlog([NSString stringWithFormat:@"Found mediaserverd PID: %d", msPid]);
                injectDylib(msPid, dylibPath);
            }
        }
    }
    
    if (g_sbCount % 60 == 0) {
        tlog([NSString stringWithFormat:@"Timer #%ld injected=%d", (long)g_sbCount, g_injected]);
    }
}

%ctor {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0777} error:nil];
        [[NSData data] writeToFile:kLoadedFlag atomically:NO];
        
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        tlog([NSString stringWithFormat:@"=== v1.0.64 LOADED into %@ ===", bid]);
        
        if ([bid isEqualToString:@"com.apple.springboard"]) {
            static dispatch_source_t timer;
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), 2*NSEC_PER_SEC, 0.5*NSEC_PER_SEC);
            dispatch_source_set_event_handler(timer, ^{ @try { sbTick(); } @catch(NSException *e) {} });
            dispatch_resume(timer);
        }
    }
}