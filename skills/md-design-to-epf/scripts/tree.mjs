// Дерево разбора разметки «Накидки» без 1С: страница редактора (index.html из макета БиблиотекаJS) открывается
// в Firefox без окна, текст передаётся функцией window.setText, а дерево берётся из события EVENT_CHANGE_CONTENT,
// которое редактор отправляет в 1С синтетическим щелчком по window (данные — в eventData1C).
// Аргументы: --index <index.html> --markup <файл разметки> --out <tree.json> [--colors-mxl <Template.xml> --colors-out <colors.json>]

import { firefox } from 'playwright-core';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const arg = n => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : undefined; };
const markup = readFileSync(arg('markup'), 'utf8').replace(/^﻿/, '').replace(/\r\n/g, '\n');

// Таблица цветов «Накидки» (макет «Цвета», табличный документ): строка — «русское имя ; имя веб-цвета».
if (arg('colors-mxl')) {
  const map = {};
  for (const row of readFileSync(arg('colors-mxl'), 'utf8').split('<rowsItem>').slice(1)) {
    const c = [...row.split('</rowsItem>')[0].matchAll(/<v8:content>([^<]*)<\/v8:content>/g)].map(m => m[1]);
    if (c.length >= 2 && c[0] !== 'Цвет') map[c[0]] = c[1];
  }
  writeFileSync(arg('colors-out'), JSON.stringify(map));
}

const browser = await firefox.launch({ headless: true });
let error = null;
try {
  const page = await browser.newPage();
  await page.goto(pathToFileURL(arg('index')).href, { waitUntil: 'load', timeout: 60000 });
  await page.waitForFunction(() => typeof window.setText === 'function', null, { timeout: 60000 });
  await page.evaluate(() => {
    window.__mdEvents = [];
    window.addEventListener('click', e => { if (e.eventData1C !== undefined) window.__mdEvents.push(e.eventData1C); }, true);
  });
  await page.evaluate(t => window.setText(t), markup);
  const data = await page.waitForFunction(() => {
    for (const ev of window.__mdEvents) {
      const d = typeof ev === 'string' ? JSON.parse(ev) : ev;
      if (d.event === 'EVENT_CHANGE_CONTENT' && d.params && d.params.data) return d.params.data;
    }
    return null;
  }, null, { timeout: 20000 }).then(h => h.jsonValue());
  writeFileSync(arg('out'), typeof data === 'string' ? data : JSON.stringify(data));
} catch (e) { error = String(e.message || e); }
await browser.close();
process.stdout.write(JSON.stringify({ tree: arg('out'), error }) + '\n');
process.exit(error ? 1 : 0);
