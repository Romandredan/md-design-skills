<#
.SYNOPSIS
  Формирует форму из разметки «Накидки» (md_design) в 1С и снимает каждую страницу в PNG.

.DESCRIPTION
  Полный прогон без участия пользователя:
    1. находит тонкий клиент 1С последней установленной версии;
    2. скачивает MDDesign.epf из последнего релиза (кэш в %LOCALAPPDATA%\md-design-sandbox);
    3. создаёт пустую файловую базу-песочницу (один раз);
    4. снимает защиту от опасных действий только для песочницы — строкой
       DisableUnsafeActionProtection в пользовательском conf.cfg (%LOCALAPPDATA%\1C\1cv8\conf);
       без этого поле HTML-документа обработки показывает «Предупреждение безопасности»
       и запуск зависает до ответа человека;
    5. запускает клиент с обработкой, вставляет разметку через буфер обмена, нажимает «Сформировать»;
    6. находит закладки страниц верхнего уровня по пикселям и снимает каждую страницу;
    7. закрывает только свой клиент (по PID) и возвращает прежнее содержимое буфера обмена.

  Экран пользователя на время прогона (около минуты) занят окном 1С.

.PARAMETER Markup
  Путь к файлу с разметкой (UTF-8).
.PARAMETER OutDir
  Каталог для снимков.
.PARAMETER Prefix
  Префикс имён файлов: <Prefix>-01.png, <Prefix>-02.png, ...
.PARAMETER KeepOpen
  Не закрывать клиент 1С после снимков.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File render.ps1 -Markup form.txt -OutDir .\img -Prefix wizard
