# HelperMCP agent for Windows 10/11 (PowerShell 5.1+). Runs in memory, installs nothing.
#   [Net.ServicePointManager]::SecurityProtocol=3072; irm RELAY/h | iex
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Stop'  # restored at the end: iex runs in the user's session
$RELAY = if ($env:HELPER_RELAY) { $env:HELPER_RELAY } else { '__RELAY__' }
$ru = (Get-Culture).TwoLetterISOLanguageName -eq 'ru'
function T($r, $e) { if ($ru) { $r } else { $e } }
$AskTools = 'run', 'start_process', 'fetch_file', 'write_file', 'click', 'type_text', 'press_key', 'scroll', 'mcp_start', 'mcp_call'
$NodeVersion = 'v22.11.0'; $NodeMin = 20   # Playwright & co. need Node >= 20
$script:NodeDir = $null; $script:NodeBin = $null
$script:TmpDirs = @(); $script:OverlayProc = $null
$script:ExtraPath = @()   # dirs of portable runtimes (node, uv) put in front of PATH for everything we start
$script:Started = @()    # processes launched with start_process (listed by sysinfo, left running on exit)
$Children = @{}   # name -> other MCP servers running on this PC
$MaxOut = 100000

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace H -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr e);
'@
[void][H.U]::SetProcessDPIAware()   # real pixels, not scaled ones

function Api($path, $data, $token, $timeout = 40) {
    $h = @{}
    if ($token) { $h.Authorization = "Bearer $token" }
    if ($null -ne $data) {
        $b = [Text.Encoding]::UTF8.GetBytes(($data | ConvertTo-Json -Depth 6 -Compress))
        if ($b.Length -gt 2048) {   # weak links: big outputs shrink a lot
            $ms = New-Object IO.MemoryStream; $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress)
            $gz.Write($b, 0, $b.Length); $gz.Close(); $b = $ms.ToArray(); $h['Content-Encoding'] = 'gzip'
        }
        Invoke-WebRequest -Uri "$RELAY$path" -Method Post -Headers $h -Body $b -ContentType 'application/json; charset=utf-8' -TimeoutSec $timeout -UseBasicParsing
    } else {
        Invoke-WebRequest -Uri "$RELAY$path" -Headers $h -TimeoutSec $timeout -UseBasicParsing
    }
}
function Clip($s) { if ($s.Length -gt $MaxOut) { $s.Substring(0, $MaxOut) + "`n...[truncated]" } else { $s } }

$Scale = 1.0
$script:OriginX = [Windows.Forms.SystemInformation]::VirtualScreen.Left; $script:OriginY = [Windows.Forms.SystemInformation]::VirtualScreen.Top   # real px of the screenshot's top-left

function Do-Screenshot($a) {
    $s = [Windows.Forms.SystemInformation]::VirtualScreen   # all monitors, or just one with "monitor"
    if ($null -ne $a.monitor) {
        $all = [Windows.Forms.Screen]::AllScreens
        if ([int]$a.monitor -lt 0 -or [int]$a.monitor -ge $all.Count) { throw "No monitor $($a.monitor). Monitors: 0..$($all.Count - 1)" }
        $s = $all[[int]$a.monitor].Bounds
    }
    $view = [bool]$a.view   # the live viewer's frames must not change the coordinates the AI clicks with
    if (-not $view) { $script:OriginX = $s.Left; $script:OriginY = $s.Top }
    $bmp = New-Object Drawing.Bitmap $s.Width, $s.Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($s.Left, $s.Top, 0, 0, $bmp.Size)
    $g.Dispose()
    $cap = if ($a.max_width) { [int]$a.max_width } elseif ($view) { 1280 } else { 1920 }
    $qual = if ($a.quality) { [long]$a.quality } elseif ($view) { 65L } else { 70L }
    $w = [Math]::Min($cap, $s.Width)
    $sc = $s.Width / $w
    if (-not $view) { $script:Scale = $sc }
    $out = New-Object Drawing.Bitmap $w, ([int]($s.Height / $sc))
    $g = [Drawing.Graphics]::FromImage($out)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.DrawImage($bmp, 0, 0, $out.Width, $out.Height)
    $g.Dispose(); $bmp.Dispose()
    $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
    $p = New-Object Drawing.Imaging.EncoderParameters 1
    $p.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), $qual
    $ms = New-Object IO.MemoryStream
    $out.Save($ms, $enc, $p); $out.Dispose()
    $bytes = $ms.ToArray()
    $hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash($bytes)).Replace('-', '').ToLower()
    if ($a.prev -and $a.prev -eq $hash) { return @{ same = $true; h = $hash } }   # nothing changed: send nothing
    @{ jpeg = $bytes; mime = 'image/jpeg'; h = $hash }
}

