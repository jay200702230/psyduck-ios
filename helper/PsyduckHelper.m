// PsyduckHelper — root helper (TrollStore: no-sandbox entitlement)
// 用法:
//   PsyduckHelper cookie  — 快扫京东容器抽 pt_key/pt_pin, stdout ###COOKIE###...###END###
//   PsyduckHelper scan    — 诊断模式: 全量扫描, 输出文件清单与全部命中(不省略)
//
// 策略(2026-10-27 重写):
//  - 老版要求 pt_key=/pt_pin= 物理相邻 → binarycookies/SQLite/plist 里是独立记录, 必空 → 全局收集再配对
//  - 扫描范围: 主容器全目录 + Shared AppGroup, 文件 >256MB 跳过
//  - 匹配: pt_key=app_open / pt_key%3Dapp_open / UTF-16BE "pt_key" / 裸 app_open token
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <ctype.h>

#define MAXHITS 64

typedef struct {
    char key[512];   // pt_key 的 value (app_open...)
    char pin[256];   // pt_pin 的 value (可能 URL 编码)
    char src[512];   // 来源文件
    long off;
} Hit;

static Hit hits[MAXHITS];
static int nhits = 0;
static int g_scan_mode = 0;
static int g_files = 0, g_scanned = 0, g_bytes = 0;

static void add_hit(const char *key, const char *pin, const char *src, long off) {
    if (nhits >= MAXHITS) return;
    Hit *h = &hits[nhits++];
    if (key) snprintf(h->key, sizeof h->key, "%s", key);
    if (pin) snprintf(h->pin, sizeof h->pin, "%s", pin);
    snprintf(h->src, sizeof h->src, "%s", src);
    h->off = off;
}

// 从 buf[i] 处的 token 提取 value: 跳过 '=' 或 "%3D"/"%3d", 直到终止符
// 返回 value 起始偏移, len 输出 value 长度; 失败返回 -1
static long extract_value(const unsigned char *b, long sz, long i, long *vlen) {
    long j = i;
    while (j < sz) {
        if (b[j] == '=') { j++; break; }
        if (b[j] == '%' && j + 2 < sz && (b[j+1]=='3'||b[j+1]=='3') && (b[j+2]=='D'||b[j+2]=='d')) { j += 3; break; }
        // binary plist token (0x5F 0x10 len 之类) 后面直接跟字符串的情况由调用方处理
        j++;
        if (j - i > 16) return -1;
    }
    if (j >= sz) return -1;
    long s = j;
    while (j < sz) {
        unsigned char c = b[j];
        if (c == ';' || c == '"' || c == '\'' || c == '\n' || c == '\r' ||
            c == ' ' || c == '&' || c == '<' || c == '>' || c == 0 || c == 0x11 || c == 0x81) break;
        if (j - s > 500) break;
        j++;
    }
    if (j == s) return -1;
    *vlen = j - s;
    return s;
}

