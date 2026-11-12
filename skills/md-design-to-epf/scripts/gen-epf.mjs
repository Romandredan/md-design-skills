// Дерево разбора «Накидки» -> XML-выгрузка внешней обработки 1С (корневой XML, форма, модуль формы).
// Аргументы: --tree <tree.json> --out <каталог выгрузки> --name <ИмяОбработки> [--colors <colors.json>]
// tree.json — данные события EVENT_CHANGE_CONTENT редактора: { СемантическоеДерево, Атрибуты }.
// Правила построения элементов повторяют модуль формы «ПостроительСхемФормы» обработки «Накидка».
// Результат — JSON-отчёт в stdout: { root, form, elements, attributes, commands, notTransferred[] }.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

const arg = n => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : undefined; };
const data = JSON.parse(readFileSync(arg('tree'), 'utf8'));
const outDir = arg('out');
const name = arg('name');
const colors = arg('colors') ? JSON.parse(readFileSync(arg('colors'), 'utf8')) : {};
const tree = data.СемантическоеДерево;
const report = { root: '', form: '', elements: 0, attributes: 0, commands: 0, notTransferred: [] };
const note = s => { if (!report.notTransferred.includes(s)) report.notTransferred.push(s); };

// --- XML-помощники ---------------------------------------------------------------------------------------
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const ls = (tag, text, attrs = '') => `<${tag}${attrs}><v8:item><v8:lang>ru</v8:lang><v8:content>${esc(text)}</v8:content></v8:item></${tag}>`;
const indent = (xml, n) => xml.split('\n').map(l => (l ? '\t'.repeat(n) + l : l)).join('\n');

// Порядок дочерних тегов — по выгрузке реальных форм (1500 форм УТ 11.5).
const ORDER = {
  InputField: 'DataPath Visible Enabled ReadOnly HorizontalAlign Title TitleLocation ShowInHeader ToolTip Height Width SpinButton DropListButton MultiLine HorizontalStretch ClearButton OpenButton ChoiceButton TextColor BackColor ChoiceList InputHint ContextMenu ExtendedTooltip',
  CheckBoxField: 'DataPath Visible Enabled ReadOnly HorizontalAlign Title TitleLocation ToolTip ShowInHeader CheckBoxType ContextMenu ExtendedTooltip',
  RadioButtonField: 'DataPath Visible Enabled Title TitleTextColor ToolTip TitleLocation RadioButtonType ColumnsCount ChoiceList ContextMenu ExtendedTooltip',
  LabelDecoration: 'Visible Enabled Width Height HorizontalStretch BackColor TextColor Font ToolTip Title HorizontalAlign ContextMenu ExtendedTooltip',
  UsualGroup: 'Visible Enabled ReadOnly Title ToolTip Width Height VerticalStretch HorizontalStretch HorizontalAlign BackColor Group Behavior Representation ShowTitle ExtendedTooltip ChildItems',
  Pages: 'Visible Enabled ReadOnly ToolTip Width Height Title HorizontalStretch VerticalStretch PagesRepresentation ExtendedTooltip ChildItems',
  Page: 'Visible Enabled ReadOnly ToolTip Width Height HorizontalStretch VerticalStretch Title Group ShowTitle ExtendedTooltip ChildItems',
  Table: 'Representation Visible Enabled TitleLocation CommandBarLocation ReadOnly ChangeRowSet Width Height HorizontalStretch VerticalStretch DataPath Title ContextMenu AutoCommandBar ExtendedTooltip SearchStringAddition ViewStatusAddition SearchControlAddition ChildItems',
  ColumnGroup: 'Visible Title Group ShowInHeader ExtendedTooltip ChildItems',
  Button: 'Type Visible Representation DefaultButton Width Enabled HorizontalStretch TextColor BackColor CommandName Picture Title ExtendedTooltip',
  CommandBar: 'Visible Enabled Title HorizontalStretch HorizontalLocation ExtendedTooltip ChildItems',
  ButtonGroup: 'Visible Enabled Title Representation ExtendedTooltip ChildItems',
  Popup: 'Visible Enabled Title Representation Picture ExtendedTooltip ChildItems',
};

let nextId = 1;
const newId = () => nextId++;