# Screenshots go as the raw JPEG body (no base64 inflation), everything else as (gzipped) JSON.
function Post-Result($res, $token) {
    if ($res.ok -and $res.data -is [hashtable] -and $res.data.jpeg) {
        $meta = @{}; foreach ($k in $res.data.Keys) { if ($k -ne 'jpeg' -and $k -ne 'mime') { $meta[$k] = $res.data[$k] } }
        $h = @{ Authorization = "Bearer $token"; 'X-Result-Id' = $res.id; 'X-Result-Meta' = [Uri]::EscapeDataString(($meta | ConvertTo-Json -Compress)) }
        [void](Invoke-WebRequest -Uri "$RELAY/a/result" -Method Post -Headers $h -Body ([byte[]]$res.data.jpeg) -ContentType $res.data.mime -TimeoutSec 60 -UseBasicParsing)
    } else { [void](Api '/a/result' $res $token 60) }
}

function Do-Click($a) {
    $x = [int]($a.x * $Scale) + $script:OriginX; $y = [int]($a.y * $Scale) + $script:OriginY
    [void][H.U]::SetCursorPos($x, $y)
    $btn = if ($a.button) { $a.button } else { 'left' }
    $down, $up = switch ($btn) { 'right' { 8, 16 } 'middle' { 32, 64 } default { 2, 4 } }
    $n = if ($a.double) { 2 } else { 1 }
    1..$n | ForEach-Object {
        [H.U]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero); [H.U]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 40
    }
    @{ text = 'ok' }
}

function Do-TypeText($a) {
    # SendKeys treats + ^ % ~ ( ) { } [ ] specially: wrap each in braces
    $esc = [regex]::Replace($a.text, '[+^%~(){}\[\]]', '{$0}')
    $esc = $esc -replace "`r?`n", '{ENTER}'
    [Windows.Forms.SendKeys]::SendWait($esc)
    @{ text = 'ok' }
}

$Vk = @{ ctrl = 0x11; control = 0x11; alt = 0x12; shift = 0x10; win = 0x5B; windows = 0x5B; enter = 0x0D; return = 0x0D
    esc = 0x1B; escape = 0x1B; tab = 0x09; space = 0x20; backspace = 0x08; delete = 0x2E; del = 0x2E; home = 0x24; end = 0x23
    pageup = 0x21; pagedown = 0x22; left = 0x25; up = 0x26; right = 0x27; down = 0x28 }
1..12 | ForEach-Object { $Vk["f$_"] = 0x6F + $_ }
function Do-PressKey($a) {
    $codes = foreach ($k in $a.keys.ToLower().Split('+')) {
        if ($Vk.ContainsKey($k)) { [byte]$Vk[$k] }
        elseif ($k.Length -eq 1) { [byte][char]$k.ToUpper() }
        else { throw "Unknown key '$k'" }
    }
    $codes | ForEach-Object { [H.U]::keybd_event($_, 0, 0, [UIntPtr]::Zero) }
    [array]::Reverse($codes)
    $codes | ForEach-Object { [H.U]::keybd_event($_, 0, 2, [UIntPtr]::Zero) }
    @{ text = 'ok' }
}

# A command mentions uv/uvx/npx/npm/node that is not installed? Fetch the portable one first (as if it had always been there).
function Ensure-For($text) {
    foreach ($m in [regex]::Matches([string]$text, '(?:^|[\s;&|(])(uvx|uv|npx|npm|node)(?=[\s;&|)]|$)')) {
        $w = $m.Groups[1].Value
        try { Ensure-Node $w; Ensure-Uv $w } catch { Write-Host "[helper] could not prepare ${w}: $($_.Exception.Message)" }
    }
}

function Do-Run($a) {
    Ensure-For $a.command
    $secs = if ($a.timeout_s) { [int]$a.timeout_s } else { 60 }
    $cmd = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference="SilentlyContinue"; ' + $a.command
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($script:ExtraPath.Count) { $psi.EnvironmentVariables['PATH'] = ($script:ExtraPath -join ';') + ';' + $env:PATH }
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'; $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'   # Python tools crash on non-ASCII output otherwise
    if ($a.cwd) { $psi.WorkingDirectory = $a.cwd }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds($secs)
    while (-not $p.WaitForExit(400)) {
        if ([DateTime]::UtcNow -gt $deadline) { Stop-Tree $p; return @{ text = "[timeout after ${secs}s]" } }
        Pump-Light
    }
    [void]$p.WaitForExit()
    @{ text = Clip ("[exit $($p.ExitCode)]`n" + $o.Result + $e.Result) }
}

