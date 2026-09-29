import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [debugPort, baseUrl, outputDir, captureSet = 'after'] =
  process.argv.slice(2);
if (!debugPort || !baseUrl || !outputDir) {
  throw new Error(
    'Usage: capture_responsive.mjs <debug-port> <base-url> <output-dir> [before|after]',
  );
}

const allCaptures = [
  ['after', 'small_iphone_390x844', 390, 844, true],
  ['after', 'large_phone_430x932', 430, 932, true],
  ['after', 'android_412x915', 412, 915, true],
  ['after', 'phone_landscape_844x390', 844, 390, true],
  ['after', 'tablet_portrait_820x1180', 820, 1180, true],
  ['after', 'desktop_1440x900', 1440, 900, false],
];
const captures =
  captureSet === 'before'
    ? [['before', 'small_iphone_390x844', 390, 844, true]]
    : allCaptures;

const delay = (milliseconds) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

async function connect() {
  let page;
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${debugPort}/json`);
      const tabs = await response.json();
      page = tabs.find(
        (tab) => tab.type === 'page' && !tab.url.startsWith('chrome-extension://'),
      );
      if (page) break;
    } catch (_) {
      // Chrome braucht beim Start einige Augenblicke.
    }
    await delay(100);
  }
  if (!page) throw new Error('Chrome DevTools ist nicht erreichbar.');

  const socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });

  let nextId = 1;
  const pending = new Map();
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    if (!message.id) return;
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    if (message.error) request.reject(new Error(message.error.message));
    else request.resolve(message.result);
  });

  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = nextId;
      nextId += 1;
      pending.set(id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params }));
    });
  return { socket, send };
}

async function waitForGame(send) {
  for (let attempt = 0; attempt < 140; attempt += 1) {
    const { result } = await send('Runtime.evaluate', {
      expression:
        "document.querySelector('flutter-view') !== null || " +
        "document.querySelector('flt-glass-pane') !== null",
      returnByValue: true,
    });
    if (result.value === true) {
      // Der produktive Einstieg initialisiert Firebase vor runApp. Das
      // Flutter-Hostelement existiert daher etwas früher als der erste
      // vollständig gezeichnete Game-Frame.
      await delay(2500);
      await send('Runtime.evaluate', {
        expression:
          "if (typeof removeSplashFromWeb === 'function') removeSplashFromWeb()",
      });
      await delay(500);
      return;
    }
    await delay(100);
  }
  throw new Error('Cat Snake wurde nicht rechtzeitig sichtbar.');
}

mkdirSync(outputDir, { recursive: true });
const { socket, send } = await connect();
await send('Page.enable');
await send('Runtime.enable');

// Ein einmaliger Warm-up-Lauf lädt CanvasKit und Firebase vollständig. So
// hängt die erste Geräteaufnahme nicht von kalten Browser-Caches ab.
await send('Emulation.setUserAgentOverride', {
  userAgent:
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140 Safari/537.36',
  platform: 'MacIntel',
});
await send('Emulation.setDeviceMetricsOverride', {
  width: 800,
  height: 600,
  deviceScaleFactor: 1,
  mobile: false,
});
await send('Page.navigate', { url: `${baseUrl}/?responsive=warmup` });
await waitForGame(send);

for (const [phase, name, width, height, mobile] of captures) {
  await send('Emulation.setUserAgentOverride', {
    userAgent: mobile
      ? 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 Chrome/140 Safari/537.36'
      : 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140 Safari/537.36',
    platform: mobile ? 'Android' : 'MacIntel',
    acceptLanguage: 'de-DE,de;q=0.9,en;q=0.8',
  });
  await send('Emulation.setDeviceMetricsOverride', {
    width,
    height,
    deviceScaleFactor: 2,
    mobile,
    screenWidth: width,
    screenHeight: height,
  });
  await send('Page.navigate', {
    url: `${baseUrl}/?responsive=${phase}-${name}-${Date.now()}`,
  });
  await waitForGame(send);
  await send('Input.dispatchKeyEvent', {
    type: 'keyDown',
    key: 'Enter',
    code: 'Enter',
    windowsVirtualKeyCode: 13,
  });
  await send('Input.dispatchKeyEvent', {
    type: 'keyUp',
    key: 'Enter',
    code: 'Enter',
    windowsVirtualKeyCode: 13,
  });
  await delay(700);
  const { data } = await send('Page.captureScreenshot', {
    format: 'png',
    fromSurface: true,
    captureBeyondViewport: false,
  });
  const fileName = `${phase}_${name}.png`;
  writeFileSync(join(outputDir, fileName), Buffer.from(data, 'base64'));
  process.stdout.write(`Erzeugt: ${fileName}\n`);
}

socket.close();
