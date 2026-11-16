#import "../Native/WindowCorners.m"

static id nativePolicy(NSRect frame) {
    NSWindow *sample = [[NSWindow alloc] initWithContentRect:NSMakeRect(300,300,500,400)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    sample.releasedWhenClosed = NO;
    [sample setFrame:frame display:NO];
    id radii = [radiiForWindow(sample) copy];
    [sample close];
    return radii;
}
static double component(id radii, NSString *name) {
    return ((double (*)(id, SEL))objc_msgSend)(radii, NSSelectorFromString(name));
}
int main(void) {
 @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSRect floating = NSMakeRect(300,300,600,400);
    NSRect filled = NSInsetRect(NSScreen.screens.firstObject.visibleFrame,8,8);
    id expectedFloating = nativePolicy(floating);
    id expectedFilled = nativePolicy(filled);
    if (!validRadii(expectedFloating) || !validRadii(expectedFilled)) return 1;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:floating styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    id original = [radiiForWindow(window) copy];
    // An asymmetric original catches accidental restoration of only one corner.
    NSArray *setters = @[@"setTopLeft:",@"setTopRight:",@"setBottomLeft:",@"setBottomRight:"];
    for (NSUInteger i=0;i<4;i++) ((void (*)(id,SEL,double))objc_msgSend)(original,NSSelectorFromString(setters[i]),3+i*2);
    applyRadii(window,original,YES);
    for (int i=0;i<20;i++) {
        [window setFrame:floating display:NO];
        enableOnMain();
        if (!enabled || ![radiiForWindow(window) isEqual:expectedFloating]) return 2;
        [window setFrame:filled display:NO];
        [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidMoveNotification object:window];
        if (![radiiForWindow(window) isEqual:expectedFilled]) { NSLog(@"Mismatch filled actual=%@ expected=%@ applied=%@ frame=%@",radiiForWindow(window),expectedFilled,[applied objectForKey:window],NSStringFromRect(window.frame)); return 3; }
        [window setFrame:floating display:NO];
        [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResizeNotification object:window];
        if (![radiiForWindow(window) isEqual:expectedFloating]) return 4;
        disableOnMain();
        if (![radiiForWindow(window) isEqual:original]) return 5;
    }
    NSLog(@"PASS 20 floating/filled/resize/restore cycles. Native filled top=%.6f bottom=%.6f; asymmetric originals retained.",
        component(expectedFilled,@"topLeft"),component(expectedFilled,@"bottomLeft"));
    [window close];
 }
 return 0;
}
