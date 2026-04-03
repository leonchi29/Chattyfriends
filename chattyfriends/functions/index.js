const { onRequest } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const admin = require('firebase-admin');

const SUPABASE_URL_VALUE = 'https://xijruxarvehmlvzbnffn.supabase.co';
const SUPABASE_ANON_VALUE = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhpanJ1eGFydmVobWx2emJuZmZuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI2NTIyMjgsImV4cCI6MjA4ODIyODIyOH0.CvoIzfgzZLkCa9Tuix4U4sP0fp1oJjEwjn-Yuczo3Yk';

const GROQ_API_KEY = defineSecret('GROQ_API_KEY');
const PUSH_WEBHOOK_TOKEN = defineSecret('PUSH_WEBHOOK_TOKEN');

if (!admin.apps.length) {
  admin.initializeApp();
}

function cors(res) {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
}

function normalizePath(path) {
  const p = path || '/';
  if (p.startsWith('/api/')) return p.substring(4);
  if (p === '/api') return '/';
  return p;
}

async function callGroq(messages, temperature) {
  const response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: 'Bearer ' + GROQ_API_KEY.value(),
    },
    body: JSON.stringify({
      model: 'llama-3.1-8b-instant',
      temperature: typeof temperature === 'number' ? temperature : 0.4,
      messages,
    }),
  });

  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const msg = (data && data.error && data.error.message) || 'Error Groq';
    throw new Error(msg);
  }

  return (
    (data && data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content) ||
    ''
  );
}

async function supabaseSelect(path, query) {
  const url = new URL('/rest/v1/' + path, SUPABASE_URL_VALUE);
  Object.entries(query || {}).forEach(([key, value]) => {
    url.searchParams.set(key, value);
  });
  const response = await fetch(url, {
    headers: {
      apikey: SUPABASE_ANON_VALUE,
      Authorization: 'Bearer ' + SUPABASE_ANON_VALUE,
    },
  });
  if (!response.ok) {
    throw new Error('Supabase select fallo: ' + response.status);
  }
  return response.json();
}

async function getTokensForUserIds(userIds) {
  if (!userIds.length) return [];
  const ids = userIds.map((id) => '"' + id + '"').join(',');
  return supabaseSelect('device_tokens', {
    select: 'token,user_id',
    user_id: 'in.(' + ids + ')',
  });
}

async function getUsername(userId) {
  if (!userId) return 'Alguien';
  const rows = await supabaseSelect('profiles', {
    select: 'username',
    id: 'eq.' + userId,
    limit: '1',
  });
  return rows && rows[0] && rows[0].username ? rows[0].username : 'Alguien';
}

async function getGroupMembers(groupId) {
  return supabaseSelect('group_members', {
    select: 'user_id',
    group_id: 'eq.' + groupId,
  });
}

async function getGroupName(groupId) {
  const rows = await supabaseSelect('groups', {
    select: 'name',
    id: 'eq.' + groupId,
    limit: '1',
  });
  return rows && rows[0] && rows[0].name ? rows[0].name : 'Grupo';
}

async function getGroupCallCount(groupId) {
  const rows = await supabaseSelect('group_calls', {
    select: 'id',
    group_id: 'eq.' + groupId,
  });
  return Array.isArray(rows) ? rows.length : 0;
}

function buildPayload(kind, title, body, target) {
  return {
    kind,
    title,
    body,
    tag: kind + ':' + (target && target.id ? target.id : 'chatty'),
    target,
  };
}

async function sendToUserIds(userIds, payload) {
  const tokens = await getTokensForUserIds(userIds);
  const uniqueTokens = [...new Set((tokens || []).map((row) => row.token).filter(Boolean))];
  if (!uniqueTokens.length) return { sent: 0 };

  const message = {
    data: Object.fromEntries(
      Object.entries(payload).map(([key, value]) => [key, typeof value === 'string' ? value : JSON.stringify(value)])
    ),
    android: {
      priority: 'high',
    },
    tokens: uniqueTokens,
  };

  return admin.messaging().sendEachForMulticast(message);
}

