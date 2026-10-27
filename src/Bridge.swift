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

    /// 返回全量 cookie 行 (guid/pt_pin/pt_key + 设备指纹字段)，失败返回空串
    static func grabCookie(_ onLine: @escaping (String) -> Void) -> String {
        var jar: [String: String] = [:]
        let hits = runTargeted(verbose: false, jar: &jar, onLine: onLine)
        // pt_key 优先级: 扫描命中 (app_openAAJq 优先) > cookies 库
        var dict = jar
        if let bk = bestKey(hits) { dict["pt_key"] = bk }
        if dict["pt_pin"] == nil || dict["pt_pin"]!.isEmpty {
            let rawPin = bestPin(hits) ?? ""
            let pin = urlDecode(rawPin)
            if !pin.isEmpty { dict["pt_pin"] = pin }
        } else {
            let dec = urlDecode(dict["pt_pin"]!)
            if !dec.isEmpty { dict["pt_pin"] = dec }
        }
        guard dict["pt_key"] != nil, !(dict["pt_key"]!.isEmpty) else {
            onLine("[jd] NO pt_key found")
            return ""
        }
        // 组装: guid/pt_pin 开头 (riskKeep 正则 ^guid=|^pt_pin=), 再 pt_key, 其余字典序
        var ordered: [String] = []
        for k in ["guid", "pt_pin", "pt_key"] {
            if let v = dict[k], !v.isEmpty { ordered.append("\(k)=\(v);") }
            dict.removeValue(forKey: k)
        }
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) where !v.isEmpty {
            ordered.append("\(k)=\(v);")
        }
        let ck = ordered.joined()
        onLine("[jd] cookie fields=\(ordered.count) len=\(ck.count)")
        return ck
    }

    /// 诊断模式：输出每个窝点清单 + 全部命中
    @discardableResult
    static func scanSandbox(_ onLine: @escaping (String) -> Void) -> String {
        var jar: [String: String] = [:]
        let hits = runTargeted(verbose: true, jar: &jar, onLine: onLine)
        onLine("[jd] cookie fields: " + jar.keys.sorted().joined(separator: ","))
        for h in hits {
            if !h.key.isEmpty { onLine("KEY  [\(h.src)] \(h.key)") }
            if !h.pin.isEmpty { onLine("PIN  [\(h.src)] \(h.pin)") }
        }
        return hits.map { "\($0.src)|k=\($0.key)|p=\($0.pin)" }.joined(separator: "\n")
    }

    // MARK: - 精准提取

    private static func runTargeted(verbose: Bool, jar: inout [String: String], onLine: @escaping (String) -> Void) -> [Hit] {
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
                        // binarycookies: 全量解析 cookie 字段
                        if b.starts(with: [0x63, 0x6F, 0x6F, 0x6B]) {
                            let got = harvestBinaryCookies(b)
                            if !got.isEmpty {
                                for (k, v) in got { jar[k] = v }
                                if verbose { onLine("[jd] cookies \(dir)/\(n): +\(got.count) fields") }
                            }
                        } else if p.contains("jdmobile.plist"), jar["guid"] == nil {
                            harvestGuid(b, into: &jar)
                        }
                        // 常规匹配 (pt_key/pt_pin 等)
                        if hits.count < 64 {
                            collect(b, path: dir + "/" + n, into: &hits, seen: &seen)
                        }
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
        onLine("[jd] hits=\(hits.count) cookieFields=\(jar.count)")
        return hits
    }

    /// binarycookies (magic 'cook') 全量解析 → name/value (已 URL 解码)
    static func harvestBinaryCookies(_ data: Data) -> [(String, String)] {
        var out: [(String, String)] = []
        let b = [UInt8](data)
        func u32(_ off: Int) -> Int {
            guard off >= 0, off + 4 <= b.count else { return 0 }
            return Int(b[off]) << 24 | Int(b[off + 1]) << 16 | Int(b[off + 2]) << 8 | Int(b[off + 3])
        }
        guard b.count > 12, u32(0) == 0x636F6F6B else { return out } // 'cook'
        let numPages = min(u32(4), 128)
        guard numPages > 0 else { return out }
        var pageOffs: [Int] = []
        for p in 0..<numPages { pageOffs.append(u32(8 + p * 4)) }
        for pageOff in pageOffs {
            guard pageOff > 0, pageOff + 8 <= b.count else { continue }
            let nCookies = u32(pageOff + 4)
            guard nCookies > 0, nCookies < 5000 else { continue }
            for ci in 0..<nCookies {
                let cOff = u32(pageOff + 8 + ci * 4)
                guard cOff > 0, cOff + 20 <= b.count else { continue }
                let size = u32(cOff)
                guard size >= 24, cOff + size <= b.count else { continue }
                func str(_ off: Int) -> String {
                    guard off > 0, cOff + off < cOff + size else { return "" }
                    var e = cOff + off
                    while e < cOff + size && b[e] != 0 { e += 1 }
                    return String(bytes: b[(cOff + off)..<min(e, b.count)], encoding: .utf8) ?? ""
                }
                let url = str(u32(cOff + 8))
                let name = str(u32(cOff + 12))
                var val = str(u32(cOff + 20))
                if val.isEmpty { continue }
                if let dec = val.removingPercentEncoding { val = dec }
                // 只收京东系域名
                guard url.contains("jd") || url.contains("jingdong") || url.contains("360buy") else { continue }
                if !name.isEmpty { out.append((name, val)) }
            }
        }
        return out
    }

    /// JD 主 plist 里抠 guid
    static func harvestGuid(_ data: Data, into jar: inout [String: String]) {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return }
        for (k, v) in obj {
            if jar["guid"] != nil { break }
            let kl = k.lowercased()
            guard kl.contains("guid") else { continue }
            if let s = v as? String, s.count > 6, s.count < 128 { jar["guid"] = s }
            else if let d = v as? Data, d.count > 6, d.count < 128 { jar["guid"] = String(bytes: d, encoding: .utf8) ?? "" }
        }
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

