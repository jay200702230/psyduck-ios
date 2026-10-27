// PsyduckHelper — root helper (TrollStore: no-sandbox entitlement)
// 用法: PsyduckHelper cookie
//  1. 遍历 /var/mobile/Containers/Data/Application 找 com.360buy.jdmobile 容器
//  2. 读 Cookies.binarycookies / Cookies.db → 抽 pt_key/pt_pin
//  3. stdout: 日志行 + ###COOKIE###...###END###
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>

static void find_jd_container(char *out, size_t outsz) {
    const char *base = "/var/mobile/Containers/Data/Application";
    DIR *d = opendir(base);
    if (!d) { fprintf(stderr, "open %s fail\n", base); return; }
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char p[1024];
        snprintf(p, sizeof p, "%s/%s/.com.apple.mobile_container_manager.metadata.plist", base, e->d_name);
        FILE *f = fopen(p, "rb");
        if (!f) continue;
        char buf[8192];
        size_t n = fread(buf, 1, sizeof buf - 1, f);
        fclose(f);
        buf[n] = 0;
        if (memmem(buf, n, "com.360buy.jdmobile", 19)) {
            snprintf(out, outsz, "%s/%s", base, e->d_name);
            closedir(d);
            return;
        }
    }
    closedir(d);
}

// 粗暴但有效：对京东容器整个 Library 递归 grep pt_key= 的二进制搜索
static void scan_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return;
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz > 64 * 1024 * 1024) { fclose(f); return; }  // >64MB 跳过
    char *b = malloc(sz + 1);
    fread(b, 1, sz, f); fclose(f);
    b[sz] = 0;
    // pt_key 是 app_open 开头; cookie 形如 "pt_key=app_openXXX;pt_pin=xxx"（binarycookies 里无空格变体也存在）
    for (long i = 0; i < sz - 8; i++) {
        if (memcmp(b + i, "app_open", 8) == 0) {
            // 向前找 pt_key=
            long ks = i - 7;
            if (ks >= 0 && memcmp(b + ks, "pt_key=", 7) == 0) {
                long ke = i + 8;
                while (ke < sz && b[ke] != ';' && b[ke] != '"' && b[ke] != '\n' && b[ke] != '\r' && ke - ks < 600) ke++;
                char key[700]; memcpy(key, b + ks, ke - ks); key[ke - ks] = 0;
                // 找邻近的 pt_pin
                char pin[300] = "";
                long ps = ke;
                while (ps < sz - 7) {
                    if (memcmp(b + ps, "pt_pin=", 7) == 0) {
                        long pe = ps + 7;
                        while (pe < sz && b[pe] != ';' && b[pe] != '"' && b[pe] != '\n' && pe - ps < 290) pe++;
                        memcpy(pin, b + ps, pe - ps); pin[pe - ps] = 0;
                        break;
                    }
                    ps++;
                    if (ps - ke > 500) break;
                }
                printf("found: %s; %s\n", key, pin);
                printf("###COOKIE###pt_key=%s;%s###END###\n", b + ks + 7 > b ? key + 7 : key, pin);
                free(b);
                return;
            }
        }
    }
    free(b);
}

static void scan_dir(const char *dir, int depth) {
    if (depth > 5) return;
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    char p[1024];
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        struct stat st;
        if (stat(p, &st)) continue;
        if (S_ISDIR(st.st_mode)) {
            scan_dir(p, depth + 1);
        } else if (S_ISREG(st.st_mode)) {
            const char *n = e->d_name;
            if (strstr(n, "Cookies") || strstr(n, "cookies") || strstr(n, ".binarycookies") || strstr(n, ".db") || strstr(n, ".plist")) {
                scan_file(p);
            }
        }
    }
    closedir(d);
}

int main(int argc, char **argv) {
    char jd[1024] = "";
    find_jd_container(jd, sizeof jd);
    if (!jd[0]) { printf("jd container not found\n"); return 1; }
    printf("jd container: %s\n", jd);

    char lib[1024];
    snprintf(lib, sizeof lib, "%s/Library", jd);
    scan_dir(lib, 0);
    return 0;
}