// Элемент: { tag, name, props: Map(тег -> xml), children: [] }
function el(tag, elName) { report.elements++; return { tag, name: elName, props: new Map(), children: [] }; }
function set(e, tag, xml) { e.props.set(tag, xml); }

function serialize(e) {
  const id = newId();
  const order = (ORDER[e.tag] || '').split(' ');
  const parts = [];
  const known = new Set(order);
  for (const t of order) {
    if (t === 'ContextMenu' && e.contextMenu) { parts.push(`<ContextMenu name="${esc(e.name)}КонтекстноеМеню" id="${newId()}"/>`); continue; }
    if (t === 'AutoCommandBar' && e.tag === 'Table') { parts.push(`<AutoCommandBar name="${esc(e.name)}КоманднаяПанель" id="${newId()}">\n\t<Autofill>false</Autofill>\n</AutoCommandBar>`); continue; }
    if (t === 'ExtendedTooltip') { parts.push(`<ExtendedTooltip name="${esc(e.name)}РасширеннаяПодсказка" id="${newId()}"/>`); continue; }
    if (['SearchStringAddition', 'ViewStatusAddition', 'SearchControlAddition'].includes(t) && e.tag === 'Table') {
      const kind = { SearchStringAddition: ['СтрокаПоиска', 'SearchStringRepresentation'], ViewStatusAddition: ['СостояниеПросмотра', 'ViewStatusRepresentation'], SearchControlAddition: ['УправлениеПоиском', 'SearchControl'] }[t];
      parts.push(`<${t} name="${esc(e.name)}${kind[0]}" id="${newId()}">\n\t<AdditionSource>\n\t\t<Item>${esc(e.name)}</Item>\n\t\t<Type>${kind[1]}</Type>\n\t</AdditionSource>\n\t<ContextMenu name="${esc(e.name)}${kind[0]}КонтекстноеМеню" id="${newId()}"/>\n\t<ExtendedTooltip name="${esc(e.name)}${kind[0]}РасширеннаяПодсказка" id="${newId()}"/>\n</${t}>`);
      continue;
    }
    if (t === 'ChildItems') { if (e.children.length) parts.push(`<ChildItems>\n${e.children.map(c => indent(serialize(c), 1)).join('\n')}\n</ChildItems>`); continue; }
    if (e.props.has(t)) parts.push(e.props.get(t));
  }
  for (const [t, x] of e.props) if (!known.has(t)) parts.push(x);
  return `<${e.tag} name="${esc(e.name)}" id="${id}">\n${parts.map(p => indent(p, 1)).join('\n')}\n</${e.tag}>`;
}

// --- свойства из НаборСвойств -----------------------------------------------------------------------------
const ENUMS = {
  ПоложениеЗаголовка: { tag: 'TitleLocation', map: { Авто: 'Auto', Лево: 'Left', Право: 'Right', Верх: 'Top', Низ: 'Bottom', Нет: 'None' } },
  ВидФлажка: { tag: 'CheckBoxType', map: { Авто: 'Auto', Флажок: 'CheckBox', Выключатель: 'Switcher', Тумблер: 'Tumbler' } },
  ВидПереключателя: { tag: 'RadioButtonType', map: { Авто: 'Auto', Переключатель: 'RadioButtons', Тумблер: 'Tumbler' } },
  Отображение: { tag: 'Representation', map: { Нет: 'None', СлабоеВыделение: 'WeakSeparation', ОбычноеВыделение: 'NormalSeparation', СильноеВыделение: 'StrongSeparation', Картинка: 'Picture', Текст: 'Text', КартинкаИТекст: 'PictureAndText', Авто: 'Auto' } },
  Поведение: { tag: 'Behavior', map: { Обычное: 'Usual', Свертываемое: 'Collapsible', Свертываемая: 'Collapsible', Всплывающее: 'PopUp', Всплывающая: 'PopUp' } },
  ГоризонтальноеПоложение: { tag: 'HorizontalAlign', map: { Авто: 'Auto', Лево: 'Left', Центр: 'Center', Право: 'Right' } },
};
const BOOLS = { КнопкаВыбора: 'ChoiceButton', КнопкаОткрытия: 'OpenButton', КнопкаОчистки: 'ClearButton', КнопкаСпискаВыбора: 'DropListButton', КнопкаРегулирования: 'SpinButton', МногострочныйРежим: 'MultiLine', Доступность: 'Enabled', Видимость: 'Visible', ТолькоПросмотр: 'ReadOnly', РастягиватьПоГоризонтали: 'HorizontalStretch', РастягиватьПоВертикали: 'VerticalStretch', КнопкаПоУмолчанию: 'DefaultButton', ОтображатьЗаголовок: 'ShowTitle' };
const NUMS = { Высота: 'Height', Ширина: 'Width' };
const SKIP = new Set(['Заголовок', 'СписокВыбора', 'Картинка', 'РеквизитФормы']);
const toBool = v => (v === true || /^(истина|true|да)$/i.test(String(v)));