async function handlePushEvent(table, record) {
  if (!table || !record) return { ignored: true };

  if (table === 'messages') {
    const sender = await getUsername(record.sender_id);
    const content = String(record.content || '');
    const body = content.startsWith('<<FILE>>') ? 'Archivo nuevo' : content.slice(0, 120);
    return sendToUserIds(
      [record.receiver_id],
      buildPayload('msg', 'Nuevo mensaje privado', sender + ': ' + body, {
        type: 'private',
        id: record.sender_id,
        name: sender,
      })
    );
  }

  if (table === 'group_messages') {
    const sender = await getUsername(record.sender_id);
    const groupName = await getGroupName(record.group_id);
    const members = await getGroupMembers(record.group_id);
    const userIds = (members || [])
      .map((row) => row.user_id)
      .filter((id) => id && id !== record.sender_id);
    const content = String(record.content || '');
    const body = content.startsWith('<<FILE>>') ? 'Archivo nuevo' : content.slice(0, 120);
    return sendToUserIds(
      userIds,
      buildPayload('grp-msg', 'Nuevo mensaje grupal', groupName + ' - ' + sender + ': ' + body, {
        type: 'group',
        id: record.group_id,
        name: groupName,
      })
    );
  }

  if (table === 'group_calls') {
    const count = await getGroupCallCount(record.group_id);
    if (count > 1) return { ignored: true, reason: 'not-first-join' };
    const caller = await getUsername(record.user_id);
    const groupName = await getGroupName(record.group_id);
    const members = await getGroupMembers(record.group_id);
    const userIds = (members || [])
      .map((row) => row.user_id)
      .filter((id) => id && id !== record.user_id);
    return sendToUserIds(
      userIds,
      buildPayload('gcall-incoming', 'Llamada grupal entrante', caller + ' inicio una llamada en ' + groupName, {
        type: 'group',
        id: record.group_id,
        name: groupName,
      })
    );
  }

  if (table === 'call_notifications') {
    const caller = await getUsername(record.caller_id);
    const isVideo = record.media_type === 'video';
    return sendToUserIds(
      [record.receiver_id],
      buildPayload(
        'call-incoming',
        isVideo ? 'Videollamada entrante' : 'Llamada entrante',
        caller + (isVideo ? ' te llama por video' : ' te esta llamando'),
        {
          type: 'private',
          id: record.caller_id,
          name: caller,
        }
      )
    );
  }

  return { ignored: true, reason: 'unknown-table' };
}

exports.api = onRequest({ secrets: [GROQ_API_KEY] }, async (req, res) => {
  cors(res);
  if (req.method === 'OPTIONS') return res.status(204).send('');
  if (req.method !== 'POST') return res.status(405).json({ error: 'Metodo no permitido' });

  const path = normalizePath(req.path);

  try {
    if (path === '/groq/chat') {
      const userMessage = (req.body && req.body.userMessage ? String(req.body.userMessage) : '').trim();
      if (!userMessage) return res.status(400).json({ error: 'userMessage requerido' });

      const reply = await callGroq(
        [
          {
            role: 'system',
            content:
              'Eres AI, un asistente amigable en un chat llamado ChattyFriends. Responde en espanol, corto y natural, como si fueras un amigo.',
          },
          { role: 'user', content: userMessage },
        ],
        0.5
      );

      return res.status(200).json({ reply: reply || 'No pude responder ahora.' });
    }

    if (path === '/groq/moderate') {
      const text = (req.body && req.body.text ? String(req.body.text) : '').trim();
      if (!text) return res.status(200).json({ allowed: true, category: 'empty', reason: '' });

      const raw = await callGroq(
        [
          {
            role: 'system',
            content:
              'Clasifica texto de chat. Detecta garabatos, spam, insultos graves, amenazas, sexual explicito, odio o contenido peligroso. Responde SOLO JSON valido con esta forma exacta: {"allowed":true|false,"category":"clean|gibberish|spam|insult|threat|sexual|hate|dangerous","reason":"motivo corto en espanol"}. allowed=false si el mensaje debe bloquearse.',
          },
          { role: 'user', content: text },
        ],
        0
      );

      let parsed = { allowed: true, category: 'clean', reason: '' };
      try {
        const match = raw.match(/\{[\s\S]*\}/);
        parsed = JSON.parse(match ? match[0] : raw);
      } catch (_) {
        parsed = { allowed: true, category: 'fallback', reason: '' };
      }

      return res.status(200).json({
        allowed: parsed.allowed !== false,
        category: parsed.category || 'clean',
        reason: parsed.reason || '',
      });
    }

    return res.status(404).json({ error: 'Ruta no encontrada' });
  } catch (e) {
    return res.status(500).json({ error: e.message || 'Error interno' });
  }
});

exports.pushWebhook = onRequest(
  {
    secrets: [PUSH_WEBHOOK_TOKEN],
  },
  async (req, res) => {
    cors(res);
    if (req.method === 'OPTIONS') return res.status(204).send('');
    if (req.method !== 'POST') return res.status(405).json({ error: 'Metodo no permitido' });
    const auth = req.get('Authorization') || '';
    if (auth !== 'Bearer ' + PUSH_WEBHOOK_TOKEN.value()) {
      return res.status(401).json({ error: 'No autorizado' });
    }

    try {
      const table = req.body && req.body.table ? String(req.body.table) : '';
      const record = req.body && req.body.record ? req.body.record : null;
      const result = await handlePushEvent(table, record);
      return res.status(200).json({ ok: true, result });
    } catch (e) {
      return res.status(500).json({ error: e.message || 'Error push' });
    }
  }
);
