#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs a personal-use Control Strip item. This uses private AppKit APIs and
/// intentionally cannot be shipped through the Mac App Store.
BOOL ABInstallControlStripItem(NSCustomTouchBarItem *item);
void ABSetControlStripItemVisible(NSTouchBarItemIdentifier identifier, BOOL visible);
NSArray<NSString *> *ABTouchBarButtonTitles(void);
NSString * _Nullable ABTouchBarPresentationMode(void);
BOOL ABSetTouchBarPresentationMode(NSString * _Nullable mode);
void ABRestartControlStrip(void);
BOOL ABPresentSystemTouchBar(
    NSTouchBar *touchBar,
    NSTouchBarItemIdentifier identifier,
    BOOL fullWidth
);
void ABMinimizeSystemTouchBar(NSTouchBar *touchBar);
void ABRemoveControlStripItem(NSCustomTouchBarItem *item);

NS_ASSUME_NONNULL_END