// 在单文件 buffer 中收集命中
static void scan_buf(const unsigned char *b, long sz, const char *path) {
    // 1) ASCII: pt_key= / pt_key%3D
    for (long i = 0; i < sz - 10; i++) {
        if (memcmp(b + i, "pt_key", 6) == 0) {
            long vs, vl;
            vs = extract_value(b, sz, i + 6, &vl);
            if (vs > 0) {
                char key[512];
                memcpy(key, b + vs, vl < 511 ? vl : 511); key[vl < 511 ? vl : 511] = 0;
                if (memcmp(key, "app_open", 8) == 0) add_hit(key, NULL, path, i);
                else if (g_scan_mode) add_hit(key, NULL, path, i);
            }
        }
        else if (memcmp(b + i, "pt_pin", 6) == 0) {
            long vs, vl;
            vs = extract_value(b, sz, i + 6, &vl);
            if (vs > 0) {
                char pin[256];
                memcpy(pin, b + vs, vl < 255 ? vl : 255); pin[vl < 255 ? vl : 255] = 0;
                add_hit(NULL, pin, path, i);
            }
        }
        // 2) UTF-16BE "pt_key" = p\0t\0_\0k\0e\0y\0 (12 字节)
        else if (b[i] == 'p' && b[i+1] == 0 && memcmp(b + i, "p\0t\0_\0k\0e\0y\0", 12) == 0) {
            // 跳过 '=', 取 UTF-16BE value 直到非可打印双字节
            long j = i + 12;
            while (j + 1 < sz && b[j+1] == 0 && b[j] != 0 && b[j] != ';' && j - i < 1100) j += 2;
            // value 从 i+12+2(跳 '=')到 j, 按 UTF-16BE 收
            char key[512]; int kn = 0;
            for (long k = i + 14; k < j && kn < 500; k += 2) {
                unsigned char c = b[k];
                if (c < 0x20 || c > 0x7e) break;
                key[kn++] = (char)c;
            }
            key[kn] = 0;
            if (kn > 8 && memcmp(key, "app_open", 8) == 0) add_hit(key, NULL, path, i);
        }
        // 3) 裸 app_open token (只有 value 没有 name 的场景: URL query/缓存)
        else if (memcmp(b + i, "app_open", 8) == 0) {
            // 前面不是 pt_key= 的话, 独立记录 (add_hit 已去重逻辑弱, scan 模式才全收)
            if (i >= 7 && memcmp(b + i - 7, "pt_key=", 7) == 0) continue; // 已由 1) 收
            long j = i + 8;
            while (j < sz && b[j] != ';' && b[j] != '"' && b[j] != '&' && b[j] != '\n' &&
                   b[j] != '\r' && b[j] != ' ' && b[j] != 0 && j - i < 500) j++;
            char key[512];
            memcpy(key, b + i, j - i < 511 ? j - i : 511); key[j - i < 511 ? j - i : 511] = 0;
            // 合法性: 后续是 base62/hex 字符
            if (j - i >= 16) add_hit(key, NULL, path, i);
        }
    }
}

static void scan_file(const char *path) {
    struct stat st;
    if (stat(path, &st)) return;
    if (!S_ISREG(st.st_mode)) return;
    g_files++;
    long sz = st.st_size;
    if (sz > 256L * 1024 * 1024) { if (g_scan_mode) printf("skip big(%ld): %s\n", sz, path); return; }
    if (sz < 16) return;
    FILE *f = fopen(path, "rb");
    if (!f) { if (g_scan_mode) printf("open fail: %s\n", path); return; }
    unsigned char *b = malloc((size_t)sz + 1);
    if (!b) { fclose(f); return; }
    if (fread(b, 1, (size_t)sz, f) != (size_t)sz) { free(b); fclose(f); return; }
    fclose(f);
    g_scanned++; g_bytes += (int)(sz / 1024);
    scan_buf(b, sz, path);
    free(b);
}

static void scan_dir(const char *dir, int depth) {
    if (depth > 8) return;
    DIR *d = opendir(dir);
    if (!d) { if (g_scan_mode && depth <= 2) printf("dir fail: %s\n", dir); return; }
    struct dirent *e;
    char p[1024];
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        if (snprintf(p, sizeof p, "%s/%s", dir, e->d_name) >= (int)sizeof p) continue;
        struct stat st;
        if (lstat(p, &st)) continue;
        if (S_ISDIR(st.st_mode)) scan_dir(p, depth + 1);
        else if (S_ISREG(st.st_mode)) scan_file(p);
    }
    closedir(d);
}

