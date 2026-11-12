<#
.SYNOPSIS
  Перевод управляемой формы 1С из XML-выгрузки (Form.xml) в разметку «Накидки» для снимка «было».

.DESCRIPTION
  Разбирает дерево элементов формы и пишет разметку: страницы, группы (колонки и однострочные),
  поля с модификаторами кнопок, флажки, переключатели, надписи, таблицы с двумя строками примера,
  командные панели. Заголовки — из Title элемента, иначе из заголовка реквизита формы, иначе из
  синонима реквизита объекта метаданных (если рядом лежит XML объекта: <Объект>.xml на четыре уровня
  выше Form.xml), иначе — имя элемента. Типы — из реквизитов формы и объекта.
  Ничего не теряется молча: невидимые элементы, элементы без аналога в «Накидке» и приближения
  перечисляются в отчёте; элементы без аналога выводятся серой надписью-заглушкой.

.OUTPUTS
  Разметка — в файл -Out (UTF-8). Отчёт — JSON в stdout:
  { markup, title, pages, elements, hidden[], unsupported[], approximated[], notes[] }.
#>
param(
    [Parameter(Mandatory = $true)][string]$FormXml,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$ObjectXml = ""      # XML объекта метаданных; пусто — искать рядом с формой
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$doc = New-Object System.Xml.XmlDocument
$doc.PreserveWhitespace = $false
$doc.Load((Resolve-Path -LiteralPath $FormXml).Path)
$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$ns.AddNamespace("f", "http://v8.1c.ru/8.3/xcf/logform")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")

$report = [ordered]@{ markup = $Out; title = ""; pages = 0; elements = 0; hidden = @(); unsupported = @(); approximated = @(); notes = @() }

# --- тексты и типы ------------------------------------------------------------------------------------------
function Get-Ru($node) {
    if (-not $node) { return "" }
    $c = $node.SelectSingleNode("v8:item[v8:lang='ru']/v8:content", $ns)
    if (-not $c) { $c = $node.SelectSingleNode("v8:item/v8:content", $ns) }
    if ($c) { return $c.InnerText.Trim() } else { return "" }
}

# Ловушки разбора «Накидки»: «/» начинает страницу, «:» делает надпись полем, « — » делит надпись,
# ёлочки рвут ячейку таблицы. В тексте заменяются похожими знаками.
function Safe([string]$t) {
    if (-not $t) { return "" }
    $t = $t -replace '[\r\n]+', ' '
    $t = $t.Replace('/', [string][char]0x2215).Replace(':', [string][char]0xA789).Replace(' — ', ' – ')
    $t = $t.Replace('«', '"').Replace('»', '"').Replace('|', [string][char]0x2223)
    $t = $t.Replace('[', '(').Replace(']', ')').Replace('<', '‹').Replace('>', '›').Replace('{', '(').Replace('}', ')')
    return $t.Trim()
}

# Реквизиты формы: имя -> @{ Title; Types; Columns }
$formAttrs = @{}
foreach ($a in $doc.SelectNodes("/f:Form/f:Attributes/f:Attribute", $ns)) {
    $types = @($a.SelectNodes("f:Type/v8:Type", $ns) | ForEach-Object { $_.InnerText })
    $cols = @{}
    foreach ($c in $a.SelectNodes("f:Columns/f:Column", $ns)) {
        $cols[$c.GetAttribute("name")] = @{ Title = (Get-Ru $c.SelectSingleNode("f:Title", $ns)); Types = @($c.SelectNodes("f:Type/v8:Type", $ns) | ForEach-Object { $_.InnerText }); Quals = $c.SelectSingleNode("f:Type", $ns) }
    }
    $formAttrs[$a.GetAttribute("name")] = @{ Title = (Get-Ru $a.SelectSingleNode("f:Title", $ns)); Types = $types; Columns = $cols; Quals = $a.SelectSingleNode("f:Type", $ns); Main = ($a.SelectSingleNode("f:MainAttribute", $ns).InnerText -eq "true") }
}

# Объект метаданных: реквизиты и табличные части (синонимы и типы).
$objAttrs = @{}; $objTabs = @{}
if (-not $ObjectXml) {
    $formDir = Split-Path (Resolve-Path -LiteralPath $FormXml).Path       # .../<Объект>/Forms/<Форма>/Ext
    $objDir = Split-Path (Split-Path (Split-Path $formDir))              # .../<Объект>
    $cand = "$objDir.xml"
    if (Test-Path -LiteralPath $cand) { $ObjectXml = $cand }
}
# Стандартные реквизиты: в DataPath выгрузки они записаны английскими именами (Объект.Code, Объект.Description).
$std = @{ "Code" = "Код"; "Description" = "Наименование"; "Date" = "Дата"; "Number" = "Номер"; "Owner" = "Владелец"; "Parent" = "Родитель"; "DeletionMark" = "Пометка удаления"; "Posted" = "Проведен"; "Ref" = "Ссылка" }
$stdTypes = @{ "Code" = "xs:string"; "Description" = "xs:string"; "Date" = "xs:dateTime"; "Number" = "xs:string"; "DeletionMark" = "xs:boolean"; "Posted" = "xs:boolean" }
function Read-MdProps($node) {
    $p = $node.SelectSingleNode("md:Properties", $ns)
    return @{ Title = (Get-Ru $p.SelectSingleNode("md:Synonym", $ns)); Types = @($p.SelectNodes("md:Type/v8:Type", $ns) | ForEach-Object { $_.InnerText }); Quals = $p.SelectSingleNode("md:Type", $ns) }
}
if ($ObjectXml -and (Test-Path -LiteralPath $ObjectXml)) {
    $od = New-Object System.Xml.XmlDocument; $od.Load((Resolve-Path -LiteralPath $ObjectXml).Path)
    $root = $od.DocumentElement.FirstChild
    while ($root -and $root.NodeType -ne [System.Xml.XmlNodeType]::Element) { $root = $root.NextSibling }
    if ($root) {
        foreach ($a in $root.SelectNodes("md:ChildObjects/md:Attribute", $ns)) { $objAttrs[$a.SelectSingleNode("md:Properties/md:Name", $ns).InnerText] = Read-MdProps $a }
        foreach ($t in $root.SelectNodes("md:ChildObjects/md:TabularSection", $ns)) {
            $cols = @{}
            foreach ($a in $t.SelectNodes("md:ChildObjects/md:Attribute", $ns)) { $cols[$a.SelectSingleNode("md:Properties/md:Name", $ns).InnerText] = Read-MdProps $a }
            $cols["LineNumber"] = @{ Title = "N"; Types = @("xs:decimal"); Quals = $null }
            $objTabs[$t.SelectSingleNode("md:Properties/md:Name", $ns).InnerText] = @{ Title = (Get-Ru $t.SelectSingleNode("md:Properties/md:Synonym", $ns)); Columns = $cols }
        }
        $report.notes += "Синонимы и типы реквизитов взяты из $ObjectXml"
    }
}
else { $report.notes += "XML объекта метаданных не найден: заголовки полей без Title — по именам реквизитов, типы реквизитов объекта неизвестны" }

# Описание данных по DataPath: @{ Title; Types; Quals }
function Resolve-Path1C([string]$path) {
    if (-not $path) { return $null }
    $parts = $path -split '\.'
    $first = $parts[0]
    if ($formAttrs.ContainsKey($first) -and $formAttrs[$first].Main -and $parts.Count -ge 2) {
        $n = $parts[1]
        if ($parts.Count -eq 2) {
            if ($objAttrs.ContainsKey($n)) { return $objAttrs[$n] }
            if ($std.ContainsKey($n)) { return @{ Title = $std[$n]; Types = @($stdTypes[$n]); Quals = $null } }
            if ($objTabs.ContainsKey($n)) { return @{ Title = $objTabs[$n].Title; Types = @(); Quals = $null } }
            return @{ Title = ""; Types = @(); Quals = $null }
        }
        if ($objTabs.ContainsKey($n) -and $objTabs[$n].Columns.ContainsKey($parts[2])) { return $objTabs[$n].Columns[$parts[2]] }
        return @{ Title = ""; Types = @(); Quals = $null }
    }
    if ($formAttrs.ContainsKey($first)) {
        if ($parts.Count -eq 1) { return $formAttrs[$first] }
        if ($formAttrs[$first].Columns.ContainsKey($parts[1])) { return $formAttrs[$first].Columns[$parts[1]] }
    }
    return @{ Title = ""; Types = @(); Quals = $null }
}

# Заголовки команд формы.
$commands = @{}
foreach ($c in $doc.SelectNodes("/f:Form/f:Commands/f:Command", $ns)) { $commands[$c.GetAttribute("name")] = Get-Ru $c.SelectSingleNode("f:Title", $ns) }
$stdCommands = @{ "Close" = "Закрыть"; "WriteAndClose" = "Записать и закрыть"; "Write" = "Записать"; "OK" = "ОК"; "Cancel" = "Отмена"; "Help" = "Справка"; "Post" = "Провести"; "PostAndClose" = "Провести и закрыть"; "Reread" = "Перечитать"; "Copy" = "Скопировать"; "Delete" = "Удалить"; "SetDeletionMark" = "Пометить на удаление"; "Add" = "Добавить"; "Change" = "Изменить"; "Refresh" = "Обновить"; "Find" = "Найти"; "MoveUp" = "Переместить вверх"; "MoveDown" = "Переместить вниз"; "CheckAll" = "Отметить все"; "UncheckAll" = "Снять отметки"; "Yes" = "Да"; "No" = "Нет"; "Abort" = "Прервать"; "Retry" = "Повторить"; "Ignore" = "Пропустить"; "Restore" = "Восстановить"; "Print" = "Печать" }

function Title-Of($el) {
    $t = Get-Ru $el.SelectSingleNode("f:Title", $ns)
    if ($t) { return $t }
    $dp = $el.SelectSingleNode("f:DataPath", $ns)
    if ($dp) {
        $d = Resolve-Path1C $dp.InnerText
        if ($d -and $d.Title) { return $d.Title }
        $last = ($dp.InnerText -split '\.')[-1]
        return ($last -creplace '([а-яёa-z])([А-ЯЁA-Z])', '$1 $2')
    }
    $cmd = $el.SelectSingleNode("f:CommandName", $ns)
    if ($cmd) {
        $n = $cmd.InnerText
        if ($n -match '^Form\.Command\.(.+)$' -and $commands[$Matches[1]]) { return $commands[$Matches[1]] }
        if ($n -match 'StandardCommand\.(.+)$' -and $stdCommands[$Matches[1]]) { return $stdCommands[$Matches[1]] }
        return ($n -split '\.')[-1]
    }
    return $el.GetAttribute("name")
}

function Prop($el, $name) { $n = $el.SelectSingleNode("f:$name", $ns); if ($n) { return $n.InnerText } else { return "" } }
function IsHidden($el) { return (Prop $el "Visible") -eq "false" }

# Пример значения по типу.
function Sample($desc, [bool]$inTable) {
    $types = @(); if ($desc) { $types = @($desc.Types) }
    if ($types.Count -eq 0) { return @{ Value = ""; Mods = ""; Explicit = "" } }
    $t = $types[0]
    switch -Regex ($t) {
        '^xs:string$' { return @{ Value = "Текст"; Mods = ""; Explicit = "" } }
        '^xs:decimal$' {
            $scale = 0
            if ($desc.Quals) { $s = $desc.Quals.SelectSingleNode("v8:NumberQualifiers/v8:FractionDigits", $ns); if ($s) { $scale = [int]$s.InnerText } }
            if ($scale -gt 0) { return @{ Value = "100." + ("0" * $scale); Mods = ""; Explicit = "" } } else { return @{ Value = "1"; Mods = ""; Explicit = "" } }
        }
        '^xs:dateTime$' {
            $f = ""; if ($desc.Quals) { $q = $desc.Quals.SelectSingleNode("v8:DateQualifiers/v8:DateFractions", $ns); if ($q) { $f = $q.InnerText } }
            if ($f -eq "Time") { return @{ Value = "10:00"; Mods = ""; Explicit = "" } }
            if ($f -eq "DateTime") { return @{ Value = "01.11.2026 10:00:00"; Mods = ""; Explicit = "" } }
            return @{ Value = "01.11.2026"; Mods = ""; Explicit = "" }
        }
        '^xs:boolean$' { return @{ Value = "Да"; Mods = ""; Explicit = "" } }
        'EnumRef\.(.+)$' { return @{ Value = ($Matches[1] -creplace '([а-яё])([А-ЯЁ])', '$1 $2'); Mods = "С"; Explicit = "" } }
        '(Catalog|Document|ChartOfCharacteristicTypes|ChartOfAccounts|ChartOfCalculationTypes|ExchangePlan|BusinessProcess|Task)Ref\.(.+)$' { return @{ Value = ($Matches[2] -creplace '([а-яё])([А-ЯЁ])', '$1 $2'); Mods = "ВО"; Explicit = "" } }
        default { return @{ Value = ""; Mods = ""; Explicit = "" } }
    }
}

# --- элементы -----------------------------------------------------------------------------------------------
$unsupportedKinds = @{ "HTMLDocumentField" = "поле HTML-документа"; "SpreadSheetDocumentField" = "табличный документ"; "ChartField" = "диаграмма"; "PictureField" = "поле картинки"; "PictureDecoration" = "картинка"; "CalendarField" = "календарь"; "PlannerField" = "планировщик"; "FormattedDocumentField" = "форматированный документ"; "TextDocumentField" = "текстовый документ"; "ProgressBarField" = "индикатор"; "TrackBarField" = "ползунок"; "DendrogramField" = "дендрограмма"; "GraphicalSchemaField" = "графическая схема"; "GeographicalSchemaField" = "географическая схема"; "PeriodField" = "поле периода"; "GanttChartField" = "диаграмма Ганта"; "PDFDocumentField" = "PDF-документ" }
$skipKinds = @("ContextMenu", "ExtendedTooltip", "SearchStringAddition", "ViewStatusAddition", "SearchControlAddition", "Events")

function Children($el) {
    $ci = $el.SelectSingleNode("f:ChildItems", $ns)
    if (-not $ci) { return @() }
    return @($ci.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $skipKinds -notcontains $_.LocalName })
}

