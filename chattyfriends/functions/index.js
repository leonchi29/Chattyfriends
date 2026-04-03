const { onRequest } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');

const GROQ_API_KEY = defineSecret('GROQ_API_KEY');

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
