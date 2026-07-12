import type { CommandModule } from '../../types.js';
import { runNotImplemented } from '../not-implemented.js';

// Also resolved for the `plugin uninstall` subcommand (see index.ts).
export const run: CommandModule['run'] = runNotImplemented;