function Hide-Note($el) { $script:report.hidden += "$($el.LocalName) $($el.GetAttribute('name'))" }

function Field-Line($el) {
    $title = Safe (Title-Of $el)
    $dp = Prop $el "DataPath"
    $desc = Resolve-Path1C $dp
    $s = Sample $desc $false
    $mods = ""
    if ((Prop $el "ChoiceButton") -eq "true") { $mods += "В" }
    if ((Prop $el "DropListButton") -eq "true") { $mods += "С" }
    if ((Prop $el "ClearButton") -eq "true") { $mods += "Х" }
    if ((Prop $el "OpenButton") -eq "true") { $mods += "О" }
    if ((Prop $el "SpinButton") -eq "true") { $mods += "Д" }
    if (-not $mods) { $mods = $s.Mods }
    $val = Safe $s.Value
    if ($mods) { $val = "$val`__$mods" }
    $titleLoc = Prop $el "TitleLocation"
    # Поле без заголовка: «Накидка» подписывает пустой заголовок служебным именем, поэтому заголовок скрывается свойством.
    $line = if ($titleLoc -eq "None") { "$($title): $val {ПоложениеЗаголовка = Нет}" } else { "$($title): $val" }
    $lines = @($line.TrimEnd())
    $h = Prop $el "Height"
    if ((Prop $el "MultiLine") -eq "true" -or ($h -and [int]$h -gt 1)) {
        $n = if ($h) { [Math]::Min([int]$h, 5) } else { 3 }
        $pad = " " * ($title.Length + 2)
        for ($i = 1; $i -lt $n; $i++) { $lines += "${pad}______________" }
    }
    return $lines
}

