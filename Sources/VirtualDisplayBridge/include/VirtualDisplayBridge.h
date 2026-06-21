#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

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

NS_ASSUME_NONNULL_END
