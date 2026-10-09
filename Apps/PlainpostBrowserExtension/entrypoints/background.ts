import { createBackgroundMessageHandler } from '../src/api/background-coordinator';

export default defineBackground(() => {
  const handleRequest = createBackgroundMessageHandler(
    () => browser.runtime.connectNative('com.marynavdovenko.plainpost.browser'),
    browser.storage.local,
  );

  browser.runtime.onMessage.addListener(message => handleRequest(message));
});
