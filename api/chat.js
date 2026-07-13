// Vercel serverless function — proxies chatbot calls to Groq's OpenAI-compatible API
// so the API key never reaches the browser. Set GROQ_API_KEY (required) and
// GROQ_MODEL (optional) as environment variables in the Vercel project settings.
export default async function handler(req, res) {
  if (req.method !== 'POST') { res.status(405).json({ error: 'Method not allowed' }); return; }
  const apiKey = process.env.GROQ_API_KEY;
  if (!apiKey) { res.status(500).json({ error: 'GROQ_API_KEY not configured' }); return; }
  const model = process.env.GROQ_MODEL || 'llama-3.3-70b-versatile';
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
    res.status(groqRes.status).json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
}