function Render($el, [int]$indent) {
    $pad = " " * $indent
    $kind = $el.LocalName
    $name = $el.GetAttribute("name")
    if (IsHidden $el) { Hide-Note $el; return @() }
    $script:report.elements++
    switch ($kind) {
        "InputField" { return @(Field-Line $el | ForEach-Object { "$pad$_" }) }
        "LabelField" {
            $script:report.approximated += "$($name): поле надписи показано полем ввода"
            return @(Field-Line $el | ForEach-Object { "$pad$_" })
        }
        "CheckBoxField" {
            $title = Safe (Title-Of $el)
            if ((Prop $el "CheckBoxType") -eq "Switcher" -or (Prop $el "CheckBoxType") -eq "Tumbler") { return @("$pad[ |1] $title") }
            if ((Prop $el "TitleLocation") -eq "Right") { return @("$pad[X] $title") }
            return @("$pad[X] $title")
        }
        "RadioButtonField" {
            $title = Safe (Title-Of $el)
            $opts = @()
            foreach ($it in $el.SelectNodes("f:ChoiceList/xr:Item", $ns)) {
                $t = Get-Ru $it.SelectSingleNode("xr:Presentation", $ns)
                if (-not $t) { $t = Get-Ru $it.SelectSingleNode("xr:Value/f:Presentation", $ns) }
                if ($t) { $opts += (Safe $t) }
            }
            if ($opts.Count -eq 0) { $opts = @("Вариант 1", "Вариант 2"); $script:report.approximated += "$($name): варианты переключателя заполняются программно — показаны условные" }
            $parts = @(); for ($i = 0; $i -lt $opts.Count; $i++) { $parts += $(if ($i -eq 0) { "(X)" } else { "( )" }) + $opts[$i] }
            $suffix = if ((Prop $el "RadioButtonType") -eq "Tumbler") { " {ВидПереключателя = Тумблер}" } else { "" }
            $head = if ((Prop $el "TitleLocation") -eq "None") { "" } else { "$($title): " }
            return @("$pad$head$($parts -join ' ')$suffix")
        }
        "LabelDecoration" {
            $t = Safe (Title-Of $el)
            if (-not $t -or $t -eq $name) { $t = Safe ($name -creplace '([а-яё])([А-ЯЁ])', '$1 $2') }
            return @("$pad$t")
        }
        "Button" { return @("$pad< $(Button-Text $el) >") }
        { $_ -in @("CommandBar", "ButtonGroup") } {
            $b = Bar-Text $el
            if ($b) { return @("$pad$b") } else { return @() }
        }
        "UsualGroup" { return Render-Group $el $indent }
        "Pages" {
            $out = @()
            if ((Prop $el "PagesRepresentation") -eq "None") {
                # Страницы без закладок переключаются программно (состояния): показывается первая видимая.
                $first = @(Children $el | Where-Object { -not (IsHidden $_) }) | Select-Object -First 1
                $script:report.approximated += "$($name): страницы без закладок — показана только «$(Title-Of $first)»"
                if ($first) { return Render-List (Children $first) $indent }
                return @()
            }
            foreach ($p in (Children $el)) {
                if (IsHidden $p) { Hide-Note $p; continue }
                $script:report.pages++
                $out += "$pad/$(Safe (Title-Of $p))"
                $out += Render-List (Children $p) ($indent + 2)
            }
            return $out
        }
        "Page" { return Render-List (Children $el) $indent }
        "Table" { return Render-Table $el $indent }
        "ColumnGroup" { return Render-List (Children $el) $indent }
        "PictureDecoration" { $script:report.unsupported += "PictureDecoration $($name) (картинка, пропущена)"; return @() }
        default {
            $what = $unsupportedKinds[$kind]; if (-not $what) { $what = $kind }
            $script:report.unsupported += "$($kind) $($name) ($what)"
            $t = Safe (Title-Of $el)
            return @("$pad[$what$(if ($t -and $t -ne $name) { ': ' + $t })] {ЦветТекста = Серый}".Replace('[', '‹').Replace(']', '›'))
        }
    }
}

