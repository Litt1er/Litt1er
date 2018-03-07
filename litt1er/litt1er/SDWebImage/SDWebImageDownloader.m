/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloader.h"
#import "SDWebImageDownloaderOperation.h"
#import <ImageIO/ImageIO.h>

static NSString *const kProgressCallbackKey = @"progress";
static NSString *const kCompletedCallbackKey = @"completed";

@interface SDWebImageDownloader () <NSURLSessionTaskDelegate, NSURLSessionDataDelegate>

@property (strong, nonatomic) NSOperationQueue *downloadQueue;
@property (weak, nonatomic) NSOperation *lastAddedOperation;
@property (assign, nonatomic) Class operationClass;
@property (strong, nonatomic) NSMutableDictionary *URLCallbacks;
@property (strong, nonatomic) NSMutableDictionary *HTTPHeaders;
// This queue is used to serialize the handling of the network responses of all the download operation in a single queue
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t barrierQueue;

// The session in which data tasks will run
@property (strong, nonatomic) NSURLSession *session;

@end

@implementation SDWebImageDownloader

+ (void)initialize {
    // Bind SDNetworkActivityIndicator if available (download it here: http://github.com/rs/SDNetworkActivityIndicator )
    // To use it, just add #import "SDNetworkActivityIndicator.h" in addition to the SDWebImage import
    if (NSClassFromString(@"SDNetworkActivityIndicator")) {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id activityIndicator = [NSClassFromString(@"SDNetworkActivityIndicator") performSelector:NSSelectorFromString(@"sharedActivityIndicator")];
#pragma clang diagnostic pop

        // Remove observer in case it was previously added.
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStopNotification object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"startActivity")
                                                     name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"stopActivity")
                                                     name:SDWebImageDownloadStopNotification object:nil];
    }
}

+ (SDWebImageDownloader *)sharedDownloader {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (id)init {
    if ((self = [super init])) {
        _operationClass = [SDWebImageDownloaderOperation class];
        _shouldDecompressImages = YES;
        _executionOrder = SDWebImageDownloaderFIFOExecutionOrder;
        _downloadQueue = [NSOperationQueue new];
        _downloadQueue.maxConcurrentOperationCount = 6;
        _downloadQueue.name = @"com.hackemist.SDWebImageDownloader";
        _URLCallbacks = [NSMutableDictionary new];
#ifdef SD_WEBP
        _HTTPHeaders = [@{@"Accept": @"image/webp,image/*;q=0.8"} mutableCopy];
#else
        _HTTPHeaders = [@{@"Accept": @"image/*;q=0.8"} mutableCopy];
#endif
        _barrierQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloaderBarrierQueue", DISPATCH_QUEUE_CONCURRENT);
        _downloadTimeout = 15.0;

        NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
        sessionConfig.timeoutIntervalForRequest = _downloadTimeout;

        /**
         *  Create the session for this task
         *  We send nil as delegate queue so that the session creates a serial operation queue for performing all delegate
         *  method calls and completion handler calls.
         */
        self.session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                     delegate:self
                                                delegateQueue:nil];
    }
    return self;
}

- (void)dealloc {
    [self.session invalidateAndCancel];
    self.session = nil;

    [self.downloadQueue cancelAllOperations];
    SDDispatchQueueRelease(_barrierQueue);
}

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (value) {
        self.HTTPHeaders[field] = value;
    }
    else {
        [self.HTTPHeaders removeObjectForKey:field];
    }
}

- (NSString *)valueForHTTPHeaderField:(NSString *)field {
    return self.HTTPHeaders[field];
}

- (void)setMaxConcurrentDownloads:(NSInteger)maxConcurrentDownloads {
    _downloadQueue.maxConcurrentOperationCount = maxConcurrentDownloads;
}

- (NSUInteger)currentDownloadCount {
    return _downloadQueue.operationCount;
}

- (NSInteger)maxConcurrentDownloads {
    return _downloadQueue.maxConcurrentOperationCount;
}

- (void)setOperationClass:(Class)operationClass {
    _operationClass = operationClass ?: [SDWebImageDownloaderOperation class];
}

