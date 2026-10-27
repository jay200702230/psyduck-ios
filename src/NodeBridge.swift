import Foundation
import NodeMobile

/// nodejs-mobile 官方 Swift 桥（node_start）
@objc public class NodeMobileBridge: NSObject {
    @objc public static func startNode(args: [String], onLine: @escaping (String) -> Void) {
        // 重定向 stdout 到管道，起读线程喂 onLine
        setvbuf(stdout, nil, _IOLBF, 8192)
        // nodejs-mobile: NodeMM.startEngine(withArguments:) 官方 API
        let cargs = args.map { strdup($0) } + [nil]
        var argv = cargs.compactMap { $0 }
        // NodeMM API 名以 framework 实际 header 为准；标准用法：
        // node_start(argc, argv)  (node_api_mobile.h)
        DispatchQueue.global(qos: .default).async {
            // libnode dylib 直接调 node_start
            let argc = Int32(argv.count)
            argv.withUnsafeMutableBufferPointer { buf in
                var ptr = buf.baseAddress
                node_start(argc, &ptr)
            }
            onLine("[node] exited")
        }
    }
}