function applyProps(e, node, opts = {}) {
  const props = node.НаборСвойств || {};
  for (const [k, v] of Object.entries(props)) {
    if (SKIP.has(k)) continue;
    if (k in BOOLS) { set(e, BOOLS[k], `<${BOOLS[k]}>${toBool(v)}</${BOOLS[k]}>`); continue; }
    if (k in NUMS) { set(e, NUMS[k], `<${NUMS[k]}>${parseInt(v, 10) || 0}</${NUMS[k]}>`); continue; }
    if (k in ENUMS) {
      const x = ENUMS[k].map[String(v)];
      if (x) set(e, ENUMS[k].tag, `<${ENUMS[k].tag}>${x}</${ENUMS[k].tag}>`); else note(`${node.УИД}: ${k} = ${v} — значение не распознано`);
      continue;
    }
    if (k === 'ЦветФона' || k === 'ЦветТекста') {
      const tag = k === 'ЦветФона' ? 'BackColor' : 'TextColor';
      const c = colors[String(v)];
      if (c) set(e, tag, `<${tag}>web:${c}</${tag}>`); else note(`${node.УИД}: ${k} = ${v} — цвет не найден в макете «Цвета»`);
      continue;
    }
    if (k === 'Тип') continue;
    note(`${node.УИД}: свойство ${k} = ${JSON.stringify(v)} не перенесено`);
  }
  const title = props.Заголовок;
  if (title !== undefined && title !== '' && !opts.noTitle) set(e, 'Title', e.tag === 'LabelDecoration' ? ls('Title', title, ' formatted="false"') : ls('Title', title));
}

// --- реквизиты --------------------------------------------------------------------------------------------
const attributes = [];   // { name, title, typeXml, columns: [{ name, title, typeXml }] }
const attrNames = new Set();

function typeXml(td, values = []) {
  let types = (td && td.Типы) || [];
  if (td && td.Авто && types.length === 1 && types[0] === 'Строка') {
    const vs = values.map(v => String(v ?? '').trim()).filter(Boolean);
    if (vs.length && vs.every(v => /^-?\d[\d\s]*([.,]\d+)?$/.test(v))) {
      const frac = Math.max(0, ...vs.map(v => (v.split(/[.,]/)[1] || '').length));
      td = { ...td, Типы: ['Число'], ДлинаЧисла: 15, ТочностьЧисла: frac }; types = td.Типы;
    } else if (vs.length && vs.every(v => /^\d{2}\.\d{2}\.\d{4}$/.test(v))) {
      td = { ...td, Типы: ['Дата'], ЧастиДаты: 'Дата' }; types = td.Типы;
    }
  }
  const out = [];
  for (const t of types) {
    if (t === 'Строка') out.push(`<v8:Type>xs:string</v8:Type>\n<v8:StringQualifiers>\n\t<v8:Length>${td.ДлинаСтроки || 0}</v8:Length>\n\t<v8:AllowedLength>Variable</v8:AllowedLength>\n</v8:StringQualifiers>`);
    else if (t === 'Число') out.push(`<v8:Type>xs:decimal</v8:Type>\n<v8:NumberQualifiers>\n\t<v8:Digits>${td.ДлинаЧисла || 15}</v8:Digits>\n\t<v8:FractionDigits>${td.ТочностьЧисла || 0}</v8:FractionDigits>\n\t<v8:AllowedSign>Any</v8:AllowedSign>\n</v8:NumberQualifiers>`);
    else if (t === 'Дата') out.push(`<v8:Type>xs:dateTime</v8:Type>\n<v8:DateQualifiers>\n\t<v8:DateFractions>${{ Дата: 'Date', Время: 'Time', ДатаВремя: 'DateTime' }[td.ЧастиДаты] || 'Date'}</v8:DateFractions>\n</v8:DateQualifiers>`);
    else if (t === 'Булево') out.push('<v8:Type>xs:boolean</v8:Type>');
    else if (t === 'ТаблицаЗначений') out.push('<v8:Type>v8:ValueTable</v8:Type>');
    else if (t === 'ДеревоЗначений') out.push('<v8:Type>v8:ValueTree</v8:Type>');
    else { note(`тип «${t}» заменён строкой: ссылочные типы во внешней обработке без конфигурации недоступны`); out.push('<v8:Type>xs:string</v8:Type>\n<v8:StringQualifiers>\n\t<v8:Length>0</v8:Length>\n\t<v8:AllowedLength>Variable</v8:AllowedLength>\n</v8:StringQualifiers>'); }
  }
  // Повторяющиеся описания строки (составной тип из нескольких «Строка») не нужны.
  return [...new Set(out)].join('\n') || '<v8:Type>xs:string</v8:Type>';
}

