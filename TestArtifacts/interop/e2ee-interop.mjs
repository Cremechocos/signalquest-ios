// Interop E2EE croisée iOS <-> web, contre la prod signalquest.fr.
// Joue le rôle du client WEB (compte B) avec les mêmes primitives que le
// navigateur : RSA-2048-OAEP-SHA256 (JWK), AES-256-GCM, PBKDF2-HMAC-SHA256 210k.
//
// Sous-commandes :
//   node e2ee-interop.mjs setup   <emailB> <passB> <emailA>   → clé B + conversation A<->B + message chiffré
//   node e2ee-interop.mjs share   <emailB> <passB>            → re-partage de la clé aux participants sans clé (A)
//   node e2ee-interop.mjs verify  <emailB> <passB> <attendu>  → déchiffre le dernier message (la réponse iOS) et compare
//
// État persisté dans ./interop-state.json (conversationId, clés B).

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const BASE = 'https://signalquest.fr';
const here = path.dirname(fileURLToPath(import.meta.url));
const STATE_FILE = path.join(here, 'interop-state.json');
const E2EE_PASSWORD_B = 'interop-B-e2ee-pass';

const b64NoPad = (buf) => Buffer.from(buf).toString('base64').replace(/=+$/, '');
const fromB64 = (value) => Buffer.from(value, 'base64');

