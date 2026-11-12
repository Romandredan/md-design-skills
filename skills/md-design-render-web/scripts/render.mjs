// Невидимый прогон «Накидки» в веб-клиенте 1С: Firefox без окна (Playwright).
// Вызывается из render.ps1, который поднимает Apache и готовит окружение.
// Аргументы: --url <адрес публикации> --epf <MDDesign.epf> --markup <файл[;файл…]> --out <каталог>
//            [--prefix <имя>] [--pages <номера через запятую>]
//            или --open <обработка.epf> вместо --markup: открыть любую внешнюю обработку и снять её форму.
// Результат — одна строка JSON в stdout. Одна разметка: { pages, files, notOpened, error, errorFile }.
// Несколько разметок: массив таких объектов с полем markup; префикс снимков — имя файла разметки.

import { firefox } from 'playwright-core';
import { readFileSync, mkdirSync } from 'node:fs';
import { join, basename, extname } from 'node:path';

const arg = name => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : undefined; };
const url = arg('url'), epf = arg('epf'), outDir = arg('out');
const openFile = arg('open');
const markupFiles = openFile ? [openFile] : arg('markup').split(';').map(s => s.trim()).filter(Boolean);
const single = markupFiles.length === 1;
const pageFilter = (arg('pages') || '').split(',').map(s => parseInt(s, 10)).filter(n => n > 0);
mkdirSync(outDir, { recursive: true });

const ERROR_TEXT = 'К сожалению, возникла непредвиденная ошибка';
const jobs = markupFiles.map(file => {
  const markup = openFile ? '' : readFileSync(file, 'utf8').replace(/^﻿/, '').replace(/\r\n/g, '\n');
  return {
    file, markup,
    prefix: single ? (arg('prefix') || 'page') : basename(file, extname(file)),
    title: (markup.match(/^---\s*(.*?)\s*---\s*$/m) || [])[1],
    result: { markup: file, pages: [...markup.matchAll(/^\/(.+)$/gm)].map(m => m[1].trim()), files: [], notOpened: [], error: null, errorFile: null },
  };
});

const browser = await firefox.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1100 }, locale: 'ru-RU', acceptDownloads: true });

// Окно ошибки 1С: снимок, отчёт об ошибке и текст ошибки в результат разметки.
async function checkError(job, stage) {
  if (!(await page.getByText(ERROR_TEXT).count())) return false;
  const r = job.result;
  let message = `${stage}: ${ERROR_TEXT}`;
  try {
    const shot = join(outDir, `${job.prefix}-error.png`);
    await page.screenshot({ path: shot }); r.errorFile = shot;
    await page.getByText('Сформировать отчет об ошибке').first().click();
    await page.waitForTimeout(2500);
    const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 20000 }), page.getByText(/^Сохранить на диск/).first().click()]);
    const zip = join(outDir, `${job.prefix}-error-report.zip`); await dl.saveAs(zip);
    message += `. Отчёт об ошибке: ${zip}`;
  } catch { /* отчёт необязателен: достаточно снимка */ }
  r.error = message;
  return true;
}

async function waitFor(fn, timeoutMs, stepMs = 500) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) { if (await fn()) return true; await page.waitForTimeout(stepMs); }
  return false;
}

// Снимок формы formN: от заголовка формы (левее него панель редактора «Накидки») до видимых элементов контейнера.
async function shotForm(job, formPrefix, file) {
  // Фокус ввода выделяет поле рамкой и подсвечивает текст — на снимке прототипа это лишнее.
  await page.evaluate(() => document.activeElement && document.activeElement.blur && document.activeElement.blur());
  const box = await page.evaluate(p => {
    const root = document.getElementById(`${p}_container`) || document.getElementById(`${p}_mainGroup`);
    const head = document.getElementById(`${p}_ЗаголовокФормы`);
    if (!root) return null;
    const hr = (head || root).getBoundingClientRect();
    const left = hr.left - 10, top = hr.top - 10;
    let r = hr.right, b = hr.bottom;
    for (const e of root.querySelectorAll('*')) {
      const rc = e.getBoundingClientRect(); const st = getComputedStyle(e);
      if (rc.width < 2 || rc.height < 2 || st.visibility === 'hidden' || st.display === 'none') continue;
      if (rc.left < left - 2 || rc.top < top - 2) continue;
      if (rc.height > window.innerHeight * 0.6) continue;   // растянутые на всю высоту панели и разделители
      if (e.children.length === 0 && !(e.textContent || '').trim() && st.borderStyle === 'none' && st.backgroundImage === 'none') continue;
      r = Math.max(r, rc.right); b = Math.max(b, rc.bottom);
    }
    return { x: left, y: top, r: r + 10, b: b + 10 };
  }, formPrefix);
  const clip = box ? { x: box.x, y: box.y, width: box.r - box.x, height: box.b - box.y } : undefined;
  await page.screenshot({ path: file, clip, fullPage: true });
  job.result.files.push(file);
}

