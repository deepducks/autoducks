#!/usr/bin/env node
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { parseArgv } from './core/args.js';
import { resolveCommand } from './core/registry.js';
import { USAGE } from './core/usage.js';

export async function main(argv: string[]): Promise<number> {
  const { command, args, options } = parseArgv(argv);

  if (options.help) {
    process.stdout.write(`${USAGE}\n`);
    return 0;
  }

  if (!command) {
    process.stderr.write(`Missing command.\n\n${USAGE}\n`);
    return 1;
  }

  const resolve = resolveCommand(command);
  if (!resolve) {
    process.stderr.write(`Unknown command: ${command}\n\n${USAGE}\n`);
    return 1;
  }

  const isInteractive = Boolean(process.stdout.isTTY) && !options.noInput;
  const mod = await resolve();
  return mod.run({ command, args, options, isInteractive });
}

const isDirectlyExecuted = process.argv[1] !== undefined && fileURLToPath(import.meta.url) === process.argv[1];

if (isDirectlyExecuted) {
  main(process.argv.slice(2))
    .then((code) => {
      process.exitCode = code;
    })
    .catch((err) => {
      console.error(err instanceof Error ? err.message : err);
      process.exitCode = 1;
    });
}