// 找容器: 主容器 + AppGroup; out[] 返回若干路径
static int find_containers(char out[][1024], int max) {
    int n = 0;
    const char *bases[] = {
        "/var/mobile/Containers/Data/Application",
        "/var/containers/Shared/AppGroup",
        "/var/mobile/Containers/Shared/AppGroup",
    };
    for (int bi = 0; bi < 3 && n < max; bi++) {
        DIR *d = opendir(bases[bi]);
        if (!d) continue;
        struct dirent *e;
        while ((e = readdir(d)) && n < max) {
            if (e->d_name[0] == '.') continue;
            char p[1024];
            snprintf(p, sizeof p, "%s/%s/.com.apple.mobile_container_manager.metadata.plist", bases[bi], e->d_name);
            FILE *f = fopen(p, "rb");
            if (!f) continue;
            char buf[8192];
            size_t rd = fread(buf, 1, sizeof buf - 1, f);
            fclose(f);
            buf[rd] = 0;
            if (memmem(buf, rd, "com.360buy.jdmobile", 19)) {
                snprintf(out[n], 1024, "%s/%s", bases[bi], e->d_name);
                n++;
            }
        }
        closedir(d);
    }
    return n;
}

// pin URL 解码 (就地, %XX)
static void url_decode(char *s) {
    char *o = s;
    for (char *p = s; *p; p++) {
        if (*p == '%' && isxdigit((unsigned char)p[1]) && isxdigit((unsigned char)p[2])) {
            char hex[3] = { p[1], p[2], 0 };
            *o++ = (char)strtol(hex, NULL, 16);
            p += 2;
        } else *o++ = *p;
    }
    *o = 0;
}

// 评分: app_openAAJq 优先(信任度最高), 其次其他 app_open
static int score_key(const char *k) {
    if (memcmp(k, "app_openAAJq", 12) == 0) return 3;
    if (memcmp(k, "app_open", 8) == 0) return 2;
    return 1;
}

int main(int argc, char **argv) {
    g_scan_mode = (argc > 1 && strcmp(argv[1], "scan") == 0);
    int want_cookie = (argc > 1 && strcmp(argv[1], "cookie") == 0) || g_scan_mode;

    char conts[8][1024];
    int nc = find_containers(conts, 8);
    printf("containers found: %d\n", nc);
    if (nc == 0) { printf("jd container NOT FOUND\n"); return 1; }
    for (int i = 0; i < nc; i++) printf("  [%d] %s\n", i, conts[i]);

    for (int i = 0; i < nc; i++) scan_dir(conts[i], 0);
    printf("files=%d scanned=%d totalKB=%d hits=%d\n", g_files, g_scanned, g_bytes, nhits);

    // scan 模式: 全部命中详情
    for (int i = 0; i < nhits; i++) {
        if (hits[i].key[0]) printf("KEY  [%s@%ld] %s\n", hits[i].src, hits[i].off, hits[i].key);
        if (hits[i].pin[0]) printf("PIN  [%s@%ld] %s\n", hits[i].src, hits[i].off, hits[i].pin);
    }

    if (!want_cookie) return 0;

    // 配对: 最优 key + 最优 pin
    Hit *bk = NULL, *bp = NULL;
    for (int i = 0; i < nhits; i++) {
        if (hits[i].key[0] && (!bk || score_key(hits[i].key) > score_key(bk->key) ||
            (score_key(hits[i].key) == score_key(bk->key) && strlen(hits[i].key) > strlen(bk->key)))) bk = &hits[i];
        if (hits[i].pin[0] && !bp) bp = &hits[i];
    }
    if (!bk) { printf("NO pt_key VALUE FOUND\n"); return 2; }

    char pin[256] = "";
    if (bp) { snprintf(pin, sizeof pin, "%s", bp->pin); url_decode(pin); }

    char ck[900];
    if (pin[0]) snprintf(ck, sizeof ck, "pt_key=%s;pt_pin=%s;", bk->key, pin);
    else        snprintf(ck, sizeof ck, "pt_key=%s;", bk->key);

    printf("chosen key from: %s\n", bk->src);
    if (bp) printf("chosen pin from: %s\n", bp->src);
    printf("###COOKIE###%s###END###\n", ck);
    return pin[0] ? 0 : 3; // 3 = 有 key 没 pin
}
