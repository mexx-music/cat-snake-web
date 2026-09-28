import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [debugPort, baseUrl, outputDir] = process.argv.slice(2);
if (!debugPort || !baseUrl || !outputDir) {
  throw new Error('Usage: capture_promo.mjs <debug-port> <base-url> <output-dir>');
}

const captures = [
  ['clean-start', 'de', 720, 1280, '01_clean_start_de_9x16.png'],
  ['early-gameplay', 'de', 720, 1280, '02_early_gameplay_de_9x16.png'],
  ['medium-snake', 'de', 720, 1280, '03_medium_snake_de_9x16.png'],
  ['long-snake', 'de', 720, 1280, '04_long_snake_de_9x16.png'],
  ['curve-showcase', 'de', 720, 1280, '05_curve_showcase_de_9x16.png'],
  ['high-score', 'de', 720, 1280, '06_high_score_de_9x16.png'],
  ['mouse-bonus', 'de', 720, 1280, '07_mouse_bonus_de_9x16.png'],
  ['game-over', 'de', 720, 1280, '08_game_over_de_9x16.png'],
  ['long-snake', 'en', 720, 1280, '09_long_snake_en_9x16.png'],
  ['curve-showcase', 'en', 720, 1280, '10_curve_showcase_en_9x16.png'],
  ['mouse-bonus', 'en', 720, 1280, '11_mouse_bonus_en_9x16.png'],
  ['long-snake', 'de', 1280, 720, '12_long_snake_de_16x9.png'],
  ['mouse-bonus', 'de', 1280, 720, '13_mouse_bonus_de_16x9.png'],
];

const delay = (milliseconds) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

async function connect() {
  let tabs;
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${debugPort}/json`);
      tabs = await response.json();
      if (tabs.some((tab) => tab.type === 'page' && !tab.url.startsWith('chrome-extension://'))) {
        break;
      }
    } catch (_) {
      // Chrome braucht beim Start einige Augenblicke.
    }
    await delay(100);
  }
  const page = tabs?.find(
    (tab) => tab.type === 'page' && !tab.url.startsWith('chrome-extension://'),
  );
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

async function waitForGame(send, scene) {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    const { result } = await send('Runtime.evaluate', {
      expression:
        "document.querySelector('flutter-view') !== null || " +
        "document.querySelector('flt-glass-pane') !== null",
      returnByValue: true,
    });
    if (result.value === true) {
      await send('Runtime.evaluate', {
        expression:
          "if (typeof removeSplashFromWeb === 'function') removeSplashFromWeb()",
      });
      await delay(scene === 'game-over' ? 1000 : 500);
      return;
    }
    await delay(100);
  }
  const diagnostic = await send('Runtime.evaluate', {
    expression:
      "JSON.stringify({url: location.href, splash: !!document.getElementById('splash'), " +
      "html: document.body.innerHTML.slice(0, 500)})",
    returnByValue: true,
  });
  throw new Error(
    `Catsnake wurde für Szene ${scene} nicht rechtzeitig sichtbar: ${diagnostic.result.value}`,
  );
}

mkdirSync(outputDir, { recursive: true });
const { socket, send } = await connect();
await send('Page.enable');
await send('Runtime.enable');
await send('Emulation.setUserAgentOverride', {
  userAgent:
    'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 Chrome/140 Safari/537.36',
  platform: 'Android',
  acceptLanguage: 'de-DE,de;q=0.9,en;q=0.8',
});

for (const [scene, language, width, height, fileName] of captures) {
  await send('Emulation.setDeviceMetricsOverride', {
    width,
    height,
    deviceScaleFactor: 2,
    mobile: true,
    screenWidth: width,
    screenHeight: height,
  });
  const url = `${baseUrl}/?scene=${scene}&lang=${language}&capture=${Date.now()}`;
  await send('Page.navigate', { url });
  await waitForGame(send, scene);
  const { data } = await send('Page.captureScreenshot', {
    format: 'png',
    fromSurface: true,
    captureBeyondViewport: false,
  });
  writeFileSync(join(outputDir, fileName), Buffer.from(data, 'base64'));
  process.stdout.write(`Erzeugt: ${fileName}\n`);
}

socket.close();
