# Compiles the real expressions of the MAI image policy (read from the policy XML) against a
# fake APIM context and runs the multipart and JSON cases of mai-cases.json through them:
# which requests the policy refuses for web_grounding, and which model name it records.
# It needs PowerShell 7 (pwsh), which has the C# compiler and Newtonsoft.Json. It does not
# run APIM, so APIM's own limits on allowed types are not checked.
#
#   pwsh -NoProfile -File tests/policy/mai-policy-test.ps1
#
# Exit status 1 when a case fails.
param(
    [string]$Policy = (Join-Path $PSScriptRoot '../../apim_policies/MAI_Image_Policy-Managed_Identity_with_Retry.xml'),
    [string]$CasesFile = (Join-Path $PSScriptRoot 'mai-cases.json')
)
$WarningPreference = 'SilentlyContinue'
[xml]$x = Get-Content -Raw $Policy
function Expr($name) {
    $v = ($x.SelectNodes("//set-variable") | Where-Object { $_.name -eq $name }).value.Trim()
    if (-not ($v.StartsWith('@{') -and $v.EndsWith('}'))) { throw "$name is not a block expression" }
    return $v.Substring(2, $v.Length - 3)
}
$code = @"
using System; using System.Collections.Generic; using Newtonsoft.Json.Linq;
public class Hdrs { public Dictionary<string,string> d = new Dictionary<string,string>(); public string GetValueOrDefault(string k, string def){ return d.ContainsKey(k)? d[k]:def; } }
public class Bdy { public string text; public T As<T>(bool preserveContent = false) { if (typeof(T)==typeof(string)) return (T)(object)text; if (typeof(T)==typeof(JObject)) return (T)(object)JObject.Parse(text); throw new Exception("type"); } }
public class Req { public Hdrs Headers = new Hdrs(); public Bdy Body = new Bdy(); }
public class Vars { public Dictionary<string,object> d = new Dictionary<string,object>(); public T GetValueOrDefault<T>(string k, T def) { return d.ContainsKey(k) && d[k] is T ? (T)d[k] : def; } }
public class Ctx { public Req Request = new Req(); public Vars Variables = new Vars(); }
public static class Pol {
  public static object FormFields(Ctx context) { $(Expr 'formFields') }
  public static object Model(Ctx context) { $(Expr 'requestModel') }
  public static object Grounding(Ctx context) { $(Expr 'webGrounding') }
}
"@
$refs = @((Join-Path $PSHOME 'Newtonsoft.Json.dll'), 'System.Collections', 'System.Runtime', 'System.Text.RegularExpressions', 'System.Linq', 'System.Private.CoreLib', 'netstandard')
Add-Type -TypeDefinition $code -ReferencedAssemblies $refs -IgnoreWarnings
$cases = Get-Content -Raw $CasesFile | ConvertFrom-Json
$bad = 0
foreach ($c in $cases) {
    $ctx = New-Object Ctx
    $ctx.Request.Headers.d['Content-Type'] = $c.contentType
    $ctx.Request.Headers.d['Content-Length'] = '1000'
    $ctx.Request.Body.text = $c.body
    $ctx.Variables.d['formFields'] = [Pol]::FormFields($ctx)
    $blocked = [Pol]::Grounding($ctx)
    $model = [Pol]::Model($ctx)
    $ok = ($blocked -eq $c.blocked) -and ($model -eq $c.model)
    if (-not $ok) { $bad++ }
    '{0,-6} {1,-50} blocked={2,-5} model={3}' -f $(if ($ok) { 'OK' } else { 'WRONG' }), $c.name, $blocked, $model
}
"failures: $bad of $($cases.Count)"
if ($bad -gt 0) { exit 1 }