// Файл → Открыть: главное меню в правом верхнем углу; запасной путь — Ctrl+O. Обработка подставляется в диалог «Выбрать с диска».
async function openProcessing(file = epf) {
  await page.mouse.click(1583, 15); await page.waitForTimeout(1000);
  const fileItem = page.locator('text="Файл" >> visible=true');
  if (await fileItem.count()) { await fileItem.first().click(); await page.waitForTimeout(800); await page.locator('text=/^Открыть/ >> visible=true').first().click(); }
  else { await page.keyboard.press('Escape'); await page.keyboard.press('Control+o'); }
  await waitFor(async () => (await page.locator('text="Выбрать с диска" >> visible=true').count()) > 0, 20000);
  const [chooser] = await Promise.all([page.waitForEvent('filechooser', { timeout: 20000 }), page.locator('text="Выбрать с диска" >> visible=true').first().click()]);
  await chooser.setFiles(file); await page.waitForTimeout(1000);
  await page.locator('text="OK" >> visible=true').first().click();
}

// Редактор обработки — фрейм поля HTML с функцией setText. Каждая следующая разметка открывает обработку заново:
// новый экземпляр формы даёт новый префикс formN, и форму прежней разметки нельзя снять по ошибке. В сборке
// без исправления 8e4e65f форка поле редактора после «Сформировать» к тому же остаётся пустым.
async function findEditor(job, stage, timeoutMs) {
  let editor = null;
  await waitFor(async () => {
    if (await checkError(job, stage)) return true;
    for (const f of page.frames()) if (await f.evaluate(() => typeof window.setText === 'function').catch(() => false)) { editor = f; return true; }
    return false;
  }, timeoutMs, 1000);
  if (job.result.error) throw new Error(job.result.error);
  if (!editor) {
    const shot = join(outDir, `${job.prefix}-debug.png`);
    await page.screenshot({ path: shot }).catch(() => {}); job.result.errorFile = shot;
    for (const f of page.frames()) process.stderr.write(`[md-design-web] фрейм: ${f.name()} ${f.url().slice(0, 120)}\n`);
    throw new Error(`Редактор «Накидки» не загрузился за ${timeoutMs / 1000} секунд; снимок страницы — ${shot}`);
  }
  return editor;
}

// Снимок произвольной формы formN (собранная обработка): у неё нет элемента ЗаголовокФормы «Накидки»,
// поэтому кадр — объединение видимых элементов формы и строка заголовка окна над ними.
async function shotAnyForm(job, formPrefix, file) {
  const box = await page.evaluate(p => {
    let l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
    for (const e of document.querySelectorAll(`[id^="${p}_"]`)) {
      const rc = e.getBoundingClientRect(); const st = getComputedStyle(e);
      if (rc.width < 2 || rc.height < 2 || st.visibility === 'hidden' || st.display === 'none' || !e.offsetParent) continue;
      if (rc.height > window.innerHeight * 0.85) continue;
      l = Math.min(l, rc.left); t = Math.min(t, rc.top); r = Math.max(r, rc.right); b = Math.max(b, rc.bottom);
    }
    return l === Infinity ? null : { x: Math.max(0, l - 10), y: Math.max(0, t - 45), r: r + 10, b: b + 10 };
  }, formPrefix);
  const clip = box ? { x: box.x, y: box.y, width: box.r - box.x, height: box.b - box.y } : undefined;
  await page.screenshot({ path: file, clip, fullPage: true });
  job.result.files.push(file);
}

async function openJob(job) {
  const r = job.result;
  await page.evaluate(() => document.querySelectorAll('[id^="form"]').forEach(e => e.setAttribute('data-mdd-old', '1')));
  await openProcessing(job.file);
  let formPrefix = null;
  await waitFor(async () => {
    if (await checkError(job, 'Открытие обработки')) return true;
    // Новая форма получает наибольший номер formN; элементы начальной страницы могут перерисоваться без пометки.
    formPrefix = await page.evaluate(() => {
      let best = -1;
      for (const e of document.querySelectorAll('[id^="form"]:not([data-mdd-old])')) { const m = e.id.match(/^form(\d+)_/); if (m && e.offsetParent) best = Math.max(best, +m[1]); }
      return best >= 0 ? `form${best}` : null;
    });
    return !!formPrefix;
  }, 60000, 1000);
  if (r.error) return;
  if (!formPrefix) { r.error = 'Форма обработки не открылась за 60 секунд'; return; }
  await page.waitForTimeout(2000);
  const blur = () => page.evaluate(() => document.activeElement && document.activeElement.blur && document.activeElement.blur());
  await blur();
  const tabs = await page.evaluate(p => [...document.querySelectorAll(`[id^="thpage_${p}_"] .tabsItemTitle`)].map(t => t.getAttribute('data-content')), formPrefix);
  r.pages = tabs;
  const num = k => String(k).padStart(2, '0');
  if (tabs.length >= 2) {
    for (let k = 0; k < tabs.length; k++) {
      if (pageFilter.length && !pageFilter.includes(k + 1)) continue;
      const rect = await page.evaluate(({ p, name }) => {
        const t = [...document.querySelectorAll(`[id^="thpage_${p}_"] .tabsItemTitle`)].find(e => e.getAttribute('data-content') === name);
        if (!t) return null;
        const b = t.closest('[id^="thpage_"]').getBoundingClientRect();
        return { x: b.left + b.width / 2, y: b.top + b.height / 2 };
      }, { p: formPrefix, name: tabs[k] });
      if (!rect) { r.notOpened.push(tabs[k]); continue; }
      await page.mouse.click(rect.x, rect.y);
      await page.waitForTimeout(1200);
      await blur();
      await shotAnyForm(job, formPrefix, join(outDir, `${job.prefix}-${num(k + 1)}.png`));
    }
  } else {
    await shotAnyForm(job, formPrefix, join(outDir, `${job.prefix}-01.png`));
  }
  await checkError(job, 'После открытия');
}

