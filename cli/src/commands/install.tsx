import type { CommandModule } from '../types.js';
import { runNotImplemented } from './not-implemented.js';

// Also resolved for the `update` command name (see core/registry.ts).
export const run: CommandModule['run'] = runNotImplemented;
