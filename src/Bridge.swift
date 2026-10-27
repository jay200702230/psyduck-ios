import Foundation

/// root helper 桥：spawn PsyduckHelper (root, no-sandbox) 读京东沙箱 cookie
enum JDHelper {
    /// cookie 模式：返回整条 cookie（###COOKIE###...###END### 包裹），失败返回空串
    static func grabCookie(_ onLine: @escaping (String) -> Void) -> String {
        let out = spawnHelper(["cookie"], onLine: onLine)
        if let r = out.range(of: "###COOKIE###"),
           let e = out.range(of: "###END###") {
            return String(out[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// scan 模式：诊断输出，返回完整日志
    @discardableResult
    static func scanSandbox(_ onLine: @escaping (String) -> Void) -> String {
        return spawnHelper(["scan"], onLine: onLine)
    }

    private static func spawnHelper(_ args: [String], onLine: @escaping (String) -> Void) -> String {
        let helper = Bundle.main.path(forAuxiliaryExecutable: "PsyduckHelper") ?? ""
        if helper.isEmpty {
            onLine("[helper] PsyduckHelper not in bundle")
            return ""
        }
        // TrollStore 环境: app 无沙箱 + persona-mgmt → 直接 posix_spawn 即 root
        var pipeOut: [Int32] = [0, 0]
        guard pipe(&pipeOut) == 0 else {
            onLine("[helper] pipe fail")
            return ""
        }
        var attr = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attr)
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, pipeOut[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, pipeOut[1], 2)
        var pid = pid_t(0)
        let argvp: [UnsafeMutablePointer<CChar>?] = [strdup(helper)] + args.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]
        let rc = posix_spawn(&pid, helper, &fileActions, &attr, argvp, envp)
        posix_spawn_file_actions_destroy(&fileActions)
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