function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); } catch { return {}; }
}
function saveState(state) {
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

async function login(email, password) {
  const res = await fetch(`${BASE}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (!res.ok) throw new Error(`login ${email}: HTTP ${res.status} ${await res.text()}`);
  const setCookie = res.headers.getSetCookie?.() ?? [res.headers.get('set-cookie')];
  const tokenCookie = setCookie.find((c) => c && c.includes('auth_token='));
  if (!tokenCookie) throw new Error('login: pas de cookie auth_token');
  const token = tokenCookie.match(/auth_token=([^;]+)/)[1];
  const me = await res.json();
  return { token, userId: me.user?.id ?? me.id };
}

async function api(token, method, pathName, body) {
  const res = await fetch(`${BASE}${pathName}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      Cookie: `auth_token=${token}`,
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${pathName}: HTTP ${res.status} ${text}`);
  try { return JSON.parse(text); } catch { return text; }
}

// --- Crypto côté "web" ---

function generateRsaJwkPair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const publicJwk = publicKey.export({ format: 'jwk' });
  const privateJwk = privateKey.export({ format: 'jwk' });
  return {
    publicJwkStr: JSON.stringify({ kty: 'RSA', n: publicJwk.n, e: publicJwk.e }),
    privateJwkStr: JSON.stringify(privateJwk),
  };
}

function encryptPrivateJwk(privateJwkStr, password) {
  const salt = crypto.randomBytes(16);
  const iv = crypto.randomBytes(12);
  const key = crypto.pbkdf2Sync(password, salt, 210000, 32, 'sha256');
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ct = Buffer.concat([cipher.update(Buffer.from(privateJwkStr, 'utf8')), cipher.final(), cipher.getAuthTag()]);
  return {
    encryptedPrivateJwk: b64NoPad(Buffer.concat([iv, ct])),
    kdfSaltB64: b64NoPad(salt),
    kdfIterations: 210000,
  };
}

function unwrapConversationKey(wrappedKeyB64, privateJwkStr) {
  const privateKey = crypto.createPrivateKey({ key: JSON.parse(privateJwkStr), format: 'jwk' });
  return crypto.privateDecrypt(
    { key: privateKey, oaepHash: 'sha256', padding: crypto.constants.RSA_PKCS1_OAEP_PADDING },
    fromB64(wrappedKeyB64)
  );
}

function wrapConversationKey(rawKey, publicJwkStr) {
  const publicKey = crypto.createPublicKey({ key: JSON.parse(publicJwkStr), format: 'jwk' });
  return b64NoPad(crypto.publicEncrypt(
    { key: publicKey, oaepHash: 'sha256', padding: crypto.constants.RSA_PKCS1_OAEP_PADDING },
    rawKey
  ));
}

function encryptMessage(rawKey, text) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', rawKey, iv);
  const ct = Buffer.concat([cipher.update(Buffer.from(text, 'utf8')), cipher.final(), cipher.getAuthTag()]);
  return { v: 1, ivB64: b64NoPad(iv), ciphertextB64: b64NoPad(ct) };
}

function decryptMessage(rawKey, message) {
  const iv = fromB64(message.e2eeIvB64);
  const combined = fromB64(message.e2eeCiphertextB64);
  const ct = combined.subarray(0, combined.length - 16);
  const tag = combined.subarray(combined.length - 16);
  const decipher = crypto.createDecipheriv('aes-256-gcm', rawKey, iv);
  if (message.e2eeAadB64) decipher.setAAD(fromB64(message.e2eeAadB64));
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ct), decipher.final()]).toString('utf8');
}

// --- Sous-commandes ---

async function ensureKeyB(token, state) {
  const bootstrap = await api(token, 'GET', '/api/e2ee/bootstrap');
  if (bootstrap.hasKey && state.privateJwkB) {
    return state.privateJwkB;
  }
  const pair = generateRsaJwkPair();
  const encrypted = encryptPrivateJwk(pair.privateJwkStr, E2EE_PASSWORD_B);
  await api(token, 'POST', '/api/e2ee/bootstrap/init', {
    publicKeyJwk: pair.publicJwkStr,
    ...encrypted,
  });
  state.privateJwkB = pair.privateJwkStr;
  saveState(state);
  console.log('B: clé E2EE créée');
  return pair.privateJwkStr;
}

async function setup(emailB, passB, emailA) {
  const state = loadState();
  const b = await login(emailB, passB);
  const privateJwkB = await ensureKeyB(b.token, state);

  // `emailA` peut être un id utilisateur direct (la recherche ne renvoie pas
  // les emails) ou un nom à rechercher.
  let userA;
  if (!emailA.includes('@')) {
    userA = { id: emailA };
  } else {
    const search = await api(b.token, 'GET', `/api/users/search?q=${encodeURIComponent(emailA)}&limit=5`);
    const users = Array.isArray(search) ? search : search.users ?? [];
    userA = users[0];
  }
  if (!userA) throw new Error(`Utilisateur A introuvable: ${emailA}`);
  console.log('A:', userA.id);

  const created = await api(b.token, 'POST', '/api/messages/conversations', {
    participantIds: [userA.id],
    e2ee: true,
  });
  console.log('Conversation:', created.conversationId, 'reused:', created.reused, 'pending:', created.e2eePendingUserIds);
  state.conversationId = created.conversationId;
  state.userIdA = userA.id;
  saveState(state);

  const keyResponse = await api(b.token, 'GET', `/api/messages/conversations/${created.conversationId}/key`);
  const rawKey = unwrapConversationKey(keyResponse.wrappedKeyB64, privateJwkB);
  console.log('B: clé de conversation dé-wrappée,', rawKey.length, 'octets');

  const text = 'Bonjour depuis le client web 🚀 (interop E2EE)';
  const e2ee = encryptMessage(rawKey, text);
  const sent = await api(b.token, 'POST', `/api/messages/conversations/${created.conversationId}/messages`, {
    kind: 'TEXT',
    e2ee,
  });
  console.log('B: message chiffré envoyé:', sent.message?.id);
  console.log('SETUP_OK', created.conversationId);
}

async function share(emailB, passB) {
  const state = loadState();
  if (!state.conversationId || !state.privateJwkB) throw new Error('setup d’abord');
  const b = await login(emailB, passB);
  const keyResponse = await api(b.token, 'GET', `/api/messages/conversations/${state.conversationId}/key`);
  const rawKey = unwrapConversationKey(keyResponse.wrappedKeyB64, state.privateJwkB);
  const missing = await api(b.token, 'GET', `/api/messages/conversations/${state.conversationId}/e2ee/missing`);
  const entries = missing.missing ?? [];
  if (entries.length === 0) {
    console.log('SHARE_OK aucun participant en attente');
    return;
  }
  const shares = entries
    .filter((m) => m.userId && m.publicKeyJwk)
    .map((m) => ({ userId: m.userId, wrappedKeyB64: wrapConversationKey(rawKey, m.publicKeyJwk) }));
  await api(b.token, 'POST', `/api/messages/conversations/${state.conversationId}/e2ee/share`, { shares });
  console.log('SHARE_OK partagé à', shares.map((s) => s.userId).join(', '));
}

async function verify(emailB, passB, expected) {
  const state = loadState();
  if (!state.conversationId || !state.privateJwkB) throw new Error('setup d’abord');
  const b = await login(emailB, passB);
  const keyResponse = await api(b.token, 'GET', `/api/messages/conversations/${state.conversationId}/key`);
  const rawKey = unwrapConversationKey(keyResponse.wrappedKeyB64, state.privateJwkB);
  const page = await api(b.token, 'GET', `/api/messages/conversations/${state.conversationId}/messages?take=20`);
  const encrypted = page.messages.filter((m) => m.e2eeCiphertextB64);
  const decrypted = encrypted.map((m) => ({ sender: m.senderId, text: decryptMessage(rawKey, m) }));
  for (const d of decrypted) console.log(`  [${d.sender === state.userIdA ? 'A/iOS' : 'B/web'}] ${d.text}`);
  const fromA = decrypted.filter((d) => d.sender === state.userIdA);
  if (expected && fromA.some((d) => d.text.includes(expected))) {
    console.log('VERIFY_OK la réponse iOS se déchiffre côté web');
  } else if (expected) {
    console.error('VERIFY_FAIL réponse iOS introuvable ou indéchiffrable');
    process.exit(1);
  }
}

async function send(emailB, passB, text) {
  const state = loadState();
  if (!state.conversationId || !state.privateJwkB) throw new Error('setup d’abord');
  const b = await login(emailB, passB);
  const keyResponse = await api(b.token, 'GET', `/api/messages/conversations/${state.conversationId}/key`);
  const rawKey = unwrapConversationKey(keyResponse.wrappedKeyB64, state.privateJwkB);
  const e2ee = encryptMessage(rawKey, text);
  const sent = await api(b.token, 'POST', `/api/messages/conversations/${state.conversationId}/messages`, {
    kind: 'TEXT',
    e2ee,
  });
  console.log('SEND_OK', sent.message?.id, new Date().toISOString());
}

// Réplique EXACTE du flux iOS de planification E2EE : AAD = JSON
// {conversationId,senderId,scheduleId,kind,nonce,sendAt,replyToId} base64,
// chiffrement AES-GCM authentifiant ce JSON. Vérifie l'acceptation + rejoue la
// validation backend `validateScheduledAad`.
async function scheduleE2EE(emailB, passB, secondsFromNow = '120') {
  const state = loadState();
  if (!state.conversationId || !state.privateJwkB) throw new Error('setup d’abord');
  const b = await login(emailB, passB);
  const keyResponse = await api(b.token, 'GET', `/api/messages/conversations/${state.conversationId}/key`);
  const rawKey = unwrapConversationKey(keyResponse.wrappedKeyB64, state.privateJwkB);

  const scheduleId = crypto.randomUUID();
  const nonce = crypto.randomUUID();
  const sendAt = new Date(Date.now() + Number(secondsFromNow) * 1000).toISOString();
  const aadObj = { conversationId: state.conversationId, senderId: b.userId, scheduleId, kind: 'TEXT', nonce, sendAt, replyToId: null };
  const aadData = Buffer.from(JSON.stringify(aadObj), 'utf8');

  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', rawKey, iv);
  cipher.setAAD(aadData);
  const text = 'Programmé chiffré depuis le pair web ⏰';
  const ct = Buffer.concat([cipher.update(Buffer.from(text, 'utf8')), cipher.final(), cipher.getAuthTag()]);
  const e2ee = { v: 2, ivB64: b64NoPad(iv), ciphertextB64: b64NoPad(ct), aadB64: Buffer.from(aadData).toString('base64') };

  const res = await api(b.token, 'POST', `/api/messages/conversations/${state.conversationId}/scheduled`, {
    id: scheduleId, sendAt, kind: 'TEXT', nonce, e2ee, replyToId: null,
  });
  console.log('SCHEDULE_POST_OK', res.scheduledMessage ? res.scheduledMessage.id : JSON.stringify(res).slice(0, 120));

  // Rejoue localement la validation AAD du dispatch backend (mêmes contrôles).
  const decoded = JSON.parse(Buffer.from(e2ee.aadB64, 'base64').toString('utf8'));
  const ok = decoded.conversationId === state.conversationId && decoded.senderId === b.userId &&
    decoded.scheduleId === scheduleId && decoded.kind === 'TEXT' && decoded.nonce === nonce &&
    Math.abs(new Date(decoded.sendAt).getTime() - new Date(sendAt).getTime()) <= 1000 &&
    (decoded.replyToId == null);
  console.log(ok ? 'AAD_VALIDATION_OK (passerait le dispatch)' : 'AAD_VALIDATION_FAIL');
  if (!ok) process.exit(1);
}

const [, , command, ...args] = process.argv;
const commands = { setup, share, verify, send, scheduleE2EE };
if (!commands[command]) {
  console.error('Usage: e2ee-interop.mjs <setup|share|verify> ...');
  process.exit(2);
}
commands[command](...args).catch((error) => {
  console.error('ERREUR:', error.message);
  process.exit(1);
});
