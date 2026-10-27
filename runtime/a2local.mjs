import fs from "fs";
import crypto from "crypto";
import path from "path";

// 用法: node a2local.mjs <prefs.xml> <psyduck_root>
// 从京东APP的 wjlogin prefs 解出 A2(wskey) 并写入 config/jdUser.ini
const SALT = Buffer.from("!q@w#e$r%t^y#n@v", "binary");
const IV = Buffer.from("1653678145712191", "binary");
const md5_16 = (s) => crypto.createHash("md5").update(s).digest("hex").substring(8, 24);

function aesDecrypt(keyStr, hexData) {
  const key = crypto.pbkdf2Sync(Buffer.from(keyStr, "binary"), SALT, 10, 16, "sha1");
  const d = crypto.createDecipheriv("aes-128-cbc", key, IV);
  return Buffer.concat([d.update(Buffer.from(hexData, "hex")), d.final()]).toString("utf8");
}
function xmlVals(xml) {
  const map = {};
  const re = /<(string|int|boolean|long)\s+name="([^"]+)"(?:\s+value="([^"]*)")?>([\s\S]*?)<\/\1>|<(string|int|boolean|long)\s+name="([^"]+)"\s+value="([^"]*)"\s*\/>/g;
  let m;
  while ((m = re.exec(xml))) {
    const name = m[2] || m[6];
    let val = m[3] !== undefined ? m[3] : (m[4] !== undefined ? m[4] : m[7]);
    val = String(val ?? "").replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&apos;/g, "'").replace(/&amp;/g, "&");
    if (name) map[name] = val;
  }
  return map;
}
const hex2str = (h) => { try { return Buffer.from(h, "hex").toString("utf8"); } catch { return h; } };

const xmlPath = process.argv[2];
const root = process.argv[3] || ".";
if (!xmlPath) { console.log("用法: node a2local.mjs <prefs.xml> <psyduck_root>"); process.exit(1); }

const map = xmlVals(fs.readFileSync(xmlPath, "utf-8"));
const blob = map[md5_16("wjlogin_users_v3")];
const shpkey = map["wj_shpkey_v6"] || map["wj_shpkey_v3"];
if (!blob || !shpkey) {
  console.log("!! prefs 缺关键字段: blob=" + !!blob + " shpkey=" + !!shpkey);
  console.log("现有键: " + Object.keys(map).join(", "));
  process.exit(2);
}
const plain = aesDecrypt(shpkey, blob);
let obj;
try { obj = JSON.parse(plain); } catch (e) { console.log("!! 解密结果非JSON: " + plain.slice(0, 200)); process.exit(3); }
const users = (obj.users || []).map((s) => (typeof s === "string" ? JSON.parse(s) : s));
if (!users.length) { console.log("!! 未解出账号"); process.exit(4); }

const iniPath = path.join(root, "config", "jdUser.ini");
let ini = fs.existsSync(iniPath) ? fs.readFileSync(iniPath, "utf-8") : "";

function setKey(section, key, val) {
  const head = "[" + section + "]";
  const idx = ini.indexOf(head);
  if (idx < 0) {
    if (ini && !ini.endsWith("\n")) ini += "\n";
    ini += "\n" + head + "\n" + key + "=" + val + "\n";
    return;
  }
  // find section end
  let end = ini.indexOf("\n[", idx + head.length);
  if (end < 0) end = ini.length;
  let sec = ini.slice(idx, end);
  const re = new RegExp("^" + key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "=.*$", "m");
  if (re.test(sec)) sec = sec.replace(re, key + "=" + val);
  else sec = sec.replace(/\n*$/, "\n") + key + "=" + val + "\n";
  ini = ini.slice(0, idx) + sec + ini.slice(end);
}

const out = [];
for (const u of users) {
  const pin = hex2str(u.Pin);
  const wskey = u.A2;
  const mobile = u.Account || "";
  const nick = u.NickName || u.nickName || "";
  if (!pin || !wskey) continue;
  setKey(pin, "pin", pin);
  setKey(pin, "mobile", mobile);
  if (nick) setKey(pin, "userName", nick);
  setKey(pin, "wskey", wskey);
  const days = Math.round((u.A2TimeOut || 0) / 86400);
  out.push(`  ${pin}  mobile=${mobile}  A2有效=${days}天  wskey=${wskey.slice(0, 12)}...`);
}

fs.writeFileSync(iniPath, ini);
console.log("已写入 " + users.length + " 个账号 -> " + iniPath);
console.log(out.join("\n"));
console.log("A2SYNC_OK");