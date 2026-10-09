// @vitest-environment node

import { describe, expect, it } from 'vitest';

import {
  CHROME_EXTENSION_ID,
  FIREFOX_EXTENSION_ID,
  deriveChromeExtensionID,
  inspectManifest,
} from './inspect-manifest.mjs';

const chromeKey = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAn6I7sCfrHxYTZ6ZvHZUERdGDiYicub+4nBQlUN1aXwoO7UHTQrVoWi7DxHCcc/uezbjnHOr+X+khmYVu5Eq2oYJ/Ld/eDxi+eaIG4gCr/3STIl0YZUdioSM7LQqJoEaksZKxHW60EuXcnGnHYEoAN8IZdEaDJp/e60JDKuE+ivzExNHYu/MueVqsDLfwPloqhd4/lrxSTzyQ4VLYCssbCq/zVhjYpUjsPx5zen0wcPcZkwego1leEU+gtCVYOO+x1pSMSgxyoktd4MPyx7EjULUQ+36YmbuBIX/g6VCjwKQhY+B0jQvg/Z7egVnKczdArxRmCgDnNY5AMj9FDaQ6BQIDAQAB';

function chromeManifest(overrides = {}) {
  return {
    permissions: ['nativeMessaging', 'storage'],
    key: chromeKey,
    ...overrides,
  };
}

function firefoxManifest(overrides = {}) {
  return {
    permissions: ['nativeMessaging', 'storage'],
    browser_specific_settings: {
      gecko: { id: FIREFOX_EXTENSION_ID },
    },
    ...overrides,
  };
}

describe('generated manifest inspection', () => {
  it('derives the fixed Chrome extension identity from the public key', () => {
    expect(deriveChromeExtensionID(chromeKey)).toBe(CHROME_EXTENSION_ID);
    expect(() => inspectManifest(chromeManifest(), 'chrome-manifest.json', 'chrome')).not.toThrow();
  });

  it('rejects a missing required permission', () => {
    expect(() => inspectManifest(
      chromeManifest({ permissions: ['nativeMessaging'] }),
      'chrome-manifest.json',
      'chrome',
    )).toThrow(/missing required permission: storage/);
  });

  it('rejects a duplicate permission', () => {
    expect(() => inspectManifest(
      chromeManifest({ permissions: ['nativeMessaging', 'storage', 'storage'] }),
      'chrome-manifest.json',
      'chrome',
    )).toThrow(/duplicates permission: storage/);
  });

  it('rejects any Chrome public key other than the fixed release key', () => {
    expect(() => inspectManifest(
      chromeManifest({ key: Buffer.from('wrong key').toString('base64') }),
      'chrome-manifest.json',
      'chrome',
    )).toThrow('must use the fixed Chrome public key');
  });

  it('accepts the fixed Gecko identity', () => {
    expect(() => inspectManifest(firefoxManifest(), 'firefox-manifest.json', 'firefox')).not.toThrow();
  });

  it('rejects the wrong Gecko identity', () => {
    expect(() => inspectManifest(
      firefoxManifest({ browser_specific_settings: { gecko: { id: 'wrong@example.com' } } }),
      'firefox-manifest.json',
      'firefox',
    )).toThrow(`must use Gecko ID ${FIREFOX_EXTENSION_ID}`);
  });
});
