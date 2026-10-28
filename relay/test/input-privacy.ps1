$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'agent/agent.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Agent syntax failure'}
foreach($name in @('T','Cut','Step-Text','Steps-Of','Describe-Action')){
 $fn=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if(-not $fn){throw ('Missing source function '+$name)}
 Invoke-Expression $fn.Extent.Text
}
$ru=$false;$AskGroup=@{type_text='input';actions='input'}
$private='https://fixture.invalid/sub/opaque-private-input-value'
$descriptions=@(Describe-Action 'ui_set' ([pscustomobject]@{id=1;value=$private}))
$descriptions+=@(Describe-Action 'type_text' ([pscustomobject]@{text=$private}))
$descriptions+=@(Describe-Action 'actions' ([pscustomobject]@{steps=@([pscustomobject]@{do='type';text=$private})}))
foreach($line in $descriptions){if($line -match 'fixture.invalid|opaque-private-input' -or $line -notmatch ([string]$private.Length)){throw 'Console input preview exposed private text or lost length metadata'}}
'Actual agent action descriptions hide individual and batched private input; syntax PASS'
