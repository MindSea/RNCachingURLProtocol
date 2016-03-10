//
//  RNCachingURLProtocol.m
//
//  Created by Robert Napier on 1/10/12.
//  Copyright (c) 2012 Rob Napier.
//
//  This code is licensed under the MIT License:
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//

#import "RNCachingURLProtocol.h"
#import "Reachability.h"
#import <CommonCrypto/CommonCrypto.h>

@interface NSURLRequest (MutableCopyWorkaround)

- (id)mutableCopyWorkaround;

@end


@interface RNCachedData : NSObject <NSCoding>
@property(nonatomic, readwrite, strong) NSData *data;
@property(nonatomic, readwrite, strong) NSURLResponse *response;
@property(nonatomic, readwrite, strong) NSURLRequest *redirectRequest;
@property(nonatomic, readwrite, strong) NSString *mimeType;
@property(nonatomic, readwrite, strong) NSDate *lastModifiedDate;
@end

static NSString * const RNCachingURLHeader = @"X-RNCache";
static NSString * const RNCachingPlistFile = @"RNCacheV2.plist";
static NSString * const RNCachingFolder = @"RNCaching";
static NSString * const RNCachingDateKey = @"date";
static NSString * const RNCachingMimeTypeKey = @"mimeType";
static NSString * const RNCachingURLKey = @"url";

@interface RNCacheListStore : NSObject
- (id)initWithPath:(NSString *)path;

- (void)setObject:(id)object forKey:(id)aKey;

- (id)objectForKey:(id)aKey;

- (NSArray *)removeObjectsOlderThan:(NSDate *)date;

- (void)clear;
@end

@interface RNCachingURLProtocol () // <NSURLConnectionDelegate, NSURLConnectionDataDelegate> iOS5-only
@property(nonatomic, readwrite, strong) NSURLConnection *connection;
@property(nonatomic, readwrite, strong) NSMutableData *data;
@property(nonatomic, readwrite, strong) NSURLResponse *response;

- (void)appendData:(NSData *)newData;
@end

static NSMutableDictionary *_expireTime = nil;
static NSMutableArray *_whiteListURLs = nil;
static NSMutableArray *_foreverCacheURLs = nil;
static RNCacheListStore *_cacheListStore = nil;
static RNCacheListStore *_bundleCacheListStore = nil;

@implementation RNCachingURLProtocol
@synthesize connection = connection_;
@synthesize data = data_;
@synthesize response = response_;

+ (RNCacheListStore *)cacheListStore {
    @synchronized (self) {
        if (_cacheListStore == nil) {
            _cacheListStore = [[RNCacheListStore alloc] initWithPath:[self cachePathForKey:RNCachingPlistFile inBundle:NO]];
        }
        return _cacheListStore;
    }
}

+ (RNCacheListStore *)bundleCacheListStore {
    @synchronized (self) {
        if (_bundleCacheListStore == nil) {
            _bundleCacheListStore = [[RNCacheListStore alloc] initWithPath:[self cachePathForKey:RNCachingPlistFile inBundle:YES]];
        }
        return _bundleCacheListStore;
    }
}

+ (NSMutableDictionary *)expireTime {
    if (_expireTime == nil) {
        _expireTime = [NSMutableDictionary dictionary];
        [_expireTime setObject:@(60 * 30) forKey:@"application/json"]; // 30 min
        [_expireTime setObject:@(60 * 30) forKey:@"application/javascript"]; // 30 min
        [_expireTime setObject:@(60 * 30) forKey:@"text/html"]; // 30 min
        [_expireTime setObject:@(60 * 30) forKey:@"text/css"]; // 30 min
        [_expireTime setObject:@(60 * 30) forKey:@"text/plain"]; // 30 min, sometimes the css/js will be treated like text/plain
        [_expireTime setObject:@(60 * 60 * 24 * 30) forKey:@"image/jpeg"]; // 30 day
        [_expireTime setObject:@(60 * 60 * 24 * 30) forKey:@"image/jpg"]; // 30 day
        [_expireTime setObject:@(60 * 60 * 24 * 30) forKey:@"image/png"]; // 30 day
        [_expireTime setObject:@(60 * 60 * 24 * 30) forKey:@"image/gif"]; // 30 day
    }
    return _expireTime;
}

