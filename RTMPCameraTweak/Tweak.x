#import <Foundation/Foundation.h>
#import <substrate.h>

static void tlog(NSString *s) {
    NSLog(@"DiCoy-TEST: %@", s);
    NSString *dir = @"/var/mobile/Documents/rtmpcamera";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *l = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:[dir stringByAppendingPathComponent:@"tweak.log"]];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [l writeToFile:[dir stringByAppendingPathComponent:@"tweak.log"] atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
}

%ctor {
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/rtmpcamera" withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSData data] writeToFile:@"/var/mobile/Documents/rtmpcamera/tweak_loaded" atomically:NO];
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    NSString *pn = [[NSProcessInfo processInfo] processName] ?: @"?";
    tlog([NSString stringWithFormat:@"DICOY-STYLE INJECTED! bid=%@ proc=%@", bid, pn]);
}
