#!/bin/bash
# KAHVEHANE TAVLA sunucu güncellemesi: hesap (kullanıcı adı+şifre), profil resmi, otomatik eşleşme + web sürümü
# Wobbots'un mevcut hesapları ve arkadaş sistemi aynen korunur.
set -e
[ "$(id -u)" = 0 ] || { echo "root olarak çalıştır"; exit 1; }
[ -d /opt/wobapi ] || { echo "/opt/wobapi yok — önce wob-api kurulumu yapılmalı"; exit 1; }
cp /opt/wobapi/server.js /opt/wobapi/server.js.yedek-$(date +%Y%m%d%H%M) 2>/dev/null || true
cat > /opt/wobapi/server.js <<'WOBAPI_EOF'
// fsfx oyun sunucusu (Wobbots + Kahvehane Tavla) — bağımlılık: nodemailer (yalnızca e-posta kodu için)
// Misafir hesap, Apple / Google / E-posta kodu / Game Center ile giriş, bulut kayıt, hesap silme.
'use strict';
const http = require('http'), https = require('https'), crypto = require('crypto'), fs = require('fs'), path = require('path');
const DIR = process.env.WOB_DIR || __dirname;
const CFG_F = path.join(DIR, 'config.json'), DB_F = path.join(DIR, 'db.json');
const CFG = Object.assign({ port: 9100, secret: '', appleAud: [], googleAud: [], gcBundle: [], smtp: null }, JSON.parse(fs.readFileSync(CFG_F, 'utf8')));
if (!CFG.secret) throw new Error('config.json: secret boş');

// ---------- veritabanı (JSON dosyası, atomik yazma) ----------
let DB = { users: {}, idx: {}, codes: {}, fc: {} };
try { DB = Object.assign(DB, JSON.parse(fs.readFileSync(DB_F, 'utf8'))) } catch (e) { }
let dirty = false;
const persist = () => { dirty = true };
setInterval(() => {
  if (!dirty) return; dirty = false;
  const tmp = DB_F + '.tmp'; fs.writeFileSync(tmp, JSON.stringify(DB)); fs.renameSync(tmp, DB_F);
}, 1500);
process.on('SIGTERM', () => { try { fs.writeFileSync(DB_F, JSON.stringify(DB)) } catch (e) { } process.exit(0) });

