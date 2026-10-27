// iOS payload 入口: 读 cookie/jd.ini → 按 panel.json 过滤 parse/jd/ → 逐个跑全部任务
// 对齐 Android main.js 的单跑逻辑(import parse/jd/<name>.js → new Main() → init({filename}))
import fs from 'fs'
import path from 'path'
import https from 'https'
import {fileURLToPath, pathToFileURL} from 'url'

const ROOT = path.dirname(fileURLToPath(import.meta.url))

function loadCookie() {
    try {
        const txt = fs.readFileSync(path.join(ROOT, 'cookie/jd.ini'), 'utf8')
        for (const ln of txt.split(/\r?\n/)) {
            if (ln.includes('pt_key=') && ln.includes('pt_pin=')) return ln.trim()
        }
    } catch (e) {}
    return ''
}

function ckInfo(ck) {
    const pin = (ck.match(/pt_pin=([^;\s]+)/) || [])[1] || '?'
    const keyTail = ((ck.match(/pt_key=([^;\s]+)/) || [])[1] || '').slice(-6)
    return {pin, keyTail}
}

// 咨询性登录态校验: 失败不拦截, 只提示
function ckIslogin(cookie) {
    return new Promise(resolve => {
        const req = https.request({
            hostname: 'plogin.m.jd.com', path: '/cgi-bin/ml/islogin', method: 'GET',
            headers: {Cookie: cookie, 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1'}
        }, res => {
            let b = ''
            res.on('data', d => b += d)
            res.on('end', () => {
                try { resolve(JSON.parse(b).islogin == '1' ? 1 : 0) } catch (e) { resolve(-1) }
            })
        })
        req.on('error', () => resolve(-1))
        req.setTimeout(8000, () => { req.destroy(); resolve(-1) })
        req.end()
    })
}

// 任务注册表: panel.json delete=物理删除(过期) remove=不进列表
function taskFilter() {
    let del = [], rm = []
    try {
        const p = JSON.parse(fs.readFileSync(path.join(ROOT, 'config/panel.json'), 'utf8'))
        del = (p.script && p.script.jd && p.script.jd.delete) || []
        rm = (p.script && p.script.jd && p.script.jd.remove) || []
    } catch (e) {}
    for (const f of del) {
        try { fs.unlinkSync(path.join(ROOT, 'parse/jd', f)); console.log('[payload] deleted(过期):', f) } catch (e) {}
    }
    return new Set(rm)
}

async function runOne(filename) {
    const type = filename.match(/(^[A-Za-z0-9]+)_/)[1]
    const params = {filename}
    try {
        const jsPath = pathToFileURL(path.join(ROOT, 'parse', type, filename + '.js')).href
        const psyDuck = await import(jsPath)
        if (!psyDuck.Main) {
            console.log(`[payload] ${filename}: no Main export, skip`)
            return false
        }
        const t0 = Date.now()
        const main = new psyDuck.Main()
        await main.init(params)
        console.log(`[payload] ${filename} done in ${((Date.now() - t0) / 1000).toFixed(1)}s`)
        return true
    } catch (e) {
        // config.ini 映射 fallback (照抄 main.js)
        try {
            const ini = (await import('ini')).default
            const iniText = fs.readFileSync(path.join(ROOT, 'config/config.ini'), 'UTF-8')
            const config = ini.parse(iniText)
            let iniPath = path.join(ROOT, 'config', type + '.ini')
            if (config.env && config.env.iniPath) iniPath = path.join(ROOT, config.env.iniPath, type + '.ini')
            const scText = fs.readFileSync(iniPath, 'UTF-8')
            const script = ini.parse(scText)
            let map = ''
            for (const i in script) {
                if (i == filename && script[i].map) map = script[i].map
            }
            if (map) {
                params.mapping = map
                const jsPath = pathToFileURL(path.join(ROOT, 'parse', type, map + '.js')).href
                const psyDuck = await import(jsPath)
                await new psyDuck.Main().init(params)
                console.log(`[payload] ${filename}(map→${map}) done`)
                return true
            }
        } catch (e2) {}
        console.log(`[payload] ${filename} fail: ${(e && e.message) || e}`)
        return false
    }
}

async function main() {
    const ck = loadCookie()
    if (!ck) {
        console.log('[payload] cookie/jd.ini 无 cookie — 先在 app 里点同步')
        return
    }
    const {pin, keyTail} = ckInfo(ck)
    console.log(`[payload] account: ${pin} (pt_key…${keyTail})`)
    const st = await ckIslogin(ck)
    if (st === 0) console.log('[payload] WARN: islogin=0 cookie疑似过期, 仍继续尝试')
    else if (st === -1) console.log('[payload] WARN: islogin 校验失败(网络?), 继续')

    const skip = taskFilter()
    let tasks = []
    try {
        tasks = fs.readdirSync(path.join(ROOT, 'parse/jd'))
            .filter(f => /^jd_.+\.js$/.test(f))
            .filter(f => !f.endsWith('_sdk.js') && f !== 'jd_signer_node.mjs')
            .filter(f => !skip.has(f))
            .sort()
    } catch (e) {}
    console.log(`[payload] tasks: ${tasks.length}`)
    if (!tasks.length) {
        console.log('[payload] parse/jd 无任务脚本')
        return
    }
    let ok = 0
    for (const f of tasks) {
        console.log(`\n[payload] === ${f} ===`)
        if (await runOne(f.replace(/\.js$/, ''))) ok++
    }
    console.log(`\n[payload] all done: ${ok}/${tasks.length}`)
    // 保持 node 事件循环存活(node_start 不返回, 不重复触发)
    setInterval(() => {}, 1 << 30)
}

main()