function Do-ReadFile($a) {
    if ($a.path -match '\.(png|jpe?g|gif|bmp|webp|tiff?)$') {   # an image: return it as an image, scaled down to max_width (default 1600)
        $cap = if ($a.max_width) { [int]$a.max_width } else { 1600 }
        $img = [Drawing.Image]::FromFile((Resolve-Path -LiteralPath $a.path).Path)
        try {
            $w = [Math]::Min($cap, $img.Width); $h = [int]($img.Height * $w / $img.Width)
            $out = New-Object Drawing.Bitmap $w, $h
            $g = [Drawing.Graphics]::FromImage($out); $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($img, 0, 0, $w, $h); $g.Dispose()
            $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
            $ep = New-Object Drawing.Imaging.EncoderParameters 1
            $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), $(if ($a.quality) { [long]$a.quality } else { 80L })
            $ms = New-Object IO.MemoryStream; $out.Save($ms, $enc, $ep); $out.Dispose()
            return @{ jpeg = $ms.ToArray(); mime = 'image/jpeg'; text = "$($img.Width)x$($img.Height) image" }
        } finally { $img.Dispose() }
    }
    $max = if ($a.max_bytes) { [int]$a.max_bytes } else { 200000 }
    $fs = [IO.File]::Open($a.path, 'Open', 'Read', 'ReadWrite')
    try { $buf = New-Object byte[] ([Math]::Min($max, $fs.Length)); [void]$fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
    @{ text = [Text.Encoding]::UTF8.GetString($buf) }
}
# Upload a file to the relay and return a download link for the operator.
function Do-FetchFile($a) {
    $f = (Resolve-Path -LiteralPath $a.path).Path
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try {
        $resp = Invoke-WebRequest -Uri ("$RELAY/a/file?name=" + [Uri]::EscapeDataString((Split-Path $f -Leaf))) -Method Post -InFile $f `
            -Headers @{ Authorization = "Bearer $script:Token" } -ContentType 'application/octet-stream' -TimeoutSec 3600 -UseBasicParsing
    } finally { $ProgressPreference = $pp }
    $d = $resp.Content | ConvertFrom-Json
    @{ text = "$($d.url)  ($($d.size) bytes, link valid 24 h)" }
}
function Do-WriteFile($a) {
    [IO.File]::WriteAllText($a.path, $a.content, (New-Object Text.UTF8Encoding $false))
    @{ text = 'written' }
}
function Do-ListDir($a) {
    $rows = Get-ChildItem -LiteralPath $a.path -Force -ErrorAction SilentlyContinue | Select-Object -First 500 | ForEach-Object {
        '{0} {1,12} {2:yyyy-MM-dd HH:mm:ss} {3}' -f $(if ($_.PSIsContainer) { 'd' } else { '-' }), $(if ($_.PSIsContainer) { 0 } else { $_.Length }), $_.LastWriteTime, $_.Name
    }
    @{ text = ($rows -join "`n") }
}
function Do-SysInfo($a) {
    $os = Get-CimInstance Win32_OperatingSystem
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')
    @{ text = (@{
        os = "$($os.Caption) build $($os.BuildNumber)"; host = $env:COMPUTERNAME; user = $env:USERNAME; admin = $admin
        powershell = $PSVersionTable.PSVersion.ToString(); cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
        ram_gb = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1); free_ram_gb = [Math]::Round($os.FreePhysicalMemory / 1MB, 1)
        monitors = @([Windows.Forms.Screen]::AllScreens | ForEach-Object -Begin { $i = 0 } -Process { "{0}: {1}x{2} at {3},{4}{5}" -f $i++, $_.Bounds.Width, $_.Bounds.Height, $_.Bounds.X, $_.Bounds.Y, $(if ($_.Primary) { " (primary)" } else { "" }) }); boot = $os.LastBootUpTime.ToString('s'); lang = (Get-Culture).Name; node = (& { try { (& node -v 2>$null) } catch { $null } }); uv = (& { try { (& uv --version 2>$null) } catch { $null } })
        started = @($script:Started | ForEach-Object { '{0} running={1}' -f $_.Id, (-not $_.HasExited) })
    } | ConvertTo-Json) }
}

function Do-Scroll($a) {
    if ($null -ne $a.x -and $null -ne $a.y) { [void][H.U]::SetCursorPos([int]($a.x * $Scale) + $script:OriginX, [int]($a.y * $Scale) + $script:OriginY) }
    $n = if ($null -ne $a.amount) { [int]$a.amount } else { 3 }   # positive = down
    $delta = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int](-120 * $n)), 0)
    [H.U]::mouse_event(0x0800, 0, 0, $delta, [UIntPtr]::Zero)
    @{ text = 'ok' }
}

