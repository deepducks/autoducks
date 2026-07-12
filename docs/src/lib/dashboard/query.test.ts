import { describe, expect, test } from 'bun:test';
import { detectMaxTurns } from './query';

// Fixtures mirror the marker shapes produced by
// .autoducks/core/feedback/notify-failure.sh (failure) and status-comment.sh
// (finished), since detectMaxTurns scans real issue-comment bodies.
function failureComment(category: string): string {
  return `⚠️ **Agent run failed.**

**Agent:** \`developer\`  ·  **Phase:** \`llm\`  ·  **Category:** \`${category}\`

The agent hit its turn limit before producing its output — nothing was committed, so re-run with a larger turn budget.

📄 [View the run logs](https://github.com/deepducks/autoducks/actions/runs/123) to see
what went wrong.

**Next:** re-run \`turns=100\`.`;
}

function finishedComment(): string {
  return '✅ **`Developer`**: finished working on [workflow #124](https://github.com/deepducks/autoducks/actions/runs/124)';
}

describe('detectMaxTurns', () => {
  test('newest comment is a max_turns failure', () => {
    expect(detectMaxTurns([failureComment('max_turns')])).toBe(true);
  });

  test('a later finished comment resolves a prior max_turns failure', () => {
    expect(detectMaxTurns([failureComment('max_turns'), finishedComment()])).toBe(false);
  });

  test('newest failure is a non-max_turns category', () => {
    expect(detectMaxTurns([failureComment('infra')])).toBe(false);
  });

  test('empty comment list', () => {
    expect(detectMaxTurns([])).toBe(false);
  });
});
