/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageManager.h"
#import <objc/message.h>

@interface SDWebImageCombinedOperation : NSObject <SDWebImageOperation>

@property (assign, nonatomic, getter = isCancelled) BOOL cancelled;
@property (copy, nonatomic) SDWebImageNoParamsBlock cancelBlock;
@property (strong, nonatomic) NSOperation *cacheOperation;

@end

@interface SDWebImageManager ()

@property (strong, nonatomic, readwrite) SDImageCache *imageCache;
@property (strong, nonatomic, readwrite) SDWebImageDownloader *imageDownloader;
@property (strong, nonatomic) NSMutableSet *failedURLs;
@property (strong, nonatomic) NSMutableArray *runningOperations;

@end

@implementation SDWebImageManager

+ (id)sharedManager {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}
/*
*初始化方法
*1.获得一个SDImageCache的单例
*2.获得一个SDWebImageDownloader的单例
*3.新建一个MutableSet来存储下载失败的url
*4.新建一个用来存储下载operation的可遍数组
*/
- (instancetype)init {
    SDImageCache *cache = [SDImageCache sharedImageCache];
    SDWebImageDownloader *downloader = [SDWebImageDownloader sharedDownloader];
    return [self initWithCache:cache downloader:downloader];
}

- (instancetype)initWithCache:(SDImageCache *)cache downloader:(SDWebImageDownloader *)downloader {
    if ((self = [super init])) {
        _imageCache = cache;
        _imageDownloader = downloader;
        _failedURLs = [NSMutableSet new];
        _runningOperations = [NSMutableArray new];
    }
    return self;
}

- (NSString *)cacheKeyForURL:(NSURL *)url {
    if (!url) {
        return @"";
    }
    // 如果用户有设置cacheKeyFilter  就用执行这个block返回
    if (self.cacheKeyFilter) {
        return self.cacheKeyFilter(url);
    } else {
        return [url absoluteString];
    }
}

//检查一个图片是否被缓存
- (BOOL)cachedImageExistsForURL:(NSURL *)url {
    NSString *key = [self cacheKeyForURL:url];
    if ([self.imageCache imageFromMemoryCacheForKey:key] != nil) return YES;
    return [self.imageCache diskImageExistsWithKey:key];
}
// 检测硬盘里是否缓存了图片
- (BOOL)diskImageExistsForURL:(NSURL *)url {
    NSString *key = [self cacheKeyForURL:url];
    return [self.imageCache diskImageExistsWithKey:key];
}

//判断图片有没有在内存缓存中,如果图片在内存缓存中存在,就在主线程里面回调block,如果图片没有在内存缓存中就去查找是不是在磁盘缓存里面,然后在主线程里面回到block
- (void)cachedImageExistsForURL:(NSURL *)url
                     completion:(SDWebImageCheckCacheCompletionBlock)completionBlock {
    NSString *key = [self cacheKeyForURL:url];
    
    BOOL isInMemoryCache = ([self.imageCache imageFromMemoryCacheForKey:key] != nil);
    
    if (isInMemoryCache) {
        // making sure we call the completion block on the main queue
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionBlock) {
                completionBlock(YES);
            }
        });
        return;
    }
    
    [self.imageCache diskImageExistsWithKey:key completion:^(BOOL isInDiskCache) {
        // the completion block of checkDiskCacheForImageWithKey:completion: is always called on the main queue, no need to further dispatch
        if (completionBlock) {
            completionBlock(isInDiskCache);
        }
    }];
}

//查询图片是否在磁盘缓存里面,然后在主线程里面回调block
- (void)diskImageExistsForURL:(NSURL *)url
                   completion:(SDWebImageCheckCacheCompletionBlock)completionBlock {
    NSString *key = [self cacheKeyForURL:url];
    
    [self.imageCache diskImageExistsWithKey:key completion:^(BOOL isInDiskCache) {
        // the completion block of checkDiskCacheForImageWithKey:completion: is always called on the main queue, no need to further dispatch
        if (completionBlock) {
            completionBlock(isInDiskCache);
        }
    }];
}

