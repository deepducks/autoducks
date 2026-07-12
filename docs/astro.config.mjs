// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import svelte from '@astrojs/svelte';

export default defineConfig({
  site: 'https://autoducks.dev',
  redirects: {
    '/agents/design': '/agents/architect',
    '/agents/wave-orchestrator': '/agents/maestro',
    '/agents/execution': '/agents/developer',
    '/agents/tactical': '/agents/engineer',
    '/getting-started/first-feature': '/getting-started/first-run',
  },
  integrations: [
    starlight({
      expressiveCode: {
        themes: ['github-dark', 'github-light'],
        useStarlightUiThemeColors: true,
        styleOverrides: {
          borderRadius: '0.5rem',
        },
      },
      head: [
        {
          tag: 'script',
          attrs: { type: 'module' },
          content: `
            async function renderMermaid() {
              const el = document.querySelector('.mermaid');
              if (!el) return;
              const { default: mermaid } = await import('https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs');
              const isDark = document.documentElement.dataset.theme !== 'light';
              mermaid.initialize({ startOnLoad: false, theme: isDark ? 'dark' : 'default', securityLevel: 'loose' });
              await mermaid.run({ querySelector: '.mermaid' });
            }
            document.addEventListener('DOMContentLoaded', renderMermaid);
            new MutationObserver(renderMermaid).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
          `,
        },
      ],
      title: 'autoducks',
      logo: {
        light: './src/assets/logo-light.svg',
        dark: './src/assets/logo-dark.svg',
        replacesTitle: false,
      },
      customCss: ['./src/styles/custom.css'],
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/deepducks/autoducks',
        },
      ],
      sidebar: [
        {
          label: 'Getting started',
          items: [
            { label: 'Introduction', slug: 'getting-started/introduction' },
            { label: 'Installation', slug: 'getting-started/installation' },
            { label: 'Your first run', slug: 'getting-started/first-run' },
          ],
        },
        {
          label: 'Agents',
          items: [
            { label: 'Overview', slug: 'agents' },
            { label: 'Architect', slug: 'agents/architect' },
            { label: 'Engineer', slug: 'agents/engineer' },
            { label: 'Maestro', slug: 'agents/maestro' },
            { label: 'Developer', slug: 'agents/developer' },
            { label: 'Reviewer', slug: 'agents/reviewer' },
            { label: 'Product Owner', slug: 'agents/product' },
            { label: 'Utility commands', slug: 'agents/utilities' },
          ],
        },
        {
          label: 'Guides',
          items: [
            { label: 'Lifecycle of an issue', slug: 'guides/pipeline-lifecycle' },
            { label: 'Chaining & overrides', slug: 'guides/chaining-and-overrides' },
            { label: 'Re-running agents', slug: 'guides/re-running-agents' },
            { label: 'When things fail', slug: 'guides/when-things-fail' },
            { label: 'Customization', slug: 'guides/customization' },
            { label: 'Plugins', slug: 'guides/plugins' },
            { label: 'Migrating from /agents', slug: 'guides/migrating-from-agents' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Slash commands', slug: 'reference/slash-commands' },
            { label: 'Configuration', slug: 'reference/configuration' },
            { label: 'Labels', slug: 'reference/labels' },
            { label: 'Branch naming', slug: 'reference/branch-naming' },
            { label: 'Security', slug: 'reference/security' },
            { label: 'Runtimes', slug: 'reference/runtimes' },
          ],
        },
        {
          label: 'Tools',
          items: [
            { label: 'Dashboard', link: '/dashboard' },
          ],
        },
        {
          label: 'About',
          collapsed: true,
          items: [
            { label: 'Design philosophy', slug: 'about' },
          ],
        },
      ],
    }),
    svelte(),
  ],
});
