import Foundation

/// root helper 桥：spawn PsyduckHelper (root, no-sandbox) 读京东沙箱 cookie
enum JDHelper {
    /// 同步阻塞。onLine 逐行回调日志
    static func grabCookie(_ onLine: @escaping (String) -> Void) -> String {
        let helper = Bundle.main.path(forAuxiliaryExecutable: "PsyduckHelper") ?? ""
        if helper.isEmpty {
            onLine("[helper] PsyduckHelper not in bundle")
            return ""
        }
        let out = runRoot(helper, args: ["cookie"], onLine: onLine)
        // helper 输出格式: ###COOKIE###<整条cookie>###END###
        if let r = out.range(of: "###COOKIE###"),
           let e = out.range(of: "###END###") {
            return String(out[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    static func runRoot(_ bin: String, args: [String], onLine: @escaping (String) -> Void) -> String {
        // TrollStore 环境: app 无沙箱 + persona-mgmt → 直接 posix_spawn 即 root
        // iOS 无 Foundation.Process → 用 posix_spawn
        var pipeOut: [Int32] = [0, 0]
        guard pipe(&pipeOut) == 0 else {
            onLine("[helper] pipe fail")
            return ""
        }
        var attr = posix_spawnattr_t()
        posix_spawnattr_init(&attr)
        var pid = pid_t(0)
        let argvp: [UnsafeMutablePointer<CChar>?] = [strdup(bin), strdup("cookie"), nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]
        let rc = posix_spawn(&pid, bin, nil, &attr, argvp, envp)
        guard rc == 0 else {
            onLine("[helper] spawn fail rc=\(rc)")
            return ""
        }
        close(pipeOut[1])
        var data = Data()
        let fd = pipeOut[0]
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        close(fd)
        waitpid(pid, nil, 0)
        let s = String(data: data, encoding: .utf8) ?? ""
        for line in s.components(separatedBy: "\n") where !line.isEmpty && !line.contains("###COOKIE###") && !line.contains("###END###") {
            onLine("[helper] " + line)
        }
        return s
    }
}

/// payload 拷贝 + cookie ini 写入
enum Payload {
    static var payloadDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("payload")
    }

    static func install(cookie: String) {
        let fm = FileManager.default
        let dst = payloadDir
        // 首次安装（bundle 内 payload_dir → Documents/payload）
        if !fm.fileExists(atPath: dst.path) {
            if let src = Bundle.main.url(forResource: "payload_dir", withExtension: nil) {
                try? fm.copyItem(at: src, to: dst)
            }
        }
        // 写 cookie/jd.ini
        let iniDir = dst.appendingPathComponent("cookie")
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
            onLine("[node] entry missing: main_ios.mjs")
            return
        }
        onLine("[node] starting: \(entry)")
        // argv[0] 是程序名
        let args = ["node", entry]
        NodeMobileBridge.startNode(args: args, onLine: onLine)
    }
}