function addAttribute(attrName, title, td, values) {
  if (!attrName || attrNames.has(attrName)) return null;
  attrNames.add(attrName);
  const a = { name: attrName, title, typeXml: typeXml(td, values), columns: [] };
  attributes.push(a);
  return a;
}

// --- команды ----------------------------------------------------------------------------------------------
const commands = [];   // { name, title }
// Имя команды — из заголовка кнопки: «Накидка» при построении УИД выбрасывает «ё» («Завершить приёмку» → «ЗавершитьПримку»).
function identFromTitle(title) {
  const words = String(title || '').replace(/ё/g, 'е').replace(/Ё/g, 'Е').split(/[^\p{L}\p{Nd}_]+/u).filter(Boolean);
  const id = words.map(w => w[0].toUpperCase() + w.slice(1)).join('');
  return /^[\p{L}_]/u.test(id) ? id : '';
}

function addCommand(btnName, title) {
  let n = identFromTitle(title) || btnName || `Команда${commands.length + 1}`;
  while (commands.some(c => c.name === n)) n += '1';
  commands.push({ name: n, title: title || n });
  return n;
}

// --- построение элементов (как ПостроительСхемФормы) ------------------------------------------------------
function build(node, parent) {
  const t = node.Тип;
  if (t === 'ГоризонтальнаяГруппа' || t === 'ОднострочнаяГруппа' || t === 'ВертикальнаяГруппа') {
    const e = el('UsualGroup', node.УИД);
    const vertical = t === 'ВертикальнаяГруппа';
    set(e, 'Group', `<Group>${vertical ? 'Vertical' : 'AlwaysHorizontal'}</Group>`);
    set(e, 'Representation', '<Representation>None</Representation>');
    const title = (node.НаборСвойств || {}).Заголовок;
    if (!vertical || !title) set(e, 'ShowTitle', '<ShowTitle>false</ShowTitle>');
    set(e, 'HorizontalStretch', '<HorizontalStretch>true</HorizontalStretch>');
    set(e, 'VerticalStretch', '<VerticalStretch>false</VerticalStretch>');
    applyProps(e, node);
    for (const c of node.Элементы || []) build(c, e);
    parent.children.push(e); return;
  }
  if (t === 'Страницы') {
    const e = el('Pages', node.УИД);
    set(e, 'HorizontalStretch', '<HorizontalStretch>true</HorizontalStretch>');
    set(e, 'VerticalStretch', '<VerticalStretch>false</VerticalStretch>');
    applyProps(e, node);
    for (const p of node.Элементы || []) {
      const pe = el('Page', p.УИД);
      applyProps(pe, p);
      for (const c of p.Элементы || []) build(c, pe);
      e.children.push(pe);
    }
    parent.children.push(e); return;
  }
  if (t === 'ПолеВвода') {
    const e = el('InputField', node.УИД); e.contextMenu = true;
    set(e, 'DataPath', `<DataPath>${esc(node.УИДАтрибута)}</DataPath>`);
    applyProps(e, node);
    addAttribute(node.УИДАтрибута, (node.НаборСвойств || {}).Заголовок, node.ОписаниеТипов, [node.Значение]);
    if ((node.НаборСвойств || {}).СписокВыбора) note(`${node.УИД}: список выбора поля ввода не перенесён`);
    parent.children.push(e); return;
  }
  if (t === 'ПолеФлажка') {
    const e = el('CheckBoxField', node.УИД); e.contextMenu = true;
    set(e, 'DataPath', `<DataPath>${esc(node.УИДАтрибута)}</DataPath>`);
    applyProps(e, node);
    addAttribute(node.УИДАтрибута, (node.НаборСвойств || {}).Заголовок, { Типы: ['Булево'] });
    parent.children.push(e); return;
  }
  if (t === 'ПолеПереключателя') {
    const e = el('RadioButtonField', node.УИД); e.contextMenu = true;
    const props = node.НаборСвойств || {};
    set(e, 'DataPath', `<DataPath>${esc(node.УИДАтрибута)}</DataPath>`);
    if (!('ПоложениеЗаголовка' in props) && !props.Заголовок) set(e, 'TitleLocation', '<TitleLocation>None</TitleLocation>');
    applyProps(e, node);
    const items = (props.СписокВыбора || []).map((p, i) => `<xr:Item>\n\t<xr:Presentation/>\n\t<xr:CheckState>0</xr:CheckState>\n\t<xr:Value xsi:type="FormChoiceListDesTimeValue">\n\t\t${ls('Presentation', p)}\n\t\t<Value xsi:type="xs:decimal">${i}</Value>\n\t</xr:Value>\n</xr:Item>`);
    if (items.length) set(e, 'ChoiceList', `<ChoiceList>\n${items.map(x => indent(x, 1)).join('\n')}\n</ChoiceList>`);
    addAttribute(node.УИДАтрибута, props.Заголовок, { Типы: ['Число'], ДлинаЧисла: 10, ТочностьЧисла: 0 });
    parent.children.push(e); return;
  }
  if (t === 'Надпись') {
    const e = el('LabelDecoration', node.УИД); e.contextMenu = true;
    applyProps(e, node);
    parent.children.push(e); return;
  }
  if (t === 'Таблица' || t === 'Дерево') { buildTable(node, parent, t === 'Дерево'); return; }
  if (t === 'КоманднаяПанель') {
    const items = node.Элементы || [];
    if (items.length === 1 && items[0].ТипЭлемента === 'КнопкаФормы' && items[0].Тип !== 'Подменю' && items[0].Тип !== 'ГруппаКнопок') {
      parent.children.push(button(items[0], 'UsualButton')); return;
    }
    const e = el('CommandBar', node.УИД);
    applyProps(e, node);
    if (!('РастягиватьПоГоризонтали' in (node.НаборСвойств || {}))) set(e, 'HorizontalStretch', '<HorizontalStretch>false</HorizontalStretch>');
    buttons(node, e);
    parent.children.push(e); return;
  }
  note(`элемент ${node.УИД} (${t}) не перенесён: вид элемента генератору неизвестен`);
}