function Button-Text($b) {
    $t = Safe (Title-Of $b)
    $props = @()
    if ((Prop $b "DefaultButton") -eq "true") { $props += "ЦветФона = Золотой" }
    if ($props.Count) { $t += " {" + ($props -join "; ") + "}" }
    return $t
}

function Bar-Items($el) {
    $items = @()
    foreach ($c in (Children $el)) {
        if (IsHidden $c) { Hide-Note $c; continue }
        if ($c.LocalName -eq "Button") { $script:report.elements++; $items += (Button-Text $c) }
        elseif ($c.LocalName -in @("ButtonGroup", "CommandBar")) { $items += (Bar-Items $c) }
        elseif ($c.LocalName -eq "Popup") { $script:report.elements++; $items += (Safe (Title-Of $c)); $script:report.approximated += "$($c.GetAttribute('name')): подменю показано кнопкой" }
    }
    return $items
}
function Bar-Text($el) {
    $items = @(Bar-Items $el)
    if ($items.Count -eq 0) { return "" }
    return "< " + ($items -join " | ") + " >"
}

function Render-List($items, [int]$indent) {
    $out = @(); $prevTable = $false
    foreach ($c in $items) {
        $lines = @(Render $c $indent)
        if ($lines.Count -eq 0) { continue }
        $isTable = $c.LocalName -eq "Table"
        if ($isTable -and $prevTable) {
            $out += (" " * $indent) + (Safe (Title-Of $c))      # две таблицы подряд — окно ошибки «Накидки»
            $script:report.approximated += "$($c.GetAttribute('name')): перед таблицей добавлена надпись (две таблицы подряд «Накидка» не формирует)"
        }
        $out += $lines; $prevTable = $isTable
    }
    return $out
}