+ (NSMutableArray *)whiteListURLs {
    if (_whiteListURLs == nil) {
        _whiteListURLs = [NSMutableArray array];
    }

    return _whiteListURLs;
}

+ (NSMutableArray *)foreverCacheURLs {
    if (_foreverCacheURLs == nil) {
        _foreverCacheURLs = [NSMutableArray array];
    }
    
    return _foreverCacheURLs;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // only handle http requests we haven't marked with our header, are GET, and match the white list.
    if ([[[request URL] scheme] isEqualToString:@"http"] &&
            ([request valueForHTTPHeaderField:RNCachingURLHeader] == nil) &&
            [[request HTTPMethod] isEqualToString:@"GET"] &&
            [self isRequestWhitelisted:request]) {
        return YES;
    }
    return NO;
}

+ (BOOL)isRequest:(NSURLRequest*)request inRegexArray:(NSArray*)regexArray {
    NSString *string = [[request URL] absoluteString];
    
    NSError *error = NULL;
    BOOL found = NO;
    for (NSString *pattern in regexArray) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:&error];
        NSTextCheckingResult *result = [regex firstMatchInString:string options:NSMatchingAnchored range:NSMakeRange(0, string.length)];
        if (result.numberOfRanges) {
            return YES;
        }
    }
    
    return found;
}

+ (BOOL)isRequestWhitelisted:(NSURLRequest*)request {
    return [self isRequest:request inRegexArray:_whiteListURLs];
}

+ (BOOL)isRequestForeverCached:(NSURLRequest*)request {
    return [self isRequest:request inRegexArray:_foreverCacheURLs];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (void)removeCache {
    [[self cacheListStore] clear];
    NSString *cachesPath = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject];
    NSString *offlineCachePath = [cachesPath stringByAppendingPathComponent:RNCachingFolder];
    [[NSFileManager defaultManager] removeItemAtPath:offlineCachePath error:nil];
}

+ (void)removeCacheOlderThan:(NSDate *)date {
    NSArray *keysToDelete = [[self cacheListStore] removeObjectsOlderThan:date];
    for (NSString *key in keysToDelete) {
        [[NSFileManager defaultManager] removeItemAtPath:key error:nil];
    }
}

+ (NSString*)cacheKeyForRequest:(NSURLRequest*)request {
    return [self cacheKeyForString:[request.URL absoluteString]];
}

+ (NSString*)cacheKeyForString:(NSString*)urlString {
    
    // SHA-1
    const char *cStr = [urlString UTF8String];
    unsigned char result[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cStr, strlen(cStr), result);
    NSString *s = [NSString  stringWithFormat:
                   @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
                   result[0], result[1], result[2], result[3], result[4],
                   result[5], result[6], result[7],
                   result[8], result[9], result[10], result[11], result[12],
                   result[13], result[14], result[15],
                   result[16], result[17], result[18], result[19]
                   ];
    
    return s;
}

+ (NSString *)cachePathForKey:(NSString *)key inBundle:(BOOL)inBundle {
    
    NSString *result = nil;
    
    if (inBundle) {
        result = [[NSBundle mainBundle] pathForResource:key ofType:nil inDirectory:RNCachingFolder];
    } else {
        NSString *cachesPath = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject];
        NSString *offlineCachePath = [cachesPath stringByAppendingPathComponent:RNCachingFolder];
        [[NSFileManager defaultManager] createDirectoryAtPath:offlineCachePath withIntermediateDirectories:YES attributes:nil error:nil];
        result = [offlineCachePath stringByAppendingPathComponent:key];
    }
    
    return result;
}