//下载
- (id <SDWebImageOperation>)downloadImageWithURL:(NSURL *)url
                                         options:(SDWebImageOptions)options
                                        progress:(SDWebImageDownloaderProgressBlock)progressBlock
                                       completed:(SDWebImageCompletionWithFinishedBlock)completedBlock {
    // Invoking this method without a completedBlock is pointless
    //completedBlock there must be
    NSAssert(completedBlock != nil, @"If you mean to prefetch the image, use -[SDWebImagePrefetcher prefetchURLs] instead");

    // Very common mistake is to send the URL using NSString object instead of NSURL. For some strange reason, XCode won't
    // throw any warning for this type mismatch. Here we failsafe this error by allowing URLs to be passed as NSString.
    
    //防止开发者把传入NSString类型的url,如果url的类型是NSString就给转换成NSURL类型
    if ([url isKindOfClass:NSString.class]) {
        url = [NSURL URLWithString:(NSString *)url];
    }

    // Prevents app crashing on argument type error like sending NSNull instead of NSURL
    //如果转换NSURL失败,就把传入的url置为nil下载停止
    if (![url isKindOfClass:NSURL.class]) {
        url = nil;
    }

    __block SDWebImageCombinedOperation *operation = [SDWebImageCombinedOperation new];
    __weak SDWebImageCombinedOperation *weakOperation = operation;

    BOOL isFailedUrl = NO;
    @synchronized (self.failedURLs) {
        isFailedUrl = [self.failedURLs containsObject:url];
    }

    //如果不相同并且isFailedUrl是true.那么就回调一个error的block
    if (url.absoluteString.length == 0 || (!(options & SDWebImageRetryFailed) && isFailedUrl)) {
        dispatch_main_sync_safe(^{
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil];
            completedBlock(nil, error, SDImageCacheTypeNone, YES, url);
        });
        return operation;
    }

    //把operation加入到self.runningOperations的数组里面,并创建一个互斥线程锁来保护这个操作
    @synchronized (self.runningOperations) {
        [self.runningOperations addObject:operation];
    }
    //获取image的url对应的key
    NSString *key = [self cacheKeyForURL:url];

    // search the iamge for url in disk
    //异步查询磁盘缓存的方法
    operation.cacheOperation = [self.imageCache queryDiskCacheForKey:key done:^(UIImage *image, SDImageCacheType cacheType) {
        // if operation is cancel  remove it to runningOperations array
        if (operation.isCancelled) {
            @synchronized (self.runningOperations) {
                [self.runningOperations removeObject:operation];
            }

            return;
        }
        /*
         8 & 10 （与运算）
         1000
         1010
         --------
         1000
         
         8（10进制） 还是真
         */
        //条件1:在缓存中没有找到图片或者options选项里面包含了SDWebImageRefreshCached(这两项都需要进行请求网络图片的)
        //条件2:SDWebImageManagerDelegate的delegate不能响应imageManager:shouldDownloadImageForURL:方法
        //或者能响应方法且方法返回值为YES
        if ((!image || options & SDWebImageRefreshCached) && (![self.delegate respondsToSelector:@selector(imageManager:shouldDownloadImageForURL:)] || [self.delegate imageManager:self shouldDownloadImageForURL:url])) {
            // image & option > 二进制第五位数上 要是1才行 == option=SDWebImageRefreshCached
            //如果在缓存中找到了image且options选项包含SDWebImageRefreshCached,先在主线程完成一次回调,使用的是缓存中找的图片

            if (image && options & SDWebImageRefreshCached) {
                dispatch_main_sync_safe(^{
                    // If image was found in the cache but SDWebImageRefreshCached is provided, notify about the cached image
                    // AND try to re-download it in order to let a chance to NSURLCache to refresh it from server.
                 // 如果在缓存中找到了image但是设置了SDWebImageRefreshCached选项，传递缓存的image，同时尝试重新下载它来让NSURLCache有机会接收服务器端的更新
                    completedBlock(image, nil, cacheType, YES, url);
                });
            }

            // download if no image or requested to refresh anyway, and download allowed by delegate
            // 如果没有在缓存中找到image 或者设置了需要请求服务器刷新的选项,则仍需要下载

            SDWebImageDownloaderOptions downloaderOptions = 0;
            // downloaderOptions = downloaderOptions | SDWebImageDownloaderLowPriority;
            if (options & SDWebImageLowPriority) downloaderOptions |= SDWebImageDownloaderLowPriority;
            if (options & SDWebImageProgressiveDownload) downloaderOptions |= SDWebImageDownloaderProgressiveDownload;
            if (options & SDWebImageRefreshCached) downloaderOptions |= SDWebImageDownloaderUseNSURLCache;
            if (options & SDWebImageContinueInBackground) downloaderOptions |= SDWebImageDownloaderContinueInBackground;
            if (options & SDWebImageHandleCookies) downloaderOptions |= SDWebImageDownloaderHandleCookies;
            if (options & SDWebImageAllowInvalidSSLCertificates) downloaderOptions |= SDWebImageDownloaderAllowInvalidSSLCertificates;
            if (options & SDWebImageHighPriority) downloaderOptions |= SDWebImageDownloaderHighPriority;
            
            //SDWebImageDownloaderContinueInBackground
            // 如果image已经被缓存但是设置了需要请求服务器刷新的选项
            if (image && options & SDWebImageRefreshCached) {
                // force progressive off if image already cached but forced refreshing
                // 如果image已经被缓存但是设置了需要请求服务器刷新的选项，强制关闭渐进式选项
                downloaderOptions &= ~SDWebImageDownloaderProgressiveDownload;
                // 忽略从NSURLCache读取的image
                downloaderOptions |= SDWebImageDownloaderIgnoreCachedResponse;
            }
            //创建下载操作,先使用self.imageDownloader下载
            id <SDWebImageOperation> subOperation = [self.imageDownloader downloadImageWithURL:url options:downloaderOptions progress:progressBlock completed:^(UIImage *downloadedImage, NSData *data, NSError *error, BOOL finished) {
                __strong __typeof(weakOperation) strongOperation = weakOperation;
                if (!strongOperation || strongOperation.isCancelled) {
                    // Do nothing if the operation was cancelled 如果操作取消了,不做任何事情
                    // See #699 for more details
                    // if we would call the completedBlock, there could be a race condition between this block and another completedBlock for the same object, so if this one is called second, we will overwrite the new data 如果我们调用completedBlock,这个block会和另外一个completedBlock争夺一个对象,因此这个block被调用后会覆盖新的数据
                }
                else if (error) {
                    //进行完成回调
                    dispatch_main_sync_safe(^{
                        if (strongOperation && !strongOperation.isCancelled) {
                            completedBlock(nil, error, SDImageCacheTypeNone, finished, url);
                        }
                    });
                    //将url添加到失败列表里面
                    if (   error.code != NSURLErrorNotConnectedToInternet
                        && error.code != NSURLErrorCancelled
                        && error.code != NSURLErrorTimedOut
                        && error.code != NSURLErrorInternationalRoamingOff
                        && error.code != NSURLErrorDataNotAllowed
                        && error.code != NSURLErrorCannotFindHost
                        && error.code != NSURLErrorCannotConnectToHost) {
                        @synchronized (self.failedURLs) {
                            [self.failedURLs addObject:url];
                        }
                    }
                }
                else {
                    //如果设置了下载失败重试,将url从失败列表中去掉
                    if ((options & SDWebImageRetryFailed)) {
                        @synchronized (self.failedURLs) {
                            [self.failedURLs removeObject:url];
                        }
                    }
                    
                    BOOL cacheOnDisk = !(options & SDWebImageCacheMemoryOnly);
                    //options包含了SDWebImageRefreshCached选项,且缓存中找到了image且没有下载成功
                    if (options & SDWebImageRefreshCached && image && !downloadedImage) {
                        // Image refresh hit the NSURLCache cache, do not call the completion block
                        // 图片刷新遇到了NSSURLCache中有缓存的状况，不调用完成回调。
                    }
                    //图片下载成功并且 设置了需要变形Image的选项且变形的代理方法已经实现
                    else if (downloadedImage && (!downloadedImage.images || (options & SDWebImageTransformAnimatedImage)) && [self.delegate respondsToSelector:@selector(imageManager:transformDownloadedImage:withURL:)]) {
                        //全局队列异步执行
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                            //调用代理方法完成图片transform
                            UIImage *transformedImage = [self.delegate imageManager:self transformDownloadedImage:downloadedImage withURL:url];

                            if (transformedImage && finished) {
                                BOOL imageWasTransformed = ![transformedImage isEqual:downloadedImage];
                                //对已经transform的图片进行缓存
                                [self.imageCache storeImage:transformedImage recalculateFromImage:imageWasTransformed imageData:(imageWasTransformed ? nil : data) forKey:key toDisk:cacheOnDisk];
                            }
                            //主线程执行完成回调
                            dispatch_main_sync_safe(^{
                                if (strongOperation && !strongOperation.isCancelled) {
                                    completedBlock(transformedImage, nil, SDImageCacheTypeNone, finished, url);
                                }
                            });
                        });
                    }
                    //如果没有图片transform的需求并且图片下载完成且图片存在就直接缓存
                    else {
                        if (downloadedImage && finished) {
                            [self.imageCache storeImage:downloadedImage recalculateFromImage:NO imageData:data forKey:key toDisk:cacheOnDisk];
                        }
                        //主线程完成回调
                        dispatch_main_sync_safe(^{
                            if (strongOperation && !strongOperation.isCancelled) {
                                completedBlock(downloadedImage, nil, SDImageCacheTypeNone, finished, url);
                            }
                        });
                    }
                }

                if (finished) {
                    // 从正在进行的操作列表中移除这组合操作
                    @synchronized (self.runningOperations) {
                        if (strongOperation) {
                            [self.runningOperations removeObject:strongOperation];
                        }
                    }
                }
            }];
            //设置组合操作取消得得回调
            operation.cancelBlock = ^{
                [subOperation cancel];
                
                @synchronized (self.runningOperations) {
                    __strong __typeof(weakOperation) strongOperation = weakOperation;
                    if (strongOperation) {
                        [self.runningOperations removeObject:strongOperation];
                    }
                }
            };
        }
        //处理其他情况
        //case1.在缓存中找到图片(代理不允许下载 或者没有设置SDWebImageRefreshCached选项  满足至少一项)
        else if (image) {
            //完成回调
            dispatch_main_sync_safe(^{
                __strong __typeof(weakOperation) strongOperation = weakOperation;
                if (strongOperation && !strongOperation.isCancelled) {
                    completedBlock(image, nil, cacheType, YES, url);
                }
            });
            //从正在进行的操作列表中移除组合操作
            @synchronized (self.runningOperations) {
                [self.runningOperations removeObject:operation];
            }
        }
        //case2:缓存中没有扎到图片且代理不允许下载
        else {
            // Image not in cache and download disallowed by delegate
            //主线程执行完成回调
            dispatch_main_sync_safe(^{
                __strong __typeof(weakOperation) strongOperation = weakOperation;
                if (strongOperation && !weakOperation.isCancelled) {
                    completedBlock(nil, nil, SDImageCacheTypeNone, YES, url);
                }
            });
            @synchronized (self.runningOperations) {
                [self.runningOperations removeObject:operation];
            }
        }
    }];

    return operation;
}

