// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

const siteUrl = 'https://sidemesh.com';
const defaultOgImage = `${siteUrl}/assets/og-card-v1.png`;

export default defineConfig({
  site: siteUrl,
  integrations: [
    starlight({
      title: 'Sidemesh',
      logo: {
        src: './public/assets/app-icon.png',
        replacesTitle: false,
      },
      customCss: [
        "./src/styles/custom.css",
      ],
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/mukhtharcm/sidemesh' },
      ],
      head: [
        { tag: 'meta', attrs: { property: 'og:image', content: defaultOgImage } },
        { tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
        { tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
        { tag: 'meta', attrs: { name: 'twitter:image', content: defaultOgImage } },
        { tag: 'meta', attrs: { name: 'twitter:site', content: '@mukhtharcm' } },
        { tag: 'meta', attrs: { name: 'twitter:creator', content: '@mukhtharcm' } },
      ],
      sidebar: [
        {
          label: 'Getting Started',
          items: [
            { label: 'Overview', slug: 'getting-started' },
            { label: 'Install', slug: 'getting-started/install' },
            { label: 'Connect', slug: 'getting-started/connect' },
            { label: 'Daily Workflow', slug: 'getting-started/workflow' },
            { label: 'Troubleshooting', slug: 'getting-started/troubleshooting' },
          ],
        },
        {
          label: 'Providers',
          items: [
            { label: 'Overview', slug: 'providers' },
            { label: 'Comparison', slug: 'providers/comparison' },
            { label: 'Codex', slug: 'providers/codex' },
            { label: 'Pi', slug: 'providers/pi' },
            { label: 'GitHub Copilot', slug: 'providers/copilot' },
          ],
        },
        {
          label: 'Features',
          items: [
            { label: 'Overview', slug: 'features' },
            { label: 'Sessions', slug: 'features/sessions' },
            { label: 'Approvals', slug: 'features/approvals' },
            { label: 'Filesystem', slug: 'features/filesystem' },
            { label: 'Git', slug: 'features/git' },
            { label: 'Terminal', slug: 'features/terminal' },
            { label: 'Browser', slug: 'features/browser-preview' },
          ],
        },
        {
          label: 'Comparisons',
          items: [
            { label: 'Overview', slug: 'comparisons' },
            { label: 'When to Use What', slug: 'comparisons/when-to-use-what' },
          ],
        },
        {
          label: 'Security',
          items: [
            { label: 'Network Model', slug: 'security/network-model' },
            { label: 'Token Management', slug: 'security/tokens' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Provider Adapter Contract', slug: 'reference/provider-adapter-contract' },
            { label: 'API Endpoints', slug: 'reference/api' },
          ],
        },
      ],
    }),
  ],
});
