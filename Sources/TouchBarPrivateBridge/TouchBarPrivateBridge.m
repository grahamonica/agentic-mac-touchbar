#import "TouchBarPrivateBridge.h"

#import <dlfcn.h>
#import <objc/message.h>

typedef void (*ABControlStripPresenceFunction)(NSString *, BOOL);
typedef void (*ABModalCloseBoxFunction)(BOOL);

static void ABLoadDFRFoundation(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY | RTLD_GLOBAL);
    });
}

static void ABConfigureModalAppearance(void) {
    ABLoadDFRFoundation();
    ABModalCloseBoxFunction function = (ABModalCloseBoxFunction)dlsym(RTLD_DEFAULT, "DFRSystemModalShowsCloseBoxWhenFrontMost");
    if (function != NULL) {
        // Keep macOS's own close box as a second escape route in addition to
        // AgentBar's explicit Exit button.
        function(YES);
    }
}

static void ABCollectButtonTitles(NSView *view, NSMutableArray<NSString *> *titles) {
    if ([view isKindOfClass:[NSButton class]]) {
        NSString *title = ((NSButton *)view).title;
        if (title.length > 0) {
            [titles addObject:title];
        }
    }
    for (NSView *subview in view.subviews) {
        ABCollectButtonTitles(subview, titles);
    }
}

BOOL ABInstallControlStripItem(NSCustomTouchBarItem *item) {
    ABLoadDFRFoundation();
    ABControlStripPresenceFunction presenceFunction = (ABControlStripPresenceFunction)dlsym(
        RTLD_DEFAULT,
        "DFRElementSetControlStripPresenceForIdentifier"
    );
    SEL selector = NSSelectorFromString(@"addSystemTrayItem:");
    Class itemClass = [NSTouchBarItem class];
    if (presenceFunction == NULL || ![itemClass respondsToSelector:selector]) {
        return NO;
    }

    ABConfigureModalAppearance();
    ((void (*)(id, SEL, id))objc_msgSend)(itemClass, selector, item);
    presenceFunction(item.identifier, YES);
    return YES;
}

void ABSetControlStripItemVisible(NSTouchBarItemIdentifier identifier, BOOL visible) {
    ABLoadDFRFoundation();
    ABControlStripPresenceFunction function = (ABControlStripPresenceFunction)dlsym(RTLD_DEFAULT, "DFRElementSetControlStripPresenceForIdentifier");
    if (function != NULL) {
        function(identifier, visible);
    }
}

NSArray<NSString *> *ABTouchBarButtonTitles(void) {
    Class functionRowClass = NSClassFromString(@"NSFunctionRow");
    SEL selector = NSSelectorFromString(@"_topLevelViews");
    if (functionRowClass == Nil || ![functionRowClass respondsToSelector:selector]) {
        return @[];
    }

    id value = ((id (*)(id, SEL))objc_msgSend)(functionRowClass, selector);
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (id candidate in (NSArray *)value) {
        if ([candidate isKindOfClass:[NSView class]]) {
            ABCollectButtonTitles((NSView *)candidate, titles);
        }
    }
    return [titles copy];
}

NSString *ABTouchBarPresentationMode(void) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.touchbar.agent"];
    return [defaults stringForKey:@"PresentationModeGlobal"];
}

BOOL ABSetTouchBarPresentationMode(NSString *mode) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.touchbar.agent"];
    NSString *current = [defaults stringForKey:@"PresentationModeGlobal"];
    if ((current == nil && mode == nil) || [current isEqualToString:mode]) {
        return NO;
    }
    if (mode == nil) {
        [defaults removeObjectForKey:@"PresentationModeGlobal"];
    } else {
        [defaults setObject:mode forKey:@"PresentationModeGlobal"];
    }
    return [defaults synchronize];
}

void ABRestartControlStrip(void) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/pkill"];
    task.arguments = @[@"ControlStrip"];
    [task launchAndReturnError:nil];
    [task waitUntilExit];
}

BOOL ABPresentSystemTouchBar(
    NSTouchBar *touchBar,
    NSTouchBarItemIdentifier identifier,
    BOOL fullWidth
) {
    Class touchBarClass = [NSTouchBar class];
    SEL placementSelector = NSSelectorFromString(
        @"presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"
    );
    if (![touchBarClass respondsToSelector:placementSelector]) {
        placementSelector = NSSelectorFromString(
            @"presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:"
        );
    }
    if ([touchBarClass respondsToSelector:placementSelector]) {
        // Placement 1 is the full-width app region. Placement 0 leaves the
        // expanded system Control Strip (volume/brightness) beside the app.
        long long placement = fullWidth ? 1 : 0;
        ((void (*)(id, SEL, id, long long, id))objc_msgSend)(
            touchBarClass,
            placementSelector,
            touchBar,
            placement,
            identifier
        );
        return YES;
    }

    SEL fallbackSelector = NSSelectorFromString(
        @"presentSystemModalTouchBar:systemTrayItemIdentifier:"
    );
    if (![touchBarClass respondsToSelector:fallbackSelector]) {
        fallbackSelector = NSSelectorFromString(
            @"presentSystemModalFunctionBar:systemTrayItemIdentifier:"
        );
    }
    if (![touchBarClass respondsToSelector:fallbackSelector]) {
        return NO;
    }

    ((void (*)(id, SEL, id, id))objc_msgSend)(
        touchBarClass,
        fallbackSelector,
        touchBar,
        identifier
    );
    return YES;
}

void ABMinimizeSystemTouchBar(NSTouchBar *touchBar) {
    Class touchBarClass = [NSTouchBar class];
    SEL selector = NSSelectorFromString(@"minimizeSystemModalTouchBar:");
    if (![touchBarClass respondsToSelector:selector]) {
        selector = NSSelectorFromString(@"minimizeSystemModalFunctionBar:");
    }
    if ([touchBarClass respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(touchBarClass, selector, touchBar);
    }
}

void ABRemoveControlStripItem(NSCustomTouchBarItem *item) {
    ABSetControlStripItemVisible(item.identifier, NO);
    SEL selector = NSSelectorFromString(@"removeSystemTrayItem:");
    Class itemClass = [NSTouchBarItem class];
    if ([itemClass respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(itemClass, selector, item);
    }
}
