import { describe, expect, test } from 'bun:test';
import { classify, priorityGlyph } from './classify';
import type { BoardIssue, Label } from './types';

function label(name: string): Label {
  return { name, color: '0E8A16' };
}

function makeIssue(labels: string[]): BoardIssue {
  return {
    number: 1,
    title: 'Test issue',
    url: 'https://github.com/deepducks/autoducks/issues/1',
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

describe('priorityGlyph', () => {
  test.each([
    ['critical', 'critical'],
    ['Critical', 'critical'],
    ['CRITICAL', 'critical'],
    ['high', 'high'],
    ['High', 'high'],
    ['medium', 'medium'],
    ['Medium', 'medium'],
    ['low', 'low'],
    ['Low', 'low'],
  ])('maps %s -> %s', (value, expected) => {
    expect(priorityGlyph(value)).toBe(expected);
  });

  test('a custom value maps to unknown', () => {
    expect(priorityGlyph('urgent')).toBe('unknown');
  });
});

describe('classify', () => {
  test('a Review:changes issue lands in the review panel changes lane', () => {
    expect(classify(makeIssue(['Review:changes']))).toEqual({ panel: 'review', lane: 'changes' });
  });

  test('a Review:reviewing issue lands in the review panel progress lane', () => {
    expect(classify(makeIssue(['Review:reviewing']))).toEqual({ panel: 'review', lane: 'progress' });
  });
});
