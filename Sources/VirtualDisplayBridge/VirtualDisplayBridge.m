#import "VirtualDisplayBridge.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const FSTVirtualDisplayErrorDomain = @"MacNotchKiller.VirtualDisplay";

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

static NSString *const FSTDisplayStreamErrorDomain = @"MacNotchKiller.DisplayStream";

typedef NS_ENUM(NSInteger, FSTDisplayStreamErrorCode) {
    FSTDisplayStreamErrorUnsupported = 1,
    FSTDisplayStreamErrorCreationFailed = 2,
    FSTDisplayStreamErrorStartFailed = 3,
};

typedef void (^FSTSystemDisplayStreamHandler)(
    int32_t status,
    uint64_t displayTime,
    IOSurfaceRef _Nullable surface,
    CFTypeRef _Nullable update
);

typedef CFTypeRef _Nullable (*FSTDisplayStreamCreateFunction)(
    CGDirectDisplayID displayID,
    size_t outputWidth,
    size_t outputHeight,
    int32_t pixelFormat,
    CFDictionaryRef _Nullable properties,
    dispatch_queue_t queue,
    FSTSystemDisplayStreamHandler handler
);
typedef CGError (*FSTDisplayStreamControlFunction)(CFTypeRef _Nullable stream);

static void *FSTLoadSymbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

static CFStringRef _Nullable FSTLoadStringConstant(const char *name) {
    CFStringRef _Nullable *address = FSTLoadSymbol(name);
    return address ? *address : nil;
}

static NSError *FSTMakeDisplayStreamError(
    FSTDisplayStreamErrorCode code,
    NSString *message
) {
    return [NSError errorWithDomain:FSTDisplayStreamErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface FSTDisplayStream () {
    CFTypeRef _stream;
    FSTDisplayStreamControlFunction _stopFunction;
    BOOL _started;
    FSTDisplayStream *_lifetimeKeeper;
}

@property(nonatomic, copy) FSTDisplayStreamFrameHandler frameHandler;

@end

@implementation FSTDisplayStream

+ (BOOL)isSupported {
    return FSTLoadSymbol("CGDisplayStreamCreateWithDispatchQueue") != NULL &&
           FSTLoadSymbol("CGDisplayStreamStart") != NULL &&
           FSTLoadSymbol("CGDisplayStreamStop") != NULL;
}

- (nullable instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
                                outputWidth:(size_t)outputWidth
                               outputHeight:(size_t)outputHeight
                                refreshRate:(double)refreshRate
                                      queue:(dispatch_queue_t)queue
                               frameHandler:(FSTDisplayStreamFrameHandler)frameHandler
                                      error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    FSTDisplayStreamCreateFunction createFunction =
        FSTLoadSymbol("CGDisplayStreamCreateWithDispatchQueue");
    _stopFunction = FSTLoadSymbol("CGDisplayStreamStop");
    if (!createFunction || !_stopFunction || ![FSTDisplayStream isSupported]) {
        if (error) {
            *error = FSTMakeDisplayStreamError(
                FSTDisplayStreamErrorUnsupported,
                @"当前 macOS 不包含可用的 CGDisplayStream 运行时符号。"
            );
        }
        return nil;
    }

    self.frameHandler = frameHandler;
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
    CFStringRef showCursorKey = FSTLoadStringConstant("kCGDisplayStreamShowCursor");
    CFStringRef queueDepthKey = FSTLoadStringConstant("kCGDisplayStreamQueueDepth");
    CFStringRef minimumFrameTimeKey =
        FSTLoadStringConstant("kCGDisplayStreamMinimumFrameTime");
    CFStringRef preserveAspectRatioKey =
        FSTLoadStringConstant("kCGDisplayStreamPreserveAspectRatio");
    if (showCursorKey) {
        properties[(__bridge NSString *)showCursorKey] = @YES;
    }
    if (queueDepthKey) {
        properties[(__bridge NSString *)queueDepthKey] = @3;
    }
    if (minimumFrameTimeKey && refreshRate > 0) {
        properties[(__bridge NSString *)minimumFrameTimeKey] = @(1.0 / refreshRate);
    }
    if (preserveAspectRatioKey) {
        properties[(__bridge NSString *)preserveAspectRatioKey] = @YES;
    }

    __weak FSTDisplayStream *weakSelf = self;
    FSTSystemDisplayStreamHandler systemHandler = ^(
        int32_t status,
        uint64_t displayTime,
        IOSurfaceRef _Nullable surface,
        CFTypeRef _Nullable update
    ) {
        (void)update;
        FSTDisplayStream *strongSelf = weakSelf;
        if (strongSelf.frameHandler) {
            strongSelf.frameHandler(
                (FSTDisplayStreamFrameStatus)status,
                displayTime,
                surface
            );
        }
        if (status == FSTDisplayStreamFrameStatusStopped) {
            // CGDisplayStreamStop 返回后仍要等到 stopped 回调才能安全释放流。
            // start 时的自持有在本回调末尾解除，确保 CFRelease 不会过早发生。
            strongSelf->_started = NO;
            strongSelf->_lifetimeKeeper = nil;
        }
    };

    // kCVPixelFormatType_32BGRA，即 'BGRA'。直接写常量可避免桥接层再依赖
    // CoreVideo，同时与 CGDisplayStream 公开支持的像素格式完全一致。
    const int32_t pixelFormatBGRA = (int32_t)'BGRA';
    _stream = createFunction(
        displayID,
        outputWidth,
        outputHeight,
        pixelFormatBGRA,
        (__bridge CFDictionaryRef)properties,
        queue,
        systemHandler
    );
    if (!_stream) {
        if (error) {
            *error = FSTMakeDisplayStreamError(
                FSTDisplayStreamErrorCreationFailed,
                @"WindowServer 无法为虚拟显示器创建直接 IOSurface 流。"
            );
        }
        return nil;
    }

    return self;
}

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error {
    if (_started) {
        return YES;
    }

    FSTDisplayStreamControlFunction startFunction = FSTLoadSymbol("CGDisplayStreamStart");
    if (!startFunction || !_stream) {
        if (error) {
            *error = FSTMakeDisplayStreamError(
                FSTDisplayStreamErrorUnsupported,
                @"CGDisplayStream 启动符号不可用。"
            );
        }
        return NO;
    }

    CGError result = startFunction(_stream);
    if (result != kCGErrorSuccess) {
        if (error) {
            *error = FSTMakeDisplayStreamError(
                FSTDisplayStreamErrorStartFailed,
                [NSString stringWithFormat:
                    @"WindowServer 拒绝启动虚拟显示器 IOSurface 流（CoreGraphics 错误 %d）。",
                    result]
            );
        }
        return NO;
    }

    _started = YES;
    _lifetimeKeeper = self;
    return YES;
}

- (void)stop {
    if (_started && _stream && _stopFunction) {
        _stopFunction(_stream);
    }
    _started = NO;
}

- (void)dealloc {
    [self stop];
    if (_stream) {
        CFRelease(_stream);
        _stream = NULL;
    }
}

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
