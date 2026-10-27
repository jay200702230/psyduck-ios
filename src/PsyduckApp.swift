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
    @State var cookieStatus = "cookie: 未同步"

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack {
                Text("psyduck")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Text(cookieStatus)
                    .font(.system(size: 11))
                    .foregroundColor(cookieStatus.contains("ok") ? .green : .orange)
            }
            .padding(.horizontal, 14)
            .padding(.top, 46)
            .padding(.bottom, 10)

            // 日志区
            ScrollViewReader { p in
                ScrollView {
                    Text(log.isEmpty ? "点击下方按钮开始" : log)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color.black)
                .foregroundColor(Color.green)
                .cornerRadius(8)
                .padding(.horizontal, 10)
                .id("logbox")
            }

            // 按钮区
            VStack(spacing: 10) {
                Button {
                    startAll()
                } label: {
                    Text(running ? "运行中…" : "▶ 同步Cookie并跑任务")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(running ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(running)

                HStack(spacing: 10) {
                    Button {
                        scanJD()
                    } label: {
                        Text("🔍 扫描京东沙盒")
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(.systemGray5))
                            .cornerRadius(8)
                    }
                    Button {
                        reinstallPayload()
                    } label: {
                        Text("📦 重装payload")
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(.systemGray5))
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .onAppear { Payload.install() }
    }

    // iOS14 兼容：扫描京东沙盒诊断（helper scan 模式，全量输出）
    func scanJD() {
        appendLog("— 扫描京东沙盒 —")
        DispatchQueue.global(qos: .userInitiated).async {
            JDHelper.scanSandbox { line in
                DispatchQueue.main.async { appendLog(line) }
            }
            DispatchQueue.main.async { appendLog("— 扫描结束 —") }
        }
    }

    func appendLog(_ s: String) {
        log += s + "\n"
        if log.count > 60000 { log = String(log.suffix(40000)) }
    }

    func reinstallPayload() {
        let ok = Payload.install()
        appendLog(ok ? "[payload] ok: main_ios.mjs 已就位" : "[payload] bundle 里没找到 mjs 资源")
    }

    func startAll() {
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            // 1. 装 payload（无论 cookie 是否拿到）
            let pOk = Payload.install()
            DispatchQueue.main.async {
                appendLog(pOk ? "[payload] ok" : "[payload] bundle 缺 mjs 资源")
            }

            // 2. root helper 掏京东 cookie
            let ck = JDHelper.grabCookie { line in
                DispatchQueue.main.async { appendLog(line) }
            }
            if ck.isEmpty {
                DispatchQueue.main.async {
                    cookieStatus = "cookie: 未取到"
                    appendLog("[cookie] 未取到 → 点「🔍 扫描京东沙盒」看详情")
                    running = false
                }
                return
            }
            DispatchQueue.main.async {
                cookieStatus = "cookie: ok len=\(ck.count)"
                appendLog("cookie: ok len=\(ck.count)")
            }

            // 3. 灌 cookie 后跑任务
            Payload.writeCookie(ck)
            DispatchQueue.main.async {
                appendLog("启动 node runtime…")
            }
            NodeRunner.start { line in
                DispatchQueue.main.async { appendLog(line) }
            }
            DispatchQueue.main.async { running = false }
        }
    }
}
