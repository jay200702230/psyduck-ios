import Foundation
import Darwin

/// 京东 cookie 精准提取（无扫描版）
/// 1. 只读各 Application/*/metadata.plist 定位京东容器（秒级, 零内存压力）
/// 2. 只读已知 cookie 窝点的小文件, 不做全盘暴力扫描（旧版全盘扫描 OOM 被 jetsam 杀）
enum JDHelper {
    struct Hit {
        var key = ""   // pt_key value (app_open...)
        var pin = ""   // pt_pin value
        var src = ""   // 来源文件
    }

    private static let jdBundle = "com.360buy.jdmobile"
    // UTF-16BE "pt_key" = p\0t\0_\0k\0e\0y\0
    private static let utf16Needle: [UInt8] = [0x70, 0x00, 0x74, 0x00, 0x5F, 0x00, 0x6B, 0x00, 0x65, 0x00, 0x79, 0x00]

    // 容器内 cookie 窝点（精准, 全是小文件）
    private static let targetDirs = [
        "Library/Cookies",
        "Library/Preferences",
        "Library/HTTPStorages",
        "Library/WebKit/WebsiteData",
        "Library/Application Support",
        "Documents",
    ]
    private static let maxFileSize = 16 * 1024 * 1024
    private static let maxFilesPerDir = 400

    // MARK: - 公共入口

    /// 返回 "pt_key=..;pt_pin=..;"，失败返回空串
    static func grabCookie(_ onLine: @escaping (String) -> Void) -> String {
        let hits = runTargeted(verbose: false, onLine: onLine)
        guard let bk = bestKey(hits) else {
            onLine("[jd] NO pt_key found")
            return ""
        }
        let rawPin = bestPin(hits) ?? ""
        let pin = urlDecode(rawPin)
        onLine("[jd] key len=\(bk.count) prefix=\(bk.prefix(12))… pin=\(pin.isEmpty ? "(none)" : "ok")")
        return pin.isEmpty ? "pt_key=\(bk);" : "pt_key=\(bk);pt_pin=\(pin);"
    }

    /// 诊断模式：输出每个窝点清单 + 全部命中
    @discardableResult
    static func scanSandbox(_ onLine: @escaping (String) -> Void) -> String {
        let hits = runTargeted(verbose: true, onLine: onLine)
        for h in hits {
            if !h.key.isEmpty { onLine("KEY  [\(h.src)] \(h.key)") }
            if !h.pin.isEmpty { onLine("PIN  [\(h.src)] \(h.pin)") }
        }
        return hits.map { "\($0.src)|k=\($0.key)|p=\($0.pin)" }.joined(separator: "\n")
    }

    // MARK: - 精准提取

    private static func runTargeted(verbose: Bool, onLine: @escaping (String) -> Void) -> [Hit] {
        var hits: [Hit] = []
        var seen = Set<String>()
        let conts = findContainers(onLine: onLine)
        onLine("[jd] containers: \(conts.count)")
        for c in conts { onLine("[jd]   " + c) }
        guard !conts.isEmpty else { return hits }

        let fm = FileManager.default
        for cont in conts {
            for dir in targetDirs {
                let dpath = cont + "/" + dir
                guard fm.fileExists(atPath: dpath) else {
                    if verbose { onLine("[jd] (no) \(dir)") }
                    continue
                }
                let names = (try? fm.contentsOfDirectory(atPath: dpath)) ?? []
                var read = 0
                autoreleasepool {
                    for n in names {
                        if read >= maxFilesPerDir {
                            if verbose { onLine("[jd] file cap hit at \(dir)") }
                            break
                        }
                        let p = dpath + "/" + n
                        var st = stat()
                        guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                        let sz = Int(st.st_size)
                        if sz > maxFileSize {
                            if verbose { onLine("[jd] skip big(\(sz)) \(dir)/\(n)") }
                            continue
                        }
                        if sz < 16 { continue }
                        guard let b = fm.contents(atPath: p) else {
                            if verbose { onLine("[jd] open fail \(dir)/\(n)") }
                            continue
                        }
                        read += 1
                        let before = hits.count
                        collect(b, path: dir + "/" + n, into: &hits, seen: &seen)
                        if verbose && hits.count > before {
                            onLine("[jd] ++ \(dir)/\(n) (\(hits.count - before) hits)")
                        }
                    }
                }
                if verbose || read > 0 {
                    onLine("[jd] \(dir): files read=\(read)/\(names.count)")
                }
            }
        }
        onLine("[jd] hits=\(hits.count)")
        return hits
    }