#>
param(
    [Parameter(Mandatory = $true)][string]$Markup,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$Prefix = "page",
    [string]$PlatformBin = "",
    [int]$LoadWaitSec = 18,
    [int]$RenderWaitSec = 8,
    [switch]$KeepOpen
)
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class MdUi {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(int f, int x, int y, int d, int e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, int f, int e);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);

  // Модальные окна клиента 1С (ошибка, предупреждение, вопрос) — отдельные окна процесса
  // класса V8TopLevelFrameSDIsec; основное окно — V8TopLevelFrameSDI. Возвращает их прямоугольники.
  public static List<RECT> Dialogs(uint pid) {
    var res = new List<RECT>();
    EnumWindows((h, p) => {
      uint wp; GetWindowThreadProcessId(h, out wp);
      if (wp == pid && IsWindowVisible(h)) {
        var c = new System.Text.StringBuilder(64); GetClassName(h, c, 64);
        if (c.ToString() == "V8TopLevelFrameSDIsec") { RECT r; GetWindowRect(h, out r); res.Add(r); }
      }
      return true;
    }, IntPtr.Zero);
    return res;
  }

  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

  // Окно, которому разрешено получать ввод скрипта. Клики и клавиши уходят в активное окно,
  // поэтому перед каждым вводом проверяется, что активно именно оно; иначе ввод не отправляется.
  public static IntPtr Target = IntPtr.Zero;

  // Windows не даёт фоновому процессу забрать фокус, пока пользователь работает в другом окне.
  // Штатный обход: нажатие Alt снимает блокировку, присоединение очереди ввода к активному окну
  // разрешает SetForegroundWindow. Возвращает, стало ли окно активным.
  public static bool Activate(IntPtr h) {
    if (GetForegroundWindow() == h) return true;
    keybd_event(0x12, 0, 0, 0); keybd_event(0x12, 0, 2, 0);
    uint fgPid; uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out fgPid);
    uint me = GetCurrentThreadId();
    AttachThreadInput(me, fgThread, true);
    ShowWindow(h, 3); BringWindowToTop(h); SetForegroundWindow(h);
    AttachThreadInput(me, fgThread, false);
    System.Threading.Thread.Sleep(400);
    return GetForegroundWindow() == h;
  }

  static void Guard() {
    if (Target == IntPtr.Zero) throw new InvalidOperationException("Не задано окно 1С для ввода.");
    if (GetForegroundWindow() != Target && !Activate(Target))
      throw new InvalidOperationException("Окно 1С не на переднем плане, ввод не отправлен: во время прогона другое окно забрало фокус. Не работайте за компьютером примерно минуту и запустите снова.");
  }

  public static void Click(int x, int y) {
    Guard();
    SetCursorPos(x, y); System.Threading.Thread.Sleep(150);
    Guard();
    mouse_event(2, 0, 0, 0, 0); mouse_event(4, 0, 0, 0, 0);
  }
  // Сочетания клавиш до поля HTML-документа доходят только через keybd_event, SendKeys печатает буквы.
  public static void Combo(byte mod, byte key) {
    Guard();
    keybd_event(mod, 0, 0, 0); System.Threading.Thread.Sleep(60);
    keybd_event(key, 0, 0, 0); System.Threading.Thread.Sleep(60);
    keybd_event(key, 0, 2, 0); System.Threading.Thread.Sleep(60);
    keybd_event(mod, 0, 2, 0);
  }

  static int[] Sums(Bitmap bmp) {
    var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
    int stride = data.Stride; byte[] buf = new byte[stride * bmp.Height];
    Marshal.Copy(data.Scan0, buf, 0, buf.Length); bmp.UnlockBits(data);
    int[] s = new int[bmp.Width * bmp.Height];
    for (int y = 0; y < bmp.Height; y++)
      for (int x = 0; x < bmp.Width; x++) { int i = y * stride + x * 3; s[y * bmp.Width + x] = buf[i] + buf[i + 1] + buf[i + 2]; }
    return s;
  }
  static char Cls(int sum) { return sum == 765 ? 'W' : (sum < 450 ? 'D' : (sum < 700 ? 'G' : 'L')); }

  // Ищет строку закладок: подряд n сегментов, разделённых серыми границами шириной 1–4 пикселя,
  // первый сегмент белый (выбранная закладка), остальные однотонно-светлые. Возвращает
  // [y, x1, x2, x1, x2, ...] или пустой массив.
  public static int[] FindTabs(Bitmap bmp, int n, int yFrom, int yTo) {
    int w = bmp.Width; int[] s = Sums(bmp);
    for (int y = yFrom; y < Math.Min(yTo, bmp.Height); y++) {
      var runs = new List<int[]>(); char prev = ' '; int start = 0;
      for (int x = 0; x <= w; x++) {
        char c = x < w ? Cls(s[y * w + x]) : '#';
        if (c != prev) { if (prev != ' ') runs.Add(new int[] { prev, start, x - 1 }); prev = c; start = x; }
      }
      for (int i = 0; i < runs.Count; i++) {
        var segs = new List<int[]>(); int j = i;
        while (j + 2 < runs.Count) {
          var sep = runs[j]; var seg = runs[j + 1]; var sep2 = runs[j + 2];
          bool sepOk = sep[0] == 'G' && sep[2] - sep[1] < 4 && sep2[0] == 'G' && sep2[2] - sep2[1] < 4;
          bool segOk = (seg[0] == 'W' || seg[0] == 'L') && seg[2] - seg[1] >= 30;
          if (!sepOk || !segOk) break;
          segs.Add(seg); j += 2;
        }
        if (segs.Count >= n && segs[0][0] == 'W') {
          bool restL = true; for (int k = 1; k < n; k++) if (segs[k][0] != 'L') restL = false;
          if (!restL) continue;
          var res = new List<int> { y };
          for (int k = 0; k < n; k++) { res.Add(segs[k][1]); res.Add(segs[k][2]); }
          return res.ToArray();
        }
      }
    }
    return new int[0];
  }

  // Пунктирный разделитель панели редактора и формы: столбец с наибольшим числом
  // чередований «белый / не белый» в полосе y1..y2. Сплошные рамки дают мало чередований,
  // текст — заметно меньше, чем пунктир через пиксель-два. Возвращает x или -1.
  public static int FindSeparator(Bitmap bmp, int xFrom, int xTo, int y1, int y2) {
    int w = bmp.Width; int[] s = Sums(bmp); int best = -1, bestCnt = 0;
    for (int x = xFrom; x < Math.Min(xTo, w); x++) {
      int cnt = 0; bool prevW = true;
      for (int y = y1; y < Math.Min(y2, bmp.Height); y++) { bool isW = s[y * w + x] >= 735; if (isW != prevW) cnt++; prevW = isW; }
      if (cnt > bestCnt) { bestCnt = cnt; best = x; }
    }
    return bestCnt > (y2 - y1) / 4 ? best : -1;
  }

  // Белая ли полоса закладки в строке закладок: выбранная закладка белая, остальные светло-серые.
  public static bool IsSelectedTab(Bitmap bmp, int x1, int x2, int y) {
    int[] s = Sums(bmp); int w = bmp.Width; int white = 0, total = 0;
    for (int x = x1 + 3; x < x2 - 3; x++) { total++; if (s[y * w + x] == 765) white++; }
    return total > 0 && white * 10 >= total * 9;
  }

  // Сколько пикселей прямоугольника различается на двух снимках: так видно, сформировалась ли форма.
  public static int DiffCount(Bitmap a, Bitmap b, int x1, int y1, int x2, int y2) {
    int w = a.Width; int[] sa = Sums(a); int[] sb = Sums(b); int cnt = 0;
    for (int y = y1; y < Math.Min(y2, a.Height); y++)
      for (int x = x1; x < Math.Min(x2, w); x++) if (sa[y * w + x] != sb[y * w + x]) cnt++;
    return cnt;
  }

  // Нижняя граница содержимого в прямоугольнике: последняя строка с не-светлым пикселем.
  public static int LastContentRow(Bitmap bmp, int x1, int y1, int x2, int y2) {
    int w = bmp.Width; int[] s = Sums(bmp);
    for (int y = Math.Min(y2, bmp.Height - 1); y > y1; y--)
      for (int x = x1; x < Math.Min(x2, w); x++) if (s[y * w + x] < 700) return y;
    return y2;
  }
}
"@