# Launch a program detached (GUI apps like Blender/Unity, servers) and return at once; it keeps running after this call.
function Resolve-Exe($cmd) {
    if (Test-Path -LiteralPath $cmd -PathType Leaf) { return (Resolve-Path -LiteralPath $cmd).Path }
    foreach ($d in $script:ExtraPath) { foreach ($e in '.exe', '.cmd', '.bat', '') { $f = Join-Path $d ($cmd + $e); if (Test-Path -LiteralPath $f -PathType Leaf) { return $f } } }
    foreach ($e in '.exe', '.cmd', '.bat', '') { $g = Get-Command ($cmd + $e) -CommandType Application -ErrorAction SilentlyContinue; if ($g) { return @($g)[0].Source } }
    $null
}
function Do-StartProcess($a) {
    Ensure-For ([IO.Path]::GetFileNameWithoutExtension([string]$a.command))
    $exe = Resolve-Exe $a.command
    if (-not $exe) { throw "Command '$($a.command)' not found" }
    $log = Join-Path $env:TEMP ("helpermcp-start-$PID-$($script:Started.Count).log")
    $argl = (@($a.args) | Where-Object { $null -ne $_ } | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi = New-Object Diagnostics.ProcessStartInfo 'cmd.exe'   # cmd keeps a log of the output; GUI windows still open normally
    $psi.Arguments = '/d /c ""' + $exe + '" ' + $argl + ' > "' + $log + '" 2>&1"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    if ($script:ExtraPath.Count) { $psi.EnvironmentVariables['PATH'] = ($script:ExtraPath -join ';') + ';' + $env:PATH }
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'; $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    if ($a.env) { foreach ($q in $a.env.PSObject.Properties) { $psi.EnvironmentVariables[$q.Name] = [string]$q.Value } }
    if ($a.cwd) { $psi.WorkingDirectory = $a.cwd }
    $proc = [Diagnostics.Process]::Start($psi); $script:Started += $proc
    $w = if ($null -ne $a.wait_s) { [Math]::Min([double]$a.wait_s, 30) } else { 2 }
    [void]$proc.WaitForExit([int]($w * 1000))
    $tail = if (Test-Path $log) { $t = Get-Content $log -Raw -ErrorAction SilentlyContinue; if ($t) { $t.Substring([Math]::Max(0, $t.Length - 1500)) } else { '' } } else { '' }
    if ($proc.HasExited) { @{ text = "[exited with code $($proc.ExitCode) right away]`n$tail" } } else { @{ text = "[started pid $($proc.Id), still running]`n$tail" } }
}

# uv/uvx (how most Python MCP servers are started) missing? Download the portable uv into a temp dir.
function Ensure-Uv($cmd) {
    if ($cmd -notmatch '^(uv|uvx)(\.exe)?$' -or (Resolve-Exe $cmd)) { return }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
    $dir = Join-Path $env:TEMP ('helpermcp-uv-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory $dir); $script:TmpDirs += $dir
    Write-Host '[helper] downloading portable uv ...'
    $zip = Join-Path $dir 'uv.zip'
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest "https://github.com/astral-sh/uv/releases/latest/download/uv-$arch-pc-windows-msvc.zip" -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $pp }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir); Remove-Item $zip
    $script:ExtraPath = @($dir) + $script:ExtraPath
}

function Node-Major { try { [int](((& node -v 2>$null) -as [string]).TrimStart('v').Split('.')[0]) } catch { 0 } }

