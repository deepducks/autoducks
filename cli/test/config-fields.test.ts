import { describe, expect, it } from 'vitest';
import {
  buildFieldDefs,
  buildPatch,
  formatFieldValue,
  formatListForEdit,
  getByPath,
  setByPath,
  shouldRebakeTriggers,
  validateFieldInput,
} from '../src/core/config-fields.js';

describe('buildFieldDefs', () => {
  it('renders every listed field in its correct control type', () => {
    const config = {
      triggers: { architect: [], engineer: [] },
      security: { per_agent: { execute: { trusted_associations: ['OWNER'] } } },
    };
    const fields = buildFieldDefs(config);
    const byPath = Object.fromEntries(fields.map((field) => [field.path, field]));

    // Selects.
    for (const path of [
      'defaults.model',
      'defaults.effort',
      'orchestrator.mode',
      'defaults.merge_method',
      'product.confidence_threshold',
      'product.priority_backend',
    ]) {
      expect(byPath[path]?.control, path).toBe('select');
      expect(byPath[path]?.options?.length ?? 0, path).toBeGreaterThan(0);
    }

    // Toggles.
    for (const path of [
      'reviewer.required_check',
      'resolver.auto',
      'checks.enabled',
      'product.enabled',
      'product.auto_merge_duplicates',
      'review.auto_rework',
      'product.provisional_classification',
      'security.codeowners',
    ]) {
      expect(byPath[path]?.control, path).toBe('toggle');
    }

    // Text/number scalars.
    expect(byPath['command']?.control).toBe('text');
    expect(byPath['defaults.base_branch']?.control).toBe('text');
    expect(byPath['defaults.integration_branch']?.control).toBe('text');
    expect(byPath['product.schedule']?.control).toBe('text');
    expect(byPath['review.max_iterations']?.control).toBe('number');
    expect(byPath['checks.max_iterations']?.control).toBe('number');
    expect(byPath['product.max_closes_per_run']?.control).toBe('number');
    expect(byPath['product.max_issues_per_run']?.control).toBe('number');

    // Lists: static + dynamic (per-config triggers/per_agent keys).
    expect(byPath['security.trusted_associations']?.control).toBe('list');
    expect(byPath['security.allow']?.control).toBe('list');
    expect(byPath['security.deny']?.control).toBe('list');
    expect(byPath['triggers.architect']?.control).toBe('list');
    expect(byPath['triggers.engineer']?.control).toBe('list');
    expect(byPath['security.per_agent.execute.trusted_associations']?.control).toBe('list');
  });

  it('falls back to the shipped agent list when triggers is empty', () => {
    const fields = buildFieldDefs({});
    const paths = fields.map((field) => field.path);
    expect(paths).toContain('triggers.architect');
    expect(paths).toContain('triggers.merge');
  });
});

describe('getByPath / setByPath', () => {
  it('reads nested values, returning undefined for missing segments', () => {
    expect(getByPath({ a: { b: 1 } }, 'a.b')).toBe(1);
    expect(getByPath({ a: { b: 1 } }, 'a.c')).toBeUndefined();
    expect(getByPath({}, 'a.b.c')).toBeUndefined();
  });

  it('sets a nested value without mutating the source', () => {
    const source = { a: { b: 1, c: 2 } };
    const updated = setByPath(source, 'a.b', 99);
    expect(updated).toEqual({ a: { b: 99, c: 2 } });
    expect(source).toEqual({ a: { b: 1, c: 2 } });
  });
});

describe('buildPatch', () => {
  it('builds a minimal nested patch from flat dot-path changes', () => {
    const patch = buildPatch({ 'defaults.model': 'opus', command: 'ad', 'security.per_agent.execute.trusted_associations': ['OWNER'] });
    expect(patch).toEqual({
      defaults: { model: 'opus' },
      command: 'ad',
      security: { per_agent: { execute: { trusted_associations: ['OWNER'] } } },
    });
  });
});

