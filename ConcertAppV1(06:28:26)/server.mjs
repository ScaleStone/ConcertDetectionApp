import { createServer } from 'node:http';
import { readFile, writeFile, mkdir, appendFile, rename } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';

const PORT = Number(process.env.PORT || 3000);
const ROOT = process.cwd();
const PUBLIC_DIR = join(ROOT, 'public');
const DATA_DIR = join(ROOT, 'data');
const STORE_FILE = join(DATA_DIR, 'store.json');
const CRISIS_LOG = join(DATA_DIR, 'crisis-audit.jsonl');
let storeWriteQueue = Promise.resolve();
let storeWriteCounter = 0;

const CRISIS_PATTERNS = [
  /\b(kill myself|end my life|take my life|suicide|suicidal)\b/i,
  /\b(self[-\s]?harm|hurt myself|cut myself|harm myself|unalive myself|end it all)\b/i,
  /\b(i can't go on|cant go on|do not want to live|don't want to live)\b/i,
  /\b(overdose|jump off|hang myself|die by suicide)\b/i,
  /\b(crisis|immediate danger|not safe with myself)\b/i,
  /\b(kms|k\s*m\s*s|si|s\s*i|sib|s\s*i\s*b|nssi|n\s*s\s*s\s*i|od|o\s*d)\b/i,
  /\b(want to|going to|gonna|might|thinking about|urge to|urges to|need to)\s+(sh|s\/h|kms|od)\b/i,
  /\b(my|these|the)\s+(sh|s\/h|si|sib|nssi)\s+(thoughts|urges|feelings|risk)\b/i
];

const mimeTypes = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml; charset=utf-8'
};

const defaultStore = {
  users: [],
  sessions: [],
  journals: [],
  sleepLogs: [],
  communityMessages: [],
  usageEvents: []
};

async function ensureStore() {
  await mkdir(DATA_DIR, { recursive: true });
  if (!existsSync(STORE_FILE)) {
    await writeFile(STORE_FILE, JSON.stringify(defaultStore, null, 2));
  }
}

async function readStore() {
  await ensureStore();
  await storeWriteQueue;
  return JSON.parse(await readFile(STORE_FILE, 'utf8'));
}

async function saveStore(store) {
  const payload = JSON.stringify(store, null, 2);
  const tempFile = `${STORE_FILE}.${Date.now()}.${storeWriteCounter++}.tmp`;
  storeWriteQueue = storeWriteQueue.then(async () => {
    await writeFile(tempFile, payload);
    await rename(tempFile, STORE_FILE);
  });
  await storeWriteQueue;
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString('utf8');
  return raw ? JSON.parse(raw) : {};
}

function sendJson(res, status, payload) {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store'
  });
  res.end(JSON.stringify(payload));
}

function hashIdentity(value = 'guest') {
  return createHash('sha256').update(value).digest('hex').slice(0, 18);
}

function detectCrisis(text = '') {
  const normalized = text
    .normalize('NFKC')
    .replace(/[._-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return CRISIS_PATTERNS.some((pattern) => pattern.test(normalized));
}

function crisisPayload() {
  return {
    crisis: true,
    resources: {
      lifeline: '988',
      textLine: 'Text HOME to 741741',
      iasp: 'https://www.iasp.info/resources/Crisis_Centres/'
    },
    message:
      'I am really glad you said something. Before we continue, please contact immediate human support now. If you are in immediate danger, call emergency services.'
  };
}

async function auditCrisis({ userId, channel, message }) {
  const entry = {
    id: randomUUID(),
    at: new Date().toISOString(),
    userHash: hashIdentity(userId),
    channel,
    messageHash: hashIdentity(message),
    matched: true
  };
  await appendFile(CRISIS_LOG, `${JSON.stringify(entry)}\n`);
}

async function generateTherapyReply({ message, mode = 'chat', context = {} }) {
  if (process.env.ANTHROPIC_API_KEY) {
    try {
      const response = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-api-key': process.env.ANTHROPIC_API_KEY,
          'anthropic-version': '2023-06-01'
        },
        body: JSON.stringify({
          model: process.env.CLAUDE_MODEL || 'claude-sonnet-4-20250514',
          max_tokens: 500,
          system: [
            'You are Serene, a warm AI mental wellness companion.',
            'Use active listening, reflective questions, and CBT-style reframing.',
            'Do not claim to be a licensed therapist.',
            'Crisis detection is handled before this call, but if a crisis appears, redirect to emergency and crisis resources first.'
          ].join(' '),
          messages: [{ role: 'user', content: message }]
        })
      });
      if (response.ok) {
        const data = await response.json();
        return data.content?.map((part) => part.text).join('\n') || fallbackReply(message, mode, context);
      }
    } catch {
      // The local fallback keeps the prototype usable when network/API access is unavailable.
    }
  }
  return fallbackReply(message, mode, context);
}

