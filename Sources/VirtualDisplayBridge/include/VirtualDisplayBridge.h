#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

/// 对 macOS 私有 CGVirtualDisplay 运行时类的窄封装。
///
/// 此类不会在链接阶段引用任何私有类符号；若当前系统没有对应运行时类，
/// `supported` 返回 NO，初始化方法返回错误。
@interface FSTVirtualDisplay : NSObject

@property(class, nonatomic, readonly, getter=isSupported) BOOL supported;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@property(nonatomic, copy, nullable) void (^terminationHandler)(void);

- (nullable instancetype)initWithName:(NSString *)name
                           pixelWidth:(uint32_t)pixelWidth
                          pixelHeight:(uint32_t)pixelHeight
                         logicalWidth:(uint32_t)logicalWidth
                        logicalHeight:(uint32_t)logicalHeight
                          refreshRate:(double)refreshRate
                         physicalSize:(CGSize)physicalSize
                                error:(NSError * _Nullable * _Nullable)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

typedef NS_ENUM(int32_t, FSTDisplayStreamFrameStatus) {
    FSTDisplayStreamFrameStatusComplete = 0,
    FSTDisplayStreamFrameStatusIdle = 1,
    FSTDisplayStreamFrameStatusBlank = 2,
    FSTDisplayStreamFrameStatusStopped = 3,
};

typedef void (^FSTDisplayStreamFrameHandler)(
    FSTDisplayStreamFrameStatus status,
    uint64_t displayTime,
    IOSurfaceRef _Nullable surface
);

/// 对已被新 SDK 标记为 obsolete 的 CGDisplayStream C 接口做动态封装。
///
/// 该接口按显示器 ID 直接返回 WindowServer 生成的 IOSurface，不经过
/// ScreenCaptureKit，也不在链接阶段引用已废弃的符号。
@interface FSTDisplayStream : NSObject

@property(class, nonatomic, readonly, getter=isSupported) BOOL supported;

- (nullable instancetype)initWithDisplayID:(CGDirectDisplayID)displayID
                                outputWidth:(size_t)outputWidth
                               outputHeight:(size_t)outputHeight
                                refreshRate:(double)refreshRate
                                      queue:(dispatch_queue_t)queue
                               frameHandler:(FSTDisplayStreamFrameHandler)frameHandler
                                      error:(NSError * _Nullable * _Nullable)error
    NS_DESIGNATED_INITIALIZER;

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
- (void)stop;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
