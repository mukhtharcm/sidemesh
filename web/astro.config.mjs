// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: "https://sidemesh.com",
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
            { label: 'Port Forwarding', slug: 'features/port-forwarding' },
            { label: 'Browser Preview', slug: 'features/browser-preview' },
          ],
        },
        {
          label: 'Comparisons',
          items: [
            { label: 'Overview', slug: 'comparisons' },
            { label: 'Terminal vs Port Forwarding', slug: 'comparisons/terminal-vs-port-forwarding' },
            { label: 'Browser vs Port Forwarding', slug: 'comparisons/browser-vs-port-forwarding' },
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
