import Foundation

/// nodejs-mobile 启动桥 — dlsym 取 libnode 的 node_start 符号（不依赖 header 暴露）
enum NodeMobileBridge {
    static func startNode(args: [String], onLine: @escaping (String) -> Void) {
        setvbuf(stdout, nil, _IOLBF, 8192)
        DispatchQueue.global(qos: .default).async {
            // node_start 符号在 NodeMobile.framework 的二进制里（主程序已 link，符号全局可见）
            let handle = dlopen(nil, RTLD_NOW)  // 当前进程镜像（NodeMobile 已 link 进来）
            let sym = dlsym(handle, "node_start")
            if sym == nil {
                // 试 libnode dylib 名
                for name in ["libnode.108.dylib", "libnode.dylib", "node"] {
                    if let h = dlopen(name, RTLD_NOW) {
                        if let s2 = dlsym(h, "node_start") {
                            runStart(s2, args: args, onLine: onLine)
                            return
                        }
                    }
                }
                onLine("[node] node_start symbol not found")
                return
            }
            runStart(sym!, args: args, onLine: onLine)
        }
    }

    private static func runStart(_ sym: UnsafeMutableRawPointer, args: [String], onLine: @escaping (String) -> Void) {
        typealias NodeStart = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        let fn = unsafeBitCast(sym, to: NodeStart.self)
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0)! }
        cargs.append(nil)
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cargs.count)
        for (i, p) in cargs.enumerated() { argv[i] = p }
        defer { argv.deallocate() }
        let rc = fn(Int32(args.count), argv)
        onLine("[node] exited rc=\(rc)")
    }
}
