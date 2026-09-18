const crypto = require('crypto');
const express = require('express');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { onRequest } = require('firebase-functions/v2/https');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { defineSecret } = require('firebase-functions/params');

initializeApp();
const db = getFirestore();
const app = express();
app.use(express.json({ limit: '64kb' }));

const microsoftClientId = defineSecret('MICROSOFT_CLIENT_ID');
const microsoftClientSecret = defineSecret('MICROSOFT_CLIENT_SECRET');
const oauthStateSecret = defineSecret('OAUTH_STATE_SECRET');
const tokenEncryptionKey = defineSecret('TOKEN_ENCRYPTION_KEY');
const geminiApiKey = defineSecret('GEMINI_API_KEY');
const publicBaseUrl = defineSecret('PUBLIC_BASE_URL');
const secretList = [
  microsoftClientId,
  microsoftClientSecret,
  oauthStateSecret,
  tokenEncryptionKey,
  geminiApiKey,
  publicBaseUrl,
];

const sha256 = (value) =>
  crypto.createHash('sha256').update(String(value)).digest('hex');

function timingSafeEqual(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

async function requireDevice(req, res, next) {
  try {
    const deviceId = String(req.header('x-catch-device') || '');
    const secret = String(req.header('authorization') || '').replace(/^Bearer\s+/i, '');
    if (!/^[a-f0-9]{32}$/.test(deviceId) || secret.length < 32) {
      return res.status(401).json({ message: '端末認証に失敗しました' });
    }
    const snap = await db.collection('devices').doc(deviceId).get();
    if (!snap.exists || !timingSafeEqual(snap.data().secretHash, sha256(secret))) {
      return res.status(401).json({ message: '端末認証に失敗しました' });
    }
    req.deviceId = deviceId;
    req.deviceRef = snap.ref;
    next();
  } catch (error) {
    next(error);
  }
}

app.get('/health', (_req, res) => res.json({ ok: true, service: 'Catch Cloud' }));

app.post('/register', async (req, res, next) => {
  try {
    const deviceId = String(req.header('x-catch-device') || req.body.deviceId || '');
    const secret = String(req.header('authorization') || '').replace(/^Bearer\s+/i, '');
    if (!/^[a-f0-9]{32}$/.test(deviceId) || secret.length < 32) {
      return res.status(400).json({ message: '端末情報が正しくありません' });
    }
    const ref = db.collection('devices').doc(deviceId);
    const snap = await ref.get();
    if (snap.exists && !timingSafeEqual(snap.data().secretHash, sha256(secret))) {
      return res.status(401).json({ message: 'この端末IDは既に登録されています' });
    }
    await ref.set(
      {
        secretHash: sha256(secret),
        updatedAt: FieldValue.serverTimestamp(),
        createdAt: snap.exists ? snap.data().createdAt : FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    res.json({ ok: true });
  } catch (error) {
    next(error);
  }
});

function createState(deviceId) {
  const payload = Buffer.from(JSON.stringify({ deviceId, exp: Date.now() + 10 * 60 * 1000 })).toString('base64url');
  const signature = crypto.createHmac('sha256', oauthStateSecret.value()).update(payload).digest('base64url');
  return `${payload}.${signature}`;
}

function readState(value) {
  const [payload, signature] = String(value || '').split('.');
  const expected = crypto.createHmac('sha256', oauthStateSecret.value()).update(payload || '').digest('base64url');
  if (!payload || !signature || !timingSafeEqual(signature, expected)) throw new Error('OAuth state is invalid');
  const decoded = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
  if (decoded.exp < Date.now()) throw new Error('OAuth state expired');
  return decoded;
}

function encrypt(value) {
  const key = crypto.createHash('sha256').update(tokenEncryptionKey.value()).digest();
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, tag, encrypted]).toString('base64');
}

function decrypt(value) {
  const key = crypto.createHash('sha256').update(tokenEncryptionKey.value()).digest();
  const data = Buffer.from(value, 'base64');
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, data.subarray(0, 12));
  decipher.setAuthTag(data.subarray(12, 28));
  return Buffer.concat([decipher.update(data.subarray(28)), decipher.final()]).toString('utf8');
}

app.post('/teams/connect', requireDevice, async (req, res) => {
  const redirectUri = `${publicBaseUrl.value().replace(/\/$/, '')}/teams/callback`;
  const params = new URLSearchParams({
    client_id: microsoftClientId.value(),
    response_type: 'code',
    redirect_uri: redirectUri,
    response_mode: 'query',
    scope: 'openid profile offline_access EduAssignments.ReadBasic EduRoster.ReadBasic',
    state: createState(req.deviceId),
  });
  res.json({ url: `https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize?${params}` });
});

