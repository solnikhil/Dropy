// Renders film.html frame by frame in headless Chromium.
//
//   node render.mjs frames <outDir> [fps=60] [workers=6]   every frame, as JPEG
//   node render.mjs stills <outDir> <t1> <t2> ...           single PNG stills
//   node render.mjs sheet <outDir> <t1> <t2> ...            a labelled contact sheet
//   node render.mjs audio <outDir>                          the score, as score.wav
//
// Needs Playwright: set PLAYWRIGHT_DIR to a node_modules/playwright folder if it is
// not resolvable from here.
import { createRequire } from 'node:module';
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_DIR || 'playwright');
const here = path.dirname(fileURLToPath(import.meta.url));
// SUB: motion-blur samples per frame (default 4). VERT=1: the vertical 9:16 cut.
const url = pathToFileURL(path.join(here, 'film.html')).href + '?render&sub=' + (process.env.SUB || 4) + (process.env.VERT ? '&v=1' : '');

const [mode, outDir, ...rest] = process.argv.slice(2);
if (!mode || !outDir) { console.error('usage: render.mjs frames|stills <outDir> ...'); process.exit(1); }
mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch({ args: ['--force-color-profile=srgb', '--disable-gpu-vsync'] });
async function page() {
  const p = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
  await p.goto(url);
  await p.waitForFunction(() => typeof window.renderAt === 'function');
  return p;
}
async function grab(p, t, type, quality) {
  const data = await p.evaluate(([t, type, quality]) => {
    window.renderAt(t);
    return document.getElementById('film').toDataURL(type, quality);
  }, [t, type, quality]);
  return Buffer.from(data.slice(data.indexOf(',') + 1), 'base64');
}

if (mode === 'audio') {
  // The score, as a 16-bit stereo WAV.
  const p = await page();
  const { sampleRate, peak, data } = await p.evaluate(() => window.scorePCM());
  const pcm = Buffer.from(data, 'base64');
  const head = Buffer.alloc(44);
  head.write('RIFF', 0); head.writeUInt32LE(36 + pcm.length, 4); head.write('WAVE', 8);
  head.write('fmt ', 12); head.writeUInt32LE(16, 16); head.writeUInt16LE(1, 20); head.writeUInt16LE(2, 22);
  head.writeUInt32LE(sampleRate, 24); head.writeUInt32LE(sampleRate * 4, 28); head.writeUInt16LE(4, 32); head.writeUInt16LE(16, 34);
  head.write('data', 36); head.writeUInt32LE(pcm.length, 40);
  const file = path.join(outDir, 'score.wav');
  writeFileSync(file, Buffer.concat([head, pcm]));
  console.log(`${file}: ${(pcm.length / 4 / sampleRate).toFixed(2)} s, peak ${peak.toFixed(3)}`);
} else if (mode === 'sheet') {
  // A contact sheet: the given times, 3 across at 640×360, labelled.
  const p = await page();
  const times = rest.map(Number);
  const data = await p.evaluate(times => {
    const film = document.getElementById('film');
    const tall = film.height > film.width, cols = tall ? 5 : 3, w = tall ? 300 : 640, h = tall ? 533 : 360, rows = Math.ceil(times.length / cols);
    const sheet = document.createElement('canvas');
    sheet.width = cols * w; sheet.height = rows * h;
    const g = sheet.getContext('2d');
    times.forEach((t, i) => {
      window.renderAt(t);
      const x = (i % cols) * w, y = Math.floor(i / cols) * h;
      g.drawImage(film, x, y, w, h);
      g.fillStyle = '#ff5050'; g.font = '600 18px sans-serif'; g.fillText(t.toFixed(2), x + 8, y + 22);
      g.strokeStyle = '#333'; g.strokeRect(x, y, w, h);
    });
    return sheet.toDataURL('image/png');
  }, times);
  const file = path.join(outDir, `sheet-${times[0]}-${times[times.length - 1]}.png`);
  writeFileSync(file, Buffer.from(data.slice(data.indexOf(',') + 1), 'base64'));
  console.log(file);
} else if (mode === 'stills') {
  const p = await page();
  for (const s of rest) {
    const file = path.join(outDir, `still-${(+s).toFixed(2).padStart(5, '0')}.png`);
    writeFileSync(file, await grab(p, +s, 'image/png'));
    console.log(file);
  }
} else {
  const fps = +(rest[0] || 60), workers = +(rest[1] || 6);
  const p0 = await page();
  const duration = await p0.evaluate(() => window.FILM.duration);
  const total = Math.round(duration * fps);
  let next = 0, done = 0;
  const started = Date.now();
  const pages = [p0, ...await Promise.all(Array.from({ length: workers - 1 }, page))];
  await Promise.all(pages.map(async p => {
    while (next < total) {
      const f = next++;
      const buf = await grab(p, f / fps, 'image/jpeg', .96);
      writeFileSync(path.join(outDir, `f${String(f).padStart(5, '0')}.jpg`), buf);
      if (++done % 120 === 0) {
        const rate = done / ((Date.now() - started) / 1000);
        console.log(`${done}/${total} frames, ${rate.toFixed(1)}/s, ~${Math.round((total - done) / rate)}s left`);
      }
    }
  }));
  console.log(`rendered ${total} frames at ${fps} fps into ${outDir}`);
}
await browser.close();