- (void)saveImageToCache:(UIImage *)image forURL:(NSURL *)url {
    if (image && url) {
        NSString *key = [self cacheKeyForURL:url];
        [self.imageCache storeImage:image forKey:key toDisk:YES];
    }
}

- (void)cancelAll {
    @synchronized (self.runningOperations) {
        NSArray *copiedOperations = [self.runningOperations copy];
        [copiedOperations makeObjectsPerformSelector:@selector(cancel)];
        [self.runningOperations removeObjectsInArray:copiedOperations];
    }
}

- (BOOL)isRunning {
    BOOL isRunning = NO;
    @synchronized(self.runningOperations) {
        isRunning = (self.runningOperations.count > 0);
    }
    return isRunning;
}

@end


@implementation SDWebImageCombinedOperation

- (void)setCancelBlock:(SDWebImageNoParamsBlock)cancelBlock {
    // check if the operation is already cancelled, then we just call the cancelBlock
    if (self.isCancelled) {
        if (cancelBlock) {
            cancelBlock();
        }
        _cancelBlock = nil; // don't forget to nil the cancelBlock, otherwise we will get crashes
    } else {
        _cancelBlock = [cancelBlock copy];
    }
}

- (void)cancel {
    self.cancelled = YES;
    if (self.cacheOperation) {
        [self.cacheOperation cancel];
        self.cacheOperation = nil;
    }
    if (self.cancelBlock) {
        self.cancelBlock();
        
        // TODO: this is a temporary fix to #809.
        // Until we can figure the exact cause of the crash, going with the ivar instead of the setter
//        self.cancelBlock = nil;
        _cancelBlock = nil;
    }
}

@end


@implementation SDWebImageManager (Deprecated)

// deprecated method, uses the non deprecated method
// adapter for the completion block
- (id <SDWebImageOperation>)downloadWithURL:(NSURL *)url options:(SDWebImageOptions)options progress:(SDWebImageDownloaderProgressBlock)progressBlock completed:(SDWebImageCompletedWithFinishedBlock)completedBlock {
    return [self downloadImageWithURL:url
                              options:options
                             progress:progressBlock
                            completed:^(UIImage *image, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
                                if (completedBlock) {
                                    completedBlock(image, error, cacheType, finished);
                                }
                            }];
}

@end
