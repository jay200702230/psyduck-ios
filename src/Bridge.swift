import Foundation

/// root helper 桥：spawn PsyduckHelper (root, no-sandbox) 读京东沙箱 cookie
enum JDHelper {
    static let jdDataPathCandidates = [
        "/var/mobile/Containers/Data/Application"  // 遍历找 com.360buy.jdmobile 的 .com.apple.mobile_container_manager.metadata.plist
    ]

    /// 同步阻塞。onLine 逐行回调日志
    static func grabCookie(_ onLine: @escaping (String) -> Void) -> String {
        let helper = Bundle.main.path(forAuxiliaryExecutable: "PsyduckHelper")!
        let out = runRoot(helper, args: ["cookie"], onLine: onLine)
        // helper 输出格式: ###COOKIE###<整条cookie>###END### 之前的都是日志
        if let r = out.range(of: "###COOKIE###"),
           let e = out.range(of: "###END###") {
            return String(out[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    static func runRoot(_ bin: String, args: [String], onLine: @escaping (String) -> Void) -> String {
        // TrollStore 环境: app 无沙箱 + persona-mgmt → 直接 posix_spawn 即 root
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8) ?? ""
            for line in s.components(separatedBy: "\n") where !line.isEmpty {
                onLine("[helper] " + line)
            }
            return s
        } catch {
            onLine("[helper] spawn fail: \(error)")
            return ""
        }
    }
}

/// payload 解压 + cookie ini 写入
enum Payload {
    static var payloadDir: URL {
        let docs = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: nil)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("payload")
    }

    static func install(cookie: String) {
        let fm = FileManager.default
        let dst = payloadDir
        // 首次解压（bundle 内 payload.zip → Documents/payload）
        if !fm.fileExists(atPath: dst.path) {
            if let zip = Bundle.main.url(forResource: "payload", withExtension: "zip") {
                try? fm.unzipItem(at: zip, to: dst.parent())
                DispatchQueue.main.async {}
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
        // libnode 启动：nodejs-mobile 的 C API
        // 简化: 用 NSThread 跑 node_start，stdout 重定向见 NodeMobile 框架约定
        onLine("[node] starting: \(entry)")
        let args = [Bundle.main.path(forResource: "libnode", ofType: "dylib") ?? "", entry]
        NodeMobileBridge.startNode(args: args, onLine: onLine)
    }
}
