import SwiftUI

@main
struct PsyduckApp: App {
    var body: some Scene {
        WindowGroup { ContentView().preferredColorScheme(.dark) }
    }
}

// MARK: - 骚话池 (对齐 Slang.java)

enum Slang {
    static let BANNER = [
        "🍆 姚禹科技：京豆夹紧点，猛男要上号了~",
        "😈 姚禹一出手，京豆腿一软就全招了…",
        "🔞 姚禹科技 yyds，今晚把京豆薅到腿软！",
        "🍑 京豆别害羞，姚禹就蹭一下，不痛的~",
        "🐽 姚禹科技出品：进得去、出得来，京豆哭着喊爸爸~",
    ]
    static let START = [
        "🍆 姚禹科技上号了，京豆自己就把腿张开了…",
        "😏 姚禹手一伸，京豆就湿了，乖乖往兜里钻~",
        "🔞 今晚不睡，陪京豆大战三百回合，谁先软谁输！",
        "💪 硬度拉满，一次干到底，不薅秃不收手！",
        "🫦 京豆：别…别薅了…   姚禹：嘴上说不要，身体倒是很诚实嘛~",
        "🚀 全部脚本上膛，京豆今天要被薅到怀疑人生！",
        "🍑 摸一摸、揉一揉，京豆自己就往身上贴，比对象还主动~",
    ]
    static let END = [
        "⭐ 收工！京豆已入袋，姚禹提上裤子就走~",
        "🤑 全清！跟着姚禹混，三天吃九顿，顿顿有豆！",
        "🧺 收网！该拿的都拿了，京豆还没爽够呢~",
        "👑 姚禹科技 yyds，这波稳如老狗，京豆哭着说下次别来~",
        "😎 任务全清，脚本下班，京豆瘫在床上起不来~",
    ]
    static let WAIT = [
        "😴 姚禹眯一会儿，养精蓄锐，到点继续猛薅…",
        "🚬 抽根事后烟歇会儿，等下接着战京豆！",
        "☕ 泡杯咖啡补补，回来再战三百回合！",
    ]
    static func pick(_ pool: [String]) -> String { pool.randomElement() ?? "" }
}