+ (RNCachedData*)cachedDataForRequest:(NSURLRequest*)request {
    
    RNCachedData *result = nil;

    NSString *key = [self cacheKeyForRequest:request];
    
    // Check the writable cache first
    NSString *path = [self cachePathForKey:key inBundle:NO];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        // Check the bundle
        path = [self cachePathForKey:key inBundle:YES];
    }
    
    if (path) {
        result = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
    }
    
    return result;
}

- (void)startLoading {
    if ([self useCache]) {
        RNCachedData *cache = [RNCachingURLProtocol cachedDataForRequest:self.request];
        if (cache) {
            NSData *data = [cache data];
            NSURLResponse *response = [cache response];
            NSURLRequest *redirectRequest = [cache redirectRequest];
            if (redirectRequest) {
                [[self client] URLProtocol:self wasRedirectedToRequest:redirectRequest redirectResponse:response];
            } else {
                [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed]; // we handle caching ourselves.
                [[self client] URLProtocol:self didLoadData:data];
                [[self client] URLProtocolDidFinishLoading:self];
            }
            return;
        }
    }

#if !(defined RNCACHING_DISABLE_LOGGING)
    NSLog(@"[RNCachingURLProtocol] fetching '%@'", [[[self request] URL] absoluteString]);
#endif
    NSMutableURLRequest *connectionRequest = [[self request] mutableCopyWorkaround];
    // we need to mark this request with our header so we know not to handle it in +[NSURLProtocol canInitWithRequest:].
    [connectionRequest setValue:@"" forHTTPHeaderField:RNCachingURLHeader];
    NSURLConnection *connection = [NSURLConnection connectionWithRequest:connectionRequest
                                                                delegate:self];
    [self setConnection:connection];
}

- (void)stopLoading {
    [[self connection] cancel];
}