# command="playwright": a real, visible browser with sound, like a normal Playwright MCP on a desktop.
function Playwright-Preset($a) {
    $exe = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $opts = [ordered]@{ headless = $false; chromiumSandbox = $true; ignoreDefaultArgs = @('--mute-audio', '--disable-blink-features=AutomationControlled'); args = @('--autoplay-policy=no-user-gesture-required') }
    if ($exe) { $opts.executablePath = $exe }
    $dir = Join-Path $env:TEMP ('helpermcp-pw-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory $dir); $script:TmpDirs += $dir
    $cfg = Join-Path $dir 'config.json'
    [IO.File]::WriteAllText($cfg, (@{ browser = @{ browserName = 'chromium'; launchOptions = $opts } } | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
    @{ command = 'npx'; args = @('-y', '@playwright/mcp@latest', '--config', $cfg) + @($a.args | Where-Object { $null -ne $_ }) }
}

# npx/node/npm missing or older than 20? Download a portable Node into a temp dir (removed on exit).
function Ensure-Node($cmd) {
    if ($cmd -notmatch '^(npx|npm|node)(\.cmd|\.exe)?$' -or $script:NodeBin -or ($cmd -match '^node(\.exe)?$' -and (Resolve-Exe $cmd)) -or (Node-Major) -ge $NodeMin) { return }   # a plain `node script.js` runs on whatever Node is installed; npx/npm packages usually need >= 20
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'Node.js is missing and there is no 32-bit portable build' }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $script:NodeDir = Join-Path $env:TEMP ('helpermcp-node-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory $script:NodeDir)
    Write-Host '[helper] downloading portable Node.js ...'
    $zip = Join-Path $script:NodeDir 'n.zip'
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'   # PS 5.1 progress bar makes downloads ~10x slower
    try { Invoke-WebRequest "https://nodejs.org/dist/$NodeVersion/node-$NodeVersion-win-$arch.zip" -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $pp }
    Add-Type -AssemblyName System.IO.Compression.FileSystem   # Expand-Archive is painfully slow on PS 5.1 (progress bar + per-file overhead)
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $script:NodeDir)
    Remove-Item $zip
    $script:NodeBin = (Get-ChildItem $script:NodeDir -Directory | Select-Object -First 1).FullName
    $script:ExtraPath = @($script:NodeBin) + $script:ExtraPath
}

function Quote-Arg($s) { if ($s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' } else { $s } }

function Child-Rpc($c, $method, $params, $timeoutSec = 60, [switch]$Notify) {
    $msg = [ordered]@{ jsonrpc = '2.0'; method = $method }
    if ($null -ne $params) { $msg.params = $params }
    if (-not $Notify) { $c.n++; $msg.id = $c.n }
    $json = $msg | ConvertTo-Json -Depth 20 -Compress
    if ($env:HELPER_DEBUG) { Write-Host "[debug] > $json" }
    $c.w.WriteLine($json); $c.w.Flush()
    if ($Notify) { return }
    $end = [DateTime]::UtcNow.AddSeconds($timeoutSec)
    while ($true) {
        if (-not $c.read) { $c.read = $c.p.StandardOutput.ReadLineAsync() }
        $left = [int]($end - [DateTime]::UtcNow).TotalMilliseconds
        $got = $false
        while ($left -gt 0) { if ($c.read.Wait([Math]::Min($left, 400))) { $got = $true; break }; Pump-Light; $left = [int]($end - [DateTime]::UtcNow).TotalMilliseconds }
        if (-not $got) {
            $why = if ($c.p.HasExited) { "exited with code $($c.p.ExitCode): " + $c.err.Result } else { 'still running, no reply' }
            throw "MCP server timed out on $method ($why)"
        }
        $line = $c.read.Result; $c.read = $null
        if ($env:HELPER_DEBUG) { Write-Host "[debug] < $line" }
        if ($null -eq $line) { [void]$c.p.WaitForExit(2000); throw ('MCP server exited: ' + $(if ($c.p.HasExited) { $c.err.Result } else { '' })) }
        try { $m = $line | ConvertFrom-Json } catch { continue }
        if ($m.id -eq $c.n -and -not $m.method) {
            if ($m.error) { throw $m.error.message }
            return $m.result
        }
    }
}

function Do-McpStart($a) {
    if ($Children.ContainsKey($a.name)) { throw "'$($a.name)' is already running" }
    if ($a.command -eq 'playwright') { $pre = Playwright-Preset $a; $a = @{ name = $a.name; command = $pre.command; args = $pre.args; env = $a.env } }
    Ensure-Node $a.command; Ensure-Uv $a.command
    $exe = Resolve-Exe $a.command   # full path incl. extension (npx.cmd, uvx.exe ...); Get-Command alone would return npx.ps1
    if (-not $exe) { throw "Command '$($a.command)' not found" }
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = (@($a.args) | Where-Object { $null -ne $_ } | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($script:ExtraPath.Count) { $psi.EnvironmentVariables['PATH'] = ($script:ExtraPath -join ';') + ';' + $env:PATH }
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'; $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    if ($a.env) { foreach ($q in $a.env.PSObject.Properties) { $psi.EnvironmentVariables[$q.Name] = [string]$q.Value } }
    if ($a.cwd) { $psi.WorkingDirectory = $a.cwd }
    if ($env:HELPER_DEBUG) { Write-Host "[debug] start $exe $($psi.Arguments)" }
    # .NET Framework builds the child's stdin writer from the console input encoding. If that is UTF-8 *with BOM*
    # (e.g. chcp 65001), a BOM is written at process start and corrupts the first JSON line. Use a BOM-less encoding.
    $oldIn = $null
    try { $oldIn = [Console]::InputEncoding; [Console]::InputEncoding = New-Object Text.UTF8Encoding $false } catch { }
    $c = @{ p = [Diagnostics.Process]::Start($psi); n = 0; read = $null; tools = @() }
    try { if ($oldIn) { [Console]::InputEncoding = $oldIn } } catch { }
    $c.err = $c.p.StandardError.ReadToEndAsync()   # drained in the background (also keeps the pipe from filling); shown if the server dies. ponytail: grows with a chatty server's stderr
    # default stdin encoding is the console codepage; MCP is UTF-8
    $c.w = New-Object IO.StreamWriter($c.p.StandardInput.BaseStream, (New-Object Text.UTF8Encoding $false))
    # setting the console encoding can fail without a console: if a BOM went out anyway, isolate it on its own (empty) line
    if ($c.p.StandardInput.Encoding.GetPreamble().Length -gt 0) { $c.w.WriteLine(''); $c.w.Flush() }
    try {
        [void](Child-Rpc $c 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'helpermcp'; version = '0.2' } } $(if ($env:HELPER_INIT_TIMEOUT) { [int]$env:HELPER_INIT_TIMEOUT } elseif ($a.timeout_s) { [int]$a.timeout_s } else { 240 }))
        Child-Rpc $c 'notifications/initialized' $null -Notify
        $c.tools = @((Child-Rpc $c 'tools/list' $null 60).tools)
    } catch { Stop-Tree $c.p; throw }
    $Children[$a.name] = $c
    @{ text = "$($a.name): $($c.tools.Count) tools: " + (($c.tools | ForEach-Object { $_.name }) -join ', ') }
}
function Do-McpTools($a) {
    $all = @(foreach ($n in $Children.Keys) { foreach ($t in $Children[$n].tools) { $t | Add-Member -NotePropertyName server -NotePropertyValue $n -PassThru -Force } })
    @{ text = (ConvertTo-Json -InputObject $all -Depth 30 -Compress) }
}
function Do-McpCall($a) {
    $c = $Children[$a.server]
    if (-not $c) { throw "No MCP server '$($a.server)'. Start it with mcp_start." }
    $args2 = if ($a.arguments) { $a.arguments } else { @{} }
    $r = Child-Rpc $c 'tools/call' @{ name = $a.tool; arguments = $args2 } $(if ($a.timeout_s) { [int]$a.timeout_s } else { 110 })
    @{ content = @($r.content); isError = [bool]$r.isError }
}
# uvx/npx start the real server as a grandchild: kill the whole tree, not just the wrapper
function Stop-Tree($proc) {
    try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
}
function Do-McpStop($a) {
    $c = $Children[$a.name]
    if ($c) { Stop-Tree $c.p; $Children.Remove($a.name) }
    @{ text = if ($c) { 'stopped' } else { 'not running' } }
}
# "Remote control" overlay: glowing screen edges that fade out + a label on top, on every monitor. Runs as its own
# process (needs a message loop), ignores the mouse, and quits when the agent's PowerShell is gone.
$OverlayScript = @'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
Add-Type -Namespace O -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i); [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][O.W]::SetProcessDPIAware()
Add-Type -Namespace O -Name Glow -MemberDefinition @"
public static byte[] Make(int w, int h, int s, int r, int g, int b) {
    var px = new byte[w * h * 4]; var prof = new double[s];
    for (int d = 0; d < s; d++) { double t = (d + 0.5) / s; prof[d] = t <= 0.35 ? 0.59 + (0.18 - 0.59) * t / 0.35 : 0.18 * (1 - (t - 0.35) / 0.65); }
    for (int y = 0; y < h; y++) { int dy = Math.Min(y, h - 1 - y);
        for (int x = 0; x < w; x++) { int d = Math.Min(dy, Math.Min(x, w - 1 - x)); if (d >= s) continue;
            double a = prof[d]; int i = (y * w + x) * 4; px[i] = (byte)(b * a); px[i + 1] = (byte)(g * a); px[i + 2] = (byte)(r * a); px[i + 3] = (byte)(255 * a); } }
    return px;
}
"@
$label = $env:HM_LABEL; $ppid = [int]$env:HM_PPID
$dpi = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero).DpiX / 96
function Col($a) { [Windows.Media.Color]::FromArgb($a, 76, 141, 255) }
$wins = @()
foreach ($scr in [Windows.Forms.Screen]::AllScreens) {
    $b = $scr.Bounds
    $w = New-Object Windows.Window
    $w.WindowStyle = 'None'; $w.ResizeMode = 'NoResize'; $w.AllowsTransparency = $true; $w.Background = [Windows.Media.Brushes]::Transparent
    $w.Topmost = $true; $w.ShowInTaskbar = $false; $w.ShowActivated = $false; $w.WindowStartupLocation = 'Manual'
    $w.Left = $b.X / $dpi; $w.Top = $b.Y / $dpi; $w.Width = $b.Width / $dpi; $w.Height = $b.Height / $dpi
    $g = New-Object Windows.Controls.Grid
    # Glow bitmap: alpha of every pixel is a fade of its distance to the NEAREST screen edge. No strips, so nothing can overlap or leave a gap.
    $pw = $b.Width; $ph = $b.Height
    $pix = [O.Glow]::Make($pw, $ph, [int](70 * $dpi), 76, 141, 255)
    $bmp = [Windows.Media.Imaging.BitmapSource]::Create($pw, $ph, 96 * $dpi, 96 * $dpi, [Windows.Media.PixelFormats]::Pbgra32, $null, $pix, $pw * 4)
    $bmp.Freeze()
    $img = New-Object Windows.Controls.Image
    $img.Source = $bmp; $img.Stretch = 'None'; $img.HorizontalAlignment = 'Left'; $img.VerticalAlignment = 'Top'
    [void]$g.Children.Add($img)
    $pill = New-Object Windows.Controls.Border
    $pill.CornerRadius = New-Object Windows.CornerRadius 17; $pill.Padding = New-Object Windows.Thickness 14, 6, 18, 6
    $pill.Margin = New-Object Windows.Thickness 0, 12, 0, 0; $pill.HorizontalAlignment = 'Center'; $pill.VerticalAlignment = 'Top'
    $pill.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(224, 15, 23, 36))
    $pill.BorderBrush = New-Object Windows.Media.SolidColorBrush (Col 230); $pill.BorderThickness = New-Object Windows.Thickness 1.5
    $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 9; $dot.Height = 9; $dot.VerticalAlignment = 'Center'; $dot.Fill = New-Object Windows.Media.SolidColorBrush (Col 255)
    $tb = New-Object Windows.Controls.TextBlock; $tb.Text = $label; $tb.Foreground = [Windows.Media.Brushes]::White; $tb.FontSize = 14
    $tb.FontWeight = 'SemiBold'; $tb.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI'; $tb.Margin = New-Object Windows.Thickness 9, 0, 0, 0
    [void]$sp.Children.Add($dot); [void]$sp.Children.Add($tb); $pill.Child = $sp; [void]$g.Children.Add($pill)
    $w.Content = $g
    $w.Show()
    $h = (New-Object Windows.Interop.WindowInteropHelper $w).Handle   # click-through, no focus, hidden from Alt+Tab
    [void][O.W]::SetWindowLong($h, -20, ([O.W]::GetWindowLong($h, -20) -bor 0x20 -bor 0x80 -bor 0x08000000))
    $wins += $w
}
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    if (-not (Get-Process -Id $ppid -ErrorAction SilentlyContinue)) { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() }
    else { foreach ($x in $wins) { $x.Topmost = $false; $x.Topmost = $true } }   # stay above other topmost windows
})
$timer.Start()
[Windows.Threading.Dispatcher]::Run()
'@
function Start-Overlay {
    if ($env:HELPER_NO_OVERLAY) { return }
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
        $psi.Arguments = '-NoProfile -STA -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($OverlayScript))
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables['HM_LABEL'] = (T 'Удалённое управление' 'Remote control'); $psi.EnvironmentVariables['HM_PPID'] = [string]$PID
        $script:OverlayProc = [Diagnostics.Process]::Start($psi)
    } catch { }   # a missing overlay must never block the help session
}

