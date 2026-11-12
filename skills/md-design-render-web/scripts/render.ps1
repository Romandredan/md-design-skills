<#
.SYNOPSIS
  Невидимый прогон разметки «Накидки» в веб-клиенте 1С и снимки каждой страницы формы.

.DESCRIPTION
  Экран пользователя не занимается: форма строится в веб-клиенте внутри Firefox без окна.
  При первом запуске готовит окружение в %LOCALAPPDATA%\md-design-sandbox\web (повторно не делает):
    1. Apache 2.4 (сборка Apache Lounge, zip) — скачивается, сверяется SHA256, распаковывается;
    2. файловая база-песочница (общая с экранным исполнителем) и строка
       DisableUnsafeActionProtection=.*md-design-sandbox.* в пользовательском conf.cfg;
    3. публикация базы: собственные httpd.conf и default.vrd, сервер слушает только 127.0.0.1;
    4. Playwright (playwright-core через npm) и его сборка Firefox: Chrome, Edge и Chromium
       корпоративная политика RemoteDebuggingAllowed=0 часто запрещает управлять;
    5. MDDesign.epf. ВРЕМЕННО — сборка из форка с поддержкой веб-клиента
       (Romandredan/md_design, ветка fix/web-client-json, PR crimsongoldteam/md_design#217):
       в выпуске 0.16.4 обработка в веб-клиенте не работает. После принятия PR — -EpfSource release.
  На каждый прогон: Apache стартует обычным процессом, после прогона останавливается вместе
  с сеансом 1С (по PID, только свои процессы).

.OUTPUTS
  Одна разметка — JSON { pages, files, notOpened, error, errorFile }, снимки <Prefix>-NN.png.
  Несколько разметок (-Markup "a.txt;b.txt") — массив таких объектов с полем markup, снимки <имя файла>-NN.png;
  окно ошибки на одной разметке останавливает прогон, у следующих — error «не выполнено…».
  -Pages "2,3" — снять только эти страницы; номер в имени файла сохраняется исходный.
  Код 0 — успех, 1 — ошибка хотя бы одной разметки (текст в error).
#>
param(
    [string]$Markup = "",                              # файл разметки или несколько через ";" (раскадровка)
    [string]$OutDir = "",
    [string]$OpenEpf = "",                             # вместо разметки: открыть эту внешнюю обработку и снять её форму
    [switch]$PrepareOnly,                              # только подготовить окружение и напечатать пути (для других навыков)
    [string]$Prefix = "page",                          # только для одной разметки; иначе — имя файла разметки
    [string]$Pages = "",                               # номера страниц верхнего уровня через запятую; пусто — все
    [string]$PlatformBin = "",
    [int]$Port = 8099,
    [ValidateSet("fork", "release")][string]$EpfSource = "fork",
    [string]$ForkRepo = "https://github.com/Romandredan/md_design.git",
    [string]$ForkBranch = "fix/web-client-json",
    [string]$ApacheZipUrl = "https://www.apachelounge.com/download/VS18/binaries/httpd-2.4.69-261002-Win64-VS18.zip",
    [string]$ApacheSha256 = "77D715D0D9CEE731E2251E7DDC2090A7A8E6D41FEDEF2E9827CD918593C5A652"
)
$ErrorActionPreference = "Stop"
$sandbox = Join-Path $env:LOCALAPPDATA "md-design-sandbox"
$web = Join-Path $sandbox "web"
if (-not $PrepareOnly) {
    if (-not $Markup -and -not $OpenEpf) { throw "Укажите -Markup <разметка> или -OpenEpf <обработка.epf>." }
    if (-not $OutDir) { throw "Укажите -OutDir <каталог снимков>." }
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    $OutDir = (Resolve-Path $OutDir).Path
}
New-Item -ItemType Directory -Force $web | Out-Null

function Write-Step($text) { [Console]::Error.WriteLine("[md-design-web] $text") }

function Get-PlatformBin {
    if ($PlatformBin) { return $PlatformBin }
    $cands = foreach ($root in "C:\Program Files\1cv8", "C:\Program Files (x86)\1cv8") {
        if (Test-Path $root) { Get-ChildItem $root -Directory | Where-Object { Test-Path (Join-Path $_.FullName "bin\wsap24.dll") } }
    }
    $best = $cands | Sort-Object { [version]($_.Name -replace '[^\d\.]', '') } -Descending | Select-Object -First 1
    if (-not $best) { throw "Не найдена платформа 1С с модулем веб-сервера (bin\wsap24.dll) в Program Files\1cv8." }
    return (Join-Path $best.FullName "bin")
}

function Invoke-Designer($bin, $arguments, $log, $timeoutSec) {
    $p = Start-Process -FilePath (Join-Path $bin "1cv8.exe") -PassThru -NoNewWindow -ArgumentList ($arguments + @("/DisableStartupDialogs", "/Out", """$log"""))
    if (-not $p.WaitForExit($timeoutSec * 1000)) { $p.Kill(); throw "Конфигуратор не завершился за $timeoutSec с: $($arguments -join ' ')" }
}

# --- проверки окружения ------------------------------------------------------------------
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "Нужен Node.js 18 или новее (https://nodejs.org): через него управляется браузер без окна." }
if (-not (Test-Path "$env:WINDIR\System32\vcruntime140.dll")) { throw "Нет Visual C++ Redistributable x64 (vcruntime140.dll): он нужен Apache. Установите vc_redist.x64.exe с сайта Microsoft." }
$bin = Get-PlatformBin

