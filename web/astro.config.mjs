// @ts-check
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://sidemesh.com',
  vite: {
    build: {
      // Keep every script external: the Content-Security-Policy in
      // public/_headers allows scripts from this origin only, not inline ones.
      assetsInlineLimit: 0,
    },
  },
});
