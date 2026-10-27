# psyduck-ios

TrollStore 巨魔版京东任务 runner：nodejs-mobile + ql_runtime lite + root helper 自动读京东 App cookie。

## 结构
- `project.yml` — xcodegen 工程（SwiftUI 壳 + NodeMobile.xcframework + entitlements）
- `src/` — SwiftUI 主程序（按钮+日志）+ node 启动桥
- `helper/PsyduckHelper.m` — root helper：遍历京东沙箱抽 pt_key/pt_pin
- `ql_runtime_lite/` — 放精简 payload（jd_signer_node.mjs + 独立任务脚本 + main_ios.mjs），无此目录则打占位

## 巨魔 entitlements 要点
- 主 app：`platform-application` + `com.apple.private.security.no-sandbox` + `com.apple.private.persona-mgmt`
- helper：ldid fake-sign 即可，helper 二进制被主 app spawn 时继承 root

## 流程
GitHub Actions (macos-14) → xcodegen → xcodebuild（无签名）→ ldid fake-sign → ipa artifact → TrollStore 安装

## 装
TrollStore → Shared/Install from file → psyduck-ios.ipa
