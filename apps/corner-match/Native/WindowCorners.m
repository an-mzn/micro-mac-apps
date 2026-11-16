#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <dlfcn.h>

// Loaded through Adobe's ExtendScript ExternalObject API. These AppKit window
// methods are private and must be checked after macOS updates.
static int (*mainConnection)(void);
static CFTypeRef (*transactionCreate)(int);
static void (*transactionCommit)(CFTypeRef, int);
static void (*clearRadius)(CFTypeRef, uint32_t);
static void (*clearRadii)(CFTypeRef, uint32_t);
static void (*clearSystemRadius)(CFTypeRef, uint32_t);
static NSMutableArray *observers;
static NSMapTable<NSWindow *, id> *originals;
static NSMapTable<NSWindow *, id> *applied;
static NSWindow *referenceWindow;
static NSCache<NSString *, id> *policyCache;
static BOOL enabled = NO;
static BOOL applying = NO;

static BOOL resolve(void) {
    static BOOL resolved = NO;
    if (!resolved) {
        void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
#define RESOLVE(var, name) var = dlsym(handle, name)
        RESOLVE(mainConnection, "SLSMainConnectionID");
        RESOLVE(transactionCreate, "SLSTransactionCreate");
        RESOLVE(transactionCommit, "SLSTransactionCommit");
        RESOLVE(clearRadius, "SLSTransactionClearWindowCornerRadius");
        RESOLVE(clearRadii, "SLSTransactionClearWindowCornerRadii");
        RESOLVE(clearSystemRadius, "SLSTransactionClearWindowSystemCornerRadius");
#undef RESOLVE
        resolved = YES;
    }
    return mainConnection && transactionCreate && transactionCommit && clearRadius && clearRadii && clearSystemRadius &&
        [NSWindow instancesRespondToSelector:NSSelectorFromString(@"_cornerRadii")] &&
        [NSWindow instancesRespondToSelector:NSSelectorFromString(@"_setCornerRadii:")] &&
        [NSWindow instancesRespondToSelector:NSSelectorFromString(@"_updateWindowCornerMask")];
}
static id radiiForWindow(NSWindow *window) {
    SEL getter = NSSelectorFromString(@"_cornerRadii");
    return [window respondsToSelector:getter] ? ((id (*)(id, SEL))objc_msgSend)(window, getter) : nil;
}
static BOOL validRadii(id radii) {
    if (!radii || ![radii respondsToSelector:@selector(copyWithZone:)]) return NO;
    for (NSString *name in @[@"topLeft", @"topRight", @"bottomLeft", @"bottomRight"]) {
        SEL getter = NSSelectorFromString(name);
        if (![radii respondsToSelector:getter]) return NO;
        double value = ((double (*)(id, SEL))objc_msgSend)(radii, getter);
        if (!isfinite(value) || value < 0) return NO;
    }
    return YES;
}
static void clearLegacyOverrides(NSWindow *window) {
    if (window.windowNumber <= 0) return;
    CFTypeRef transaction = transactionCreate(mainConnection());
    if (!transaction) return;
    clearRadius(transaction, (uint32_t)window.windowNumber);
    clearRadii(transaction, (uint32_t)window.windowNumber);
    clearSystemRadius(transaction, (uint32_t)window.windowNumber);
    transactionCommit(transaction, 0);
    CFRelease(transaction);
}
static void applyRadii(NSWindow *window, id radii, BOOL clearLegacy) {
    if (!resolve() || !validRadii(radii)) return;
    if (clearLegacy) clearLegacyOverrides(window);
    ((void (*)(id, SEL, id))objc_msgSend)(window, NSSelectorFromString(@"_setCornerRadii:"), [radii copy]);
    ((void (*)(id, SEL))objc_msgSend)(window, NSSelectorFromString(@"_updateWindowCornerMask"));
    [window invalidateShadow];
}
static id policyForWindow(NSWindow *window) {
    // Use the same frame and screen as the host. Modern AppKit resolves each
    // corner separately; legacy scalar getters omit the adaptive bottom radii.
    NSString *key = NSStringFromRect(window.frame);
    id desired = [[policyCache objectForKey:key] copy];
    if (!desired) {
        // AppKit caches the resolved policy on a window. A fresh deferred,
        // never-ordered reference avoids stale radii after moving or resizing.
        referenceWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(300, 300, 500, 400)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:YES];
        referenceWindow.releasedWhenClosed = NO;
        [referenceWindow setFrame:window.frame display:NO];
        desired = [radiiForWindow(referenceWindow) copy];
        [referenceWindow close]; referenceWindow = nil;
        if (validRadii(desired)) [policyCache setObject:[desired copy] forKey:key];
    }
    if (!validRadii(desired)) return nil;
    if (window.styleMask & NSWindowStyleMaskFullScreen) {
        for (NSString *name in @[@"setTopLeft:", @"setTopRight:", @"setBottomLeft:", @"setBottomRight:"]) {
            SEL setter = NSSelectorFromString(name);
            if (![desired respondsToSelector:setter]) return nil;
            ((void (*)(id, SEL, double))objc_msgSend)(desired, setter, 0);
        }
    }
    return desired;
}
static void applyWindow(NSWindow *window) {
    if (!enabled || applying || ![window isKindOfClass:NSWindow.class] || window == referenceWindow ||
        window.level != NSNormalWindowLevel || window.isSheet || window.frame.size.width < 400 ||
        window.frame.size.height < 300) return;
    applying = YES;
    @try {
        id original = [originals objectForKey:window];
        BOOL firstApplication = !original;
        if (firstApplication) {
            original = [radiiForWindow(window) copy];
            if (!validRadii(original)) return;
            [originals setObject:original forKey:window];
        }
        id desired = policyForWindow(window);
        if (!desired) return;
        // Moving within the same geometry policy should incur no shape update.
        if (!firstApplication && [[applied objectForKey:window] isEqual:desired] &&
            [radiiForWindow(window) isEqual:desired]) return;
        applyRadii(window, desired, firstApplication);
        [applied setObject:[desired copy] forKey:window];
    } @finally { applying = NO; }
}
static void enableOnMain(void) {
    if (enabled || !resolve()) return;
    originals = [NSMapTable weakToStrongObjectsMapTable];
    applied = [NSMapTable weakToStrongObjectsMapTable];
    policyCache = [[NSCache alloc] init];
    policyCache.countLimit = 64;
    enabled = YES;
    observers = [NSMutableArray array];
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification,
            NSWindowDidResizeNotification, NSWindowDidMoveNotification, NSWindowDidChangeScreenNotification,
            NSWindowDidDeminiaturizeNotification, NSWindowDidExitFullScreenNotification, NSWindowDidEnterFullScreenNotification]) {
        id token = [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
            usingBlock:^(NSNotification *note) { applyWindow(note.object); }];
        [observers addObject:token];
    }
    id screenToken = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidChangeScreenParametersNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) { [policyCache removeAllObjects]; for (NSWindow *w in NSApp.windows) applyWindow(w); }];
    [observers addObject:screenToken];
    for (NSWindow *window in NSApp.windows) applyWindow(window);
}
static void disableOnMain(void) {
    enabled = NO;
    for (id token in observers) [[NSNotificationCenter defaultCenter] removeObserver:token];
    [observers removeAllObjects]; observers = nil;
    for (NSWindow *window in originals) applyRadii(window, [originals objectForKey:window], YES);
    [originals removeAllObjects]; originals = nil;
    [applied removeAllObjects]; applied = nil;
    [referenceWindow close]; referenceWindow = nil; policyCache = nil;
}
static void onMain(void (^block)(void)) {
    if ([NSThread isMainThread]) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}
char *ESInitialize(void *args, long count) { onMain(^{ enableOnMain(); }); return ""; }
long ESGetVersion(void) { return 2; }
void ESFreeMem(void *p) { free(p); }
void ESTerminate(void) { onMain(^{ disableOnMain(); }); }
long cmEnable(void *args, long count, void *result) { onMain(^{ enableOnMain(); }); return enabled ? 0 : 1; }
long cmDisable(void *args, long count, void *result) { onMain(^{ disableOnMain(); }); return 0; }