function Group-Hashes($g) {
    $rep = Prop $g "Representation"; $beh = Prop $g "Behavior"
    if ($beh -eq "Collapsible") { return "#####" }
    if ($beh -eq "PopUp") { return "######" }
    switch ($rep) { "WeakSeparation" { "##" } "NormalSeparation" { "###" } "StrongSeparation" { "####" } default { "#" } }
}
function Group-Title($g) {
    if ((Prop $g "ShowTitle") -eq "false") { return "" }
    $t = Get-Ru $g.SelectSingleNode("f:Title", $ns)
    return (Safe $t)
}

function Render-Group($g, [int]$indent) {
    $pad = " " * $indent
    $kids = @(Children $g | Where-Object { -not (IsHidden $_) -or (Hide-Note $_) })
    $dir = Prop $g "Group"
    $horizontal = $dir -in @("Horizontal", "AlwaysHorizontal", "HorizontalIfPossible")
    $title = Group-Title $g
    $hashes = Group-Hashes $g
    if (-not $horizontal) {
        if (-not $title -and $hashes -eq "#") { return Render-List $kids $indent }
        $inner = @(Render-List $kids ($indent + 2))
        if ($inner.Count -eq 0) { return @() }   # все элементы группы скрыты
        return @("$pad$hashes$title") + $inner
    }
    # Горизонтальная группа из простых элементов — однострочная группа через «&».
    $simple = @($kids | Where-Object { $_.LocalName -in @("InputField", "LabelField", "CheckBoxField", "LabelDecoration", "RadioButtonField") })
    if ($simple.Count -eq $kids.Count -and $kids.Count -gt 0 -and -not $title) {
        $parts = @(); foreach ($k in $kids) { $l = @(Render $k 0); if ($l.Count) { $parts += $l[0] } }
        return @("$pad$($parts -join ' & ')")
    }
    # Иначе — колонки: каждая дочерняя группа — колонка, отдельный элемент — колонка без заголовка.
    $cols = @()
    foreach ($k in $kids) {
        if ($k.LocalName -eq "UsualGroup") {
            $inner = @(Render-List (Children $k) 0)
            $cols += @{ Head = "$(Group-Hashes $k)$(Group-Title $k)"; Lines = $inner }
            $script:report.elements++
        }
        else { $cols += @{ Head = "#"; Lines = @(Render $k 0) } }
    }
    if ($title) { $script:report.approximated += "$($g.GetAttribute('name')): заголовок горизонтальной группы «$title» не показан" }
    $widths = @($cols | ForEach-Object { $w = $_.Head.Length; foreach ($l in $_.Lines) { if ($l.Length + 1 -gt $w) { $w = $l.Length + 1 } }; $w + 2 })
    $head = $pad; for ($i = 0; $i -lt $cols.Count; $i++) { $head += $cols[$i].Head.PadRight($widths[$i]) }
    $out = @($head.TrimEnd())
    $rows = ($cols | ForEach-Object { $_.Lines.Count } | Measure-Object -Maximum).Maximum
    for ($r = 0; $r -lt $rows; $r++) {
        $line = "$pad  "
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $cell = if ($r -lt $cols[$i].Lines.Count) { $cols[$i].Lines[$r] } else { "" }
            if ($i -gt 0) { $cell = if ($cell) { "+$cell" } else { "" } }
            $line += $cell.PadRight($widths[$i])
        }
        $out += $line.TrimEnd()
    }
    return $out
}

