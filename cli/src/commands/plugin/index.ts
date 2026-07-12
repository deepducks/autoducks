import type { CommandModule } from '../../types.js';

const PLUGIN_COMMANDS: Record<string, () => Promise<CommandModule>> = {
  list: () => import('./list.js'),
  install: () => import('./install.js'),
  uninstall: () => import('./install.js'),
  'install-recommended': () => import('./install-recommended.js'),
};

const PLUGIN_USAGE = 'Usage: autoducks plugin <list|install|uninstall|install-recommended> [options]';

export const run: CommandModule['run'] = async (ctx) => {
  const [sub, ...rest] = ctx.args;
  const resolve = sub ? PLUGIN_COMMANDS[sub] : undefined;

  if (!resolve) {
    process.stderr.write(`Unknown plugin subcommand: ${sub ?? '<none>'}\n${PLUGIN_USAGE}\n`);
    return 1;
  }

  const mod = await resolve();
  return mod.run({ ...ctx, command: `plugin ${sub}`, args: rest });
};