// ---------- yardımcılar ----------
const now = () => Date.now();
const b64u = b => Buffer.from(b).toString('base64url');
const sign = s => crypto.createHmac('sha256', CFG.secret).update(s).digest('base64url');
function token(uid) { const p = uid + '.' + (now() + 1000 * 3600 * 24 * 180); return p + '.' + sign(p) }
function checkToken(t) {
  if (typeof t !== 'string') return null; const [uid, exp, sg] = t.split('.');
  if (!uid || !exp || !sg) return null;
  const good = sign(uid + '.' + exp);
  if (sg.length !== good.length || !crypto.timingSafeEqual(Buffer.from(sg), Buffer.from(good))) return null;
  if (+exp < now() || !DB.users[uid]) return null; return uid;
}
const BAD = ['orospu', 'siktir', 'sikerim', 'yarak', 'amcik', 'amina', 'gotveren', 'kahpe', 'pezevenk', 'ibne', 'fuck', 'shit', 'bitch', 'nigg', 'whore', 'porn', 'nazi', 'hitler'];
function cleanNick(n) {
  n = String(n || '').replace(/[<>"'`]/g, '').trim().slice(0, 12);
  const t = n.toLocaleLowerCase('tr').replace(/ı/g, 'i').replace(/ş/g, 's').replace(/ğ/g, 'g').replace(/ü/g, 'u').replace(/ö/g, 'o').replace(/ç/g, 'c').replace(/[^a-z]/g, '');
  return BAD.some(w => t.includes(w)) ? 'Robo' + (10 + crypto.randomInt(90)) : n;
}
function newUser(nick) {
  let uid; do { uid = crypto.randomBytes(9).toString('base64url') } while (DB.users[uid]);
  DB.users[uid] = { uid, nick: cleanNick(nick) || ('Robo' + (10 + crypto.randomInt(90))), created: now(), updated: 0, save: null, ids: {} };
  persist(); return DB.users[uid];
}
// ---------- arkadaşlar ----------
const FCA = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function ensureFC(u) {
  if (!DB.fc) DB.fc = {};
  if (u.fc && DB.fc[u.fc] === u.uid) return u.fc;
  let c, i = 0; do { const h = crypto.createHash('sha256').update(u.uid + ':' + i++).digest(); c = ''; for (let k = 0; k < 6; k++) c += FCA[h[k] % 32] } while (DB.fc[c] && DB.fc[c] !== u.uid);
  u.fc = c; DB.fc[c] = u.uid; persist(); return c;
}
const PRES = new Map(), INV = new Map();
const roomOK = r => typeof r === 'string' && /^[a-z0-9]{3,8}$/.test(r) ? r : null;
function frList(u) {
  const t = now();
  return (u.fr || []).filter(id => DB.users[id]).map(id => { const f = DB.users[id], p = PRES.get(id), on = !!p && t - p.t < 45e3; return { uid: id, nick: f.nick, fc: ensureFC(f), on, room: on ? p.room : null, busy: on ? !!p.busy : false } })
    .sort((a, b) => (b.on - a.on) || (!!b.room - !!a.room) || a.nick.localeCompare(b.nick));
}
function befriend(a, b) { for (const [x, y] of [[a, b], [b, a]]) { x.fr = x.fr || []; if (!x.fr.includes(y.uid)) { x.fr.unshift(y.uid); x.fr = x.fr.slice(0, 100) } } persist() }
const pub = u => ({ uid: u.uid, nick: u.nick, fc: ensureFC(u), created: u.created, updated: u.updated, save: u.save, tv: u.tv || null, av: u.av || null, uname: u.ids.pass || null, linked: Object.keys(u.ids).filter(k => k !== 'guest') });
// ---------- kullanıcı adı + şifre ----------
const unameOK = n => typeof n === 'string' && /^[a-z0-9_.]{3,20}$/.test(n);
const passHash = (pw, salt) => crypto.scryptSync(String(pw), salt, 32).toString('hex');
// ---------- tavla otomatik eşleşme ----------
const MQ = new Map(), MCA = 'ABCDEFGHJKLMNPRSTUVYZ23456789';
const mcode = () => { let c = 'M'; for (let i = 0; i < 6; i++) c += MCA[crypto.randomInt(MCA.length)]; return c };
function getJSON(url) {
  return new Promise((res, rej) => {
    https.get(url, r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { try { res(JSON.parse(d)) } catch (e) { rej(e) } }) }).on('error', rej);
  })
}
function getBuf(url) {
  return new Promise((res, rej) => { https.get(url, r => { const a = []; r.on('data', c => a.push(c)); r.on('end', () => res(Buffer.concat(a))) }).on('error', rej) })
}
const JWKS = {};
async function verifyJWT(tok, jwksUrl, issuers, auds) {
  const [h, p, sg] = String(tok || '').split('.'); if (!sg) throw new Error('token');
  const head = JSON.parse(Buffer.from(h, 'base64url')), body = JSON.parse(Buffer.from(p, 'base64url'));
  let ks = JWKS[jwksUrl];
  if (!ks || ks.t < now() - 3600e3 || !ks.keys.find(k => k.kid === head.kid)) { const j = await getJSON(jwksUrl); ks = JWKS[jwksUrl] = { t: now(), keys: j.keys || [] } }
  const jwk = ks.keys.find(k => k.kid === head.kid); if (!jwk || head.alg !== 'RS256') throw new Error('anahtar');
  const ok = crypto.verify('RSA-SHA256', Buffer.from(h + '.' + p), crypto.createPublicKey({ key: jwk, format: 'jwk' }), Buffer.from(sg, 'base64url'));
  if (!ok) throw new Error('imza');
  if (!issuers.includes(body.iss)) throw new Error('iss');
  const aud = Array.isArray(body.aud) ? body.aud : [body.aud];
  if (!auds.length || !aud.some(a => auds.includes(a))) throw new Error('aud');
  if (body.exp * 1000 < now() - 60e3) throw new Error('süre');
  return body;
}
async function verifyGameCenter(b) {
  const pid = String(b.teamPlayerID || b.playerId || ''), url = String(b.publicKeyUrl || '');
  if (!pid || !/^https:\/\/static\.gc\.apple\.com\/[\w\-./]+\.cer$/.test(url)) throw new Error('gc url');
  if (!CFG.gcBundle.includes(b.bundleId)) throw new Error('gc bundle');
  const ts = BigInt(b.timestamp); if (Math.abs(Number(ts) - now()) > 600e3) throw new Error('gc zaman');
  const der = await getBuf(url), cert = new crypto.X509Certificate(der);
  const tsb = Buffer.alloc(8); tsb.writeBigUInt64BE(ts);
  const data = Buffer.concat([Buffer.from(pid, 'utf8'), Buffer.from(b.bundleId, 'utf8'), tsb, Buffer.from(b.salt, 'base64')]);
  if (!crypto.verify('RSA-SHA256', data, cert.publicKey, Buffer.from(b.signature, 'base64'))) throw new Error('gc imza');
  return pid;
}
let mailer = null;
function getMailer() {
  if (!CFG.smtp || !CFG.smtp.host) return null;
  if (!mailer) { const nm = require('nodemailer'); mailer = nm.createTransport({ host: CFG.smtp.host, port: CFG.smtp.port || 465, secure: (CFG.smtp.port || 465) === 465, auth: { user: CFG.smtp.user, pass: CFG.smtp.pass } }) }
  return mailer;
}
const RL = new Map();
function limited(key, max, ms) { const t = now(), a = (RL.get(key) || []).filter(x => x > t - ms); a.push(t); RL.set(key, a); return a.length > max }
const emailOK = e => typeof e === 'string' && e.length < 120 && /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e);
const hashCode = (e, c) => crypto.createHash('sha256').update(CFG.secret + '|' + e + '|' + c).digest('hex');