function buttons(node, parent) {
  for (const b of node.Элементы || []) {
    if (b.Тип === 'ГруппаКнопок') { const g = el('ButtonGroup', b.УИД); applyProps(g, b); buttons(b, g); parent.children.push(g); continue; }
    if (b.Тип === 'Подменю') {
      const p = el('Popup', b.УИД);
      applyProps(p, b);
      if ((b.НаборСвойств || {}).Картинка) note(`${b.УИД}: картинка подменю не перенесена`);
      buttons(b, p); parent.children.push(p); continue;
    }
    parent.children.push(button(b, 'CommandBarButton'));
  }
}

function button(b, type) {
  const e = el('Button', b.УИД);
  set(e, 'Type', `<Type>${type}</Type>`);
  const title = (b.НаборСвойств || {}).Заголовок || '';
  const cmd = addCommand(b.УИД, title);
  set(e, 'CommandName', `<CommandName>Form.Command.${esc(cmd)}</CommandName>`);
  applyProps(e, b);
  if ((b.НаборСвойств || {}).Картинка) note(`${b.УИД}: картинка кнопки «${b.НаборСвойств.Картинка}» не перенесена — задать в конфигураторе`);
  return e;
}

function buildTable(node, parent, isTree) {
  const e = el('Table', node.УИД); e.contextMenu = true;
  if (isTree) set(e, 'Representation', '<Representation>Tree</Representation>');
  set(e, 'DataPath', `<DataPath>${esc(node.УИДАтрибута)}</DataPath>`);
  set(e, 'CommandBarLocation', '<CommandBarLocation>None</CommandBarLocation>');
  applyProps(e, node);
  const a = addAttribute(node.УИДАтрибута, (node.НаборСвойств || {}).Заголовок, { Типы: [isTree ? 'ДеревоЗначений' : 'ТаблицаЗначений'] });
  const rows = [];
  (function collect(rs) { for (const r of rs || []) { rows.push(r); collect(r.Строки); } })(node.Строки);
  const cellValues = key => rows.map(r => ((r.Ячейки || {})[key] || {}).Значение);
  const addColumn = (colName, title, td, values) => { if (a && colName && !a.columns.some(c => c.name === colName)) a.columns.push({ name: colName, title, typeXml: typeXml(td, values) }); };
  const addCols = (cols, target) => {
    for (const c of cols || []) {
      if ((c.Колонки || []).length || c.ЕстьГоризонтальнаяГруппа || c.ЕстьВертикальнаяГруппа) note(`${node.УИД}: многоуровневая шапка колонки «${(c.НаборСвойств || {}).Заголовок || c.УИД}» развёрнута в простые колонки`);
      let holder = target;
      const title = (c.НаборСвойств || {}).Заголовок;
      if (c.ЕстьГруппаВместе) {
        const g = el('ColumnGroup', c.УИДГруппаВместе);
        set(g, 'Group', '<Group>InCell</Group>');
        if (title) set(g, 'Title', ls('Title', title));
        target.children.push(g); holder = g;
      }
      if (c.ЕстьФлажок) {
        const f = el('CheckBoxField', c.УИДФлажок); f.contextMenu = true;
        set(f, 'DataPath', `<DataPath>${esc(node.УИДАтрибута)}.${esc(c.УИДАтрибутаФлажок)}</DataPath>`);
        if (title) set(f, 'Title', ls('Title', title));
        if (c.ЕстьГруппаВместе) set(f, 'ShowInHeader', '<ShowInHeader>false</ShowInHeader>');
        holder.children.push(f);
        addColumn(c.УИДАтрибутаФлажок, title, { Типы: ['Булево'] });
      }
      if (c.ЕстьЗначение) {
        const f = el('InputField', c.УИД); f.contextMenu = true;
        set(f, 'DataPath', `<DataPath>${esc(node.УИДАтрибута)}.${esc(c.УИДАтрибута)}</DataPath>`);
        applyProps(f, c);
        // Флажок и значение в одной ячейке: заголовок в шапке — у группы, как в «ПостроительСхемФормы».
        if (c.ЕстьГруппаВместе || !title) set(f, 'ShowInHeader', '<ShowInHeader>false</ShowInHeader>');
        holder.children.push(f);
        addColumn(c.УИДАтрибута, title, c.ОписаниеТипов, cellValues(c.УИДАтрибута));
      }
      if ((c.Колонки || []).length) addCols(c.Колонки, holder);
    }
  };
  addCols(node.Колонки, e);
  if (rows.length) note(`${node.УИД}: строки примера (${rows.length}) в таблицу не переносятся — заполняются данными при работе`);
  parent.children.push(e);
}

