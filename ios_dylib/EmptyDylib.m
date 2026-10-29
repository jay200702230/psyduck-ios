// EmptyDylib.m — 空壳对照：验证 TrollFools 注入链路本身是否被京东拦截
#import <Foundation/Foundation.h>
__attribute__((constructor))
static void EmptyInit(void) {
    NSLog(@"[EmptyDylib] loaded ok");
}