- (id <SDWebImageOperation>)downloadImageWithURL:(NSURL *)url options:(SDWebImageDownloaderOptions)options progress:(SDWebImageDownloaderProgressBlock)progressBlock completed:(SDWebImageDownloaderCompletedBlock)completedBlock {
    __block SDWebImageDownloaderOperation *operation;
    __weak __typeof(self)wself = self;

    [self addProgressCallback:progressBlock completedBlock:completedBlock forURL:url createCallback:^{
        
        // if url is not nil this block will be perform
        //配置下载超时的时间
        NSTimeInterval timeoutInterval = wself.downloadTimeout;
        if (timeoutInterval == 0.0) {
            timeoutInterval = 15.0;
        }

        // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests if told otherwise
        /**
         创建请求对象,并根据options参数设置其属性
         为了避免潜在的重复缓存(NSURLCache + SDImageCache)，
         如果没有明确告知需要缓存，
         则禁用图片请求的缓存操作, 这样就只有SDImageCache进行了缓存
         这里的options 是SDWebImageDownloaderOptions
         */
        NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url cachePolicy:(options & SDWebImageDownloaderUseNSURLCache ? NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringLocalCacheData) timeoutInterval:timeoutInterval];
        //通过设置 NSMutableURLRequest.HTTPShouldHandleCookies = YES
        //的方式来处理存储在NSHTTPCookieStore的cookies
        request.HTTPShouldHandleCookies = (options & SDWebImageDownloaderHandleCookies);
        //返回在接到上一个请求得得响应之前,是否需要传输数据,YES传输,NO不传输
        request.HTTPShouldUsePipelining = YES;
        /**
         如果你自定义了wself.headersFilter,那就用你自己设置的
         wself.headersFilter来设置HTTP的header field
         它的定义是
         typedef NSDictionary *(^SDWebImageDownloaderHeadersFilterBlock)(NSURL *url, NSDictionary *headers);
         一个返回结果为NSDictionary类型的block
         
         如果你没有自己设置wself.headersFilter那么就用SDWebImage提供的HTTPHeaders
         HTTPHeaders在#import "SDWebImageDownloader.h",init方法里面初始化,下载webp图片需要的header不一样
         (WebP格式，[谷歌]开发的一种旨在加快图片加载速度的图片格式。图片压缩体积大约只有JPEG的2/3，并能节省大量的服务器带宽资源和数据空间)
         #ifdef SD_WEBP
         _HTTPHeaders = [@{@"Accept": @"image/webp,image/*;q=0.8"} mutableCopy];
         #else
         _HTTPHeaders = [@{@"Accept": @"image/*;q=0.8"} mutableCopy];
         #endif
         */
        if (wself.headersFilter) {
            request.allHTTPHeaderFields = wself.headersFilter(url, [wself.HTTPHeaders copy]);
        }
        else {
            request.allHTTPHeaderFields = wself.HTTPHeaders;
        }
        /**
         创建SDWebImageDownLoaderOperation操作对象(下载的操作就是在SDWebImageDownLoaderOperation类里面进行的)
         传入了进度回调,完成回调,取消回调
         
         @property (assign, nonatomic) Class operationClass;
         将Class作为属性存储,初始化具体Class,使用的时候调用具体class的方法
         */
        operation = [[wself.operationClass alloc] initWithRequest:request
                                                        inSession:self.session
                                                          options:options
                                                         progress:^(NSInteger receivedSize, NSInteger expectedSize) {
                                                             //progress block回调的操作                                                            SDWebImageDownloader *sself = wself;

                                                             SDWebImageDownloader *sself = wself;
                                                             if (!sself) return;
                                                             __block NSArray *callbacksForURL;
                                                             /**
                                                              URLCallbacks是一个字典,key是url,value是一个数组,
                                                              数组里面装的是字典,key是NSString代表着回调类型,value为block是对应的回调
                                                              确保提交的block是指定队列中特定时段唯一在执行的一个.
                                                              */
                                                             dispatch_sync(sself.barrierQueue, ^{
                                                                 callbacksForURL = [sself.URLCallbacks[url] copy];
                                                             });
                                                             for (NSDictionary *callbacks in callbacksForURL) {
                                                                 dispatch_async(dispatch_get_main_queue(), ^{
                                                                     //根据kProgressCallbackKey这个key取出进度的操作
                                                                     SDWebImageDownloaderProgressBlock callback = callbacks[kProgressCallbackKey];
                                                                     if (callback) callback(receivedSize, expectedSize);
                                                                 });
                                                             }
                                                         }
                                                        completed:^(UIImage *image, NSData *data, NSError *error, BOOL finished) {
                                                            SDWebImageDownloader *sself = wself;
                                                            if (!sself) return;
                                                            __block NSArray *callbacksForURL;
                                                            dispatch_barrier_sync(sself.barrierQueue, ^{
                                                                callbacksForURL = [sself.URLCallbacks[url] copy];
                                                                if (finished) {
                                                                    //如果这个任务已经完成,就根据url这个key从URLCallbacks字典里面删除
                                                                    [sself.URLCallbacks removeObjectForKey:url];
                                                                }
                                                            });
                                                            for (NSDictionary *callbacks in callbacksForURL) {
                                                                SDWebImageDownloaderCompletedBlock callback = callbacks[kCompletedCallbackKey];
                                                                //回调 图片 data error 是否完成的
                                                                if (callback) callback(image, data, error, finished);
                                                            }
                                                        }
                                                        cancelled:^{
                                                            SDWebImageDownloader *sself = wself;
                                                            if (!sself) return;
                                                            //将url对应的所有回调移除
                                                            dispatch_barrier_async(sself.barrierQueue, ^{
                                                                [sself.URLCallbacks removeObjectForKey:url];
                                                            });
                                                        }];
        //上面 是SDWebImageDownloaderOperation *operation的创建,从这里开始就都是对operation的配置
        
        // 设置是否需要解压
        operation.shouldDecompressImages = wself.shouldDecompressImages;
        /**
         用户认证 NSURLCredential
         当连接客户端与服务端进行数据传输的时候,web服务器
         收到客户端请求时可能需要先验证客户端是否是正常用户,再决定是否返回该接口的真实数据
         
         iOS7.0之前使用的网络框架是NSURLConnection,在 2013 的 WWDC 上，
         苹果推出了 NSURLConnection 的继任者：NSURLSession
         
         SDWebImage使用的是NSURLConnection,这两种网络框架的认证调用的方法也是不一样的,有兴趣的可以去google一下这里只看下NSURLConnection的认证(在这里写看着有些吃力,移步到这个代码框外面阅读)
         
         */
        if (wself.urlCredential) {
            operation.credential = wself.urlCredential;
        } else if (wself.username && wself.password) {
            operation.credential = [NSURLCredential credentialWithUser:wself.username password:wself.password persistence:NSURLCredentialPersistenceForSession];
        }
        //根据下载选项SDWebImageDownloaderHighPriority设置优先级
        if (options & SDWebImageDownloaderHighPriority) {
            operation.queuePriority = NSOperationQueuePriorityHigh;
        } else if (options & SDWebImageDownloaderLowPriority) {
            operation.queuePriority = NSOperationQueuePriorityLow;
        }
        
        //将下载操作加到下载队列中
        [wself.downloadQueue addOperation:operation];
        if (wself.executionOrder == SDWebImageDownloaderLIFOExecutionOrder) {
            /**
             根据executionOrder设置操作的依赖关系
             executionOrder代表着下载操作执行的顺序,它是一个枚举
             SD添加下载任务是同步的，而且都是在self.barrierQueue这个并行队列中，
             同步添加任务。这样也保证了根据executionOrder设置依赖关是正确的。
             换句话说如果创建下载任务不是使用dispatch_barrier_sync完成的，而是使用异步方法 ，虽然依次添加创建下载操作A、B、C的任务，但实际创建顺序可能为A、C、B，这样当executionOrder的值是SDWebImageDownloaderLIFOExecutionOrder，设置的操作依赖关系就变成了A依赖C，C依赖B
             
             typedef NS_ENUM(NSInteger, SDWebImageDownloaderExecutionOrder) {
             // 默认值，所有的下载操作以队列类型执行,先被加入下载队列的操作先执行
             SDWebImageDownloaderFIFOExecutionOrder,
             // 所有的下载操作以栈类型执行,后进先出,后被加入下载队列的操作先执行
             SDWebImageDownloaderLIFOExecutionOrder
             };
             */
            // Emulate LIFO execution order by systematically adding new operations as last operation's dependency
            [wself.lastAddedOperation addDependency:operation];
            wself.lastAddedOperation = operation;
        }
    }];

    return operation;
}