// hesap bağlama: kimlik başka hesaptaysa o hesaba geçilir, yoksa mevcut hesaba eklenir
function link(prov, sub, cur, nick) {
  const key = prov + ':' + sub, owner = DB.idx[key];
  if (owner && DB.users[owner]) return { uid: owner, switched: owner !== cur };
  let u = cur && DB.users[cur];
  if (!u) u = newUser(nick);
  DB.idx[key] = u.uid; u.ids[prov] = prov === 'guest' ? [...new Set([...(u.ids.guest || []), sub])] : sub; persist();
  return { uid: u.uid, switched: false };
}

// ---------- HTTP ----------
function send(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Content-Type, Authorization', 'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(obj));
}
const routes = {
  'GET /status': async () => ({ ok: true, pass: true, email: !!(CFG.smtp && CFG.smtp.host), apple: CFG.appleAud.length > 0, google: CFG.googleAud.length > 0, gc: CFG.gcBundle.length > 0 }),
  'POST /guest': async (b) => {
    const dev = String(b.dev || ''); if (!/^[a-f0-9]{24,64}$/.test(dev)) throw [400, 'cihaz kimliği geçersiz'];
    const r = link('guest', dev, null, b.nick); return { token: token(r.uid), user: pub(DB.users[r.uid]) };
  },
  'POST /email/start': async (b, uid, ip) => {
    const e = String(b.email || '').trim().toLowerCase(); if (!emailOK(e)) throw [400, 'e-posta adresi geçersiz'];
    const m = getMailer(); if (!m) throw [503, 'e-posta ile giriş henüz aktif değil'];
    if (limited('em:' + e, 3, 600e3) || limited('ip:' + ip, 10, 3600e3)) throw [429, 'çok fazla deneme, biraz bekle'];
    const code = String(crypto.randomInt(100000, 1000000));
    DB.codes[e] = { h: hashCode(e, code), exp: now() + 600e3, tries: 0 }; persist();
    await m.sendMail({ from: CFG.smtp.from || CFG.smtp.user, to: e, subject: (b.app === 'tavla' ? 'Kahvehane Tavla' : 'Wobbots') + ' giriş kodun: ' + code, text: (b.app === 'tavla' ? 'Kahvehane Tavla' : 'Wobbots') + ' giriş kodun: ' + code + '\n\nKod 10 dakika geçerlidir. Bu isteği sen yapmadıysan bu e-postayı yok sayabilirsin.' });
    return { ok: true };
  },
  'POST /link/email': async (b, uid) => {
    const e = String(b.email || '').trim().toLowerCase(), c = DB.codes[e];
    if (!c || c.exp < now()) throw [400, 'kodun süresi doldu, yeniden iste'];
    if (++c.tries > 5) { delete DB.codes[e]; persist(); throw [429, 'çok fazla hatalı deneme'] }
    if (hashCode(e, String(b.code || '').trim()) !== c.h) { persist(); throw [400, 'kod hatalı'] }
    delete DB.codes[e]; const r = link('email', e, uid, b.nick); return { token: token(r.uid), switched: r.switched, user: pub(DB.users[r.uid]) };
  },
  'POST /link/apple': async (b, uid) => {
    let p; try { p = await verifyJWT(b.idToken, 'https://appleid.apple.com/auth/keys', ['https://appleid.apple.com'], CFG.appleAud) } catch (e) { throw [401, 'Apple doğrulaması başarısız (' + e.message + ')'] }
    const r = link('apple', p.sub, uid, b.nick); return { token: token(r.uid), switched: r.switched, user: pub(DB.users[r.uid]) };
  },
  'POST /link/google': async (b, uid) => {
    let p; try { p = await verifyJWT(b.idToken, 'https://www.googleapis.com/oauth2/v3/certs', ['https://accounts.google.com', 'accounts.google.com'], CFG.googleAud) } catch (e) { throw [401, 'Google doğrulaması başarısız (' + e.message + ')'] }
    const r = link('google', p.sub, uid, b.nick); return { token: token(r.uid), switched: r.switched, user: pub(DB.users[r.uid]) };
  },
  'POST /link/gc': async (b, uid) => {
    let pid; try { pid = await verifyGameCenter(b) } catch (e) { throw [401, 'Game Center doğrulaması başarısız (' + e.message + ')'] }
    const r = link('gc', pid, uid, b.nick); return { token: token(r.uid), switched: r.switched, user: pub(DB.users[r.uid]) };
  },
  'POST /link/pass': async (b, uid, ip) => {
    const n = String(b.name || '').trim().toLowerCase(), pw = String(b.pass || '');
    if (!unameOK(n)) throw [400, 'kullanıcı adı 3-20 karakter olmalı (harf, rakam, _ .)'];
    if (pw.length < 6 || pw.length > 64) throw [400, 'şifre en az 6 karakter olmalı'];
    if (limited('pw:' + ip, 20, 600e3) || limited('pwn:' + n, 8, 600e3)) throw [429, 'çok fazla deneme, biraz bekle'];
    const owner = DB.idx['pass:' + n];
    if (b.mode === 'login') {
      const u = owner && DB.users[owner]; if (!u || !u.ph || passHash(pw, u.ps) !== u.ph) throw [401, 'kullanıcı adı veya şifre hatalı'];
      return { token: token(u.uid), switched: u.uid !== uid, user: pub(u) };
    }
    if (owner && DB.users[owner]) throw [409, 'bu kullanıcı adı alınmış'];
    const cu = uid && DB.users[uid]; if (cu && cu.ids.pass) throw [400, 'bu hesapta zaten kullanıcı adı var'];
    const r = link('pass', n, uid, b.nick), u = DB.users[r.uid]; u.ps = crypto.randomBytes(12).toString('hex'); u.ph = passHash(pw, u.ps); persist();
    return { token: token(u.uid), switched: false, user: pub(u) };
  },
  'POST /tv/q': async (b, uid, ip) => {
    const id = String(b.id || ''); if (!/^[a-z0-9]{8,24}$/.test(id)) throw [400, 'kimlik geçersiz'];
    if (limited('q:' + ip, 200, 60e3)) throw [429, 'yavaş'];
    const t = now(); for (const [k, v] of MQ) if ((!v.m && t - v.t > 5000) || t - v.t > 30000) MQ.delete(k);
    let me = MQ.get(id); if (!me) { me = { id, t, m: null }; MQ.set(id, me) } me.t = t;
    if (me.m) { MQ.delete(id); return { match: me.m } }
    for (const [k, v] of MQ) if (k !== id && !v.m) { const code = mcode(); v.m = { code, host: true }; MQ.delete(id); return { match: { code, host: false } } }
    return { wait: true };
  },
  'POST /tv/leave': async (b) => { MQ.delete(String(b.id || '')); return { ok: true } },
  'GET /me': async (b, uid) => { if (!uid) throw [401, 'oturum yok']; return { user: pub(DB.users[uid]) } },
  'PUT /me': async (b, uid) => {
    if (!uid) throw [401, 'oturum yok']; const u = DB.users[uid];
    if (b.nick !== undefined) u.nick = cleanNick(b.nick) || u.nick;
    if (b.avatar !== undefined) {
      if (!Object.keys(u.ids).some(k => k !== 'guest')) throw [403, 'profil resmi için önce hesabını bağla'];
      if (b.avatar === null) delete u.av;
      else { const a = String(b.avatar); if (a.length > 45000 || !/^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(a)) throw [400, 'resim geçersiz veya çok büyük']; u.av = a }
      u.updated = now();
    }
    if (b.tv !== undefined) { const s = JSON.stringify(b.tv); if (s.length > 8000) throw [413, 'kayıt çok büyük']; u.tv = b.tv }
    if (b.save !== undefined) { const s = JSON.stringify(b.save); if (s.length > 40000) throw [413, 'kayıt çok büyük']; u.save = b.save; u.updated = now() }
    persist(); return { user: pub(u) };
  },
  'POST /ping': async (b, uid) => {
    if (!uid) throw [401, 'oturum yok']; const u = DB.users[uid];
    PRES.set(uid, { t: now(), room: roomOK(b.room), busy: !!b.busy });
    const inv = (INV.get(uid) || []).filter(x => now() - x.t < 120e3); INV.delete(uid);
    return { fc: ensureFC(u), friends: frList(u), inv };
  },
  'POST /friends/add': async (b, uid, ip) => {
    if (!uid) throw [401, 'oturum yok']; if (limited('fa:' + uid, 20, 600e3)) throw [429, 'çok fazla deneme, biraz bekle'];
    const u = DB.users[uid]; let t = null;
    if (b.fc) { const c = String(b.fc).toUpperCase().replace(/[^A-Z0-9]/g, ''); t = DB.users[(DB.fc || {})[c]] }
    else if (b.uid) t = DB.users[String(b.uid)];
    if (!t) throw [404, 'bu kodla oyuncu bulunamadı'];
    if (t.uid === uid) throw [400, 'kendini ekleyemezsin'];
    befriend(u, t); return { friend: { uid: t.uid, nick: t.nick }, friends: frList(u) };
  },
  'POST /friends/remove': async (b, uid) => {
    if (!uid) throw [401, 'oturum yok']; const u = DB.users[uid], t = DB.users[String(b.uid)];
    u.fr = (u.fr || []).filter(x => x !== String(b.uid)); if (t) t.fr = (t.fr || []).filter(x => x !== uid); persist();
    return { friends: frList(u) };
  },
  'POST /invite': async (b, uid) => {
    if (!uid) throw [401, 'oturum yok']; const u = DB.users[uid], to = String(b.uid || ''), room = roomOK(b.room);
    if (!room) throw [400, 'oda kodu geçersiz']; if (!(u.fr || []).includes(to) || !DB.users[to]) throw [403, 'sadece arkadaşlarını davet edebilirsin'];
    if (limited('inv:' + uid, 30, 600e3)) throw [429, 'çok fazla davet, biraz bekle'];
    const a = (INV.get(to) || []).filter(x => x.from !== uid && now() - x.t < 120e3); a.push({ from: uid, nick: u.nick, room, t: now() }); INV.set(to, a.slice(-5));
    return { ok: true };
  },
  'DELETE /me': async (b, uid) => {
    if (!uid) throw [401, 'oturum yok']; const u = DB.users[uid];
    for (const id of (u.fr || [])) { const f = DB.users[id]; if (f) f.fr = (f.fr || []).filter(x => x !== uid) }
    if (u.fc && DB.fc) delete DB.fc[u.fc]; PRES.delete(uid); INV.delete(uid);
    for (const k of Object.keys(DB.idx)) if (DB.idx[k] === uid) delete DB.idx[k];
    delete DB.users[uid]; persist(); return { ok: true, deleted: true };
  }
};
http.createServer((req, res) => {
  if (req.method === 'OPTIONS') return send(res, 204, {});
  const url = new URL(req.url, 'http://x'), key = req.method + ' ' + url.pathname.replace(/\/+$/, ''), fn = routes[key];
  if (!fn) return send(res, 404, { error: 'bulunamadı' });
  let body = '', size = 0;
  req.on('data', c => { size += c.length; if (size > 60000) { req.destroy() } else body += c });
  req.on('end', async () => {
    let b = {}; try { b = body ? JSON.parse(body) : {} } catch (e) { return send(res, 400, { error: 'geçersiz istek' }) }
    const auth = (req.headers.authorization || '').replace(/^Bearer\s+/i, ''), uid = checkToken(auth);
    const ip = (req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim();
    try { send(res, 200, await fn(b, uid, ip)) }
    catch (e) { if (Array.isArray(e)) send(res, e[0], { error: e[1] }); else { console.error(e); send(res, 500, { error: 'sunucu hatası' }) } }
  });
}).listen(CFG.port, '127.0.0.1', () => console.log('wob-api 127.0.0.1:' + CFG.port));
WOBAPI_EOF
chown wobapi:wobapi /opt/wobapi/server.js
systemctl restart wobapi
sleep 1
if [ -f /root/tavla.html ]; then
  mkdir -p /var/www/oyunlar/tavla
  cp /root/tavla.html /var/www/oyunlar/tavla/index.html
  chmod 755 /var/www/oyunlar/tavla; chmod 644 /var/www/oyunlar/tavla/index.html
  echo ">> Tavla web sürümü güncellendi"
else
  echo "!! /root/tavla.html yok — web sürümü atlandı (uygulama yine çalışır)"
fi
echo "================ GÜNCELLEME TAMAM ================"
curl -s 127.0.0.1:9100/status; echo