function Render-Table($t, [int]$indent) {
    $pad = " " * $indent
    $out = @()
    $bar = $t.SelectSingleNode("f:AutoCommandBar", $ns)
    if ($bar) { $b = Bar-Text $bar; if ($b) { $out += "$pad$b" } }
    $cols = @()
    $stack = New-Object System.Collections.Queue
    foreach ($c in (Children $t)) { $stack.Enqueue($c) }
    while ($stack.Count) {
        $c = $stack.Dequeue()
        if (IsHidden $c) { Hide-Note $c; continue }
        if ($c.LocalName -eq "ColumnGroup") { foreach ($x in (Children $c)) { $stack.Enqueue($x) }; $script:report.approximated += "$($c.GetAttribute('name')): группа колонок развёрнута в отдельные колонки"; continue }
        if ($c.LocalName -notin @("InputField", "LabelField", "CheckBoxField", "PictureField")) { $script:report.unsupported += "$($c.LocalName) $($c.GetAttribute('name')) (колонка таблицы)"; continue }
        $script:report.elements++
        $cols += $c
    }
    if ($cols.Count -eq 0) {
        $script:report.unsupported += "Table $($t.GetAttribute('name')) (колонки заполняются программно)"
        return @("$pad‹Таблица: $(Safe (Title-Of $t))› {ЦветТекста = Серый}")
    }
    $heads = @(); $cells = @(@(), @())
    foreach ($c in $cols) {
        $heads += (Safe (Title-Of $c))
        if ($c.LocalName -eq "CheckBoxField") { $cells[0] += "[X]"; $cells[1] += "[ ]"; continue }
        if ($c.LocalName -eq "PictureField") { $cells[0] += ""; $cells[1] += ""; continue }
        $s = Sample (Resolve-Path1C (Prop $c "DataPath")) $true
        $v = Safe $s.Value
        $cells[0] += $v; $cells[1] += $(if ($v -match '^\d') { $v } elseif ($v) { "$v 2" } else { "" })
    }
    $w = @(); for ($i = 0; $i -lt $heads.Count; $i++) { $w += [Math]::Max(3, [Math]::Max($heads[$i].Length, [Math]::Max($cells[0][$i].Length, $cells[1][$i].Length))) }
    $row = { param($vals) "$pad| " + (($(for ($i = 0; $i -lt $vals.Count; $i++) { ([string]$vals[$i]).PadRight($w[$i]) }) -join " | ")) + " |" }
    $out += (& $row $heads)
    $out += "$pad| " + (($w | ForEach-Object { "-" * $_ }) -join " | ") + " |"
    $out += (& $row $cells[0])
    $out += (& $row $cells[1])
    return $out
}

