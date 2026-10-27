// node 端京东 h5st 签名器: SDK直跑 + 真机WQ_* seed + env补丁, 纯协议无 WebView
// 用法: const {sign} = await import('./signer_node.mjs'); sign({functionId, body, ck, base})
//   ck: 账号 cookie (提取 pt_pin 预置 document.cookie -> 段8 pp.p1 对齐真机), 多账号切换自动重建实例
import fs from 'fs'
import util from 'util'
import webcrypto from 'crypto'
import https from 'https'
import path from 'path'
import url from 'url'

const __dirname = path.dirname(url.fileURLToPath(import.meta.url))

process.on('uncaughtException', e => { if (!process.env.SIGNER_VERBOSE) return; console.log('[signer-bg]', String(e).slice(0, 100)) })

const src = fs.readFileSync(path.join(__dirname, process.env.SDKF || 'farm_sign_sdk.js'), 'utf8')
const SEED_PATH = process.env.WQF ? path.resolve(process.env.WQF) : path.join(__dirname, 'farm_wq_seed.json')

// ---- 浏览器环境 stub ----
const noop = () => {}
const g = globalThis
let signerCookie = ''
let signerPin = ''
const def = (k, v) => { try { Object.defineProperty(g, k, {value: v, writable: true, configurable: true}) } catch (e) { g[k] = v } }
if (!g.__signerEnvReady) {
    def('window', g); def('self', g); def('top', g); def('parent', g); def('frames', g)
    def('location', {href: 'https://pro.m.jd.com/mall/active/42HV4J3Q87B2xFQMJk81PCc1mEs3/index.html', host: 'pro.m.jd.com', hostname: 'pro.m.jd.com', protocol: 'https:', origin: 'https://pro.m.jd.com', pathname: '/mall/active/42HV4J3Q87B2xFQMJk81PCc1mEs3/index.html', search: '', hash: '', port: '', reload: noop, replace: noop, toString() { return this.href }})
    def('navigator', {userAgent: g.__signerUa || 'Mozilla/5.0 (Linux; Android 13; IN2010 Build/RKQ1.211119.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/116.0.0.0 Mobile Safari/537.36', appName: 'Netscape', platform: 'Linux aarch64', language: 'zh-CN', languages: ['zh-CN', 'zh'], vendor: 'Google Inc.', hardwareConcurrency: 8, deviceMemory: 8, maxTouchPoints: 5, cookieEnabled: true, onLine: true, webdriver: false, connection: {effectiveType: '4g'}, plugins: {length: 0}, mimeTypes: {length: 0}})
    def('screen', {width: 360, height: 800, availWidth: 360, availHeight: 759, colorDepth: 24, pixelDepth: 24, availLeft: 0, availTop: 0, orientation: {type: 'portrait-primary', angle: 0}})
    def('history', {length: 2, state: null, back: noop, forward: noop, go: noop, pushState: noop, replaceState: noop})
    const _ls = new Map()
    let seed = {}
    try { seed = JSON.parse(fs.readFileSync(SEED_PATH, 'utf8').replace(/^\uFEFF/, '')) } catch (e) {}
    for (const k in seed) if (!k.startsWith('_')) _ls.set(k, seed[k])
    def('localStorage', {getItem: k => _ls.has(k) ? _ls.get(k) : null, setItem: (k, v) => _ls.set(k, String(v)), removeItem: k => _ls.delete(k), key: i => [..._ls.keys()][i] ?? null, get length() { return _ls.size }, clear: () => _ls.clear(), __map: _ls})
    def('sessionStorage', {getItem: () => null, setItem: noop, removeItem: noop, key: () => null, length: 0, clear: noop})
    def('document', {
        cookie: {get() { return signerCookie }, set(v) { const kv = String(v).split(';')[0]; const [k] = kv.split('='); const re = new RegExp('(^|;\\s*)' + k + '=[^;]*'); signerCookie = re.test(signerCookie) ? signerCookie.replace(re, '$1' + kv) : (signerCookie ? signerCookie + '; ' + kv : kv) }, configurable: true},
        title: '', referrer: 'https://pro.m.jd.com/', readyState: 'complete', hidden: false, visibilityState: 'visible',
        createElement: tag => ({tag, style: {}, setAttribute: noop, getAttribute: () => null, appendChild: noop, remove: noop, addEventListener: noop, attachShadow: () => ({appendChild: noop}), getContext: () => null, toDataURL: () => 'data:image/png;base64,', sheet: {insertRule: noop, cssRules: []}, contentWindow: null}),
        createTextNode: t => ({textContent: t}), createEvent: () => ({initEvent: noop}),
        getElementsByTagName: () => [], getElementsByClassName: () => [], querySelector: () => null, querySelectorAll: () => [], getElementById: () => null,
        head: {appendChild: noop}, body: {appendChild: noop}, documentElement: {style: {}},
        addEventListener: noop, removeEventListener: noop, attachEvent: noop, detachEvent: noop,
        createRange: () => ({selectNodeContents: noop, collapse: noop}), characterSet: 'UTF-8', charset: 'UTF-8',
    })
    def('devicePixelRatio', 3); def('addEventListener', noop); def('removeEventListener', noop)
    def('XMLHttpRequest', function () {
        const self = this
        this.readyState = 0; this.status = 0; this.responseText = ''; this.timeout = 0
        this.__h = {}
        this.open = (m, u) => { self.__m = String(m || 'GET').toUpperCase(); self.__u = String(u) }
        this.setRequestHeader = (k, v) => { try { self.__h[String(k)] = String(v) } catch (e) {} }
        this.getAllResponseHeaders = () => ''
        this.abort = noop
        this.send = body => {
            try {
                const u = new URL(self.__u, 'https://pro.m.jd.com')
                const hd = Object.assign({}, self.__h)
                if (signerCookie && !hd.cookie) hd.cookie = signerCookie
                hd['content-length'] = Buffer.byteLength(body || '')
                if (globalThis.__signerVerbose) console.log('[XHR]', self.__m, u.href, String(body || '').slice(0, 120))
                const rq = https.request({hostname: u.hostname, path: u.pathname + u.search, method: self.__m, headers: hd}, rs => {
                    if (globalThis.__signerVerbose) { let dd = ''; rs.on('data', c => dd += c); rs.on('end', () => console.log('[XHR-RESP]', rs.statusCode, dd.slice(0, 200))) }
                    let d = ''
                    rs.on('data', c => d += c)
                    rs.on('end', () => {
                        self.status = rs.statusCode
                        self.responseText = d
                        self.readyState = 4
                        try { self.onreadystatechange && self.onreadystatechange() } catch (e) {}
                    })
                })
                rq.on('error', () => {})
                rq.setTimeout(self.timeout || 10000, () => { try { rq.destroy() } catch (e) {} })
                if (body) rq.write(body)
                rq.end()
            } catch (e) {}
        }
    })
    def('requestAnimationFrame', cb => setTimeout(cb, 16))
    def('getComputedStyle', () => ({getPropertyValue: () => ''}))
    def('matchMedia', () => ({matches: false, media: '', addListener: noop, removeListener: noop, addEventListener: noop}))
    def('CanvasRenderingContext2D', function () {}); def('WebGLRenderingContext', function () {})
    def('TextEncoder', util.TextEncoder); def('TextDecoder', util.TextDecoder)
    def('crypto', webcrypto.webcrypto)
    def('MessageChannel', class { constructor() { this.port1 = {postMessage: noop, onmessage: null}; this.port2 = {postMessage: noop, onmessage: null} } })
    def('Image', class { constructor() { this.style = {} } set src(v) {} })
    def('HTMLElement', class {}); def('Element', class {}); def('Node', class {}); def('Document', class {}); def('Window', class {})
    def('Navigator', class {}); def('Screen', class {}); def('Location', class {}); def('Storage', class {})
    def('SVGElement', class {}); def('HTMLCanvasElement', class {}); def('HTMLIFrameElement', class {})
    def('Event', class {}); def('CustomEvent', class {}); def('UIEvent', class {})
    def('MutationObserver', class { observe() {} disconnect() {} takeRecords() { return [] } })
    def('IntersectionObserver', class { observe() {} disconnect() {} unobserve() {} })
    def('ResizeObserver', class { observe() {} disconnect() {} unobserve() {} })
    def('PerformanceObserver', class { observe() {} disconnect() {} })
    def('DOMParser', class { parseFromString() { return g.document } })
    def('CSSStyleDeclaration', class {})
    def('DOMException', class DOMException extends Error { constructor(m, n) { super(m); this.name = n || 'DOMException' } })
    def('open', noop); def('close', noop); def('postMessage', noop)
    def('origin', 'https://pro.m.jd.com'); def('name', ''); def('status', '')
    def('ontouchstart', null); def('ontouchend', null); def('ontouchmove', null)
    g.__signerEnvReady = true
}

