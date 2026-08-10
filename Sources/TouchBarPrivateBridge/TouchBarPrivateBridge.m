#import "TouchBarPrivateBridge.h"

#import <dlfcn.h>
#import <objc/message.h>

typedef void (*ABControlStripPresenceFunction)(NSString *, BOOL);
typedef void (*ABModalCloseBoxFunction)(BOOL);

static void ABLoadDFRFoundation(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY | RTLD_LOCAL);
    });
}

static void ABConfigureModalAppearance(void) {
    ABLoadDFRFoundation();
    ABModalCloseBoxFunction function = (ABModalCloseBoxFunction)dlsym(RTLD_DEFAULT, "DFRSystemModalShowsCloseBoxWhenFrontMost");
    if (function != NULL) {
        function(NO);
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
