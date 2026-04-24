export async function onRequestPost({ request, env }) {
  const headers = { 'content-type': 'application/json', 'cache-control': 'no-store' };

  let email;
  try {
    const body = await request.json();
    email = (body.email || '').trim().toLowerCase();
  } catch {
    return new Response(JSON.stringify({ ok: false, error: 'bad_request' }), { status: 400, headers });
  }

  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
    return new Response(JSON.stringify({ ok: false, error: 'invalid_email' }), { status: 400, headers });
  }

  const ua = request.headers.get('user-agent')?.slice(0, 255) ?? null;
  const ref = request.headers.get('referer')?.slice(0, 255) ?? null;
  const country = request.cf?.country ?? null;

  try {
    await env.DB.prepare(
      'INSERT INTO waitlist (email, user_agent, referrer, ip_country) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(email) DO NOTHING'
    ).bind(email, ua, ref, country).run();
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, error: 'store_failed' }), { status: 500, headers });
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers });
}

export async function onRequest({ request }) {
  if (request.method !== 'POST') {
    return new Response('method not allowed', { status: 405 });
  }
}
