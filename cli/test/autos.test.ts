import { describe, expect, it } from 'vitest';
import { AUTOS, applyAuto, getAuto } from '../src/core/autos.js';

describe('AUTOS mapping table', () => {
  it('matches the documented auto ⇄ config-key table', () => {
    expect(AUTOS.map((auto) => [auto.id, auto.configKey, auto.enabledValue, auto.manualValue])).toEqual([
      ['auto_groom', 'product.enabled', true, false],
      ['orchestration_mode', 'orchestrator.mode', 'waves', 'sequential'],
      ['auto_checks', 'checks.enabled', true, false],
      ['auto_resolve', 'resolver.auto', true, false],
      ['auto_rework', 'review.auto_rework', true, false],
      ['auto_spec', 'architect.auto', true, false],
      ['auto_plan', 'engineer.auto', true, false],
      ['auto_review', 'reviewer.auto', true, false],
    ]);
  });
});

describe('getAuto', () => {
  it('throws on an unknown auto id', () => {
    expect(() => getAuto('nope' as never)).toThrow('Unknown auto');
  });
});

describe('applyAuto', () => {
  it('produces the documented enabled/manual values for boolean autos', () => {
    expect(applyAuto({}, 'auto_checks', true).checks?.enabled).toBe(true);
    expect(applyAuto({}, 'auto_checks', false).checks?.enabled).toBe(false);
    expect(applyAuto({}, 'auto_resolve', true).resolver?.auto).toBe(true);
    expect(applyAuto({}, 'auto_resolve', false).resolver?.auto).toBe(false);
    expect(applyAuto({}, 'auto_rework', true).review?.auto_rework).toBe(true);
    expect(applyAuto({}, 'auto_rework', false).review?.auto_rework).toBe(false);
    expect(applyAuto({}, 'auto_spec', true).architect?.auto).toBe(true);
    expect(applyAuto({}, 'auto_plan', true).engineer?.auto).toBe(true);
    expect(applyAuto({}, 'auto_review', true).reviewer?.auto).toBe(true);
  });

  it('maps Orchestration Mode to waves|sequential', () => {
    expect(applyAuto({}, 'orchestration_mode', true).orchestrator?.mode).toBe('waves');
    expect(applyAuto({}, 'orchestration_mode', false).orchestrator?.mode).toBe('sequential');
  });

  it('accepts an explicit mode value for orchestration_mode', () => {
    expect(applyAuto({}, 'orchestration_mode', 'sequential').orchestrator?.mode).toBe('sequential');
  });

  it('enabling Auto Groom sets product.enabled and defaults product.schedule when unset', () => {
    const result = applyAuto({}, 'auto_groom', true);
    expect(result.product?.enabled).toBe(true);
    expect(result.product?.schedule).toBe('0 9 * * *');
  });

  it('enabling Auto Groom does not clobber an existing custom schedule', () => {
    const result = applyAuto({ product: { schedule: '0 0 * * 1' } }, 'auto_groom', true);
    expect(result.product?.schedule).toBe('0 0 * * 1');
  });

  it('disabling Auto Groom only touches product.enabled', () => {
    const result = applyAuto({ product: { schedule: '0 0 * * 1' } }, 'auto_groom', false);
    expect(result.product?.enabled).toBe(false);
    expect(result.product?.schedule).toBe('0 0 * * 1');
  });

  it('is a pure transform: leaves the input config untouched', () => {
    const original = { checks: { enabled: false } };
    const result = applyAuto(original, 'auto_checks', true);
    expect(original.checks.enabled).toBe(false);
    expect(result.checks?.enabled).toBe(true);
    expect(result).not.toBe(original);
  });

  it('never touches unrelated existing keys', () => {
    const original = { command: '', defaults: { model: 'claude-sonnet-5' } };
    const result = applyAuto(original, 'auto_checks', true);
    expect(result.command).toBe('');
    expect(result.defaults).toEqual({ model: 'claude-sonnet-5' });
  });
});