app.get('/teams/callback', async (req, res) => {
  let state;
  try {
    state = readState(req.query.state);
    const ref = db.collection('devices').doc(state.deviceId);
    if (req.query.error) {
      await ref.set({ teamsNeedsAdminConsent: true, teamsLastError: String(req.query.error_description || req.query.error) }, { merge: true });
      return res.status(403).send('<h2>Teamsの接続には学校管理者の承認が必要です</h2><p>この画面を閉じてCatchへ戻ってください。</p>');
    }
    const redirectUri = `${publicBaseUrl.value().replace(/\/$/, '')}/teams/callback`;
    const tokenResponse = await fetch('https://login.microsoftonline.com/organizations/oauth2/v2.0/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: microsoftClientId.value(),
        client_secret: microsoftClientSecret.value(),
        grant_type: 'authorization_code',
        code: String(req.query.code || ''),
        redirect_uri: redirectUri,
        scope: 'openid profile offline_access EduAssignments.ReadBasic EduRoster.ReadBasic',
      }),
    });
    const token = await tokenResponse.json();
    if (!tokenResponse.ok || !token.refresh_token) throw new Error(token.error_description || 'Token exchange failed');
    await ref.set({
      teamsConnected: true,
      teamsNeedsAdminConsent: false,
      teamsRefreshToken: encrypt(token.refresh_token),
      teamsLastError: FieldValue.delete(),
      teamsConnectedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    await syncTeamsDevice(state.deviceId);
    res.send('<h2>TeamsをCatchへ接続しました</h2><p>この画面を閉じてCatchで「今すぐ同期」を押してください。</p>');
  } catch (error) {
    if (state?.deviceId) {
      await db.collection('devices').doc(state.deviceId).set({ teamsLastError: String(error.message || error) }, { merge: true });
    }
    res.status(500).send('<h2>Teams接続に失敗しました</h2><p>Catchへ戻って、もう一度試してください。</p>');
  }
});

async function accessTokenFor(device) {
  const response = await fetch('https://login.microsoftonline.com/organizations/oauth2/v2.0/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: microsoftClientId.value(),
      client_secret: microsoftClientSecret.value(),
      grant_type: 'refresh_token',
      refresh_token: decrypt(device.teamsRefreshToken),
      scope: 'openid profile offline_access EduAssignments.ReadBasic EduRoster.ReadBasic',
    }),
  });
  const token = await response.json();
  if (!response.ok) throw new Error(token.error_description || 'Teams token refresh failed');
  return token;
}