// NSURLConnection delegates (generally we pass these on to our client)

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response {
// Thanks to Nick Dowell https://gist.github.com/1885821
    if (response != nil) {
        NSMutableURLRequest *redirectableRequest = [request mutableCopyWorkaround];
        // We need to remove our header so we know to handle this request and cache it.
        // There are 3 requests in flight: the outside request, which we handled, the internal request,
        // which we marked with our header, and the redirectableRequest, which we're modifying here.
        // The redirectable request will cause a new outside request from the NSURLProtocolClient, which
        // must not be marked with our header.
        [redirectableRequest setValue:nil forHTTPHeaderField:RNCachingURLHeader];

        NSString *cacheKey = [RNCachingURLProtocol cacheKeyForRequest:self.request];
        NSString *cachePath = [RNCachingURLProtocol cachePathForKey:cacheKey inBundle:NO];
        RNCachedData *cache = [RNCachedData new];
        [cache setResponse:response];
        [cache setData:[self data]];
        [cache setRedirectRequest:redirectableRequest];
        [NSKeyedArchiver archiveRootObject:cache toFile:cachePath];
        [[self client] URLProtocol:self wasRedirectedToRequest:redirectableRequest redirectResponse:response];
        return redirectableRequest;
    } else {
        return request;
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [[self client] URLProtocol:self didLoadData:data];    
    [self appendData:data];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [[self client] URLProtocol:self didFailWithError:error];
    [self setConnection:nil];
    [self setData:nil];
    [self setResponse:nil];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    [self setResponse:response];
    [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];  // We cache ourselves.
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    [[self client] URLProtocolDidFinishLoading:self];

    NSString *cacheKey = [RNCachingURLProtocol cacheKeyForRequest:self.request];
    NSString *cachePath = [RNCachingURLProtocol cachePathForKey:cacheKey inBundle:NO];
    RNCachedData *cache = [RNCachedData new];
    [cache setResponse:[self response]];
    [cache setData:[self data]];
    NSDictionary *cacheEntry = @{RNCachingDateKey:[NSDate date], RNCachingMimeTypeKey:self.response.MIMEType, RNCachingURLKey:self.request.URL.absoluteString};
    [[[self class] cacheListStore] setObject:cacheEntry forKey:cacheKey];

    [NSKeyedArchiver archiveRootObject:cache toFile:cachePath];

    [self setConnection:nil];
    [self setData:nil];
    [self setResponse:nil];
}

- (BOOL)useCache {
    
    // Check if it's forever cached and use it immediately if we have it
    if ([RNCachingURLProtocol isRequestForeverCached:self.request]) {
        NSDictionary *meta = [self cacheMeta];
        if (meta != nil) {
            return YES;
        }
    }
    
    BOOL reachable = (BOOL) [[Reachability reachabilityWithHostname:[[[self request] URL] host]] currentReachabilityStatus] != NotReachable;
    if (!reachable) {
        return YES;
    } else {
        return ![self isCacheExpired];
    }
}

- (NSDictionary *)cacheMeta {
    NSDictionary *result = nil;
    
    NSString *cacheKey = [RNCachingURLProtocol cacheKeyForRequest:self.request];
    
    if (cacheKey) {
        // Look up in the writable store first
        result = [[RNCachingURLProtocol cacheListStore] objectForKey:cacheKey];
        
        if (!result) {
            // Look in the bundle store
            result = [[RNCachingURLProtocol bundleCacheListStore] objectForKey:cacheKey];
        }
    }
    
    return result;
}

- (BOOL)isCacheExpired {
    NSDictionary *meta = [self cacheMeta];
    if (meta == nil) {
        return YES;
    }

    NSDate *modifiedDate = meta[RNCachingDateKey];
    NSString *mimeType = meta[RNCachingMimeTypeKey];

    BOOL expired = YES;

    NSNumber *time = [[RNCachingURLProtocol expireTime] valueForKey:mimeType];
    if (time) {
        NSTimeInterval delta = [[NSDate date] timeIntervalSinceDate:modifiedDate];

        expired = (delta > [time intValue]);
    }

#if !(defined RNCACHING_DISABLE_LOGGING)
    NSLog(@"[RNCachingURLProtocol] %@: %@", expired ? @"expired" : @"hit", [[[self request] URL] absoluteString]);
#endif
    return expired;
}

- (void)appendData:(NSData *)newData {
    if ([self data] == nil) {
        [self setData:[newData mutableCopy]];
    }
    else {
        [[self data] appendData:newData];
    }
}

@end

static NSString *const kDataKey = @"data";
static NSString *const kResponseKey = @"response";
static NSString *const kHTTPResponseKey = @"httpResponse";
static NSString *const kRedirectRequestKey = @"redirectRequest";
static NSString *const kMimeType = @"mimeType";
static NSString *const kLastModifiedDateKey = @"lastModifiedDateKey";

@implementation RNCachedData

@synthesize data = data_;
@synthesize response = response_;
@synthesize redirectRequest = redirectRequest_;
@synthesize mimeType = mimeType_;
@synthesize lastModifiedDate = lastModifiedDate_;

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:[NSDate new] forKey:kLastModifiedDateKey];
    [aCoder encodeObject:[self data] forKey:kDataKey];
    [aCoder encodeObject:[self response].MIMEType forKey:kMimeType];
    
    if ([[self response] isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)[self response];
        
        NSDictionary *encodedResponse = @{@"url": httpResponse.URL,
                                          @"statusCode": @(httpResponse.statusCode),
                                          @"HTTPVersion": @"HTTP/1.1",
                                          @"headerFields": [NSDictionary dictionaryWithDictionary:httpResponse.allHeaderFields]
                                          };
        
        
        [aCoder encodeObject:encodedResponse forKey:kHTTPResponseKey];
    } else {
        [aCoder encodeObject:[self response] forKey:kResponseKey];
    }
    [aCoder encodeObject:[self redirectRequest] forKey:kRedirectRequestKey];
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super init];
    if (self != nil) {
        [self setLastModifiedDate:[aDecoder decodeObjectForKey:kLastModifiedDateKey]];
        [self setData:[aDecoder decodeObjectForKey:kDataKey]];
        [self setMimeType:[aDecoder decodeObjectForKey:kMimeType]];
        
        if ([aDecoder containsValueForKey:kHTTPResponseKey]) {
            NSDictionary *encodedResponse = [aDecoder decodeObjectForKey:kHTTPResponseKey];
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:encodedResponse[@"url"]
                                                                      statusCode:[encodedResponse[@"statusCode"] integerValue]
                                                                     HTTPVersion:encodedResponse[@"HTTPVersion"]
                                                                    headerFields:encodedResponse[@"headerFields"]];
            [self setResponse:response];
        } else {
            [self setResponse:[aDecoder decodeObjectForKey:kResponseKey]];
        }
        
        [self setRedirectRequest:[aDecoder decodeObjectForKey:kRedirectRequestKey]];
    }

    return self;
}

