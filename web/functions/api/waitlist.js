export async function onRequestPost({ request, env }) {
  const headers = { 'content-type': 'application/json', 'cache-control': 'no-store' };

  let body;
  try {
    body = await request.json();
  } catch {
    return new Response(JSON.stringify({ ok: false, error: 'bad_request' }), { status: 400, headers });
  }

  const email = (body.email || '').trim().toLowerCase();
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
    return new Response(JSON.stringify({ ok: false, error: 'invalid_email' }), { status: 400, headers });
  }

  // Turnstile verification (skipped if TURNSTILE_SECRET is unset, e.g. in local dev)
  if (env.TURNSTILE_SECRET) {
    const token = body.ts_token;
    if (!token || typeof token !== 'string') {
      return new Response(JSON.stringify({ ok: false, error: 'captcha_missing' }), { status: 400, headers });
    }
    const ip = request.headers.get('cf-connecting-ip') || '';
    const form = new FormData();
    form.append('secret', env.TURNSTILE_SECRET);
    form.append('response', token);
    if (ip) form.append('remoteip', ip);
    const verify = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
      method: 'POST',
      body: form,
    });
    const v = await verify.json().catch(() => ({ success: false }));
    if (!v.success) {
      return new Response(JSON.stringify({ ok: false, error: 'captcha_failed' }), { status: 403, headers });
    }
  }

  const trim = (v, n = 255) => (typeof v === 'string' ? v.slice(0, n) : null);
  const h = request.headers;
  const cf = request.cf || {};

  const row = {
    email,
    user_agent: trim(h.get('user-agent')),
    referrer: trim(h.get('referer')),
    ip_country: trim(cf.country, 8),
    city: trim(cf.city, 120),
    region: trim(cf.region, 120),
    timezone: trim(cf.timezone, 64),
    asn: Number.isFinite(cf.asn) ? cf.asn : null,
    as_org: trim(cf.asOrganization, 200),
    colo: trim(cf.colo, 16),
    accept_language: trim(h.get('accept-language'), 120),
    ua_platform: trim(h.get('sec-ch-ua-platform')?.replace(/"/g, ''), 40),
    ua_mobile: trim(h.get('sec-ch-ua-mobile'), 8),
    screen: trim(body.screen, 32),
    dpr: typeof body.dpr === 'number' && body.dpr > 0 && body.dpr < 10 ? body.dpr : null,
    client_tz: trim(body.tz, 64),
    utm_source: trim(body.utm_source, 80),
    utm_medium: trim(body.utm_medium, 80),
    utm_campaign: trim(body.utm_campaign, 120),
  };

  try {
    await env.DB.prepare(
      `INSERT INTO waitlist (
         email, user_agent, referrer, ip_country, city, region, timezone,
         asn, as_org, colo, accept_language, ua_platform, ua_mobile,
         screen, dpr, client_tz, utm_source, utm_medium, utm_campaign
       ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19)
       ON CONFLICT(email) DO NOTHING`
    ).bind(
      row.email, row.user_agent, row.referrer, row.ip_country, row.city, row.region, row.timezone,
      row.asn, row.as_org, row.colo, row.accept_language, row.ua_platform, row.ua_mobile,
      row.screen, row.dpr, row.client_tz, row.utm_source, row.utm_medium, row.utm_campaign
    ).run();
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