// ---- env 补丁: SDK 收集的环境对象在 stringify 前就地改写为真机同款 (段8 校验对齐) ----
// 必须: hook 先于 SDK eval 安装 (SDK 闭包缓存 stringify 引用)
const _origStr = JSON.stringify
JSON.stringify = function (v, r, s) {
    try {
        if (v && typeof v === 'object' && v.sua && v.fp && v.extend && !v.__patched) {
            v.__patched = 1
            v.pf = 'Linux aarch64'
            v.pp = {p1: signerPin}
            const e = v.extend
            e.wk = 0; e.bu3 = 145; e.bu4 = 0; e.bu6 = 33; e.bu7 = 0; e.bu8 = 0; e.bu9 = 0
        }
    } catch (err) {}
    return _origStr.apply(JSON, arguments)
}

let PS = null, psInst = null, psInstKey = null
const getPS = (pin, appId) => {
    const key = pin + '|' + (appId || 'c57f6')
    if (psInst && psInstKey === key) return psInst
    if (!PS) PS = new Function(src + '\nreturn ParamsSignMain')()
    psInst = new PS({appId: appId || 'c57f6'})
    psInstKey = key
    return psInst
}

export function sign(input) {
    const ck = String(input.ck || '')
    const pm = ck.match(/pt_pin=([^;\s]+)/)
    const pin = pm ? pm[1] : signerPin
    if (ck) signerCookie = ck
    if (pin !== signerPin) { signerPin = pin; psInst = null }
    const base = {appid: 'signed_wh5', client: 'android', clientVersion: '15.10.50', screen: '360*1597', wqDefault: 'false', build: '102649', osVersion: '13', networkType: 'wifi', d_brand: 'OnePlus', d_model: 'IN2010', partner: 'oppo', uuid: '3303461326131633-2313731633939346', t: String(Date.now()), body: JSON.stringify(input.body), functionId: input.functionId}
    if (input.base) Object.assign(base, input.base)
    const signed = getPS(signerPin, input.appId).signSync(base)
    return Object.assign({}, base, signed)
}
export default {sign}