- (void)addProgressCallback:(SDWebImageDownloaderProgressBlock)progressBlock completedBlock:(SDWebImageDownloaderCompletedBlock)completedBlock forURL:(NSURL *)url createCallback:(SDWebImageNoParamsBlock)createCallback {
    // The URL will be used as the key to the callbacks dictionary so it cannot be nil. If it is nil immediately call the completed block with no image or data.
    //如果图片的url是空的就直接返回
    if (url == nil) {
        if (completedBlock != nil) {
            completedBlock(nil, nil, nil, NO);
        }
        return;
    }
    /*
     共同点：
     
     1、等待在它前面插入队列的任务先执行完
     
     2、等待他们自己的任务执行完再执行后面的任务
     
     不同点：
     
     1、dispatch_barrier_sync将自己的任务插入到队列的时候，需要等待自己的任务结束之后才会继续插入被写在它后面的任务，然后执行它们
     
     2、dispatch_barrier_async将自己的任务插入到队列之后，不会等待自己的任务结束，它会继续把后面的任务插入到队列，然后等待自己的任务结束后才执行后面任务。
     
     URLCallbacks是一个可变字典,key是NSURL类型,value为NSMutableArray类型,value(数组里面)只包含一个元素,这个元素的类型是NSMutableDictionary类型,这个字典的key为NSString类型代表着回调类型,value为block,是对应的回调
     这些代码的目的都是为了给url绑定回调
     
     这里有个细节需要注意，因为可能同时下载多张图片，所以就可能出现多个线程同时访问 URLCallbacks 属性的情况。为了保证线程安全，所以这里使用了 dispatch_barrier_sync 来分步执行添加到 barrierQueue 中的任务，这样就能保证同一时间只有一个线程能对 URLCallbacks 进行操作。
     */

    dispatch_barrier_sync(self.barrierQueue, ^{
        BOOL first = NO;
        if (!self.URLCallbacks[url]) {
            self.URLCallbacks[url] = [NSMutableArray new];
            first = YES;
        }

        // Handle single download of simultaneous download request for the same URL
        NSMutableArray *callbacksForURL = self.URLCallbacks[url];
        NSMutableDictionary *callbacks = [NSMutableDictionary new];
        if (progressBlock) callbacks[kProgressCallbackKey] = [progressBlock copy];
        if (completedBlock) callbacks[kCompletedCallbackKey] = [completedBlock copy];
        [callbacksForURL addObject:callbacks];
        self.URLCallbacks[url] = callbacksForURL;

        if (first) {
            createCallback();
        }
    });
}

- (void)setSuspended:(BOOL)suspended {
    [self.downloadQueue setSuspended:suspended];
}

- (void)cancelAllDownloads {
    [self.downloadQueue cancelAllOperations];
}

#pragma mark Helper methods

- (SDWebImageDownloaderOperation *)operationWithTask:(NSURLSessionTask *)task {
    SDWebImageDownloaderOperation *returnOperation = nil;
    for (SDWebImageDownloaderOperation *operation in self.downloadQueue.operations) {
        if (operation.dataTask.taskIdentifier == task.taskIdentifier) {
            returnOperation = operation;
            break;
        }
    }
    return returnOperation;
}

#pragma mark NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];

    [dataOperation URLSession:session dataTask:dataTask didReceiveResponse:response completionHandler:completionHandler];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];

    [dataOperation URLSession:session dataTask:dataTask didReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];

    [dataOperation URLSession:session dataTask:dataTask willCacheResponse:proposedResponse completionHandler:completionHandler];
}

#pragma mark NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];

    [dataOperation URLSession:session task:task didCompleteWithError:error];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];

    [dataOperation URLSession:session task:task didReceiveChallenge:challenge completionHandler:completionHandler];
}

@end