    /// 只读 metadata.plist 定位京东容器（不碰任何内容文件）
    private static func findContainers(onLine: @escaping (String) -> Void) -> [String] {
        let fm = FileManager.default
        let bases = ["/var/mobile/Containers/Data/Application",
                     "/var/containers/Shared/AppGroup",
                     "/var/mobile/Containers/Shared/AppGroup"]
        var out: [String] = []
        for base in bases {
            let namesOpt = try? fm.contentsOfDirectory(atPath: base)
            if namesOpt == nil {
                onLine("[jd] base DENIED: \(base) (entitlements 没生效?)")
                continue
            }
            for n in namesOpt! where !n.hasPrefix(".") {
                let meta = base + "/" + n + "/.com.apple.mobile_container_manager.metadata.plist"
                guard let d = fm.contents(atPath: meta) else { continue }
                if d.range(of: Data(jdBundle.utf8)) != nil {
                    out.append(base + "/" + n)
                }
            }
        }
        return out
    }

    // MARK: - 内容匹配

    private static func collect(_ data: Data, path: String, into hits: inout [Hit], seen: inout Set<String>) {
        var buf: [Hit] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let b = base.assumingMemoryBound(to: UInt8.self)
            let sz = raw.count
            var i = 0
            while i < sz - 10 {
                if buf.count >= 16 { return } // 单文件上限
                let c = b[i]
                if c != 0x70 && c != 0x61 { i += 1; continue } // 只看 'p'/'a' 开头
                if memcmp(b + i, "pt_key", 6) == 0 {
                    var vl = 0
                    let vs = extractValue(b, sz, i + 6, &vl)
                    if vs > 0 {
                        let key = bytesToStr(b, vs, vl)
                        if key.hasPrefix("app_open") { buf.append(Hit(key: key, src: path)) }
                    }
                } else if memcmp(b + i, "pt_pin", 6) == 0 {
                    var vl = 0
                    let vs = extractValue(b, sz, i + 6, &vl)
                    if vs > 0 {
                        buf.append(Hit(pin: bytesToStr(b, vs, vl), src: path))
                    }
                } else if memcmp(b + i, utf16Needle, 12) == 0 {
                    var j = i + 12
                    while j + 1 < sz && b[j+1] == 0 && b[j] != 0 && b[j] != 0x3B && j - i < 1100 { j += 2 }
                    var kn = 0
                    var key = [UInt8](repeating: 0, count: 512)
                    var k = i + 14
                    while k < j && kn < 500 {
                        let cc = b[k]
                        if cc < 0x20 || cc > 0x7e { break }
                        key[kn] = cc; kn += 1; k += 2
                    }
                    let ks = String(bytes: key[0..<kn], encoding: .utf8) ?? ""
                    if kn > 8 && ks.hasPrefix("app_open") { buf.append(Hit(key: ks, src: path)) }
                } else if memcmp(b + i, "app_open", 8) == 0 {
                    if i >= 7 && memcmp(b + i - 7, "pt_key=", 7) == 0 { i += 1; continue }
                    var j = i + 8
                    while j < sz && b[j] != 0x3B && b[j] != 0x22 && b[j] != 0x26 && b[j] != 0x0A &&
                            b[j] != 0x0D && b[j] != 0x20 && b[j] != 0 && j - i < 500 { j += 1 }
                    if j - i >= 16 {
                        let key = bytesToStr(b, i, j - i)
                        if !key.isEmpty { buf.append(Hit(key: key, src: path)) }
                    }
                }
                i += 1
            }
        }
        for h in buf {
            if hits.count >= 64 { return } // 全局上限
            let sig = h.key.isEmpty ? "p|\(h.pin)" : "k|\(h.key)"
            if seen.contains(sig) { continue }
            seen.insert(sig)
            hits.append(h)
        }
    }

    /// 跳过 '=' 或 %3D/%3d，取 value 到终止符；返回起始偏移，vlen 输出长度，失败 -1
    private static func extractValue(_ b: UnsafePointer<UInt8>, _ sz: Int, _ start: Int, _ vlen: inout Int) -> Int {
        var j = start
        while j < sz {
            if b[j] == 0x3D { j += 1; break } // '='
            if b[j] == 0x25 && j + 2 < sz && b[j+1] == 0x33 && (b[j+2] == 0x44 || b[j+2] == 0x64) { j += 3; break } // %3D/%3d
            j += 1
            if j - start > 16 { return -1 }
        }
        if j >= sz { return -1 }
        let s = j
        while j < sz {
            let c = b[j]
            if c == 0x3B || c == 0x22 || c == 0x27 || c == 0x0A || c == 0x0D ||
                c == 0x20 || c == 0x26 || c == 0x3C || c == 0x3E || c == 0 || c == 0x11 || c == 0x81 { break }
            if j - s > 500 { break }
            j += 1
        }
        if j == s { return -1 }
        vlen = j - s
        return s
    }

    // MARK: - 工具

    private static func bytesToStr(_ p: UnsafePointer<UInt8>, _ s: Int, _ len: Int) -> String {
        var arr = [UInt8](repeating: 0, count: len)
        memcpy(&arr, p + s, len)
        return String(bytes: arr, encoding: .utf8) ?? ""
    }

    private static func bestKey(_ hits: [Hit]) -> String? {
        var best: String? = nil
        for h in hits where !h.key.isEmpty {
            if let b = best {
                if score(h.key) > score(b) || (score(h.key) == score(b) && h.key.count > b.count) { best = h.key }
            } else {
                best = h.key
            }
        }
        return best
    }

    private static func bestPin(_ hits: [Hit]) -> String? {
        hits.first { !$0.pin.isEmpty }?.pin
    }

    /// app_openAAJq 优先（信任度最高）
    private static func score(_ k: String) -> Int {
        if k.hasPrefix("app_openAAJq") { return 3 }
        if k.hasPrefix("app_open") { return 2 }
        return 1
    }

    private static func urlDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }
}