# --- Apache --------------------------------------------------------------------------------
$httpd = Join-Path $web "apache\Apache24\bin\httpd.exe"
if (-not (Test-Path $httpd)) {
    Write-Step "Скачивание Apache: $ApacheZipUrl"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $web "apache.zip"
    Invoke-WebRequest -UseBasicParsing $ApacheZipUrl -OutFile $zip -Headers @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" }
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
    if ($hash -ne $ApacheSha256.ToUpper()) { Remove-Item $zip -Force; throw "Контрольная сумма Apache не совпала: $hash. Архив удалён." }
    Expand-Archive $zip -DestinationPath (Join-Path $web "apache") -Force
    Remove-Item $zip -Force
}

# --- база-песочница и защита от опасных действий ------------------------------------------------
$ib = Join-Path $sandbox "ib"
if (-not (Test-Path (Join-Path $ib "1Cv8.1CD"))) {
    Write-Step "Создание базы-песочницы"
    Invoke-Designer $bin @("CREATEINFOBASE", "File=""$ib"";") (Join-Path $sandbox "create.log") 180
}
$confDir = Join-Path $env:LOCALAPPDATA "1C\1cv8\conf"; New-Item -ItemType Directory -Force $confDir | Out-Null
$conf = Join-Path $confDir "conf.cfg"; $pattern = ".*md-design-sandbox.*"
$lines = @(); if (Test-Path $conf) { $lines = @(Get-Content $conf -Encoding UTF8) }
$idx = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*DisableUnsafeActionProtection\s*=') { $idx = $i } }
if ($idx -lt 0) { $lines += "DisableUnsafeActionProtection=$pattern" }
elseif ($lines[$idx] -notlike "*$pattern*") { $lines[$idx] = $lines[$idx].TrimEnd(';') + ";" + $pattern }
[IO.File]::WriteAllLines($conf, $lines, (New-Object Text.UTF8Encoding $false))

# --- публикация -------------------------------------------------------------------------------------
$pub = Join-Path $web "publication"; $logs = Join-Path $web "logs"; $confHttpd = Join-Path $web "conf\httpd.conf"
New-Item -ItemType Directory -Force $pub, $logs, (Split-Path $confHttpd) | Out-Null
$vrd = @"
<?xml version="1.0" encoding="UTF-8"?>
<point xmlns="http://v8.1c.ru/8.2/virtual-resource-system"
		xmlns:xs="http://www.w3.org/2001/XMLSchema"
		xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
		base="/md-design-sandbox"
		ib="File=&quot;$ib&quot;;">
