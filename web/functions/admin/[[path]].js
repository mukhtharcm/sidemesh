function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
}

function shortRef(referrer) {
  try {
    return new URL(referrer).hostname;
  } catch {
    return String(referrer ?? "").slice(0, 40);
  }
}

const page = (stats, rows) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>sidemesh · waitlist</title>
<meta name="robots" content="noindex,nofollow"/>
<link rel="preconnect" href="https://fonts.googleapis.com"/>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet"/>
<style>
  :root{--bg:#FAF7EF;--ink:#1A1B22;--muted:#7C7A73;--rust:#B8542A;--rule:#D4CCBA;--panel:#fff;}
  *{box-sizing:border-box;}html,body{margin:0;padding:0;}
  body{background:var(--bg);color:var(--ink);font-family:'JetBrains Mono',ui-monospace,Menlo,monospace;font-size:13px;line-height:1.55;-webkit-font-smoothing:antialiased;}
  .wrap{max-width:1240px;margin:0 auto;padding:36px 24px 72px;}
  h1{font-family:'Inter',system-ui,sans-serif;font-size:28px;letter-spacing:-0.02em;font-weight:700;margin:0 0 4px;}
  .sub{color:var(--muted);font-size:12px;margin-bottom:28px;display:flex;justify-content:space-between;align-items:center;}
  .sub a{color:var(--rust);text-decoration:none;}
  .sub a:hover{text-decoration:underline;}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin-bottom:28px;}
  .card{background:var(--panel);border:1px solid var(--rule);border-radius:8px;padding:14px 16px;}
  .card .k{font-size:10px;letter-spacing:0.12em;text-transform:uppercase;color:var(--muted);margin-bottom:6px;}
  .card .v{font-family:'Inter',system-ui,sans-serif;font-size:26px;font-weight:700;letter-spacing:-0.02em;}
  .card .v em{color:var(--rust);font-style:normal;}
  h2{font-family:'Inter',system-ui,sans-serif;font-size:15px;font-weight:600;letter-spacing:-0.005em;margin:28px 0 10px;color:var(--ink);}
  h2 span{color:var(--muted);font-weight:400;font-size:12px;margin-left:8px;}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px;margin-bottom:20px;}
  .mini{background:var(--panel);border:1px solid var(--rule);border-radius:8px;padding:10px 14px;font-size:12px;}
  .mini h2{margin-top:0;}
  .mini table{width:100%;border-collapse:collapse;}
  .mini td{padding:3px 0;}
  .mini td:last-child{text-align:right;color:var(--muted);}
  table.list{width:100%;border-collapse:collapse;font-size:12px;background:var(--panel);border:1px solid var(--rule);border-radius:8px;overflow:hidden;}
  table.list th{text-align:left;font-weight:600;padding:10px 12px;border-bottom:1px solid var(--rule);background:#F3EEDE;font-size:10px;letter-spacing:0.1em;text-transform:uppercase;color:var(--muted);}
  table.list td{padding:10px 12px;border-bottom:1px solid var(--rule);vertical-align:top;}
  table.list tr:last-child td{border-bottom:0;}
  table.list tr:hover td{background:#F7F2E4;}
  .email{font-weight:500;color:var(--ink);}
  .dim{color:var(--muted);}
  .utm{display:inline-block;background:#F0EADC;border-radius:3px;padding:1px 6px;font-size:10px;color:var(--rust);margin-right:4px;}
  .empty{padding:40px;text-align:center;color:var(--muted);background:var(--panel);border:1px dashed var(--rule);border-radius:8px;}
</style></head><body>
<div class="wrap">
  <h1>Waitlist</h1>
  <div class="sub"><span>sidemesh.dev · live from D1</span><a href="/admin/export.csv">export CSV →</a></div>

  <div class="cards">
    <div class="card"><div class="k">Total signups</div><div class="v">${stats.total}</div></div>
    <div class="card"><div class="k">Last 24h</div><div class="v"><em>${stats.last24}</em></div></div>
    <div class="card"><div class="k">Last 7d</div><div class="v">${stats.last7}</div></div>
    <div class="card"><div class="k">Countries</div><div class="v">${stats.countries}</div></div>
    <div class="card"><div class="k">w/ UTM</div><div class="v">${stats.withUtm}</div></div>
  </div>

  <div class="grid">
    <div class="mini"><h2>By country <span>top 8</span></h2><table>${stats.byCountry.map((row) => `<tr><td>${esc(row.ip_country || "—")}</td><td>${row.n}</td></tr>`).join("")}</table></div>
    <div class="mini"><h2>By ISP / org <span>top 8</span></h2><table>${stats.byOrg.map((row) => `<tr><td>${esc(row.as_org || "—")}</td><td>${row.n}</td></tr>`).join("")}</table></div>
    <div class="mini"><h2>By UTM source <span>top 8</span></h2><table>${stats.bySource.length ? stats.bySource.map((row) => `<tr><td>${esc(row.utm_source || "direct")}</td><td>${row.n}</td></tr>`).join("") : '<tr><td class="dim">no UTM signups yet</td><td></td></tr>'}</table></div>
  </div>

  <h2>All signups <span>${rows.length} rows, newest first</span></h2>
  ${rows.length === 0 ? '<div class="empty">no signups yet</div>' : `
  <table class="list">
    <thead><tr>
      <th>When (UTC)</th><th>Email</th><th>Location</th><th>ISP</th><th>Device</th><th>Source</th>
    </tr></thead>
    <tbody>${rows.map((row) => `
      <tr>
        <td class="dim">${esc(row.created_at)}</td>
        <td class="email">${esc(row.email)}</td>
        <td>${esc([row.city, row.region, row.ip_country].filter(Boolean).join(", ") || "—")}</td>
        <td class="dim">${esc(row.as_org || "—")}</td>
        <td class="dim">${esc([row.ua_platform, row.screen, row.dpr ? row.dpr + "x" : null].filter(Boolean).join(" · ") || "—")}</td>
        <td>${row.utm_source ? `<span class="utm">${esc(row.utm_source)}</span>${row.utm_medium ? `<span class="utm">${esc(row.utm_medium)}</span>` : ""}${row.utm_campaign ? `<span class="utm">${esc(row.utm_campaign)}</span>` : ""}` : row.referrer ? `<span class="dim">← ${esc(shortRef(row.referrer))}</span>` : '<span class="dim">direct</span>'}</td>
      </tr>`).join("")}
    </tbody>
  </table>`}
</div></body></html>`;

function unauth() {
  return new Response("auth required", {
    status: 401,
    headers: { "www-authenticate": 'Basic realm="sidemesh admin"', "content-type": "text/plain" },
  });
}

function checkAuth(request, env) {
  if (!env.ADMIN_PASS) return false;
  const auth = request.headers.get("authorization") || "";
  if (!auth.startsWith("Basic ")) return false;

  try {
    const decoded = atob(auth.slice(6));
    const split = decoded.indexOf(":");
    if (split < 0) return false;
    return decoded.slice(split + 1) === env.ADMIN_PASS;
  } catch {
    return false;
  }
}

export async function onRequest({ request, env, params }) {
  if (!checkAuth(request, env)) return unauth();

  const raw = params.path;
  const subpath = Array.isArray(raw) ? raw.join("/") : (raw || "");

  if (subpath === "export.csv") {
    const { results } = await env.DB.prepare(
      "SELECT email, created_at, ip_country, city, region, timezone, asn, as_org, colo, user_agent, accept_language, ua_platform, ua_mobile, screen, dpr, client_tz, referrer, utm_source, utm_medium, utm_campaign FROM waitlist ORDER BY created_at DESC"
    ).all();
    const columns = ["email", "created_at", "ip_country", "city", "region", "timezone", "asn", "as_org", "colo", "user_agent", "accept_language", "ua_platform", "ua_mobile", "screen", "dpr", "client_tz", "referrer", "utm_source", "utm_medium", "utm_campaign"];
    const csvEsc = (value) => {
      if (value == null) return "";
      const stringValue = String(value);
      return /[",\n]/.test(stringValue) ? `"${stringValue.replace(/"/g, "\"\"")}"` : stringValue;
    };
    const lines = [columns.join(","), ...results.map((row) => columns.map((column) => csvEsc(row[column])).join(","))];
    return new Response(lines.join("\n"), {
      headers: {
        "content-type": "text/csv; charset=utf-8",
        "content-disposition": `attachment; filename="sidemesh-waitlist-${new Date().toISOString().slice(0, 10)}.csv"`,
        "cache-control": "no-store",
      },
    });
  }

  const rowsPromise = env.DB.prepare(
    "SELECT email, created_at, ip_country, city, region, as_org, ua_platform, screen, dpr, referrer, utm_source, utm_medium, utm_campaign FROM waitlist ORDER BY created_at DESC LIMIT 500"
  ).all();

  const statsPromise = env.DB.batch([
    env.DB.prepare("SELECT COUNT(*) n FROM waitlist"),
    env.DB.prepare("SELECT COUNT(*) n FROM waitlist WHERE created_at >= datetime('now','-1 day')"),
    env.DB.prepare("SELECT COUNT(*) n FROM waitlist WHERE created_at >= datetime('now','-7 days')"),
    env.DB.prepare("SELECT COUNT(DISTINCT ip_country) n FROM waitlist WHERE ip_country IS NOT NULL"),
    env.DB.prepare("SELECT COUNT(*) n FROM waitlist WHERE utm_source IS NOT NULL"),
    env.DB.prepare("SELECT ip_country, COUNT(*) n FROM waitlist GROUP BY ip_country ORDER BY n DESC LIMIT 8"),
    env.DB.prepare("SELECT as_org, COUNT(*) n FROM waitlist GROUP BY as_org ORDER BY n DESC LIMIT 8"),
    env.DB.prepare("SELECT utm_source, COUNT(*) n FROM waitlist WHERE utm_source IS NOT NULL GROUP BY utm_source ORDER BY n DESC LIMIT 8"),
  ]);

  const [{ results: rows }, stats] = await Promise.all([rowsPromise, statsPromise]);

  const shapedStats = {
    total: stats[0].results[0].n,
    last24: stats[1].results[0].n,
    last7: stats[2].results[0].n,
    countries: stats[3].results[0].n,
    withUtm: stats[4].results[0].n,
    byCountry: stats[5].results,
    byOrg: stats[6].results,
    bySource: stats[7].results,
  };

  return new Response(page(shapedStats, rows), {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-robots-tag": "noindex" },
  });
}
