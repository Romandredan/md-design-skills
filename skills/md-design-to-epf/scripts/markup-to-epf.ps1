<#
.SYNOPSIS
  Разметка «Накидки» -> внешняя обработка 1С (.epf) с формой, построенной так же, как прототип, и её снимки.

.DESCRIPTION
  1. Окружение веб-исполнителя (Apache, Firefox, исходники «Накидки», база сборки) — через
     md-design-render-web\scripts\render.ps1 -PrepareOnly.
  2. Дерево разбора — от самой «Накидки»: страница редактора index.html (макет БиблиотекаJS) открывается
     в Firefox без окна, дерево берётся из события изменения текста (tree.mjs).
  3. XML-выгрузка обработки по дереву (gen-epf.mjs): реквизиты формы с типами, таблицы значений,
     команды кнопок с пустыми обработчиками.
  4. Сборка .epf конфигуратором в пакетном режиме.
  5. Снимок собранной формы веб-исполнителем (-OpenEpf), если не задан -NoSnapshot.

.OUTPUTS
  JSON: { epf, xml, generator: { elements, attributes, commands, notTransferred[] }, snapshots: [...], error }.
#>
param(
    [Parameter(Mandatory = $true)][string]$Markup,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$Name,          # имя обработки: идентификатор 1С (буквы, цифры, «_», не с цифры)
    [switch]$NoSnapshot,
    [string]$RenderWeb = ""                               # каталог навыка md-design-render-web; пусто — рядом с этим навыком
)
$ErrorActionPreference = "Stop"
if ($Name -notmatch '^[\p{L}_][\p{L}\p{Nd}_]*$') { throw "-Name: идентификатор 1С (буквы, цифры, подчёркивание, не с цифры): $Name" }
$here = $PSScriptRoot
if (-not $RenderWeb) { $RenderWeb = Join-Path (Split-Path (Split-Path $here)) "md-design-render-web" }
$renderPs1 = Join-Path $RenderWeb "scripts\render.ps1"
if (-not (Test-Path $renderPs1)) { throw "Не найден веб-исполнитель: $renderPs1 (навык md-design-render-web)." }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$Markup = (Resolve-Path $Markup).Path
function Write-Step($text) { [Console]::Error.WriteLine("[md-design-epf] $text") }

# 1. Окружение
Write-Step "Подготовка окружения веб-исполнителя"
$prepJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $renderPs1 -PrepareOnly | Where-Object { $_ -like '{*' } | Select-Object -Last 1
if (-not $prepJson) { throw "Веб-исполнитель не подготовил окружение." }
$prep = $prepJson | ConvertFrom-Json
if (-not $prep.mdDesignSrc) { throw "Нужны исходники «Накидки» (страница редактора): запускайте веб-исполнитель с -EpfSource fork." }
$templates = Join-Path $prep.mdDesignSrc ("s" + "rc\MDDesign\Templates")

# 2. Страница редактора и дерево разбора
$commit = (git -C $prep.mdDesignSrc rev-parse --short=8 HEAD).Trim()
$jslib = Join-Path $prep.web "jslib-$commit"
if (-not (Test-Path (Join-Path $jslib "index.html"))) {
    Write-Step "Распаковка страницы редактора ($commit)"
    $zip = Join-Path $prep.web "jslib-$commit.zip"
    Copy-Item (Join-Path $templates "БиблиотекаJS\Ext\Template.bin") $zip -Force
    Expand-Archive -Path $zip -DestinationPath $jslib -Force
    Remove-Item $zip -Force
}
Copy-Item (Join-Path $here "tree.mjs") (Join-Path $prep.runner "tree.mjs") -Force
$work = Join-Path $OutDir "_work"
New-Item -ItemType Directory -Force $work | Out-Null
$env:PLAYWRIGHT_BROWSERS_PATH = $prep.browsers
Write-Step "Разбор разметки страницей редактора"
$treeOut = & node (Join-Path $prep.runner "tree.mjs") --index (Join-Path $jslib "index.html") --markup $Markup --out (Join-Path $work "tree.json") `
    --colors-mxl (Join-Path $templates "Цвета\Ext\Template.xml") --colors-out (Join-Path $work "colors.json")
if ($LASTEXITCODE -ne 0) { throw "Разбор разметки не удался: $treeOut" }

# 3. XML-выгрузка обработки
$xmlDir = Join-Path $OutDir "xml"
if (Test-Path $xmlDir) { Remove-Item $xmlDir -Recurse -Force }
Write-Step "Генерация XML-выгрузки обработки $Name"
$genJson = & node (Join-Path $here "gen-epf.mjs") --tree (Join-Path $work "tree.json") --out $xmlDir --name $Name --colors (Join-Path $work "colors.json") | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) { throw "Генерация XML не удалась: $genJson" }
$gen = $genJson | ConvertFrom-Json

# 4. Сборка .epf
$epf = Join-Path $OutDir "$Name.epf"
$log = Join-Path $work "build.log"
Write-Step "Сборка $Name.epf"
$p = Start-Process -FilePath (Join-Path $prep.bin "1cv8.exe") -PassThru -WindowStyle Hidden -ArgumentList @(
    "DESIGNER", "/F", """$($prep.buildIb)""", "/DisableStartupDialogs", "/DisableStartupMessages", "/Out", """$log""",
    "/LoadExternalDataProcessorOrReportFromFiles", """$(Join-Path $xmlDir "$Name.xml")""", """$epf""")
$null = $p.Handle
if (-not $p.WaitForExit(300000)) { $p.Kill(); throw "Сборка не завершилась за 5 минут." }
if ($p.ExitCode -ne 0 -or -not (Test-Path $epf)) { throw "Сборка $Name.epf не удалась (код $($p.ExitCode)): $(Get-Content $log -Raw -ErrorAction SilentlyContinue)" }

# 5. Снимок собранной формы
$shots = @(); $shotError = $null
if (-not $NoSnapshot) {
    Write-Step "Снимок собранной формы"
    $shotJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $renderPs1 -OpenEpf $epf -OutDir (Join-Path $OutDir "img") -Prefix $Name | Where-Object { $_ -like '{*' } | Select-Object -Last 1
    if ($shotJson) { $shot = $shotJson | ConvertFrom-Json; $shots = @($shot.files); $shotError = $shot.error } else { $shotError = "веб-исполнитель не вернул результат" }
}

[ordered]@{
    epf = $epf; xml = $xmlDir
    generator = [ordered]@{ elements = $gen.elements; attributes = $gen.attributes; commands = $gen.commands; notTransferred = @($gen.notTransferred) }
    snapshots = $shots; error = $shotError
} | ConvertTo-Json -Depth 4 -Compress