</point>
"@
[IO.File]::WriteAllText((Join-Path $pub "default.vrd"), $vrd, (New-Object Text.UTF8Encoding $false))
$f = { param($p) $p -replace '\\', '/' }
$httpdConf = @"
Define SRVROOT "$(& $f (Join-Path $web 'apache\Apache24'))"
ServerRoot "`${SRVROOT}"
Listen 127.0.0.1:$Port
ServerName 127.0.0.1:$Port
PidFile "$(& $f $logs)/httpd.pid"
ErrorLog "$(& $f $logs)/error.log"
LogLevel warn
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule alias_module modules/mod_alias.so
LoadModule mime_module modules/mod_mime.so
LoadModule dir_module modules/mod_dir.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule _1cws_module "$(& $f (Join-Path $bin 'wsap24.dll'))"
TypesConfig conf/mime.types
DocumentRoot "$(& $f $pub)"
<Directory />
    AllowOverride None
    Require all denied
</Directory>
Alias "/md-design-sandbox" "$(& $f $pub)"
<Directory "$(& $f $pub)">
    AllowOverride All
    Options None
    Require all granted
    SetHandler 1c-application
    ManagedApplicationDescriptor "$(& $f $pub)/default.vrd"
</Directory>
"@
[IO.File]::WriteAllText($confHttpd, $httpdConf, (New-Object Text.UTF8Encoding $false))

# --- Playwright и Firefox -----------------------------------------------------------------------------
$runner = Join-Path $web "runner"; New-Item -ItemType Directory -Force $runner | Out-Null
$env:PLAYWRIGHT_BROWSERS_PATH = Join-Path $web "browsers"
Push-Location $runner
try {
    if (-not (Test-Path (Join-Path $runner "node_modules\playwright-core"))) {
        Write-Step "Установка playwright-core"
        if (-not (Test-Path (Join-Path $runner "package.json"))) { npm init -y *> $null }
        npm install playwright-core@1.48.2 --no-audit --no-fund *> $null
        if ($LASTEXITCODE -ne 0) { throw "npm install playwright-core завершился с ошибкой." }
    }
    if (-not (Get-ChildItem $env:PLAYWRIGHT_BROWSERS_PATH -Directory -Filter "firefox-*" -ErrorAction SilentlyContinue)) {
        Write-Step "Скачивание Firefox для Playwright"
        npx playwright-core install firefox *> $null
        if ($LASTEXITCODE -ne 0) { throw "Не удалось скачать Firefox для Playwright." }
    }
} finally { Pop-Location }
Copy-Item (Join-Path $PSScriptRoot "render.mjs") (Join-Path $runner "render.mjs") -Force

