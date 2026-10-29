// JDCookieGrabber.m — 京东完整登录态采集 dylib（TrollFools 注入，无越狱）
// 参考已验证的 CMCC.dylib 骨架：悬浮球 + WKWebView swizzle 注入 JS + WKHTTPCookieStore + NSHTTPCookieStorage
// 采集：jd 系全部 cookie（pt_key/pt_pin/shshshfpa/shshshfpx/__jda/__jdu 等指纹 cookie）+ 京东 App UA + H5 页面 cookie
// 导出：一键复制到剪贴板（JSON v1 格式，psyduck-iOS App 直接解析），并追加写 Documents/jd_cookie.log
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#define HANDLER_NAME @"jdHook"
#define LOG_FILE     @"jd_cookie.log"
#define EXPORT_VER   @"JDCOOKIES_V1"

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
            @"ts"    : @((long)[NSDate date].timeIntervalSince1970),
        };
        NSData *jd = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingWithoutEscapingSlashes error:nil];
        NSString *json = [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding];
        [[UIPasteboard generalPasteboard] setString:json];
        appendLog([NSString stringWithFormat:@"[%@] export ver=%@ pin=%@ cookieLen=%lu pages=%lu ua=%@", EXPORT_VER, EXPORT_VER, pin, (unsigned long)cookieStr.length, (unsigned long)pages.count, ua]);
        NSString *prev = [btn titleForState:UIControlStateNormal];
        [btn setTitle:@"已复制" forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [btn setTitle:prev forState:UIControlStateNormal];
        });
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
}
