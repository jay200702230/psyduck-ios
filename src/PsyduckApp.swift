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
    @State var showPaste = false
    @State var pasteText = ""

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
                        pasteText = UIPasteboard.general.string ?? ""
                        showPaste = true
                    } label: {
                        Text("📋 粘贴Cookie")
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
        .alert("粘贴 Cookie", isPresented: $showPaste) {
            TextField("pt_key=app_open...;pt_pin=...;", text: $pasteText)
            Button("保存并跑") { useManualCookie(pasteText) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("从京东 App 复制 cookie，或用电脑端已存的")
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

    func useManualCookie(_ ck: String) {
        let clean = ck.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.contains("pt_key=") else {
            appendLog("[cookie] 无效（缺 pt_key=）")
            return
        }
        Payload.writeCookie(clean)
        cookieStatus = "cookie: ok len=\(clean.count)"
        appendLog("[cookie] 手动 cookie 已写入 jd.ini")
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.main.async { appendLog("启动 node runtime…") }
            NodeRunner.start { line in
                DispatchQueue.main.async { appendLog(line) }
            }
            DispatchQueue.main.async { running = false }
        }
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
                    cookieStatus = "cookie: helper失败-请手动粘贴"
                    appendLog("[cookie] helper 未取到 → 用「📋 粘贴Cookie」手动灌")
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