# --- MDDesign.epf ---------------------------------------------------------------------------------------
if ($EpfSource -eq "release") {
    $epf = Join-Path $sandbox "MDDesign.epf"
    if (-not (Test-Path $epf)) {
        $rel = Invoke-RestMethod "https://api.github.com/repos/crimsongoldteam/md_design/releases/latest"
        Invoke-WebRequest -UseBasicParsing ($rel.assets | Where-Object name -eq "MDDesign.epf" | Select-Object -First 1).browser_download_url -OutFile $epf
    }
}
else {
    # ВРЕМЕННО, до принятия PR crimsongoldteam/md_design#217: сборка из форка.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Для сборки «Накидки» из форка нужен git." }
    $src = Join-Path $web "md_design-src"
    if (-not (Test-Path (Join-Path $src ".git"))) {
        Write-Step "Клонирование $ForkRepo ($ForkBranch)"
        git clone -q --depth 1 -b $ForkBranch $ForkRepo $src
    }
    else {
        # Источник берётся из параметров на каждом прогоне: -ForkRepo может указывать и на локальную копию форка.
        git -C $src remote set-url origin $ForkRepo
        git -C $src fetch -q --depth 1 origin $ForkBranch
        git -C $src reset -q --hard FETCH_HEAD
    }
    $commit = (git -C $src rev-parse --short=8 HEAD).Trim()
    $epf = Join-Path $web "MDDesign-$commit.epf"
    if (-not (Test-Path $epf)) {
        Write-Step "Сборка MDDesign.epf из форка ($commit)"
        $buildIb = Join-Path $web "build-ib"
        if (-not (Test-Path (Join-Path $buildIb "1Cv8.1CD"))) { Invoke-Designer $bin @("CREATEINFOBASE", "File=""$buildIb"";") (Join-Path $web "build-create.log") 180 }
        $xml = Join-Path $src ("s" + "rc\MDDesign.xml")
        Invoke-Designer $bin @("DESIGNER", "/F", """$buildIb""", "/LoadExternalDataProcessorOrReportFromFiles", """$xml""", """$epf""") (Join-Path $web "build.log") 600
        if (-not (Test-Path $epf)) { throw "Сборка MDDesign.epf не удалась: $(Get-Content (Join-Path $web 'build.log') -Raw)" }
    }
}

if ($PrepareOnly) {
    $mdSrc = if ($EpfSource -eq "fork") { $src } else { $null }
    [ordered]@{ web = $web; runner = $runner; browsers = (Join-Path $web "browsers"); bin = $bin; epf = $epf; buildIb = (Join-Path $web "build-ib"); mdDesignSrc = $mdSrc } | ConvertTo-Json -Compress
    exit 0
}

# --- прогон -----------------------------------------------------------------------------------------------
$mdFull = if ($Markup) { (($Markup -split ';' | Where-Object { $_.Trim() } | ForEach-Object { (Resolve-Path $_.Trim()).Path }) -join ';') } else { "" }
if ($Pages -and $Pages -notmatch '^\s*\d+(\s*,\s*\d+)*\s*$') { throw "-Pages: номера страниц через запятую, например ""2,3""." }
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { throw "Порт $Port занят. Укажите другой: -Port <номер>." }
$apache = Start-Process -FilePath $httpd -ArgumentList @("-f", """$confHttpd""") -WindowStyle Hidden -PassThru
$url = "http://127.0.0.1:$Port/md-design-sandbox/ru_RU/"
$json = $null
try {
    $deadline = (Get-Date).AddSeconds(30); $up = $false
    while (-not $up -and (Get-Date) -lt $deadline) {
        try { $up = (Invoke-WebRequest -UseBasicParsing $url -TimeoutSec 5).StatusCode -eq 200 } catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $up) { throw "Apache не ответил за 30 секунд. Журнал: $(Join-Path $logs 'error.log')" }
    $source = if ($OpenEpf) { @("--open", (Resolve-Path $OpenEpf).Path) } else { @("--markup", $mdFull) }
    $lines = & node (Join-Path $runner "render.mjs") --url $url --epf $epf @source --out $OutDir --prefix $Prefix --pages $Pages
    $json = ($lines | Where-Object { $_ -like '{*' -or $_ -like '[[]*' } | Select-Object -Last 1)
}
finally {
    # Сеанс 1С живёт в процессе Apache: остановка Apache завершает и его, следующий прогон начнётся чисто.
    $children = (Get-CimInstance Win32_Process -Filter "ParentProcessId=$($apache.Id)" -ErrorAction SilentlyContinue).ProcessId
    foreach ($c in $children) { Stop-Process -Id $c -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $apache.Id -Force -ErrorAction SilentlyContinue
}
if (-not $json) { throw "Сценарий браузера не вернул результат." }
$json
if (@($json | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.error }).Count -gt 0) { exit 1 }