/// 任务运行控制: cmd.json 指令 + 任务注册表 (config/jd.ini)
enum RunnerCtl {
    struct Task {
        let alias: String
        let title: String
    }

    static var cmdURL: URL { Payload.payloadDir.appendingPathComponent("cmd.json") }

    /// 发指令给 node 指令服务器 (main_ios.mjs 轮询)
    static func send(_ op: String, index: Int? = nil) {
        var d: [String: Any] = ["op": op]
        if let i = index { d["index"] = i }
        guard let data = try? JSONSerialization.data(withJSONObject: d) else { return }
        try? data.write(to: cmdURL)
    }

    /// config/jd.ini [alias] + title=/map= → 任务列表 (对齐 Android Runner.listTasks)
    static func listTasks() -> [Task] {
        let p = Payload.payloadDir.appendingPathComponent("config/jd.ini").path
        guard let txt = try? String(contentsOfFile: p, encoding: .utf8) else { return [] }
        var out: [Task] = []
        var alias = ""
        var title = ""
        var map = ""
        func flush() {
            if !alias.isEmpty { out.append(Task(alias: alias, title: displayTitle(alias, title: title, map: map))) }
        }
        for raw in txt.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") && l.hasSuffix("]") && !l.hasPrefix("[#") {
                flush()
                alias = String(l.dropFirst().dropLast())
                title = ""
                map = ""
            } else if l.hasPrefix("title=") {
                title = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if l.hasPrefix("map=") {
                map = String(l.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return out
    }

    /// 对齐 Android resolveTitle: ini title → map 脚本 title → alias 脚本 title → alias
    private static func displayTitle(_ alias: String, title: String, map: String) -> String {
        if !title.isEmpty { return title }
        if !map.isEmpty, let t = titleFromScript(map + ".js") { return t }
        if let t = titleFromScript(alias + ".js") { return t }
        return alias
    }

    /// 对齐 Android P_TITLE: title\s*:\s*['"`]([^'"`\r\n]+)['"`]
    private static func titleFromScript(_ name: String) -> String? {
        let p = Payload.payloadDir.appendingPathComponent("parse/jd/" + name).path
        guard let head = try? String(contentsOfFile: p, encoding: .utf8) else { return nil }
        guard let m = head.range(of: #"title\s*:\s*['"`]([^'"`\r\n]+)['"`]"#, options: .regularExpression) else { return nil }
        var t = String(head[m])
        t = t.replacingOccurrences(of: #"^title\s*:\s*"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "'\"` \t"))
        return t.isEmpty ? nil : t
    }
}

/// payload 拷贝 + cookie ini 写入
enum Payload {
    static var payloadDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("payload")
    }

    /// bundle 里的整目录资源（folder reference, 结构同 Android rt tar）
    static var bundlePayloadDir: URL {
        Bundle.main.bundleURL.appendingPathComponent("payload_dir")
    }

    /// 安装/换血 payload：版本标记不一致自动整包替换, cookie 目录保留
    @discardableResult
    static func install(force: Bool = false) -> Bool {
        let fm = FileManager.default
        let src = bundlePayloadDir
        guard fm.fileExists(atPath: src.path) else { return false }
        let dst = payloadDir
        let entry = dst.appendingPathComponent("main_ios.mjs").path

        let bVer = (try? String(contentsOf: src.appendingPathComponent(".payload_version"), encoding: .utf8)) ?? ""
        let iVer = (try? String(contentsOf: dst.appendingPathComponent(".payload_version"), encoding: .utf8)) ?? ""
        guard force || bVer != iVer || !fm.fileExists(atPath: entry) else { return true }

        // 保留 cookie 目录 + jdUser.ini (wskey 授权数据, 换血不丢登录态)
        let keep: [(URL, String)] = [
            (dst.appendingPathComponent("cookie"), "cookie"),
            (dst.appendingPathComponent("config/jdUser.ini"), "jdUser.ini"),
        ]
        var saved: [(URL, String)] = []
        for (src, tag) in keep where FileManager.default.fileExists(atPath: src.path) {
            let tmp = fm.temporaryDirectory.appendingPathComponent("keep_\(tag)_\(Int(Date().timeIntervalSince1970))")
            try? fm.copyItem(at: src, to: tmp)
            if fm.fileExists(atPath: tmp.path) { saved.append((tmp, tag)) }
        }

        if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)

        var ok = true
        if let items = try? fm.contentsOfDirectory(atPath: src.path) {
            for f in items {
                do {
                    try fm.copyItem(at: src.appendingPathComponent(f), to: dst.appendingPathComponent(f))
                } catch { ok = false }
            }
        } else { ok = false }

        for (tmp, tag) in saved {
            let back = dst.appendingPathComponent(tag == "cookie" ? "cookie" : "config/jdUser.ini")
            if fm.fileExists(atPath: back.path) { try? fm.removeItem(at: back) }
            try? fm.createDirectory(at: back.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: tmp, to: back)
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
        let root = Payload.payloadDir
        let entry = root.appendingPathComponent("main_ios.mjs").path
        guard FileManager.default.fileExists(atPath: entry) else {
            onLine("[node] entry missing: main_ios.mjs（payload 未安装）")
            return
        }
        // 脚本大量使用相对路径 (config/config.ini, parse/jd/...) → chdir 到 payload 根
        FileManager.default.changeCurrentDirectoryPath(root.path)
        // 对齐 Android Runner 的 export: HOME/TMPDIR 指向 runtime (脚本 curlBin/tmpDir 用)
        setenv("HOME", root.path, 1)
        let tmpDir = root.appendingPathComponent("tmp").path
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        setenv("TMPDIR", tmpDir, 1)
        onLine("[node] starting: \(entry)")
        // 注意: 不能开 --no-jitless (V8 真 JIT 在 iOS 被内核 W^X 拒 → node 一起动直接 SIGKILL 闪退)
        // WASM 缺失无碍任务执行 (本地 sim 验证), Intl 由 shim polyfill
        let args = ["node", entry]
        NodeMobileBridge.startNode(args: args, onLine: onLine)
    }
}
