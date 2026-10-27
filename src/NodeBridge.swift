import Foundation

/// nodejs-mobile 启动桥（node_start C API）
enum NodeMobileBridge {
    static func startNode(args: [String], onLine: @escaping (String) -> Void) {
        setvbuf(stdout, nil, _IOLBF, 8192)
        DispatchQueue.global(qos: .default).async {
            // 构造 char** argv（node_start 签名: int node_start(int, char**)
            var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0)! }
            cargs.append(nil)
            var argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cargs.count)
            for (i, p) in cargs.enumerated() { argv[i] = p }
            let argc = Int32(args.count)
            node_start(argc, argv)
            onLine("[node] exited")
        }
    }
}
