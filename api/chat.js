// Vercel serverless function — proxies chatbot calls to Groq's OpenAI-compatible API
// so the API key never reaches the browser. Set GROQ_API_KEY (required) and
// GROQ_MODEL (optional) as environment variables in the Vercel project settings.
export default async function handler(req, res) {
  if (req.method !== 'POST') { res.status(405).json({ error: 'Method not allowed' }); return; }
  const apiKey = process.env.GROQ_API_KEY;
  if (!apiKey) { res.status(500).json({ error: 'GROQ_API_KEY not configured' }); return; }
  // llama-3.3-70b-versatile is deprecated on Groq's free/dev tier (deprecation announced
  // 2026-06-17, cutoff 2026-08-16) — requests were already failing/rate-limiting ahead of
  // the hard cutoff, especially on larger tool-result payloads (search/list queries).
  // openai/gpt-oss-120b is Groq's recommended replacement: same 131k context, comparable
  // speed, full tool-calling support.
  const model = process.env.GROQ_MODEL || 'openai/gpt-oss-120b';
  try {
    const { messages, tools } = req.body || {};
    const groqRes = await fetch('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${apiKey}` },
      body: JSON.stringify({
        model,
        messages,
        tools,
        tool_choice: tools && tools.length ? 'auto' : undefined,
        max_tokens: 1024
      })
    });
    const data = await groqRes.json();
    if (groqRes.status === 429) {
      const retryAfter = groqRes.headers.get('retry-after');
      if (retryAfter && data && typeof data === 'object') data.retryAfter = Number(retryAfter);
    }
    res.status(groqRes.status).json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
}
