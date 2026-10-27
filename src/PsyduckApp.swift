import SwiftUI

@main
struct PsyduckApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State var log: String = "psyduck ios runner\n"
    @State var running = false

    var body: some View {
        VStack(spacing: 12) {
            ScrollViewReader { p in
                ScrollView {
                    Text(log)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color.black)
                .foregroundColor(Color.green)
                .id("logbox")
            }
            HStack {
                Button(running ? "运行中…" : "▶ 同步Cookie+跑任务") {
                    start()
                }
                .disabled(running)
                .buttonStyle(.bordered)
            }
            .padding(.bottom, 20)
        }
        .padding(.top, 40)
    }

    func appendLog(_ s: String) {
        log += s + "\n"
        if log.count > 60000 { log = String(log.suffix(40000)) }
    }

    func start() {
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            // 1. root helper 掏京东 cookie
            let ck = JDHelper.grabCookie { line in
                DispatchQueue.main.async { appendLog(line) }
            }
            DispatchQueue.main.async { appendLog("cookie: \(ck.isEmpty ? "未取到" : "ok len=\(ck.count)")") }

            // 2. 灌 payload 的 cookie/jd.ini
            if !ck.isEmpty {
                Payload.install(cookie: ck)
                DispatchQueue.main.async { appendLog("payload cookie/jd.ini 已写入") }
            }

            // 3. 起 node 跑任务脚本
            DispatchQueue.main.async { appendLog("启动 node runtime…") }
            NodeRunner.start { line in
                DispatchQueue.main.async { appendLog(line) }
            }
        }
    }
}