async function renderJob(job, first) {
  const r = job.result;
  // Элементы уже сформированных форм помечаются, чтобы не снять форму предыдущей разметки.
  await page.evaluate(() => document.querySelectorAll('[id$="_ЗаголовокФормы"], [id^="thpage_"]').forEach(e => e.setAttribute('data-mdd-old', '1')));
  if (!first) await openProcessing();
  const editor = await findEditor(job, 'Открытие обработки', 90000);
  await editor.evaluate(t => window.setText(t), job.markup);
  await page.waitForTimeout(1500);
  await page.locator('text="Сформировать" >> visible=true').first().click();

  // Префикс элементов формы formN — по закладке первой страницы или по заголовку формы, только среди непомеченных.
  let formPrefix = null;
  await waitFor(async () => {
    if (await checkError(job, 'Формирование')) return true;
    formPrefix = await page.evaluate(({ firstPage, title }) => {
      if (firstPage) {
        const t = [...document.querySelectorAll('[id^="thpage_"]:not([data-mdd-old]) .tabsItemTitle')].find(e => e.getAttribute('data-content') === firstPage);
        const item = t && t.closest('[id^="thpage_"]');
        if (item) return item.id.replace(/^thpage_/, '').split('___')[0];
      }
      for (const e of document.querySelectorAll('[id$="_ЗаголовокФормы"]:not([data-mdd-old])')) {
        if (!title || (e.textContent || '').trim() === title) return e.id.replace(/_ЗаголовокФормы$/, '');
      }
      return null;
    }, { firstPage: r.pages[0], title: job.title });
    return !!formPrefix;
  }, 60000, 1000);
  if (r.error) return;
  if (!formPrefix) { r.error = 'Форма прототипа не сформировалась за 60 секунд'; return; }
  await page.waitForTimeout(1500);

  const num = k => String(k).padStart(2, '0');
  if (r.pages.length >= 2) {
    for (let k = 0; k < r.pages.length; k++) {
      if (pageFilter.length && !pageFilter.includes(k + 1)) continue;
      const name = r.pages[k];
      const rect = await page.evaluate(({ p, name }) => {
        const t = [...document.querySelectorAll(`[id^="thpage_${p}___"] .tabsItemTitle`)].find(e => e.getAttribute('data-content') === name);
        if (!t) return null;
        const b = t.closest('[id^="thpage_"]').getBoundingClientRect();
        return { x: b.left + b.width / 2, y: b.top + b.height / 2 };
      }, { p: formPrefix, name });
      if (!rect) { r.notOpened.push(name); continue; }
      await page.mouse.click(rect.x, rect.y);
      await page.waitForTimeout(1200);
      await shotForm(job, formPrefix, join(outDir, `${job.prefix}-${num(k + 1)}.png`));
    }
  } else {
    await shotForm(job, formPrefix, join(outDir, `${job.prefix}-01.png`));
  }
  await checkError(job, 'После формирования');
}

let fatal = null;
try {
  await page.goto(url, { waitUntil: 'load', timeout: 120000 });
  if (!(await waitFor(async () => (await page.getByText('Поиск Ctrl+Shift+F').count()) > 0
      || (await page.locator('text=Поиск').count()) > 0, 60000))) throw new Error('Веб-клиент не загрузился за 60 секунд');
  if (await page.getByText('вход в приложение невозможен').count()) throw new Error('Вход в базу невозможен: вероятно, остался сеанс прежнего прогона — перезапустите прогон');

  if (!openFile) await openProcessing();

  // Ошибка на одной разметке останавливает прогон: продолжать в сеансе с открытым окном ошибки ненадёжно.
  for (const [i, job] of jobs.entries()) {
    try { if (openFile) await openJob(job); else await renderJob(job, i === 0); } catch (e) { if (!job.result.error) job.result.error = String(e.message || e); }
    job.done = !job.result.error;
    if (!job.done) { fatal = `не выполнено: прогон остановлен на ошибке в ${job.file}`; break; }
  }
} catch (e) {
  fatal = String(e.message || e);
  if (!jobs[0].result.error) jobs[0].result.error = fatal;
} finally {
  await browser.close();
  for (const job of jobs) if (!job.done && !job.result.error && fatal) job.result.error = fatal;
  const results = jobs.map(j => j.result);
  if (single) delete results[0].markup;
  process.stdout.write(JSON.stringify(single ? results[0] : results) + '\n');
  process.exit(results.some(x => x.error) ? 1 : 0);
}