@end


@implementation NSURLRequest (MutableCopyWorkaround)

- (id)mutableCopyWorkaround {
    NSMutableURLRequest *mutableURLRequest = [[NSMutableURLRequest alloc] initWithURL:[self URL]
                                                                          cachePolicy:[self cachePolicy]
                                                                      timeoutInterval:[self timeoutInterval]];
    [mutableURLRequest setHTTPMethod:[self HTTPMethod]];
    [mutableURLRequest setAllHTTPHeaderFields:[self allHTTPHeaderFields]];
    [mutableURLRequest setHTTPBody:[self HTTPBody]];
    [mutableURLRequest setHTTPShouldHandleCookies:[self HTTPShouldHandleCookies]];
    [mutableURLRequest setHTTPShouldUsePipelining:[self HTTPShouldUsePipelining]];
    return mutableURLRequest;
}

@end

#pragma mark - RNCacheListStore
@implementation RNCacheListStore {
    NSMutableDictionary *_dict;
    NSString *_path;
    dispatch_queue_t _queue;
}

- (id)initWithPath:(NSString *)path {
    if (self = [super init]) {
        _path = [path copy];

        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:_path];
        if (dict) {
            _dict = [[NSMutableDictionary alloc] initWithDictionary:dict];
        } else {
            _dict = [[NSMutableDictionary alloc] init];
        }

        _queue = dispatch_queue_create("cache.savelist.queue", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)setObject:(id)object forKey:(id)key {
    dispatch_barrier_async(_queue, ^{
        _dict[key] = object;
    });

    [self performSelector:@selector(saveAfterDelay)];
}

- (id)objectForKey:(id)key {
    __block id obj;
    dispatch_sync(_queue, ^{
        obj = _dict[key];
    });
    return obj;
}

- (NSArray *)removeObjectsOlderThan:(NSDate *)date {
    __block NSSet *keysToDelete;
    dispatch_sync(_queue, ^{
        keysToDelete = [_dict keysOfEntriesPassingTest:^BOOL(id key, id obj, BOOL *stop) {
            NSDate *d = ((NSDictionary *) obj)[RNCachingDateKey];
            return [d compare:date] == NSOrderedAscending;
        }];
    });

    dispatch_barrier_async(_queue, ^{
        [_dict removeObjectsForKeys:[keysToDelete allObjects]];
    });

    [self performSelector:@selector(saveAfterDelay)];

    return [keysToDelete allObjects];
}

- (void)clear {
    dispatch_barrier_async(_queue, ^{
        [_dict removeAllObjects];
    });

    [self performSelector:@selector(saveAfterDelay)];
}

- (void)saveCacheDictionary {
    dispatch_barrier_async(_queue, ^{
        NSError *error = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:_dict
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0
                                                                   error:&error];
        if (data) {
            [data writeToFile:_path atomically:YES];
            
            #if !(defined RNCACHING_DISABLE_LOGGING)
            NSLog(@"[RNCachingURLProtocol] cache list persisted.");
            #endif
        } else {
            #if !(defined RNCACHING_DISABLE_LOGGING)
            NSLog(@"[RNCachingURLProtocol] error persisting cache list: %@", error);
            #endif
        }

    });
}

- (void)saveAfterDelay {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveCacheDictionary) object:nil];
    [self performSelector:@selector(saveCacheDictionary) withObject:nil afterDelay:0.5];
}

@end