// MARK: - 全局状态 (对齐 Android refresh() 每 1.5s 轮询)

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var logLines: [String] = []
    @Published var statusText = "○ 后台未运行"
    @Published var statusGreen = false
    @Published var runtimeLine = "当前: 空闲 · 运行时: 未解包"
    @Published var accountsLine = "👤 账号(0): (未读取到账号, 点「刷新登录态」)"
    @Published var tasks: [RunnerCtl.Task] = []
    @Published var nodeRunning = false
    @Published var loopOn = false
    /// 日志追加计数 (驱动滚动跟随)
    @Published var logTick = 0

    var currentStatus = "空闲"
    var loopTimer: Timer?
    var capturingAssets = false
    var assetLines: [String] = []
    var onAssets: ((String) -> Void)?

    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func append(_ line: String) {
        DispatchQueue.main.async {
            self.logLines.append("[\(self.df.string(from: Date()))] " + line)
            if self.logLines.count > 3000 { self.logLines.removeFirst(self.logLines.count - 2600) }
            self.logTick += 1
        }
    }

    /// node stdout 行入口: [ui] 指令行驱动状态卡, 其余进日志
    func handleLine(_ raw: String) {
        var line = raw
        if line.hasPrefix("[payload] ") { line = String(line.dropFirst(10)) }
        if line.hasPrefix("[ui] ") {
            let s = String(line.dropFirst(5))
            DispatchQueue.main.async {
                if s == "begin" {
                    self.nodeRunning = true
                } else if s == "end" {
                    self.nodeRunning = false
                    self.append(Slang.pick(Slang.END))
                } else if s.hasPrefix("status:") {
                    self.currentStatus = String(s.dropFirst(7))
                } else if s == "assets-begin" {
                    self.capturingAssets = true
                    self.assetLines = []
                } else if s == "assets-end" {
                    self.capturingAssets = false
                    let r = self.assetLines.joined(separator: "\n")
                    if let cb = self.onAssets { DispatchQueue.main.async { cb(r) } }
                }
                self.refresh()
            }
            return
        }
        if capturingAssets { assetLines.append(line) }
        append(line)
    }

    /// 对齐 Android refresh(): 状态/运行时/账号/任务数
    func refresh() {
        let ready = FileManager.default.fileExists(atPath: Payload.payloadDir.appendingPathComponent("main_ios.mjs").path)
        statusText = nodeRunning ? "● 手动跑任务中" : (loopOn ? "● 后台循环运行中" : "○ 后台未运行")
        statusGreen = nodeRunning || loopOn
        runtimeLine = "当前: \(nodeRunning ? currentStatus : "空闲")    ·    运行时: \(ready ? "已就绪" : "未解包")"

        let pin = self.readPin()
        if pin.isEmpty {
            accountsLine = "👤 账号(0): (未读取到账号, 点「刷新登录态」)"
        } else {
            accountsLine = "👤 账号(1): \(pin)"
        }

        let t = RunnerCtl.listTasks()
        if t.count != tasks.count { tasks = t }
    }

    func readPin() -> String {
        let p = Payload.payloadDir.appendingPathComponent("cookie/jd.ini").path
        guard let txt = try? String(contentsOfFile: p, encoding: .utf8) else { return "" }
        for ln in txt.components(separatedBy: .newlines) where ln.contains("pt_key=") && ln.contains("pt_pin=") {
            if let m = ln.range(of: #"pt_pin=([^;\s]+)"#, options: .regularExpression) {
                var pin = String(ln[m]).dropFirst(7)
                if let d = pin.removingPercentEncoding { pin = d }
                return String(pin)
            }
        }
        return ""
    }

    // 后台循环 (iOS 无前台服务, app 存活期间由 Timer 驱动)
    func startLoop(hours: Int) {
        let h = max(1, hours)
        let t = Timer.scheduledTimer(withTimeInterval: TimeInterval(h * 3600), repeats: true) { _ in
            RunnerFlows.runAll()
        }
        t.fireDate = Date().addingTimeInterval(TimeInterval(h * 3600))
        RunLoop.main.add(t, forMode: .common)
        loopTimer = t
        loopOn = true
        append("后台循环已启动, 每 \(h) 小时跑一轮 · " + Slang.pick(Slang.BANNER))
        refresh()
    }

    func stopLoop() {
        loopTimer?.invalidate()
        loopTimer = nil
        loopOn = false
        append("后台已停止 · " + Slang.pick(Slang.WAIT))
        refresh()
    }
}

// MARK: - 按钮动作流

enum RunnerFlows {
    static func toast(_ s: String) { AppState.shared.append("⚠️ " + s) }

    /// 跑前准备: payload 版本换血 → 重掏京东 cookie → 确保 node 已启动 → 发指令
    static func startRun(op: String, index: Int? = nil) {
        let st = AppState.shared
        DispatchQueue.global(qos: .userInitiated).async {
            if !Payload.install() {
                st.append("ERR payload 未安装 (bundle 里没找到 payload_dir)")
                return
            }
            st.append("刷新京东登录态…")
            let ck = JDHelper.grabCookie { line in
                if !line.contains("base DENIED") { st.append(line.replacingOccurrences(of: "[jd] ", with: "")) }
            }
            if ck.isEmpty {
                st.append("ERR cookie 未取到, 京东 App 是否已登录? 先点「② 刷新登录态」重试")
                DispatchQueue.main.async { st.refresh() }
                return
            }
            Payload.writeCookie(ck)
            DispatchQueue.main.async { st.refresh() }
            if !NodeMobileBridge.started {
                DispatchQueue.main.async { st.append("启动 node 运行时…") }
                NodeRunner.start { line in st.handleLine(line) }
            }
            RunnerCtl.send(op, index: index)
        }
    }

    static func runAll() {
        let st = AppState.shared
        if st.nodeRunning { toast("手动任务正在跑, 别连点, 等这轮跑完"); return }
        startRun(op: "runAll")
    }

