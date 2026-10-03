import type { APIRoute } from 'astro';

// Keeps the sitemap URLs that the previous site published.
export const GET: APIRoute = ({ site }) => {
  const sitemap = new URL('/sitemap-0.xml', site).toString();
  const body = `<?xml version="1.0" encoding="UTF-8"?><sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><sitemap><loc>${sitemap}</loc></sitemap></sitemapindex>`;
  return new Response(body, { headers: { 'Content-Type': 'application/xml' } });
};
