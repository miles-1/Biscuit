#import <Cocoa/Cocoa.h>
#import <sys/stat.h>
#import <signal.h>
#import <unistd.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSTask *serverTask;
@property (strong) NSString *workspacePath;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];

    NSString *homeDir = NSHomeDirectory();
    NSString *configDir = [homeDir stringByAppendingPathComponent:@".config/biscuit"];
    NSString *lastWsFile = [configDir stringByAppendingPathComponent:@"last_workspace.txt"];
    NSString *logFile = [configDir stringByAppendingPathComponent:@"biscuit.log"];

    [[NSFileManager defaultManager] createDirectoryAtPath:configDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Determine workspace folder
    if (!self.workspacePath || [self.workspacePath length] == 0) {
        NSString *lastDir = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:lastWsFile]) {
            lastDir = [[NSString stringWithContentsOfFile:lastWsFile
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }

        NSOpenPanel *panel = [NSOpenPanel openPanel];
        [panel setCanChooseFiles:NO];
        [panel setCanChooseDirectories:YES];
        [panel setAllowsMultipleSelection:NO];
        [panel setMessage:@"Select your Biscuit course workspace folder:"];
        [panel setPrompt:@"Select"];
        if (lastDir && [[NSFileManager defaultManager] fileExistsAtPath:lastDir]) {
            [panel setDirectoryURL:[NSURL fileURLWithPath:lastDir]];
        }

        NSModalResponse res = [panel runModal];
        if (res == NSModalResponseOK) {
            self.workspacePath = [[panel URL] path];
        } else {
            [NSApp terminate:nil];
            return;
        }
    }

    [self.workspacePath writeToFile:lastWsFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // Log rotation: if biscuit.log > 5MB, keep recent lines
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:logFile error:nil];
    if (attrs && [attrs fileSize] > 5 * 1024 * 1024) {
        NSString *logContent = [NSString stringWithContentsOfFile:logFile encoding:NSUTF8StringEncoding error:nil];
        if (logContent) {
            NSArray *lines = [logContent componentsSeparatedByString:@"\n"];
            if ([lines count] > 5000) {
                NSArray *recent = [lines subarrayWithRange:NSMakeRange([lines count] - 5000, 5000)];
                [[recent componentsJoinedByString:@"\n"] writeToFile:logFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
    }

    // Append session header to log file
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *dateStr = [formatter stringFromDate:[NSDate date]];
    NSString *header = [NSString stringWithFormat:@"\n============================================================\n  Biscuit started at %@\n  Workspace: %@\n  URL:       http://127.0.0.1:8080\n============================================================\n", dateStr, self.workspacePath];

    if (![[NSFileManager defaultManager] fileExistsAtPath:logFile]) {
        [[NSFileManager defaultManager] createFileAtPath:logFile contents:[header dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logFile];
        [fh seekToEndOfFile];
        [fh writeData:[header dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }

    NSFileHandle *logHandle = [NSFileHandle fileHandleForWritingAtPath:logFile];
    [logHandle seekToEndOfFile];

    // Resolve paths relative to bundle
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *backendBin = [bundlePath stringByAppendingPathComponent:@"Contents/app/bin/Biscuit"];
    NSString *resBin = [bundlePath stringByAppendingPathComponent:@"Contents/Resources/bin"];
    NSString *appBin = [bundlePath stringByAppendingPathComponent:@"Contents/app/bin"];
    NSString *appLib = [bundlePath stringByAppendingPathComponent:@"Contents/app/lib"];
    NSString *resLib = [bundlePath stringByAppendingPathComponent:@"Contents/Resources/lib"];

    // Launch background Julia backend task
    self.serverTask = [[NSTask alloc] init];
    [self.serverTask setLaunchPath:backendBin];
    [self.serverTask setCurrentDirectoryPath:self.workspacePath];
    [self.serverTask setStandardOutput:logHandle];
    [self.serverTask setStandardError:logHandle];

    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    NSString *currentPath = env[@"PATH"] ?: @"";
    NSString *newPath = [NSString stringWithFormat:@"%@:%@:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:%@/.cargo/bin:%@/.local/bin:%@", resBin, appBin, homeDir, homeDir, currentPath];
    env[@"PATH"] = newPath;

    NSString *currentDyld = env[@"DYLD_LIBRARY_PATH"] ?: @"";
    NSString *newDyld = [NSString stringWithFormat:@"%@:%@:%@", appLib, resLib, currentDyld];
    env[@"DYLD_LIBRARY_PATH"] = newDyld;

    [self.serverTask setEnvironment:env];

    @try {
        [self.serverTask launch];
    } @catch (NSException *e) {
        NSLog(@"Failed to launch server: %@", e);
        [NSApp terminate:nil];
        return;
    }

    // Poll http://127.0.0.1:8080 until server is listening, then open browser
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:8080/"];
        for (int i = 0; i < 400; i++) { // up to 60s
            if (!self.serverTask || ![self.serverTask isRunning]) {
                break;
            }
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:0.4];
            [req setHTTPMethod:@"GET"];

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL ready = NO;

            NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    if (!error && [response isKindOfClass:[NSHTTPURLResponse class]]) {
                        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                        if ([httpResp statusCode] >= 200 && [httpResp statusCode] < 500) {
                            ready = YES;
                        }
                    }
                    dispatch_semaphore_signal(sem);
                }];
            [task resume];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)));

            if (ready) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSWorkspace sharedWorkspace] openURL:url];
                });
                break;
            }
            usleep(150000); // 150ms interval
        }
    });
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:filename isDirectory:&isDir] && isDir) {
        self.workspacePath = filename;
        return YES;
    }
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (self.serverTask && [self.serverTask isRunning]) {
        pid_t pid = [self.serverTask processIdentifier];
        if (pid > 0) {
            kill(pid, SIGTERM);
            for (int i = 0; i < 50; i++) {
                if (![self.serverTask isRunning]) break;
                usleep(100000);
            }
        }
    }
    return NSTerminateNow;
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        if (argc > 1) {
            NSString *argPath = [NSString stringWithUTF8String:argv[1]];
            BOOL isDir = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:argPath isDirectory:&isDir] && isDir) {
                delegate.workspacePath = argPath;
            }
        }
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
