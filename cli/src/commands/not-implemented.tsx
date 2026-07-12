import React from 'react';
import { render, Text } from 'ink';
import type { CommandContext } from '../types.js';

function NotImplemented({ command }: { command: string }) {
  return <Text>autoducks {command}: not implemented yet.</Text>;
}

/** Shared stub body: renders "not implemented yet" for `ctx.command` and exits 0. */
export async function runNotImplemented(ctx: CommandContext): Promise<number> {
  const { waitUntilExit } = render(<NotImplemented command={ctx.command} />);
  await waitUntilExit();
  return 0;
}
