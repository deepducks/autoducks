import type { CommandModule } from '../types.js';
import { runNotImplemented } from './not-implemented.js';

// `-h`/`--help` is handled directly by the dispatcher (index.tsx), which
// prints the full usage block. This stub covers the bare `autoducks help`
// invocation until the dedicated help command lands.
export const run: CommandModule['run'] = runNotImplemented;