async function graphJson(path, accessToken) {
  const response = await fetch(`https://graph.microsoft.com/v1.0${path}`, {
    headers: { authorization: `Bearer ${accessToken}` },
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error?.message || `Graph error ${response.status}`);
  return data;
}

async function syncTeamsDevice(deviceId) {
  const ref = db.collection('devices').doc(deviceId);
  const snap = await ref.get();
  const device = snap.data();
  if (!device?.teamsConnected || !device.teamsRefreshToken) return;
  try {
    const token = await accessTokenFor(device);
    if (token.refresh_token) await ref.set({ teamsRefreshToken: encrypt(token.refresh_token) }, { merge: true });
    const classes = await graphJson('/education/me/classes?$select=id,displayName', token.access_token);
    const batch = db.batch();
    for (const schoolClass of classes.value || []) {
      const assignments = await graphJson(`/education/classes/${encodeURIComponent(schoolClass.id)}/assignments?$select=id,displayName,dueDateTime,status`, token.access_token);
      for (const assignment of assignments.value || []) {
        if (!assignment.dueDateTime || assignment.status === 'draft') continue;
        const externalId = `teams:${schoolClass.id}:${assignment.id}`;
        const taskRef = ref.collection('remoteTasks').doc(sha256(externalId));
        batch.set(taskRef, {
          externalId,
          title: assignment.displayName || 'Teamsの課題',
          subject: schoolClass.displayName || 'Microsoft Teams',
          deadline: assignment.dueDateTime,
          source: 'teams',
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    }
    batch.set(ref, { teamsLastSync: FieldValue.serverTimestamp(), teamsLastError: FieldValue.delete() }, { merge: true });
    await batch.commit();
  } catch (error) {
    await ref.set({ teamsLastError: String(error.message || error), teamsLastSync: FieldValue.serverTimestamp() }, { merge: true });
  }
}

app.post('/watches', requireDevice, async (req, res) => {
  const input = Array.isArray(req.body.watches) ? req.body.watches : [];
  const watches = input.slice(0, 30).map((item) => ({
    keyword: String(item.keyword || '').trim().slice(0, 200),
    enabled: item.enabled !== false,
  })).filter((item) => item.keyword);
  await req.deviceRef.set({ watches, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
  res.json({ ok: true, count: watches.length });
});

app.post('/ai/check', requireDevice, async (req, res, next) => {
  try {
    const snap = await req.deviceRef.get();
    for (const watch of snap.data()?.watches || []) {
      if (watch.enabled && watch.keyword) await checkWatch(req.deviceRef, watch);
    }
    const results = await req.deviceRef.collection('watchResults').orderBy('foundAt', 'desc').limit(100).get();
    res.json({
      teamsConnected: snap.data()?.teamsConnected === true,
      needsAdminConsent: snap.data()?.teamsNeedsAdminConsent === true,
      tasks: [],
      watchResults: results.docs.map((doc) => ({ id: doc.id, ...doc.data() })),
    });
  } catch (error) {
    next(error);
  }
});

app.get('/status', requireDevice, async (req, res) => {
  const snap = await req.deviceRef.get();
  const data = snap.data();
  res.json({
    teamsConnected: data.teamsConnected === true,
    needsAdminConsent: data.teamsNeedsAdminConsent === true,
    teamsLastError: data.teamsLastError || '',
  });
});

app.get('/sync', requireDevice, async (req, res) => {
  const [device, tasks, results] = await Promise.all([
    req.deviceRef.get(),
    req.deviceRef.collection('remoteTasks').limit(200).get(),
    req.deviceRef.collection('watchResults').orderBy('foundAt', 'desc').limit(100).get(),
  ]);
  const data = device.data();
  res.json({
    teamsConnected: data.teamsConnected === true,
    needsAdminConsent: data.teamsNeedsAdminConsent === true,
    tasks: tasks.docs.map((doc) => doc.data()),
    watchResults: results.docs.map((doc) => ({ id: doc.id, ...doc.data() })),
  });
});

async function checkWatch(deviceRef, watch) {
  const prompt = `次のテーマについて、直近の重要な新情報をGoogle検索で確認してください。テーマ: ${watch.keyword}\n新情報がなければ [] のみ。あれば最大3件をJSON配列 [{"title":"...","summary":"日本語で100文字以内","url":"https://..."}] のみで返してください。`;
  const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${encodeURIComponent(geminiApiKey.value())}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }], tools: [{ google_search: {} }] }),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error?.message || 'Gemini request failed');
  const raw = data.candidates?.[0]?.content?.parts?.map((part) => part.text || '').join('') || '[]';
  const jsonText = raw.replace(/^```(?:json)?/i, '').replace(/```$/i, '').trim();
  let items;
  try { items = JSON.parse(jsonText); } catch (_) { items = []; }
  if (!Array.isArray(items)) return;
  const batch = db.batch();
  for (const item of items.slice(0, 3)) {
    const title = String(item.title || '').trim();
    const url = String(item.url || '').trim();
    if (!title) continue;
    const id = sha256(`${watch.keyword}\n${title}\n${url}`);
    batch.set(deviceRef.collection('watchResults').doc(id), {
      keyword: watch.keyword,
      title,
      summary: String(item.summary || '').trim().slice(0, 500),
      url: /^https:\/\//.test(url) ? url : '',
      foundAt: new Date().toISOString(),
    }, { merge: true });
  }
  await batch.commit();
}

app.use((error, _req, res, _next) => {
  console.error(error);
  res.status(500).json({ message: 'サーバー処理に失敗しました' });
});

exports.api = onRequest({ region: 'asia-northeast1', secrets: secretList, timeoutSeconds: 120 }, app);

exports.syncTeams = onSchedule({
  schedule: 'every 15 minutes',
  region: 'asia-northeast1',
  secrets: secretList,
  timeoutSeconds: 540,
}, async () => {
  const devices = await db.collection('devices').where('teamsConnected', '==', true).get();
  for (const device of devices.docs) await syncTeamsDevice(device.id);
});

exports.checkAiWatches = onSchedule({
  schedule: 'every 60 minutes',
  region: 'asia-northeast1',
  secrets: secretList,
  timeoutSeconds: 540,
}, async () => {
  const devices = await db.collection('devices').get();
  for (const device of devices.docs) {
    for (const watch of device.data().watches || []) {
      if (watch.enabled && watch.keyword) await checkWatch(device.ref, watch);
    }
  }
});
