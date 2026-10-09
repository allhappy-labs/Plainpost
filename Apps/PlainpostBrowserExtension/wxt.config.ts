import preact from '@preact/preset-vite';
import { defineConfig } from 'wxt';

const chromeKey = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAn6I7sCfrHxYTZ6ZvHZUERdGDiYicub+4nBQlUN1aXwoO7UHTQrVoWi7DxHCcc/uezbjnHOr+X+khmYVu5Eq2oYJ/Ld/eDxi+eaIG4gCr/3STIl0YZUdioSM7LQqJoEaksZKxHW60EuXcnGnHYEoAN8IZdEaDJp/e60JDKuE+ivzExNHYu/MueVqsDLfwPloqhd4/lrxSTzyQ4VLYCssbCq/zVhjYpUjsPx5zen0wcPcZkwego1leEU+gtCVYOO+x1pSMSgxyoktd4MPyx7EjULUQ+36YmbuBIX/g6VCjwKQhY+B0jQvg/Z7egVnKczdArxRmCgDnNY5AMj9FDaQ6BQIDAQAB';

export default defineConfig({
  suppressWarnings: { firefoxDataCollection: true },
  vite: () => ({ plugins: [preact()] }),
  manifest: ({ browser }) => ({
    name: 'Plainpost Quick Mail',
    description: 'View and reply to unread Plainpost mail from this Mac.',
    version: '0.1.0',
    permissions: ['nativeMessaging', 'storage'],
    key: browser === 'firefox' ? undefined : chromeKey,
    browser_specific_settings: browser === 'firefox'
      ? { gecko: { id: 'quick-mail@plainpost.olhapi.com', strict_min_version: '128.0' } }
      : undefined,
  }),
});
