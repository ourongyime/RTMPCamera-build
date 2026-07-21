#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>

static void tlog(NSString *s) {
    NSLog(@"DICOY-TEST: %@", s);
    NSString *l = [NSString stringWithFormat:@"[%@][DICOY-TEST] %@\n",
        [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle], s];
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/rtmpcamera" withIntermediateDirectories:YES attributes:nil error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/Documents/rtmpcamera/tweak.log"];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [l writeToFile:@"/var/mobile/Documents/rtmpcamera/tweak.log" atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    NSString *pname = [[NSProcessInfo processInfo] processName] ?: @"?";
    tlog([NSString stringWithFormat:@"INJECTED! bundleID=%@ process=%@", bid, pname]);
    [[NSData data] writeToFile:@"/var/mobile/Documents/rtmpcamera/tweak_loaded" atomically:NO];
}