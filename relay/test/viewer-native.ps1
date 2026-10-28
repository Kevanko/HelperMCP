$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'agent/agent.ps1'),[ref]$null,[ref]$errors)
if($errors){throw 'Agent parser failed'}
foreach($name in 'Target','Btn','Do-ViewerInput','Process-Command'){
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $fn){throw "Missing $name"}
    Invoke-Expression $fn.Extent.Text.Replace('__BUILD__','ViewerFixture')
}
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic;
namespace H { public static class UViewerFixture {
 public static List<string> Events=new List<string>(); public static bool Reject=false,FailKey=false;
 public static bool SetCursorPos(int x,int y){Events.Add("move:"+x+":"+y);return !Reject;}
 public static void mouse_event(uint f,uint x,uint y,uint d,UIntPtr e){Events.Add("mouse:"+f+":"+d);}
 public static void keybd_event(byte k,byte s,uint f,UIntPtr e){Events.Add("key:"+k+":"+f);if(FailKey&&k==67&&f==0)throw new Exception("fixture injection failure");}
} }
namespace VViewerFixture { public static class Kb {public static void Type(string s){H.UViewerFixture.Events.Add("text:"+s);}} }
namespace KViewerFixture { public static class Keys {public static bool Paused=false;} }
'@
$VkExt=@(0xA3)
function Key-Code($k){switch($k){'ctrl'{17};'c'{67};default{throw 'unknown fixture key'}}}
function Assert($value,$why){if(-not $value){throw $why}}
# The real functions call instrumented managed APIs: no user32/native input.
Do-ViewerInput 'move' @{x=100;y=200;raw=$true}|Out-Null
Do-ViewerInput 'click' @{x=100;y=200;raw=$true;button='middle'}|Out-Null
Assert (([H.UViewerFixture]::Events -join ',') -eq 'move:100:200,move:100:200,mouse:32:0,mouse:64:0') 'pointer/click ordering'
[H.UViewerFixture]::Events.Clear()
Do-ViewerInput 'press_key' @{keys='ctrl+c'}|Out-Null
Assert (([H.UViewerFixture]::Events -join ',') -eq 'key:17:0,key:67:0,key:67:2,key:17:2') 'shortcut modifiers not released in reverse order'
[H.UViewerFixture]::Events.Clear();[H.UViewerFixture]::FailKey=$true
try{Do-ViewerInput 'press_key' @{keys='ctrl+c'};throw 'failure ignored'}catch{Assert ($_.Exception.Message -match 'fixture injection') 'wrong injection error'}
Assert (([H.UViewerFixture]::Events -join ',') -eq 'key:17:0,key:67:0,key:67:2,key:17:2') 'injection failure left modifier held'
[H.UViewerFixture]::FailKey=$false;[H.UViewerFixture]::Events.Clear()
Do-ViewerInput 'type_text' @{text="line1`r`nline2"}|Out-Null
Assert ([H.UViewerFixture]::Events[0] -eq "text:line1`nline2") 'Unicode typing path or newline normalization'
[H.UViewerFixture]::Events.Clear();[H.UViewerFixture]::Reject=$true
try{Do-ViewerInput 'click' @{x=1;y=2;raw=$true};throw 'rejected position ignored'}catch{Assert ($_.Exception.Message -match 'Windows rejected') 'wrong pointer rejection'}
Assert ([H.UViewerFixture]::Events.Count -eq 1) 'clicked after failed pointer move'
[H.UViewerFixture]::Reject=$false
$script:OperatorSeen=$true; $script:Phase='ok'; $script:Mode='confirm'; $script:Token='fixture'
$script:AiAt=[DateTime]::UtcNow
$Quiet=@{}; $AskTools=@('type_text'); $script:Asks=0; $script:Resumes=0; $script:Marks=0
function Say-Step { }
function Overlay-Send { }
function Check-Esc { }
function Ask-Permission { $script:Asks++ }
function Resume-State { $script:Resumes++ }
function Mark-State { $script:Marks++ }
function Post-Result($r,$token) { $script:Result=$r }
function T($ru,$en){$en}
function Cut($s,$n){$s}
Process-Command ([pscustomobject]@{id='manual-fixture';tool='type_text';args=@{text='direct';viewer_input=$true}})
Assert ($script:Result.ok -and $script:Result.data.text -eq 'ok') 'manual dispatcher failed'
Assert ($script:Asks -eq 1) 'manual acceleration bypassed confirm mode'
Assert ($script:Resumes -eq 0 -and $script:Marks -eq 0) 'manual input restored or overwrote AI focus state'
Assert ($null -eq $script:AiAt) 'handback could restore a stale AI window'
[KViewerFixture.Keys]::Paused=$true
function Do-ViewerPointer($a){if($a.op -ne 'release'){throw 'Unexpected fixture pointer operation'};@{text='released'}}
Process-Command ([pscustomobject]@{id='release-fixture';tool='viewer_pointer';args=@{op='release';viewer_input=$true}})
Assert ($script:Result.ok -and $script:Result.data.text -eq 'released') 'paused/confirm mode blocked emergency release'
[KViewerFixture.Keys]::Paused=$false
Write-Output 'Direct viewer input: no AI focus/probes/delays, pointer rejection, shortcut release on failure PASS'
