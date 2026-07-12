import { describe, expect, it } from 'vitest';
import { describeInstallOutcome } from '../src/commands/install.js';

describe('describeInstallOutcome', () => {
  it('continues into setup on a fresh install without --no-setup', () => {
    const outcome = describeInstallOutcome({ freshInstall: true, noSetup: false, version: 'v1.2.3' });
    expect(outcome).toEqual({ continueToSetup: true, message: 'Continuing into setup...' });
  });

  it('skips setup on a fresh install with --no-setup', () => {
    const outcome = describeInstallOutcome({ freshInstall: true, noSetup: true, version: 'v1.2.3' });
    expect(outcome.continueToSetup).toBe(false);
    expect(outcome.message).toBe('Skipping setup (--no-setup). Run `autoducks setup` to configure your repo.');
  });

  it('always stops on update with a re-run hint, regardless of --no-setup', () => {
    const withFlag = describeInstallOutcome({ freshInstall: false, noSetup: true, version: 'v1.3.0' });
    const withoutFlag = describeInstallOutcome({ freshInstall: false, noSetup: false, version: 'v1.3.0' });
    expect(withFlag.continueToSetup).toBe(false);
    expect(withoutFlag.continueToSetup).toBe(false);
    expect(withFlag.message).toBe('Updated to v1.3.0. Run `autoducks setup` to re-run setup checks.');
    expect(withoutFlag.message).toBe(withFlag.message);
  });
});
