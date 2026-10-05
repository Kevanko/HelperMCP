$ErrorActionPreference = 'Continue'
"PS $($PSVersionTable.PSVersion)  OS $([Environment]::OSVersion.Version)  node $(node -v)"
$node = (Get-Command node.exe -CommandType Application | Select-Object -First 1).Source
$js = @'
process.stdin.on('data', d => { console.log('GOT:' + d.toString().trim()); });
process.stdin.on('end', () => console.log('STDIN-END'));
console.log('READY');
'@
$jsfile = Join-Path $env:TEMP 'pipe-test.js'; Set-Content $jsfile $js

function Try-Variant($label, $exe, $arguments, $mode) {
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = $arguments
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = ($mode -ne 'window')
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadLineAsync()
    $ready = $out.Wait(5000); "[$label] first line: $(if ($ready) { $out.Result } else { '<none in 5s>' })"
    if ($mode -eq 'writer') {
        $w = New-Object IO.StreamWriter($p.StandardInput.BaseStream, (New-Object Text.UTF8Encoding $false)); $w.WriteLine('hello'); $w.Flush()
    } else { $p.StandardInput.WriteLine('hello'); $p.StandardInput.Flush() }
    if ($ready) { $out = $p.StandardOutput.ReadLineAsync() }
    "[$label] reply: $(if ($out.Wait(5000)) { $out.Result } else { '<none in 5s>' })  exited=$($p.HasExited)"
    try { $p.Kill() } catch { }
}
Try-Variant 'A node, std stdin writer' $node $jsfile 'std'
Try-Variant 'B node, BaseStream writer' $node $jsfile 'writer'
Try-Variant 'C cmd /c node' $env:ComSpec "/c `"$node`" $jsfile" 'std'
Try-Variant 'D node, with window' $node $jsfile 'window'
Try-Variant 'E node --stdin-pipe? readline' $node "-e `"require('readline').createInterface({input:process.stdin}).on('line',l=>console.log('GOT:'+l));console.log('READY')`"" 'std'
