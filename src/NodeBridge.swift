import Foundation

/// nodejs-mobile 启动桥 — dlsym 取 node_start + stdout/stderr 重定向到日志 UI
enum NodeMobileBridge {
    private static var started = false

    static func startNode(args: [String], onLine: @escaping (String) -> Void) {
        if started {
            onLine("[node] 本进程已跑过 node（node_start 只能调一次）, 要再跑就重启 app")
            return
        }
        started = true
        DispatchQueue.global(qos: .default).async {
            redirectStdout(onLine)
            // node_start 符号在 NodeMobile.framework 的二进制里（主程序已 link，符号全局可见）
            let handle = dlopen(nil, RTLD_NOW)
            var sym = dlsym(handle, "node_start")
            if sym == nil {
                for name in ["libnode.108.dylib", "libnode.dylib", "node"] {
                    if let h = dlopen(name, RTLD_NOW) {
                        if let s2 = dlsym(h, "node_start") { sym = s2; break }
                    }
                }
            }
            guard let s = sym else {
                onLine("[node] node_start symbol not found")
                return
            }
            typealias NodeStart = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
            let fn = unsafeBitCast(s, to: NodeStart.self)
            var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0)! }
            cargs.append(nil)
            let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cargs.count)
            for (i, p) in cargs.enumerated() { argv[i] = p }
            let rc = fn(Int32(args.count), argv)
            onLine("[node] exited rc=\(rc)")
        }
    }

    /// stdout/stderr → pipe → 逐行喂 onLine（node 的 console.log 全靠这条进 UI）
    private static func redirectStdout(_ onLine: @escaping (String) -> Void) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        dup2(fds[1], STDOUT_FILENO)
        dup2(fds[1], STDERR_FILENO)
        close(fds[1])
        let t = Thread {
            var buf = [UInt8](repeating: 0, count: 8192)
            var line: [UInt8] = []
            while true {
                let n = read(fds[0], &buf, buf.count)
                if n <= 0 { break }
                for k in 0..<n {
                    if buf[k] == 0x0A {
                        if !line.isEmpty {
                            let s = String(decoding: line, as: UTF8.self)
                            DispatchQueue.main.async { onLine(s) }
                        }
                        line.removeAll(keepingCapacity: true)
                    } else {
                        line.append(buf[k])
                    }
                }
                if line.count > 65536 { line.removeAll(keepingCapacity: true) }
            }
        }
        t.stackSize = 1 << 20
        t.start()
    }
}
