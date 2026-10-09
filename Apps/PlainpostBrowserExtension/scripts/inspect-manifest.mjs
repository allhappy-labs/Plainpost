import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const manifestURLs = [
  { browser: 'chrome', url: new URL('../.output/chrome-mv3/manifest.json', import.meta.url) },
  { browser: 'firefox', url: new URL('../.output/firefox-mv2/manifest.json', import.meta.url) },
];
const requiredPermissions = ['nativeMessaging', 'storage'];
const requiredPermissionSet = new Set(requiredPermissions);

export const CHROME_EXTENSION_ID = 'fjhlbghobimgnakkhigjmjejahjackfo';
export const CHROME_PUBLIC_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAn6I7sCfrHxYTZ6ZvHZUERdGDiYicub+4nBQlUN1aXwoO7UHTQrVoWi7DxHCcc/uezbjnHOr+X+khmYVu5Eq2oYJ/Ld/eDxi+eaIG4gCr/3STIl0YZUdioSM7LQqJoEaksZKxHW60EuXcnGnHYEoAN8IZdEaDJp/e60JDKuE+ivzExNHYu/MueVqsDLfwPloqhd4/lrxSTzyQ4VLYCssbCq/zVhjYpUjsPx5zen0wcPcZkwego1leEU+gtCVYOO+x1pSMSgxyoktd4MPyx7EjULUQ+36YmbuBIX/g6VCjwKQhY+B0jQvg/Z7egVnKczdArxRmCgDnNY5AMj9FDaQ6BQIDAQAB';
export const FIREFOX_EXTENSION_ID = 'quick-mail@plainpost.olhapi.com';

export function deriveChromeExtensionID(publicKey) {
  assert(typeof publicKey === 'string' && publicKey.length > 0, 'Chrome manifest has no public key');
  const digest = createHash('sha256').update(Buffer.from(publicKey, 'base64')).digest();
  return Array.from(digest.subarray(0, 16), byte => (
    `${String.fromCharCode(97 + (byte >> 4))}${String.fromCharCode(97 + (byte & 0x0f))}`
  )).join('');
}

export function inspectManifest(manifest, manifestPath, browser) {
  assert(Array.isArray(manifest.permissions), `${manifestPath} has no permissions array`);

  const permissions = new Set();
  for (const permission of manifest.permissions) {
    assert(typeof permission === 'string', `${manifestPath} has a non-string permission`);
    assert(!permissions.has(permission), `${manifestPath} duplicates permission: ${permission}`);
    assert(requiredPermissionSet.has(permission), `${manifestPath} requests an unexpected permission: ${permission}`);
    permissions.add(permission);
  }
  for (const permission of requiredPermissions) {
    assert(permissions.has(permission), `${manifestPath} is missing required permission: ${permission}`);
  }

  assert(!manifest.host_permissions, `${manifestPath} requests host permissions`);
  assert(!manifest.content_scripts, `${manifestPath} registers content scripts`);
  assert(!manifest.externally_connectable, `${manifestPath} is externally connectable`);

  if (browser === 'chrome') {
    assert.equal(
      manifest.key,
      CHROME_PUBLIC_KEY,
      `${manifestPath} must use the fixed Chrome public key`,
    );
    const extensionID = deriveChromeExtensionID(manifest.key);
    assert.equal(
      extensionID,
      CHROME_EXTENSION_ID,
      `${manifestPath} must derive Chrome extension ID ${CHROME_EXTENSION_ID}`,
    );
    return;
  }

  assert.equal(
    manifest.browser_specific_settings?.gecko?.id,
    FIREFOX_EXTENSION_ID,
    `${manifestPath} must use Gecko ID ${FIREFOX_EXTENSION_ID}`,
  );
}

export async function inspectGeneratedManifests() {
  for (const { browser, url } of manifestURLs) {
    const manifest = JSON.parse(await readFile(url, 'utf8'));
    inspectManifest(manifest, url.pathname, browser);
    const identity = browser === 'chrome'
      ? `chrome_id=${deriveChromeExtensionID(manifest.key)}`
      : `gecko_id=${manifest.browser_specific_settings.gecko.id}`;
    console.log(`${url.pathname}: permissions=${manifest.permissions.join(',')} ${identity}`);
  }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  await inspectGeneratedManifests();
}