function Cleanup-Children {
    foreach ($c in $Children.Values) { Stop-Tree $c.p }
    if ($script:OverlayProc) { try { $script:OverlayProc.Kill() } catch { } }
    foreach ($d in @($script:NodeDir) + $script:TmpDirs) { if ($d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } }
}

# Light requests (screenshots, sysinfo, file reads) are answered even while a long command runs: the live viewer and the AI's
# screenshots never freeze behind a 5-minute install or render. Heavy ones wait their turn.
$LightTools = 'screenshot', 'sysinfo', 'list_dir', 'read_file', 'mcp_tools'
$script:Deferred = New-Object System.Collections.ArrayList
$script:Token = $null; $script:Mode = 'full'; $script:LastPump = [DateTime]::MinValue

function Process-Command($cmd) {
    $name = $cmd.tool; $a = $cmd.args
    $short = ($cmd.args | ConvertTo-Json -Compress); if ($short.Length -gt 200) { $short = $short.Substring(0, 200) }
    Write-Host "[helper] $name $short"
    $res = @{ id = $cmd.id }
    try {
        if ($script:Mode -eq 'ask' -and $AskTools -contains $name) {
            $yn = Read-Host (T 'Разрешить? [y/N]' 'Allow? [y/N]')
            if ($yn -notmatch '^(y|yes|д|да)$') { throw 'User denied this action.' }
        }
        $fn = @{ screenshot = 'Do-Screenshot'; click = 'Do-Click'; scroll = 'Do-Scroll'; type_text = 'Do-TypeText'; press_key = 'Do-PressKey'
            run = 'Do-Run'; read_file = 'Do-ReadFile'; write_file = 'Do-WriteFile'; list_dir = 'Do-ListDir'; sysinfo = 'Do-SysInfo'
            fetch_file = 'Do-FetchFile'; start_process = 'Do-StartProcess'; mcp_start = 'Do-McpStart'; mcp_tools = 'Do-McpTools'; mcp_call = 'Do-McpCall'; mcp_stop = 'Do-McpStop' }[$name]
        if (-not $fn) { throw "Unknown tool $name" }
        $res.ok = $true; $res.data = & $fn $a
    } catch { $res.ok = $false; $res.error = $_.Exception.Message }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {   # a lost result would leave the operator waiting for a call that already finished
        try { Post-Result $res $script:Token; break }
        catch { $sc = 0; try { $sc = [int]$_.Exception.Response.StatusCode } catch { }; if ($sc -eq 401 -or $sc -eq 410) { break }; Start-Sleep (1 + $attempt) }
    }
}