    static func stopAll() {
        let st = AppState.shared
        if !st.nodeRunning { toast("当前没有正在跑的任务"); return }
        RunnerCtl.send("stop")
        st.append("⏹ 已停止 · " + Slang.pick(Slang.WAIT))
    }

    static func refreshCookie() {
        let st = AppState.shared
        DispatchQueue.global(qos: .userInitiated).async {
            let ck = JDHelper.grabCookie { line in st.append(line.replacingOccurrences(of: "[jd] ", with: "")) }
            if ck.isEmpty {
                st.append("ERR cookie 未取到 (京东 App 未登录或容器不可读)")
            } else {
                Payload.writeCookie(ck)
                st.append("OK 登录态已刷新, pin=" + (st.readPin() ))
            }
            DispatchQueue.main.async { st.refresh() }
        }
    }

    static func queryAssets(_ onResult: @escaping (String) -> Void) {
        let st = AppState.shared
        if st.nodeRunning { toast("有任务正在跑, 稍后再查询"); return }
        st.onAssets = onResult
        startRun(op: "assets")
    }

    static func singleRun(index: Int, toEnd: Bool) {
        startRun(op: toEnd ? "runFrom" : "single", index: index)
    }
}

// MARK: - 颜色 (对齐 MainActivity.java 调色板)

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    static let bg = Color(hex: 0x0E1014)
    static let card = Color(hex: 0x171A21)
    static let line = Color(hex: 0x262B36)
    static let txt = Color(hex: 0xF2F4F7)
    static let sub = Color(hex: 0x98A2B3)
    static let accent = Color(hex: 0xE1251B)
    static let accent2 = Color(hex: 0xFF8A3D)
    static let btnGray = Color(hex: 0x232833)
    static let logBg = Color(hex: 0x0B0D11)
    static let logTxt = Color(hex: 0xC9D1D9)
}

// MARK: - 主界面 (对齐 MainActivity.java 布局)