describe('validateFieldInput', () => {
  const selectField = { path: 'defaults.effort', label: 'Default effort', control: 'select' as const, options: ['low', 'medium', 'high', 'max'] };
  const numberField = { path: 'review.max_iterations', label: 'Max iterations', control: 'number' as const, min: 1, max: 10 };
  const textField = { path: 'command', label: 'Command namespace', control: 'text' as const, pattern: /^$|^\/?[a-z0-9-]+$/ };
  const listField = { path: 'security.allow', label: 'Allow list', control: 'list' as const };
  const toggleField = { path: 'resolver.auto', label: 'Auto Resolve', control: 'toggle' as const };

  it('rejects an out-of-enum select value', () => {
    const outcome = validateFieldInput(selectField, 'turbo');
    expect(outcome.valid).toBe(false);
    expect(outcome.error).toContain('turbo');
  });

  it('accepts a valid select value', () => {
    expect(validateFieldInput(selectField, 'high')).toEqual({ valid: true, value: 'high' });
  });

  it('rejects a non-numeric number value', () => {
    const outcome = validateFieldInput(numberField, 'abc');
    expect(outcome.valid).toBe(false);
  });

  it('rejects a number outside min/max', () => {
    expect(validateFieldInput(numberField, '0').valid).toBe(false);
    expect(validateFieldInput(numberField, '11').valid).toBe(false);
    expect(validateFieldInput(numberField, '5')).toEqual({ valid: true, value: 5 });
  });

  it('rejects a text value that fails its pattern', () => {
    const outcome = validateFieldInput(textField, 'Not Valid!');
    expect(outcome.valid).toBe(false);
  });

  it('accepts an empty text value when the pattern allows it', () => {
    expect(validateFieldInput(textField, '')).toEqual({ valid: true, value: '' });
  });

  it('splits and trims a comma-separated list value', () => {
    expect(validateFieldInput(listField, 'OWNER, MEMBER ,, COLLABORATOR')).toEqual({
      valid: true,
      value: ['OWNER', 'MEMBER', 'COLLABORATOR'],
    });
  });

  it('coerces a toggle value to boolean', () => {
    expect(validateFieldInput(toggleField, true)).toEqual({ valid: true, value: true });
    expect(validateFieldInput(toggleField, false)).toEqual({ valid: true, value: false });
  });
});

describe('shouldRebakeTriggers', () => {
  it('re-bakes when command changed', () => {
    expect(shouldRebakeTriggers(['command'])).toBe(true);
  });

  it('re-bakes when a triggers.* field changed', () => {
    expect(shouldRebakeTriggers(['triggers.architect'])).toBe(true);
  });

  it('does not re-bake for an unrelated field change', () => {
    expect(shouldRebakeTriggers(['defaults.model', 'product.enabled'])).toBe(false);
  });

  it('does not re-bake when nothing changed', () => {
    expect(shouldRebakeTriggers([])).toBe(false);
  });
});

describe('formatFieldValue / formatListForEdit', () => {
  it('formats toggles as Yes/No', () => {
    expect(formatFieldValue({ path: 'x', label: 'X', control: 'toggle' }, true)).toBe('Yes');
    expect(formatFieldValue({ path: 'x', label: 'X', control: 'toggle' }, false)).toBe('No');
  });

  it('formats empty lists as (none) and non-empty lists joined', () => {
    expect(formatFieldValue({ path: 'x', label: 'X', control: 'list' }, [])).toBe('(none)');
    expect(formatFieldValue({ path: 'x', label: 'X', control: 'list' }, ['a', 'b'])).toBe('a, b');
  });

  it('formats unset scalars as (unset)', () => {
    expect(formatFieldValue({ path: 'x', label: 'X', control: 'text' }, undefined)).toBe('(unset)');
    expect(formatFieldValue({ path: 'x', label: 'X', control: 'text' }, '')).toBe('(unset)');
  });

  it('joins an array for editing, and empty string for non-arrays', () => {
    expect(formatListForEdit(['a', 'b'])).toBe('a, b');
    expect(formatListForEdit(undefined)).toBe('');
  });
});