# Called from the wait loops of long operations: take a look at the relay without blocking, serve light requests right away.
function Pump-Light {
    if (-not $script:Token -or ([DateTime]::UtcNow - $script:LastPump).TotalMilliseconds -lt 400) { return }
    $script:LastPump = [DateTime]::UtcNow
    try { $r = Api '/a/poll?w=0' $null $script:Token 10 } catch { return }
    if ($r.StatusCode -ne 200 -or -not $r.Content) { return }
    $cmd = $r.Content | ConvertFrom-Json
    if ($cmd.tool -eq 'bye') { [void]$script:Deferred.Add($cmd); return }
    if ($LightTools -contains $cmd.tool) { Process-Command $cmd } else { [void]$script:Deferred.Add($cmd) }
}

function Start-Helper {
    $mode = $env:HELPER_MODE
    if ($mode -ne 'ask' -and $mode -ne 'full') {
        $ans = Read-Host (T 'Режим: [1] спрашивать про каждое действие (рекомендуется)  [2] полный доступ' 'Mode: [1] ask before every action (recommended)  [2] full access')
        $mode = if ($ans.Trim() -eq '2') { 'full' } else { 'ask' }
    }
    $script:Mode = $mode
    $osn = (Get-CimInstance Win32_OperatingSystem).Caption
    $r = (Api '/a/register' @{ os = $osn; host = $env:COMPUTERNAME; user = $env:USERNAME; mode = $mode }).Content | ConvertFrom-Json
    $token = $r.token; $script:Token = $token
    Write-Host ''
    Write-Host ("  " + (T 'УДАЛЁННАЯ ПОМОЩЬ. Код сессии:' 'REMOTE HELP. Session code:') + "  " + $r.code) -ForegroundColor Yellow
    Write-Host ("  " + (T 'Назови этот код тому, кто тебе помогает. Закрой окно или Ctrl+C - доступ пропадёт.' 'Give this code to your helper. Close this window or press Ctrl+C to stop.'))
    Write-Host ''
    Start-Overlay
    try {
        while ($true) {
            if ($script:Deferred.Count) { $cmd = $script:Deferred[0]; $script:Deferred.RemoveAt(0) }
            else {
                try { $resp = Api '/a/poll' $null $token 40 }
                catch {
                    $code = [int]$_.Exception.Response.StatusCode
                    if ($code -eq 401 -or $code -eq 410) { Write-Host (T 'сессия закрыта (помощник завершил её или сервер помощи перезапущен): запусти команду заново' 'session closed (ended by the helper, or the helper server was reset: run the command again)'); return }
                    Start-Sleep 3; continue
                }
                if ($resp.StatusCode -ne 200 -or -not $resp.Content) { continue }
                $cmd = $resp.Content | ConvertFrom-Json
            }
            if ($cmd.tool -eq 'bye') { Write-Host 'session closed'; return }
            Process-Command $cmd
        }
    } finally {
        Cleanup-Children
        try { [void](Api '/a/bye' @{} $token 5) } catch { }
    }
}
Start-Helper
$ErrorActionPreference = $prevEAP
