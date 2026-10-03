import type { APIRoute } from 'astro';

const pages = ['/', '/privacy/', '/support/'];

export const GET: APIRoute = ({ site }) => {
  const urls = pages.map((path) => `<url><loc>${new URL(path, site).toString()}</loc></url>`).join('');
  const body = `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${urls}</urlset>`;
  return new Response(body, { headers: { 'Content-Type': 'application/xml' } });
};