function Get-PlatformBin {
    if ($PlatformBin) { return $PlatformBin }
    $cands = foreach ($root in "C:\Program Files\1cv8", "C:\Program Files (x86)\1cv8") {
        if (Test-Path $root) { Get-ChildItem $root -Directory | Where-Object { Test-Path (Join-Path $_.FullName "bin\1cv8c.exe") } }
    }
    $best = $cands | Sort-Object { [version]($_.Name -replace '[^\d\.]', '') } -Descending | Select-Object -First 1
    if (-not $best) { throw "Не найден тонкий клиент 1С (1cv8c.exe) в Program Files\1cv8." }
    return (Join-Path $best.FullName "bin")
}

function Get-WindowRect($h) {
    $r = New-Object MdUi+RECT
    [MdUi]::GetWindowRect($h, [ref]$r) | Out-Null
    return $r
}

function Get-Shot($r, [switch]$NoGuard) {
    # Снимок берётся с экрана: если активно чужое окно, на снимок попадёт оно.
    if (-not $NoGuard -and [MdUi]::Target -ne [IntPtr]::Zero -and -not [MdUi]::Activate([MdUi]::Target)) {
        throw "Окно 1С перестало быть активным во время прогона, снимок не сделан. Не работайте за компьютером примерно минуту и запустите снова."
    }
    $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T), ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
    $g.Dispose()
    return $bmp
}

function Save-Crop($bmp, $x1, $y1, $x2, $y2, $path) {
    $x1 = [Math]::Max(0, $x1); $y1 = [Math]::Max(0, $y1)
    $x2 = [Math]::Min($bmp.Width - 1, $x2); $y2 = [Math]::Min($bmp.Height - 1, $y2)
    $rect = New-Object System.Drawing.Rectangle $x1, $y1, ($x2 - $x1), ($y2 - $y1)
    $crop = $bmp.Clone($rect, $bmp.PixelFormat)
    $crop.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $crop.Dispose()
}

# Модальное окно процесса 1С: снимок в <Prefix>-error.png и исключение с текстом $what.
function Assert-NoDialog($proc, $what) {
    $dlg = [MdUi]::Dialogs([uint32]$proc.Id)
    if ($dlg.Count -eq 0) { return }
    Start-Sleep -Milliseconds 500
    $d = $dlg[0]
    $rect = New-Object MdUi+RECT
    $rect.L = $d.L - 20; $rect.T = $d.T - 20; $rect.R = $d.R + 20; $rect.B = $d.B + 20
    $shot = Get-Shot $rect -NoGuard              # активно само модальное окно, основное не выводим
    $path = Join-Path $OutDir "$Prefix-error.png"
    $shot.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $shot.Dispose()
    $script:errorShot = $path
    throw "$what Снимок окна: $path"
}