function fallbackReply(message, mode, context) {
  const sleepHint = context.sleepHours && context.sleepHours < 6.5
    ? ` I also noticed your recent sleep average is around ${context.sleepHours} hours; being tired can make emotions feel louder.`
    : '';
  const journalHint = mode === 'journal'
    ? ' One gentle prompt: what felt most true in what you wrote, and what is one small kindness you could offer yourself next?'
    : ' Would it help to name the main thought underneath this feeling, then test whether it is fully true, partly true, or asking for care?';
  return `I hear how much is in this, and I am going to stay with the feeling instead of rushing past it.${sleepHint} ${journalHint}`;
}

function requireFields(body, fields) {
  const missing = fields.filter((field) => !body[field]);
  if (missing.length) return `Missing required field(s): ${missing.join(', ')}`;
  return null;
}

async function handleApi(req, res, url) {
  const store = await readStore();

  if (req.method === 'POST' && url.pathname === '/api/auth/guest') {
    const user = {
      id: `guest-${randomUUID()}`,
      guest: true,
      email: null,
      displayName: 'Guest',
      avatar: 'sage',
      createdAt: new Date().toISOString(),
      paid: false
    };
    store.users.push(user);
    await saveStore(store);
    return sendJson(res, 201, { user });
  }

  if (req.method === 'POST' && url.pathname === '/api/auth/register') {
    const body = await readBody(req);
    const error = requireFields(body, ['email', 'password']);
    if (error) return sendJson(res, 400, { error });
    const existing = store.users.find((u) => u.email === body.email);
    if (existing) return sendJson(res, 409, { error: 'Email is already registered.' });
    const user = {
      id: `user-${randomUUID()}`,
      guest: false,
      email: body.email,
      displayName: body.displayName || body.email.split('@')[0],
      passwordHash: hashIdentity(body.password),
      avatar: body.avatar || 'sage',
      createdAt: new Date().toISOString(),
      paid: Boolean(body.paid)
    };
    store.users.push(user);
    await saveStore(store);
    return sendJson(res, 201, { user: { ...user, passwordHash: undefined } });
  }

  if (req.method === 'POST' && url.pathname === '/api/auth/login') {
    const body = await readBody(req);
    const error = requireFields(body, ['email', 'password']);
    if (error) return sendJson(res, 400, { error });
    const user = store.users.find((u) => !u.guest && u.email === body.email);
    if (!user || user.passwordHash !== hashIdentity(body.password)) {
      return sendJson(res, 401, { error: 'Email or password did not match.' });
    }
    return sendJson(res, 200, { user: { ...user, passwordHash: undefined } });
  }

  if (req.method === 'POST' && url.pathname === '/api/profile') {
    const body = await readBody(req);
    const user = store.users.find((u) => u.id === body.userId);
    if (!user) return sendJson(res, 404, { error: 'User not found.' });
    Object.assign(user, {
      displayName: body.displayName ?? user.displayName,
      avatar: body.avatar ?? user.avatar,
      paid: body.paid ?? user.paid
    });
    await saveStore(store);
    return sendJson(res, 200, { user: { ...user, passwordHash: undefined } });
  }

  if (req.method === 'POST' && url.pathname === '/api/chat') {
    const body = await readBody(req);
    const error = requireFields(body, ['userId', 'message']);
    if (error) return sendJson(res, 400, { error });
    if (detectCrisis(body.message)) {
      await auditCrisis({ userId: body.userId, channel: 'ai-chat', message: body.message });
      store.sessions.push({
        id: randomUUID(),
        userId: body.userId,
        at: new Date().toISOString(),
        userMessage: body.message,
        aiMessage: null,
        crisis: true
      });
      await saveStore(store);
      return sendJson(res, 200, crisisPayload());
    }
    const recentSleep = store.sleepLogs.filter((log) => log.userId === body.userId).slice(-7);
    const sleepHours = recentSleep.length
      ? Number((recentSleep.reduce((sum, log) => sum + log.hours, 0) / recentSleep.length).toFixed(1))
      : null;
    const aiMessage = await generateTherapyReply({ message: body.message, mode: 'chat', context: { sleepHours } });
    const session = {
      id: randomUUID(),
      userId: body.userId,
      at: new Date().toISOString(),
      userMessage: body.message,
      aiMessage,
      crisis: false
    };
    store.sessions.push(session);
    store.usageEvents.push({ userId: body.userId, type: 'chat', at: session.at });
    await saveStore(store);
    return sendJson(res, 200, { crisis: false, reply: aiMessage, session });
  }

  if (req.method === 'POST' && url.pathname === '/api/crisis-support') {
    const body = await readBody(req);
    await auditCrisis({ userId: body.userId || 'guest', channel: 'emergency-ai-support', message: body.message || 'support requested' });
    return sendJson(res, 200, {
      ...crisisPayload(),
      support:
        'First, please call or text a crisis resource now if there is any immediate risk. While you reach out, put distance between yourself and anything you could use to hurt yourself, move near another person if possible, and take one slow breath with me.'
    });
  }

  if (req.method === 'POST' && url.pathname === '/api/journal') {
    const body = await readBody(req);
    const error = requireFields(body, ['userId', 'content', 'mood']);
    if (error) return sendJson(res, 400, { error });
    if (detectCrisis(body.content)) {
      await auditCrisis({ userId: body.userId, channel: 'journal', message: body.content });
      return sendJson(res, 200, crisisPayload());
    }
    const entry = {
      id: randomUUID(),
      userId: body.userId,
      content: body.content,
      mood: body.mood,
      attachments: body.attachments || [],
      voiceMemo: body.voiceMemo || null,
      createdAt: new Date().toISOString()
    };
    store.journals.push(entry);
    store.usageEvents.push({ userId: body.userId, type: 'journal', at: entry.createdAt });
    await saveStore(store);
    return sendJson(res, 201, { entry });
  }

  if (req.method === 'POST' && url.pathname === '/api/journal/reflect') {
    const body = await readBody(req);
    if (detectCrisis(body.content || '')) {
      await auditCrisis({ userId: body.userId, channel: 'journal-reflection', message: body.content });
      return sendJson(res, 200, crisisPayload());
    }
    const reply = await generateTherapyReply({ message: body.content || '', mode: 'journal' });
    return sendJson(res, 200, { crisis: false, reply });
  }

  if (req.method === 'POST' && url.pathname === '/api/sleep') {
    const body = await readBody(req);
    const error = requireFields(body, ['userId', 'bedtime', 'wakeTime', 'quality']);
    if (error) return sendJson(res, 400, { error });
    const hours = Math.max(0, (new Date(body.wakeTime) - new Date(body.bedtime)) / 36e5);
    const log = {
      id: randomUUID(),
      userId: body.userId,
      bedtime: body.bedtime,
      wakeTime: body.wakeTime,
      quality: Number(body.quality),
      source: body.source || 'manual',
      hours: Number(hours.toFixed(1)),
      createdAt: new Date().toISOString()
    };
    store.sleepLogs.push(log);
    await saveStore(store);
    return sendJson(res, 201, { log });
  }

  if (req.method === 'POST' && url.pathname === '/api/community') {
    const body = await readBody(req);
    const error = requireFields(body, ['userId', 'room', 'message']);
    if (error) return sendJson(res, 400, { error });
    if (detectCrisis(body.message)) {
      await auditCrisis({ userId: body.userId, channel: `community:${body.room}`, message: body.message });
      return sendJson(res, 200, crisisPayload());
    }
    const user = store.users.find((u) => u.id === body.userId);
    if (!user?.paid) return sendJson(res, 402, { error: 'Peer rooms are available on the paid tier.' });
    const message = {
      id: randomUUID(),
      userId: body.userId,
      room: body.room,
      displayName: user.displayName,
      avatar: user.avatar,
      message: body.message,
      createdAt: new Date().toISOString()
    };
    store.communityMessages.push(message);
    await saveStore(store);
    return sendJson(res, 201, { message });
  }

  if (req.method === 'GET' && url.pathname === '/api/dashboard') {
    const userId = url.searchParams.get('userId');
    const entries = store.journals.filter((entry) => entry.userId === userId);
    const sleeps = store.sleepLogs.filter((entry) => entry.userId === userId);
    const sessions = store.sessions.filter((entry) => entry.userId === userId);
    const events = store.usageEvents.filter((entry) => entry.userId === userId);
    const streakDays = new Set(events.map((event) => event.at.slice(0, 10))).size;
    return sendJson(res, 200, {
      entries,
      sleeps,
      sessions,
      communityMessages: store.communityMessages,
      stats: {
        sessions: sessions.length,
        journalEntries: entries.length,
        sleepLogs: sleeps.length,
        streakDays,
        crisisFlags: sessions.filter((session) => session.crisis).length
      }
    });
  }

  return sendJson(res, 404, { error: 'API route not found.' });
}

async function serveStatic(req, res, url) {
  const pathname = url.pathname === '/' ? '/index.html' : url.pathname;
  const normalized = normalize(pathname).replace(/^(\.\.[/\\])+/, '');
  const filePath = join(PUBLIC_DIR, normalized);
  if (!filePath.startsWith(PUBLIC_DIR)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }
  try {
    const content = await readFile(filePath);
    res.writeHead(200, {
      'content-type': mimeTypes[extname(filePath)] || 'application/octet-stream'
    });
    res.end(content);
  } catch {
    const index = await readFile(join(PUBLIC_DIR, 'index.html'));
    res.writeHead(200, { 'content-type': mimeTypes['.html'] });
    res.end(index);
  }
}

await ensureStore();

createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  try {
    if (url.pathname.startsWith('/api/')) {
      await handleApi(req, res, url);
    } else {
      await serveStatic(req, res, url);
    }
  } catch (error) {
    sendJson(res, 500, { error: error.message || 'Unexpected server error.' });
  }
}).listen(PORT, () => {
  console.log(`Serene is running at http://localhost:${PORT}`);
});
