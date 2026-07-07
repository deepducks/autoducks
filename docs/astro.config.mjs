// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://autoducks.dev',
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
            { label: 'Your first feature', slug: 'getting-started/first-feature' },
          ],
        },
        {
          label: 'Agents',
          items: [
            { label: 'Overview', slug: 'agents' },
            { label: 'Design agent', slug: 'agents/design' },
            { label: 'Tactical agent', slug: 'agents/tactical' },
            { label: 'Wave orchestrator', slug: 'agents/wave-orchestrator' },
            { label: 'Execution agent', slug: 'agents/execution' },
            { label: 'Utility commands', slug: 'agents/utilities' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Slash commands', slug: 'reference/slash-commands' },
            { label: 'Configuration', slug: 'reference/configuration' },
            { label: 'Runtimes', slug: 'reference/runtimes' },
            { label: 'Branch naming', slug: 'reference/branch-naming' },
            { label: 'Security', slug: 'reference/security' },
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
  ],
});