# --- подготовка песочницы ---------------------------------------------------------------
$sandbox = Join-Path $env:LOCALAPPDATA "md-design-sandbox"
New-Item -ItemType Directory -Force $sandbox, $OutDir | Out-Null
$bin = Get-PlatformBin
$epf = Join-Path $sandbox "MDDesign.epf"
if (-not (Test-Path $epf)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod "https://api.github.com/repos/crimsongoldteam/md_design/releases/latest"
    $asset = $rel.assets | Where-Object { $_.name -eq "MDDesign.epf" } | Select-Object -First 1
    Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $epf
    Set-Content (Join-Path $sandbox "version.txt") $rel.tag_name
}
$ib = Join-Path $sandbox "ib"
if (-not (Test-Path (Join-Path $ib "1Cv8.1CD"))) {
    $log = Join-Path $sandbox "create.log"
    $p = Start-Process -FilePath (Join-Path $bin "1cv8.exe") -PassThru -NoNewWindow `
        -ArgumentList @("CREATEINFOBASE", "File=""$ib"";", "/DisableStartupDialogs", "/Out", """$log""")
    if (-not $p.WaitForExit(180000)) { $p.Kill(); throw "CREATEINFOBASE не завершился за 3 минуты." }
    if (-not (Test-Path (Join-Path $ib "1Cv8.1CD"))) { throw "База-песочница не создана: $(Get-Content $log -Raw)" }
}

# Защита от опасных действий снимается только для баз, строка соединения которых содержит md-design-sandbox.
$confDir = Join-Path $env:LOCALAPPDATA "1C\1cv8\conf"
New-Item -ItemType Directory -Force $confDir | Out-Null
$conf = Join-Path $confDir "conf.cfg"
$pattern = ".*md-design-sandbox.*"
$lines = @(); if (Test-Path $conf) { $lines = @(Get-Content $conf -Encoding UTF8) }
$idx = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*DisableUnsafeActionProtection\s*=') { $idx = $i } }
if ($idx -lt 0) { $lines += "DisableUnsafeActionProtection=$pattern" }
elseif ($lines[$idx] -notlike "*$pattern*") { $lines[$idx] = $lines[$idx].TrimEnd(';') + ";" + $pattern }
[IO.File]::WriteAllLines($conf, $lines, (New-Object Text.UTF8Encoding $false))

# --- число страниц верхнего уровня: строки, начинающиеся с «/» без отступа ---------------
$text = [IO.File]::ReadAllText((Resolve-Path $Markup), [Text.Encoding]::UTF8)
$pageNames = @([regex]::Matches($text, '(?m)^/(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() })

# --- запуск и формирование ------------------------------------------------------------------
$oldClip = $null; try { $oldClip = Get-Clipboard -Raw } catch { }
$proc = Start-Process -FilePath (Join-Path $bin "1cv8c.exe") -PassThru `
    -ArgumentList @("ENTERPRISE", "/F""$ib""", "/Execute""$epf""", "/DisableStartupDialogs", "/DisableStartupMessages")
Write-Host "MDDESIGN_PID=$($proc.Id)"            # для -KeepOpen: остановить клиент можно только по этому PID
try {
    $deadline = (Get-Date).AddSeconds(90)
    do { Start-Sleep -Milliseconds 500; $proc.Refresh() } while ($proc.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline)
    if ($proc.MainWindowHandle -eq 0) { throw "Окно 1С не появилось за 90 секунд." }
    Start-Sleep -Seconds $LoadWaitSec          # редактор обработки — поле HTML, грузится после окна
    $h = $proc.MainWindowHandle
    [MdUi]::Target = $h                        # весь ввод скрипта — только в это окно
    [MdUi]::ShowWindow($h, 3) | Out-Null       # развернуть: координаты ниже рассчитаны на развёрнутое окно
    if (-not [MdUi]::Activate($h)) {
        throw "Окно 1С не удалось вывести на передний план: активно другое окно. Ввод не отправлялся. Не работайте за компьютером примерно минуту и запустите снова."
    }
    Start-Sleep -Milliseconds 800
    $r = Get-WindowRect $h
    Assert-NoDialog $proc "При открытии обработки появилось модальное окно 1С (предупреждение или ошибка)."

    Set-Clipboard -Value $text
    # Редактор — поле HTML и грузится с разной скоростью: если вставка ушла раньше его готовности,
    # правая панель после «Сформировать» не меняется. Тогда вставка и формирование повторяются.
    $bmp = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $before = Get-Shot $r
        [MdUi]::Click($r.L + 120, $r.T + 500)  # поле редактора; при любом положении разделителя оно начинается у x≈60
        Start-Sleep -Milliseconds 400
        [MdUi]::Combo(0x11, 0x41); Start-Sleep -Milliseconds 300   # Ctrl+A
        [MdUi]::Combo(0x11, 0x56); Start-Sleep -Seconds 2          # Ctrl+V
        [MdUi]::Click($r.L + 130, $r.T + 181)  # «Сформировать» — при первом открытии панель редактора развёрнута
        Start-Sleep -Seconds $RenderWaitSec
        Assert-NoDialog $proc ("Формирование завершилось окном ошибки 1С: в разметке конструкция, которую «Накидка» " +
            "не обрабатывает (например, две таблицы подряд без элемента между ними).")
        $bmp = Get-Shot $r
        $x1 = [int]($bmp.Width * 0.75)
        $changed = [MdUi]::DiffCount($before, $bmp, $x1, 160, $bmp.Width - 20, 700)
        $before.Dispose()
        if ($changed -gt 500) { break }
        Write-Warning "Форма не сформировалась (попытка $attempt), повтор через 8 секунд."
        $bmp.Dispose(); $bmp = $null
        Start-Sleep -Seconds 8
    }
    if ($null -eq $bmp) { throw "Форма не сформировалась за 3 попытки: проверьте, что обработка открылась." }

    $files = @()
    $tabs = @(); $notOpened = @()
    if ($pageNames.Count -ge 2) { $tabs = [MdUi]::FindTabs($bmp, $pageNames.Count, 150, 700) }
    if ($pageNames.Count -ge 2 -and $tabs.Count -eq 0) {
        $dbg = Join-Path $OutDir "$Prefix-debug.png"; $bmp.Save($dbg)
        Write-Warning "Закладки страниц не найдены (ожидалось $($pageNames.Count)). Снимок окна: $dbg"
        $files += $dbg
    }
    elseif ($tabs.Count -gt 0) {
        $tabY = $tabs[0]; $left = $tabs[1] - 12
        $bmp.Dispose()
        for ($k = 0; $k -lt $pageNames.Count; $k++) {
            $cx = [int](($tabs[1 + 2 * $k] + $tabs[2 + 2 * $k]) / 2)
            [MdUi]::Click($r.L + $cx, $r.T + $tabY + 6)
            Start-Sleep -Milliseconds 1500
            $shot = Get-Shot $r
            # Клик по закладке иногда не срабатывает, и снимок повторил бы предыдущую страницу:
            # проверяем, что закладка стала выбранной, при неудаче кликаем ещё раз.
            if (-not [MdUi]::IsSelectedTab($shot, $tabs[1 + 2 * $k], $tabs[2 + 2 * $k], $tabY)) {
                $shot.Dispose()
                [MdUi]::Click($r.L + $cx, $r.T + $tabY + 6)
                Start-Sleep -Milliseconds 2000
                $shot = Get-Shot $r
            }
            if (-not [MdUi]::IsSelectedTab($shot, $tabs[1 + 2 * $k], $tabs[2 + 2 * $k], $tabY)) {
                Write-Warning "Страница «$($pageNames[$k])» не открылась после двух кликов: возможно, она пуста или её содержимое разобрано с ошибкой. Снимок не сделан."
                $notOpened += $pageNames[$k]
                $shot.Dispose(); continue
            }
            # Левее первой закладки идёт пунктир разделителя панелей до низа окна — его не учитываем.
            $bottom = [MdUi]::LastContentRow($shot, $left + 20, $tabY, $shot.Width - 20, $shot.Height - 15)
            $path = Join-Path $OutDir ("{0}-{1:D2}.png" -f $Prefix, ($k + 1))
            # Верх — строка заголовка формы (y≈160 в развёрнутом окне); над закладками может быть командная панель.
            Save-Crop $shot $left ([Math]::Min($tabY - 45, 158)) ($shot.Width - 14) ($bottom + 12) $path
            $shot.Dispose(); $files += $path
        }
    }
    else {
        # Форма без страниц: левая граница — пунктирный разделитель панелей; не нашёлся — всё окно.
        $path = Join-Path $OutDir "$Prefix-01.png"
        $sep = [MdUi]::FindSeparator($bmp, 150, $bmp.Width - 150, 300, $bmp.Height - 60)
        if ($sep -lt 0) {
            Write-Warning "Разделитель панелей не найден, снимается всё окно."
            Save-Crop $bmp 0 125 ($bmp.Width - 8) ($bmp.Height - 8) $path
        }
        else {
            $bottom = [MdUi]::LastContentRow($bmp, $sep + 10, 158, $bmp.Width - 20, $bmp.Height - 15)
            Save-Crop $bmp ($sep + 4) 158 ($bmp.Width - 14) ($bottom + 12) $path
        }
        $bmp.Dispose(); $files += $path
    }
    [pscustomobject]@{ pages = $pageNames; files = $files; notOpened = $notOpened; pid = $proc.Id } | ConvertTo-Json -Depth 3
}
finally {
    if (-not $KeepOpen -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        # Следующий прогон должен стартовать после полного завершения клиента: база-песочница файловая.
        $proc.WaitForExit(15000) | Out-Null
    }
    if ($null -ne $oldClip) { Set-Clipboard -Value $oldClip } else { try { Set-Clipboard -Value " " } catch { } }
}
