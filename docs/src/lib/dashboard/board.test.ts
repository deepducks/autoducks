import { describe, expect, test } from 'bun:test';
import { assemblePanels } from './board';
import { PANEL_ORDER } from './classify';
import type { BoardIssue, Label } from './types';

function label(name: string): Label {
  return { name, color: '0E8A16' };
}

function makeIssue(number: number, labels: string[]): BoardIssue {
  return {
    number,
    title: `Test issue #${number}`,
    url: `https://github.com/deepducks/autoducks/issues/${number}`,
    body: '',
    type: 'feature',
    labels: labels.map(label),
    isTask: false,
    pr: null,
    subtasks: null,
    priority: null,
    branch: null,
    run: null,
    maxTurnsWarning: false,
  };
}

describe('assemblePanels', () => {
  test('a Review:changes issue lands in the review panel changes array', () => {
    const panels = assemblePanels([makeIssue(1, ['Review:changes'])]);
    const review = panels.find((p) => p.id === 'review')!;
    expect(review.changes.map((i) => i.number)).toEqual([1]);
  });

  test('changes is empty on every non-review panel', () => {
    const issues = [
      makeIssue(1, []), // inbox
      makeIssue(2, ['Design:draft']), // design
      makeIssue(3, ['Tactics:crafting']), // tactics
      makeIssue(4, ['Work:coding']), // delivery
      makeIssue(5, ['Review:changes']), // review
    ];
    const panels = assemblePanels(issues);
    for (const panel of panels) {
      if (panel.id === 'review') continue;
      expect(panel.changes).toEqual([]);
    }
    expect(PANEL_ORDER.every((id) => panels.some((p) => p.id === id))).toBe(true);
  });
});