// --- сборка формы -----------------------------------------------------------------------------------------
const formTitle = (tree.НаборСвойств || {}).Заголовок || name;
const root = { tag: 'Form', name: 'Форма', props: new Map(), children: [] };
for (const c of tree.Элементы || []) build(c, root);

let attrId = 1;
const attrXml = [`<Attribute name="Объект" id="${attrId++}">\n\t<Type>\n\t\t<v8:Type>cfg:ExternalDataProcessorObject.${esc(name)}</v8:Type>\n\t</Type>\n\t<MainAttribute>true</MainAttribute>\n</Attribute>`];
for (const a of attributes) {
  const cols = a.columns.map((c, i) => `<Column name="${esc(c.name)}" id="${i + 1}">\n${c.title ? '\t' + ls('Title', c.title) + '\n' : ''}\t<Type>\n${indent(c.typeXml, 2)}\n\t</Type>\n</Column>`);
  attrXml.push(`<Attribute name="${esc(a.name)}" id="${attrId++}">\n${a.title ? '\t' + ls('Title', a.title) + '\n' : ''}\t<Type>\n${indent(a.typeXml, 2)}\n\t</Type>${cols.length ? `\n\t<Columns>\n${cols.map(x => indent(x, 2)).join('\n')}\n\t</Columns>` : ''}\n</Attribute>`);
}
report.attributes = attributes.length;
// Обработчик команды — с префиксом «Команда»: имена кнопок вроде «Закрыть» или «Записать» совпали бы с методами формы.
const cmdXml = commands.map((c, i) => `<Command name="${esc(c.name)}" id="${i + 1}">\n\t${ls('Title', c.title)}\n\t<Action>Команда${esc(c.name)}</Action>\n</Command>`);
report.commands = commands.length;