/// payload 拷贝 + cookie ini 写入
enum Payload {
    static var payloadDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("payload")
    }

    /// 安装 payload（与 cookie 无关，app 启动即装）
    @discardableResult
    static func install() -> Bool {
        let fm = FileManager.default
        let dst = payloadDir
        let entry = dst.appendingPathComponent("main_ios.mjs").path
        guard !fm.fileExists(atPath: entry) else { return true } // 已装
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var ok = false
        // bundle 内 mjs 资源被平铺到 app 根 → 收拢
        if let files = try? fm.contentsOfDirectory(atPath: Bundle.main.bundlePath) {
            for f in files where f.hasSuffix(".mjs") {
                let s = Bundle.main.bundlePath + "/" + f
                do {
                    if fm.fileExists(atPath: dst.appendingPathComponent(f).path) {
                        try? fm.removeItem(at: dst.appendingPathComponent(f))
                    }
                    try fm.copyItem(atPath: s, toPath: dst.appendingPathComponent(f).path)
                    ok = true
                } catch {
                    ok = false
                }
            }
        }
        return ok
    }

    static func writeCookie(_ cookie: String) {
        let fm = FileManager.default
        let iniDir = payloadDir.appendingPathComponent("cookie")
        try? fm.createDirectory(at: iniDir, withIntermediateDirectories: true)
        let ini = iniDir.appendingPathComponent("jd.ini")
        let body = "[main]\n\(cookie)\n"
        try? body.write(to: ini, atomically: true, encoding: .utf8)
    }
}

/// nodejs-mobile 启动器
enum NodeRunner {
    static func start(_ onLine: @escaping (String) -> Void) {
        let entry = Payload.payloadDir.appendingPathComponent("main_ios.mjs").path
        guard FileManager.default.fileExists(atPath: entry) else {
            onLine("[node] entry missing: main_ios.mjs（payload 未安装）")
            return
        }
        onLine("[node] starting: \(entry)")
        let args = ["node", entry]
        NodeMobileBridge.startNode(args: args, onLine: onLine)
    }
}
