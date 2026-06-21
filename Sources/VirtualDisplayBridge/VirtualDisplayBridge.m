#import "VirtualDisplayBridge.h"

#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const FSTVirtualDisplayErrorDomain = @"FullScreenTools.VirtualDisplay";

typedef NS_ENUM(NSInteger, FSTVirtualDisplayErrorCode) {
    FSTVirtualDisplayErrorUnsupported = 1,
    FSTVirtualDisplayErrorCreationFailed = 2,
    FSTVirtualDisplayErrorSettingsRejected = 3,
};

static NSError *FSTMakeError(FSTVirtualDisplayErrorCode code, NSString *message) {
    return [NSError errorWithDomain:FSTVirtualDisplayErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface FSTVirtualDisplay () {
    id _descriptor;
    id _display;
    id _settings;
}

@property(nonatomic, readwrite) CGDirectDisplayID displayID;

@end


@implementation FSTVirtualDisplay

+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") != Nil &&
           NSClassFromString(@"CGVirtualDisplayDescriptor") != Nil &&
           NSClassFromString(@"CGVirtualDisplayMode") != Nil &&
           NSClassFromString(@"CGVirtualDisplaySettings") != Nil;
}

- (nullable instancetype)initWithName:(NSString *)name
                           pixelWidth:(uint32_t)pixelWidth
                          pixelHeight:(uint32_t)pixelHeight
                         logicalWidth:(uint32_t)logicalWidth
                        logicalHeight:(uint32_t)logicalHeight
                          refreshRate:(double)refreshRate
                         physicalSize:(CGSize)physicalSize
                                error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    if (![FSTVirtualDisplay isSupported]) {
        if (error) {
            *error = FSTMakeError(
                FSTVirtualDisplayErrorUnsupported,
                @"当前 macOS 不包含所需的 CGVirtualDisplay 私有运行时接口。"
            );
        }
        return nil;
    }

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");

    _descriptor = [[descriptorClass alloc] init];
    if (!_descriptor) {
        if (error) {
            *error = FSTMakeError(
                FSTVirtualDisplayErrorCreationFailed,
                @"无法创建虚拟显示器描述对象。"
            );
        }
        return nil;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(_descriptor, @selector(setName:), name);
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(
        _descriptor, @selector(setMaxPixelsWide:), pixelWidth
    );
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(
        _descriptor, @selector(setMaxPixelsHigh:), pixelHeight
    );
    ((void (*)(id, SEL, CGSize))objc_msgSend)(
        _descriptor, @selector(setSizeInMillimeters:), physicalSize
    );

    // 固定但不与真实硬件冲突的本地标识。
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(
        _descriptor, @selector(setVendorID:), 0xF5F5
    );
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(
        _descriptor, @selector(setProductID:), 0x4653
    );
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(
        _descriptor, @selector(setSerialNum:), 0x00010001
    );

    if ([_descriptor respondsToSelector:@selector(setDispatchQueue:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            _descriptor, @selector(setDispatchQueue:), dispatch_get_main_queue()
        );
    } else if ([_descriptor respondsToSelector:@selector(setQueue:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            _descriptor, @selector(setQueue:), dispatch_get_main_queue()
        );
    }

    __weak FSTVirtualDisplay *weakSelf = self;
    void (^privateTerminationHandler)(id, id) = ^(id unused, id display) {
        FSTVirtualDisplay *strongSelf = weakSelf;
        if (strongSelf.terminationHandler) {
            strongSelf.terminationHandler();
        }
    };
    ((void (*)(id, SEL, id))objc_msgSend)(
        _descriptor,
        @selector(setTerminationHandler:),
        privateTerminationHandler
    );

    _display = ((id (*)(id, SEL, id))objc_msgSend)(
        [displayClass alloc],
        @selector(initWithDescriptor:),
        _descriptor
    );
    if (!_display) {
        if (error) {
            *error = FSTMakeError(
                FSTVirtualDisplayErrorCreationFailed,
                @"系统拒绝创建虚拟显示器。"
            );
        }
        return nil;
    }

    id pixelMode = ((id (*)(id, SEL, uint32_t, uint32_t, double))objc_msgSend)(
        [modeClass alloc],
        @selector(initWithWidth:height:refreshRate:),
        pixelWidth,
        pixelHeight,
        refreshRate
    );
    id logicalMode = ((id (*)(id, SEL, uint32_t, uint32_t, double))objc_msgSend)(
        [modeClass alloc],
        @selector(initWithWidth:height:refreshRate:),
        logicalWidth,
        logicalHeight,
        refreshRate
    );

    if (!pixelMode || !logicalMode) {
        if (error) {
            *error = FSTMakeError(
                FSTVirtualDisplayErrorCreationFailed,
                @"无法创建与内置屏幕匹配的虚拟显示模式。"
            );
        }
        return nil;
    }

    _settings = [[settingsClass alloc] init];
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(
        _settings, @selector(setHiDPI:), 1
    );
    NSArray *modes = (pixelWidth == logicalWidth && pixelHeight == logicalHeight)
        ? @[pixelMode]
        : @[pixelMode, logicalMode];
    ((void (*)(id, SEL, id))objc_msgSend)(
        _settings, @selector(setModes:), modes
    );

    BOOL applied = ((BOOL (*)(id, SEL, id))objc_msgSend)(
        _display, @selector(applySettings:), _settings
    );
    if (!applied) {
        if (error) {
            *error = FSTMakeError(
                FSTVirtualDisplayErrorSettingsRejected,
                @"系统拒绝应用虚拟显示器的 HiDPI 设置。"
            );
        }
        _display = nil;
        return nil;
    }

    self.displayID = ((CGDirectDisplayID (*)(id, SEL))objc_msgSend)(
        _display, @selector(displayID)
    );
    if (self.displayID == kCGNullDirectDisplay) {
        if (error) {
            *error = FSTMakeError(
                FSTVirtualDisplayErrorCreationFailed,
                @"虚拟显示器没有有效的显示器 ID。"
            );
        }
        _display = nil;
        return nil;
    }

    return self;
}

@end
