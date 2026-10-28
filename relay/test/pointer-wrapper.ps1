param([switch]$SkipPwsh)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$dir=Join-Path $env:TEMP ('hm-pointer-wrapper-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $dir)
$log=Join-Path $dir 'events.txt'
$source=[IO.File]::ReadAllText((Join-Path $root 'agent/pointer.cs')).Replace('Run(new NativeSink());','Run(new FixtureSink());')+@'
namespace HelperPointer {
 public sealed class FixtureSink : IPointerSink {
  string log=System.Environment.GetEnvironmentVariable("HELPER_POINTER_FIXTURE_LOG");
  public void Move(int x,int y){System.IO.File.AppendAllText(log,"move:"+x+":"+y+"\n");}
  public void Button(uint f){System.IO.File.AppendAllText(log,"button:"+f+"\n");}
 }
}
'@
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'agent/agent.ps1'),[ref]$null,[ref]$errors)
if($errors){throw 'Agent parser failed'}
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Do-ViewerPointer'},$true)
Invoke-Expression $fn.Extent.Text.Replace('__POINTER_CS_B64__',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source)))
function Test-Admin{$false}
function Quote-Arg($s){'"'+$s+'"'}
$StateDir=$dir;$script:Mode='auto';$script:PointerProc=$null;$script:PointerExe=$null
$prior=$env:HELPER_POINTER_FIXTURE_LOG;$env:HELPER_POINTER_FIXTURE_LOG=$log
$a=@{owner='e'*64;gesture='f'*32;seq=1;op='down';x=1;y=2;button='left'}
try{
    $r=Do-ViewerPointer $a
    if($r.text -ne 'held'){throw 'PS wrapper down failed'}
    $a.op='move';$a.seq=2;$a.x=3;$a.y=4
    if((Do-ViewerPointer $a).text -ne 'held'){throw 'PS wrapper move failed'}
    $a.op='up';$a.seq=3
    if((Do-ViewerPointer $a).text -ne 'released'){throw 'PS wrapper up failed'}
    $actual=([IO.File]::ReadAllLines($log) -join ',')
    if($actual -ne 'move:1:2,button:2,move:3:4,move:3:4,button:4'){throw 'PS wrapper did not preserve native protocol ordering'}
    Write-Output ('Pointer PS wrapper, real Framework compile/IPC, fake native sink PASS (PowerShell '+$PSVersionTable.PSVersion+')')
}finally{
    if($script:PointerProc){$script:PointerProc.StandardInput.Close();[void]$script:PointerProc.WaitForExit(2000);$script:PointerProc.Dispose()}
    $env:HELPER_POINTER_FIXTURE_LOG=$prior
}
if(-not $SkipPwsh -and $PSVersionTable.PSVersion.Major -le 5){
    $pwsh=Get-Command pwsh -ErrorAction SilentlyContinue
    if($pwsh){& $pwsh.Source -NoProfile -File $PSCommandPath -SkipPwsh;if($LASTEXITCODE -ne 0){throw 'PS7 pointer wrapper failed'}}
}
