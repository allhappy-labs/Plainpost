/** @jsxImportSource preact */

import { render } from 'preact';

import { RuntimePlainpostClient } from '../../src/api/client';
import { PopupController } from '../../src/state/popup-controller';
import { App } from '../../src/ui/App';
import {
  installPopupLifecycle,
  restoreOrOpen,
  RuntimePopupLifecycleClient,
} from '../../src/ui/popup-lifecycle';
import './style.css';

const root = document.querySelector<HTMLDivElement>('#app');
if (!root) throw new Error('Popup root is missing.');

const client = new RuntimePlainpostClient(message => browser.runtime.sendMessage(message));
const lifecycleClient = new RuntimePopupLifecycleClient(
  message => browser.runtime.sendMessage(message),
);
const controller = new PopupController(client);

render(
  <App
    controller={controller}
    onRetryConnection={() => restoreOrOpen(controller, lifecycleClient)}
  />,
  root,
);
installPopupLifecycle(controller, lifecycleClient, window, {
  visibilityTarget: document,
  handoffDraft: payload => lifecycleClient.handoffDraft(payload),
});
void restoreOrOpen(controller, lifecycleClient);