struct ContentView: View {
    @ObservedObject var st = AppState.shared
    @AppStorage("intervalH") var intervalH = 6
    @State var taskExpand = false
    @State var follow = true
    @State var slangLine = Slang.pick(Slang.START)
    @State var showPicker = false
    @State var pickerStart = 0
    @State var showAsset = false
    @State var assetText = ""
    @State var toast: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            banner
            statusCard
            opCard
            logCard
        }
        .padding(12)
        .background(Color.bg.ignoresSafeArea())
        .onAppear {
            Payload.install()
            st.refresh()
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            st.refresh()
        }
    }

    // —— 顶部品牌横幅 ——
    var banner: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("🐽 京东任务盒子").font(.system(size: 20, weight: .bold)).foregroundColor(.white)
            Text("全脚本手机本机执行 · 请求由手机发出 · 登录态取自京东APP")
                .font(.system(size: 11)).foregroundColor(Color(hex: 0xFFE0D6))
            Text("🏢 姚禹科技 · yyds    👤 作者：姚禹    💬 QQ：2524151408")
                .font(.system(size: 11, weight: .bold)).foregroundColor(Color(hex: 0xFFD3C2))
            Text(slangLine).font(.system(size: 11)).foregroundColor(Color(hex: 0xFFF0EA))
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(
            LinearGradient(colors: [Color(hex: 0xB31A12), .accent, Color(hex: 0xFF7A3D)],
                           startPoint: .leading, endPoint: .trailing)
        )
        .cornerRadius(18)
    }

    // —— 状态卡片 ——
    var statusCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(st.statusText)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(st.statusGreen ? Color(hex: 0x7CE38B) : Color(hex: 0xE5C07B))
            Text(st.runtimeLine).font(.system(size: 11)).foregroundColor(.sub)
                .padding(.vertical, 2)
            Text(st.accountsLine).font(.system(size: 11)).foregroundColor(Color(hex: 0xBFE3C6))
            Text("📋 任务(\(st.tasks.count)) \(taskExpand ? "▾ 收起" : "▸ 展开")")
                .font(.system(size: 10, weight: .bold)).foregroundColor(.sub)
                .padding(.top, 4).padding(.bottom, 2)
                .onTapGesture { taskExpand.toggle() }
            if taskExpand {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(st.tasks.enumerated()), id: \.offset) { i, t in
                            Text("\(i + 1). \(t.title)")
                                .font(.system(size: 10))
                                .foregroundColor(.sub)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 170)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.card)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.line, lineWidth: 1))
    }

    // —— 操作卡片 ——
    var opCard: some View {
        VStack(spacing: 8) {
            HStack {
                Text("后台重跑间隔(小时, 最小1)")
                    .font(.system(size: 11)).foregroundColor(.sub)
                Spacer()
                TextField("小时", value: $intervalH, formatter: NumberFormatter())
                    .font(.system(size: 13)).foregroundColor(.txt)
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .frame(width: 84, height: 28)
                    .background(Color.btnGray)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.line, lineWidth: 1))
            }
            HStack(spacing: 8) {
                btn("① 初始化运行时", primary: false) { initRuntime() }
                    .frame(maxWidth: .infinity)
                btn("② 刷新登录态", primary: false) { RunnerFlows.refreshCookie() }
                    .frame(maxWidth: .infinity)
            }
            propRow(0.583) {
                btn("▶ 立即跑全部任务", primary: true) { RunnerFlows.runAll() }
                btn(st.loopOn ? "■ 停止后台" : "▶ 启动后台循环", primary: false) {
                    if st.loopOn { st.stopLoop() } else { st.startLoop(hours: max(1, intervalH)) }
                }
            }
            propRow(0.583) {
                btn("⏹ 停止任务", primary: true) { RunnerFlows.stopAll() }
                btn("🗑 清空日志", primary: false) {
                    st.logLines.removeAll()
                    st.append("日志已清空 · " + Slang.pick(Slang.WAIT))
                }
            }
            HStack(spacing: 8) {
                btn("💰 查询今日资产", primary: false) { queryAssets() }
                    .frame(maxWidth: .infinity)
                btn("🎯 单跑脚本", primary: true) {
                    if st.nodeRunning { self.toastMsg("有任务正在跑, 等它结束") } else { showPicker = true }
                }
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.card)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.line, lineWidth: 1))
        .sheet(isPresented: $showPicker) { singlePicker }
        .alert(isPresented: $showAsset) {
            Alert(title: Text("💰 今日资产"),
                  message: Text(assetText.isEmpty ? "没有输出" : assetText),
                  dismissButton: .default(Text("关闭")))
        }
        .overlay(toastView)
    }

    // —— 日志卡片 ——
    var logCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("📜 运行日志").font(.system(size: 13, weight: .bold)).foregroundColor(.txt)
                Spacer()
                btn("📋 复制日志", primary: false, small: true) { copyLog() }
                btn(follow ? "🔒 跟随: 开" : "🔓 跟随: 关", primary: false, small: true) { follow.toggle() }
            }
            .padding(.bottom, 6)
            logView
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.logBg)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.line, lineWidth: 1))
    }

    var logView: some View {
        let lines = Array(st.logLines.suffix(2600))
        return ScrollViewReader { p in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { i in
                        logLine(lines[i]).id(i)
                    }
                    Color.clear.frame(height: 2).id("logBottom")
                }
                .padding(.top, 6)
            }
            .gesture(DragGesture().onChanged { v in
                if v.translation.height > 12 && follow { follow = false }
                else if v.translation.height < -12 && !follow { follow = true }
            })
            .onChange(of: st.logTick) { _ in
                if follow {
                    DispatchQueue.main.async {
                        withAnimation(.linear(duration: 0.1)) { p.scrollTo("logBottom", anchor: .bottom) }
                    }
                }
            }
        }
    }

    /// 日志行色化 (对齐 Android colorize())
    func logLine(_ l: String) -> some View {
        var color = Color.logTxt
        var bold = false
        if l.contains("▶") { color = Color(hex: 0xFFB020); bold = true }
        else if l.contains("ERR") || l.contains("失败") || l.contains("错误") || l.contains("异常") || l.contains("未执行") { color = Color(hex: 0xFF7A7A) }
        else if l.contains("跳过") { color = Color(hex: 0xE5C07B) }
        else if l.contains("OK") || l.contains("完成") || l.contains("成功") || l.contains("已就绪") { color = Color(hex: 0x7CE38B) }
        else if l.contains("👤") { color = Color(hex: 0x7CC7FF) }
        else if l.hasPrefix("[") { color = Color(hex: 0x8B95A5) }
        return Text(l)
            .font(.system(size: 11, weight: bold ? .bold : .regular), design: .monospaced)
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 工具

    /// Android 权重行 (1.4:1)
    func propRow<V0: View, V1: View>(_ ratio: CGFloat, @ViewBuilder _ content: () -> TupleView<(V0, V1)>) -> some View {
        GeometryReader { g in
            let w = (g.size.width - 8) * ratio
            HStack(spacing: 8) {
                content().value.0.frame(width: w)
                content().value.1.frame(maxWidth: .infinity)
            }
        }
        .frame(height: 36)
    }

    func btn(_ text: String, primary: Bool, small: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: small ? 11 : 13))
                .foregroundColor(primary ? .white : Color(hex: 0xD6DCE5))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.vertical, small ? 6 : 8)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
                .background(
                    Group {
                        if primary {
                            LinearGradient(colors: [.accent, .accent2], startPoint: .leading, endPoint: .trailing)
                        } else {
                            Rectangle().fill(Color.btnGray)
                        }
                    }
                )
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(primary ? .clear : Color.line, lineWidth: 1))
        }
    }

    func initRuntime() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Payload.install(force: true)
            let ver = (try? String(contentsOf: Payload.payloadDir.appendingPathComponent(".payload_version"), encoding: .utf8)) ?? "?"
            st.append(ok ? "OK 运行时就绪 version=\(ver.trimmingCharacters(in: .whitespacesAndNewlines))" : "ERR 解包失败: bundle 里没找到 payload_dir")
            DispatchQueue.main.async { st.refresh() }
        }
    }

    func queryAssets() {
        if st.nodeRunning { toastMsg("手动跑任务进行中, 稍后再查询"); return }
        RunnerFlows.queryAssets { result in
            assetText = result.trimmingCharacters(in: .whitespacesAndNewlines)
            showAsset = true
        }
    }

    func copyLog() {
        let txt = st.logLines.joined(separator: "\n")
        if txt.trimmingCharacters(in: .whitespaces).isEmpty {
            toastMsg("日志为空, 没东西可复制")
            return
        }
        UIPasteboard.general.string = txt
        toastMsg("已复制 \(st.logLines.count) 行日志到剪贴板")
    }

    func toastMsg(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if toast == s { toast = nil }
        }
    }

    var toastView: some View {
        Group {
            if let t = toast {
                Text(t)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(hex: 0x2A2F3A).opacity(0.96))
                    .cornerRadius(10)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    // —— 单跑选择器 (对齐 pickTask: 单选 + 只跑这个/从这里跑到最后) ——
    var singlePicker: some View {
        NavigationView {
            List {
                ForEach(Array(st.tasks.enumerated()), id: \.offset) { i, t in
                    Button {
                        pickerStart = i
                    } label: {
                        HStack {
                            Text("\(i + 1). \(t.title)")
                                .font(.system(size: 13))
                                .foregroundColor(pickerStart == i ? .accent : .txt)
                            Spacer()
                            if pickerStart == i { Image(systemName: "checkmark").foregroundColor(.accent) }
                        }
                    }
                }
            }
            .navigationTitle("选择要跑的脚本(共\(st.tasks.count)个)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { showPicker = false }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("只跑这个") {
                        showPicker = false
                        RunnerFlows.singleRun(index: pickerStart, toEnd: false)
                    }
                    Button("跑到最后") {
                        showPicker = false
                        RunnerFlows.singleRun(index: pickerStart, toEnd: true)
                    }
                }
            }
        }
        .onAppear { st.refresh() }
    }
}