# --- сборка -------------------------------------------------------------------------------------------------
$lines = @()
$title = Get-Ru $doc.SelectSingleNode("/f:Form/f:Title", $ns)
if (-not $title -and $ObjectXml -and (Test-Path -LiteralPath $ObjectXml)) {
    $s = $od.DocumentElement.SelectSingleNode("*/md:Properties/md:Synonym", $ns); $title = Get-Ru $s
}
if (-not $title) { $title = Split-Path (Split-Path (Split-Path (Resolve-Path -LiteralPath $FormXml).Path)) -Leaf }
$report.title = $title
$lines += "--- $(Safe $title) ---"

$acb = $doc.SelectSingleNode("/f:Form/f:AutoCommandBar", $ns)
if ($acb) {
    $b = Bar-Text $acb
    if ($b) { $lines += $b }
    if ((Prop $acb "Autofill") -ne "false") { $report.notes += "Командная панель формы заполняется автоматически: стандартные команды объекта в разметку не попали — показаны только явно добавленные кнопки" }
}
$top = @(Children $doc.SelectSingleNode("/f:Form", $ns))
$body = @(Render-List $top 0)

# Содержимое после страниц без отступа выводится под страницами; общий контент до страниц — над ними.
$lines += $body
$report.notes += "Элементы, создаваемые программно, и условное оформление в Form.xml не видны — на снимке их нет"

$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Out, (($lines -join "`r`n") + "`r`n"), $enc)
$report | ConvertTo-Json -Depth 4 -Compress
