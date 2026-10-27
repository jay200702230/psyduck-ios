// iOS payload 指令服务器: node_start 只能调一次 → 常驻, 轮询 cmd.json 执行任务
// cmd.json: {op:"runAll"|"runFrom"|"single"|"assets"|"stop", index?}
// UI 同步: [ui] begin / [ui] end / [ui] status:xxx 行给 Swift 状态卡消费
import fs from 'fs'
import path from 'path'
import {fileURLToPath, pathToFileURL} from 'url'

const ROOT = path.dirname(fileURLToPath(import.meta.url))
const CMD = path.join(ROOT, 'cmd.json')

function log(s) { console.log(s) }
function ui(s) { console.log('[ui] ' + s) }

// ===== 嵌入环境保命 =====
// nodejs-mobile 里任何 uncaughtException/process.exit 都会 exit 整个 app 进程 = 闪退。
// psyduck 框架用 throw 'End' 当正常收尾, 且大量在定时器回调里抛 → 必须全局兜底。
process.on('uncaughtException', e => log('[payload] uncaught: ' + ((e && e.message) || e)))
process.on('unhandledRejection', e => log('[payload] unhandledRejection: ' + ((e && e.message) || e)))
process.exit = (code = 0) => { log('[payload] process.exit(' + code + ') intercepted') }
process.reallyExit = () => {}

// 任务注册表: config/jd.ini [alias] + title= + map= (对齐 Android Runner.listTasks)
function loadTasks() {
    const out = []
    let cur = null
    try {
        const txt = fs.readFileSync(path.join(ROOT, 'config/jd.ini'), 'utf8')
        for (let ln of txt.split(/\r?\n/)) {
            ln = ln.trim()
            const m = ln.match(/^\[(.+)\]$/)
            if (m && !ln.startsWith('[#')) {
                if (cur) out.push(cur)
                cur = {alias: m[1], title: '', map: ''}
            } else if (cur) {
                if (ln.startsWith('title=')) cur.title = ln.slice(6).trim()
                else if (ln.startsWith('map=')) cur.map = ln.slice(4).trim()
            }
        }
        if (cur) out.push(cur)
    } catch (e) {}
    return out
}
const titleOf = t => t.title || t.map || t.alias

// 清某脚本的去重缓存 (对齐 Android clearTaskCache): 1 小时内跑过会被「已有记录,跳过运行」拦住
function clearTaskCache(alias) {
    let n = 0
    try {
        const dir = path.join(ROOT, 'temp')
        for (const f of fs.readdirSync(dir)) {
            if (f.includes(alias)) { try { fs.rmSync(path.join(dir, f), {recursive: true, force: true}); n++ } catch (e) {} }
        }
    } catch (e) {}
    if (n > 0) log('[payload] 已清 ' + alias + ' 缓存 ' + n + ' 项')
}

async function runOne(alias) {
    const type = alias.match(/(^[A-Za-z0-9]+)_/)[1]
    const params = {filename: alias}
    try {
        log('[payload] import ' + alias + '…')
        const t0 = Date.now()
        const jsPath = pathToFileURL(path.join(ROOT, 'parse', type, alias + '.js')).href
        const psyDuck = await import(jsPath)
        if (!psyDuck.Main) {
            log('[payload] ' + alias + ': no Main export, skip')
            return false
        }
        log('[payload] imported in ' + (Date.now() - t0) + 'ms, init…')
        await new psyDuck.Main().init(params)
        log('[payload] ' + alias + ' done in ' + ((Date.now() - t0) / 1000).toFixed(1) + 's')
        return true
    } catch (e) {
        // 框架约定: throw 'End' = 正常结束
        if (e === 'End' || (e && e.message === 'End')) {
            log('[payload] ' + alias + ' End')
            return true
        }
        // config.ini 映射 fallback (照抄 main.js)
        try {
            const ini = (await import('ini')).default
            const config = ini.parse(fs.readFileSync(path.join(ROOT, 'config/config.ini'), 'UTF-8'))
            let iniPath = path.join(ROOT, 'config', type + '.ini')
            if (config.env && config.env.iniPath) iniPath = path.join(ROOT, config.env.iniPath, type + '.ini')
            const script = ini.parse(fs.readFileSync(iniPath, 'UTF-8'))
            let map = ''
            for (const i in script) {
                if (i == alias && script[i].map) map = script[i].map
            }
            if (map) {
                params.mapping = map
                const jsPath = pathToFileURL(path.join(ROOT, 'parse', type, map + '.js')).href
                const mod2 = await import(jsPath)
                await new mod2.Main().init(params)
                log('[payload] ' + alias + '(map→' + map + ') done')
                return true
            }
        } catch (e2) {
            if (e2 === 'End' || (e2 && e2.message === 'End')) return true
        }
        log('[payload] ' + alias + ' fail: ' + ((e && e.message) || e))
        return false
    }
}

let stopReq = false
let running = false
let tasks = loadTasks()

async function runSeq(start, end, label) {
    tasks = loadTasks()
    running = true
    ui('begin')
    log('[payload] ' + label + ': 第 ' + (start + 1) + ' ~ ' + end + ' 项 (共 ' + (end - start) + ' 个)')
    for (let i = start; i < end; i++) {
        if (stopReq) { log('[payload] ⏹ 手动停止, 剩余任务不再执行'); break }
        const t = tasks[i]
        ui('status:执行任务 ' + (i + 1) + '/' + tasks.length + ': ' + titleOf(t))
        log('[payload] ▶ ' + (i + 1) + '. ' + titleOf(t))
        clearTaskCache(t.alias)
        await runOne(t.alias)
    }
    ui('end')
    ui('status:' + label + '完成')
    running = false
}

async function runAssets() {
    running = true
    ui('begin')
    ui('assets-begin')
    clearTaskCache('jd_task_assets')
    await runOne('jd_task_assets')
    ui('assets-end')
    ui('end')
    running = false
}

function handle(c) {
    if (c.op === 'stop') {
        if (running) { stopReq = true; ui('status:⏹ 停止请求已接收, 当前任务跑完即停') }
        else log('[payload] 当前没有正在跑的任务')
        return
    }
    if (running) { log('[payload] 已有任务在跑, 忽略 ' + c.op); return }
    stopReq = false
    tasks = loadTasks()
    if (c.op === 'runAll') runSeq(0, tasks.length, '跑全部任务')
    else if (c.op === 'runFrom') runSeq(Math.max(0, Math.min(c.index | 0, tasks.length - 1)), tasks.length, '单跑到最后')
    else if (c.op === 'single') { const i = Math.max(0, Math.min(c.index | 0, tasks.length - 1)); runSeq(i, i + 1, '单跑') }
    else if (c.op === 'assets') runAssets()
    else log('[payload] 未知指令: ' + c.op)
}

// 指令轮询
setInterval(() => {
    try {
        const txt = fs.readFileSync(CMD, 'utf8')
        fs.unlinkSync(CMD)
        handle(JSON.parse(txt))
    } catch (e) {}
}, 400)

log('[payload] runtime ready, tasks=' + tasks.length + ', waiting cmd.json…')
setInterval(() => {}, 1 << 30) // 事件循环常驻