const FORM_NS = 'xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"';
const MD_NS = 'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"';

const childItems = root.children.map(c => indent(serialize(c), 2)).join('\n');
const formXml = `<?xml version="1.0" encoding="UTF-8"?>
<Form ${FORM_NS} version="2.17">
	${ls('Title', formTitle)}
	<AutoTitle>false</AutoTitle>
	<AutoCommandBar name="ФормаКоманднаяПанель" id="-1">
		<Autofill>false</Autofill>
	</AutoCommandBar>
	<ChildItems>
${childItems}
	</ChildItems>
	<Attributes>
${attrXml.map(x => indent(x, 2)).join('\n')}
	</Attributes>${cmdXml.length ? `\n\t<Commands>\n${cmdXml.map(x => indent(x, 2)).join('\n')}\n\t</Commands>` : ''}
</Form>
`;

const handlers = commands.map(c => `&НаКлиенте\nПроцедура Команда${c.name}(Команда)\n\t// Кнопка «${c.title.replace(/\r?\n/g, ' ')}»: действие задаётся при разработке.\nКонецПроцедуры`).join('\n\n');
const moduleBsl = handlers ? `#Область ОбработчикиКомандФормы\n\n${handlers}\n\n#КонецОбласти\n` : '';

const uuid = () => randomUUID();
const rootXml = `<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject ${MD_NS} version="2.17">
	<ExternalDataProcessor uuid="${uuid()}">
		<InternalInfo>
			<xr:ContainedObject>
				<xr:ClassId>c3831ec8-d8d5-4f93-8a22-f9bfae07327f</xr:ClassId>
				<xr:ObjectId>${uuid()}</xr:ObjectId>
			</xr:ContainedObject>
			<xr:GeneratedType name="ExternalDataProcessorObject.${esc(name)}" category="Object">
				<xr:TypeId>${uuid()}</xr:TypeId>
				<xr:ValueId>${uuid()}</xr:ValueId>
			</xr:GeneratedType>
		</InternalInfo>
		<Properties>
			<Name>${esc(name)}</Name>
			${ls('Synonym', formTitle)}
			<Comment/>
			<DefaultForm>ExternalDataProcessor.${esc(name)}.Form.Форма</DefaultForm>
			<AuxiliaryForm/>
		</Properties>
		<ChildObjects>
			<Form>Форма</Form>
		</ChildObjects>
	</ExternalDataProcessor>
</MetaDataObject>
`;
const formMetaXml = `<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject ${MD_NS} version="2.17">
	<Form uuid="${uuid()}">
		<Properties>
			<Name>Форма</Name>
			${ls('Synonym', 'Форма')}
			<Comment/>
			<FormType>Managed</FormType>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<UsePurposes>
				<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
			</UsePurposes>
			<ExtendedPresentation/>
		</Properties>
	</Form>
</MetaDataObject>
`;

const bom = '﻿';
mkdirSync(join(outDir, name, 'Forms', 'Форма', 'Ext', 'Form'), { recursive: true });
writeFileSync(join(outDir, `${name}.xml`), bom + rootXml);
writeFileSync(join(outDir, name, 'Forms', 'Форма.xml'), bom + formMetaXml);
writeFileSync(join(outDir, name, 'Forms', 'Форма', 'Ext', 'Form.xml'), bom + formXml);
writeFileSync(join(outDir, name, 'Forms', 'Форма', 'Ext', 'Form', 'Module.bsl'), bom + moduleBsl.replace(/\n/g, '\r\n'));
report.root = join(outDir, `${name}.xml`);
report.form = join(outDir, name, 'Forms', 'Форма', 'Ext', 'Form.xml');
process.stdout.write(JSON.stringify(report) + '\n');
