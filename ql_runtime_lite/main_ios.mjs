// psyduck ios payload 入口：读 cookie/jd.ini → 顺序跑任务脚本
import fs from 'fs'
import path from 'path'
import {fileURLToPath} from 'url'

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

async function main() {
    const ck = loadCookie()
    if (!ck) {
        console.log('[payload] cookie/jd.ini 无 cookie — 先在 app 里点同步')
        return
    }
    const {pin, keyTail} = ckInfo(ck)
    console.log(`[payload] account: ${pin} (pt_key…${keyTail})`)

    // 任务注册表：按需增删（文件放 tasks/ 下即可）
    const tasksDir = path.join(ROOT, 'tasks')
    let tasks = []
    try { tasks = fs.readdirSync(tasksDir).filter(f => f.endsWith('.mjs')).sort() } catch (e) {}
    if (!tasks.length) {
        console.log('[payload] tasks/ 无任务脚本（构建时放入 ql_runtime_lite/tasks）')
        return
    }
    for (const f of tasks) {
        console.log(`\n[payload] === ${f} ===`)
        try {
            const mod = await import(path.join(tasksDir, f))
            if (mod.run) await mod.run(ck)
            else console.log('[payload] no run() export, skip')
        } catch (e) {
            console.log(`[payload] ${f} fail: ${e.message || e}`)
        }
    }
    console.log('\n[payload] all done')
}

main()
