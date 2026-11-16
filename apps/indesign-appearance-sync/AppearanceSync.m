#import <AppKit/AppKit.h>

// Loaded in InDesign via ExtendScript. No resident helper or timer is required.
static id appearanceObserver;

static BOOL systemIsDark(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("AppleInterfaceStyle"), kCFPreferencesAnyApplication);
    BOOL dark = value && CFGetTypeID(value) == CFStringGetTypeID() &&
        [(__bridge NSString *)value caseInsensitiveCompare:@"Dark"] == NSOrderedSame;
    if (value) CFRelease(value);
    return dark;
}

static void syncAppearance(void) {
    // The child process exits after the Apple event; InDesign's scripting DOM
    // owns the preference change.
    NSString *source = [NSString stringWithFormat:
        @"tell application id \"com.adobe.InDesign\" to do script \"app.generalPreferences.uiBrightnessPreference = %@;\" language javascript",
        systemIsDark() ? @"0.0" : @"1.0"];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    task.arguments = @[@"-e", source];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) NSLog(@"Appearance Sync could not start: %@", error);
}

static void enable(void) {
    if (appearanceObserver) return;
    appearanceObserver = [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:@"AppleInterfaceThemeChangedNotification" object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) { syncAppearance(); }];
    syncAppearance();
}
static void disable(void) {
    if (appearanceObserver) {
        [[NSDistributedNotificationCenter defaultCenter] removeObserver:appearanceObserver];
        appearanceObserver = nil;
    }
}
char *ESInitialize(void *args, long count) { enable(); return ""; }
long ESGetVersion(void) { return 1; }
void ESFreeMem(void *p) { free(p); }
void ESTerminate(void) { disable(); }

long appearanceSyncStart(void *args, long count, void *result) { enable(); return 0; }
long appearanceSyncStop(void *args, long count, void *result) { disable(); return 0; }
