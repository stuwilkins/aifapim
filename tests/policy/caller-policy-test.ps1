# Compiles the real expressions of the open product policy (Product_EntraOpen_Policy.xml), the
# usageId / usageName variables of the inference policies and the usage trace fragment against a
# fake APIM context, and checks them with hand-made (unsigned) tokens: which tokens are treated
# as service principals, which object id, name and client the caller gets, and how a keyed or a
# keyless request is named. It also checks the policy files statically: that no inference policy
# reads context.Subscription outside the two usageId / usageName variables, and that no policy
# uses a Regex member APIM does not allow.
# It needs PowerShell 7 (pwsh), which has the C# compiler and Newtonsoft.Json. It does not run
# APIM, so APIM's own limits on allowed types, and validate-azure-ad-token itself, are not
# checked here: the tokens are not signed and are never validated.
#
#   pwsh -NoProfile -File tests/policy/caller-policy-test.ps1
#
# Exit status 1 when a check fails.
param(
    [string]$PolicyDir = (Join-Path $PSScriptRoot '../../apim_policies')
)
$WarningPreference = 'SilentlyContinue'
$bad = 0
function Check($ok, $what) {
    if (-not $ok) { $script:bad++ }
    '{0,-6} {1}' -f $(if ($ok) { 'OK' } else { 'WRONG' }), $what
}

# ---- static checks -------------------------------------------------------------------------
$allowedRegex = @('IsMatch', 'Match', 'Matches', 'Replace', 'Unescape', 'Split')
foreach ($file in Get-ChildItem -Path $PolicyDir -Filter '*.xml') {
    $text = Get-Content -Raw $file.FullName
    foreach ($m in [regex]::Matches($text, 'RegularExpressions\.Regex\.(\w+)')) {
        Check ($allowedRegex -contains $m.Groups[1].Value) ('{0}: Regex.{1} is an APIM-allowed member' -f $file.Name, $m.Groups[1].Value)
    }
}
$inference = @(
    'AOAI_Policy-Managed_Identity_with_Retry_MultiRegion.xml',
    'OpenAIv1Messages_Policy-Managed_Identity_with_Retry_MultiRegion.xml',
    'Anthropic_Policy-Managed_Identity_with_Retry_MultiRegion.xml',
    'BlackForestLabs_Policy-Managed_Identity_with_Retry_MultiRegion.xml',
    'MAI_Image_Policy-Managed_Identity_with_Retry.xml'
)
foreach ($name in $inference + @('ClaudeAuto_Fragment.xml', 'RequestBodyLog_Fragment.xml', 'UsageTrace_Fragment.xml')) {
    $text = Get-Content -Raw (Join-Path $PolicyDir $name)
    # Only the usageId and usageName variables may read the subscription; without a key it is null.
    $reads = [regex]::Matches($text, 'context\.Subscription\.(Id|Name)').Count
    $allowed = if ($inference -contains $name) { 2 } else { 0 }
    Check ($reads -eq $allowed) ('{0}: reads context.Subscription.Id/Name {1} time(s), expected {2}' -f $name, $reads, $allowed)
}
foreach ($name in $inference) {
    $text = Get-Content -Raw (Join-Path $PolicyDir $name)
    $first = $text.IndexOf('name="usageId"')
    $use = $text.IndexOf('GetValueOrDefault(&quot;usageId&quot;')
    Check (($first -ge 0) -and ($use -gt $first)) ('{0}: usageId is set before it is read' -f $name)
    $base = $text.IndexOf('<base />')
    Check (($base -ge 0) -and ($first -gt $base)) ('{0}: usageId is set after the first <base /> (the product policy has run)' -f $name)
}
[xml]$open = Get-Content -Raw (Join-Path $PolicyDir 'Product_EntraOpen_Policy.xml')
$validators = $open.SelectNodes('//validate-azure-ad-token')
Check ($validators.Count -eq 2) 'open product policy has two validate-azure-ad-token branches'
Check ((@($validators | Where-Object { $_.GetAttribute('tenant-id') -eq '__ENTRA_TENANT_ID__' }).Count) -eq 2) 'both branches validate the tenant'
Check ((@($validators | Where-Object { $_.audiences.audience -eq '__ENTRA_AUDIENCE__' }).Count) -eq 2) 'both branches validate the audience'
$person = @($validators | Where-Object { $_.SelectNodes('.//claim[@name="scp"]').Count -gt 0 })
Check ($person.Count -eq 1) 'exactly one branch is the person branch (requires the scp claim)'
Check ($person[0].SelectNodes('.//claim[@name="roles"]/value').InnerText -eq '__ENTRA_USER_ROLE__') 'the person branch also requires the user app role'
$service = @($validators | Where-Object { $_.SelectNodes('.//claim[@name="scp"]').Count -eq 0 })
Check (($service.Count -eq 1) -and ($service[0].SelectNodes('.//claim[@name="azpacr"]/value').InnerText -eq '2')) 'the service branch requires a certificate token (azpacr 2)'

# ---- compiled expressions ------------------------------------------------------------------
function Body($xml, $name) {
    $v = ($xml.SelectNodes('//set-variable') | Where-Object { $_.name -eq $name } | Select-Object -First 1).value.Trim()
    if ($v.StartsWith('@{') -and $v.EndsWith('}')) { return $v.Substring(2, $v.Length - 3) }
    if ($v.StartsWith('@(') -and $v.EndsWith(')')) { return 'return ' + $v.Substring(2, $v.Length - 3) + ';' }
    throw "$name is not an expression"
}
[xml]$anthropic = Get-Content -Raw (Join-Path $PolicyDir $inference[2])
[xml]$trace = '<r>' + ((Get-Content -Raw (Join-Path $PolicyDir 'UsageTrace_Fragment.xml')) -replace '<!--[\s\S]*?-->', '') + '</r>'
$code = @"
using System; using System.Collections.Generic; using System.Linq; using Newtonsoft.Json.Linq;
public class Hdrs { public Dictionary<string,string> d = new Dictionary<string,string>(); public string GetValueOrDefault(string k, string def){ return d.ContainsKey(k)? d[k]:def; } }
public class Req { public Hdrs Headers = new Hdrs(); }
public class Vars {
  public Dictionary<string,object> d = new Dictionary<string,object>();
  public T GetValueOrDefault<T>(string k, T def) { return d.ContainsKey(k) && d[k] is T ? (T)d[k] : def; }
  public object this[string k] { get { return d[k]; } }
}
public class Claims { public Dictionary<string,string> d = new Dictionary<string,string>(); public string GetValueOrDefault(string k, string def){ return d.ContainsKey(k)? d[k]:def; } }
public class Jwt { public Claims Claims = new Claims(); }
public class Sub { public string Id; public string Name; }
public class Ctx { public Req Request = new Req(); public Vars Variables = new Vars(); public Sub Subscription; }
public static class Ext {
  public static Jwt AsJwt(this string s) {
    try {
      var parts = s.Split('.');
      if (parts.Length != 3) return null;
      var p = parts[1].Replace('-', '+').Replace('_', '/');
      while (p.Length % 4 != 0) p += "=";
      var o = JObject.Parse(System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(p)));
      var j = new Jwt();
      foreach (var kv in o) { j.Claims.d[kv.Key] = kv.Value is JArray ? string.Join(",", ((JArray)kv.Value).Select(x => (string)x)) : (string)kv.Value; }
      return j;
    } catch { return null; }
  }
}
public static class Pol {
  public static object CallerIsApp(Ctx context) { $(Body $open 'callerIsApp') }
  public static object CallerId(Ctx context) { $(Body $open 'callerId') }
  public static object CallerClient(Ctx context) { $(Body $open 'callerClient') }
  public static object CallerName(Ctx context) { $(Body $open 'callerName') }
  public static object UsageId(Ctx context) { $(Body $anthropic 'usageId') }
  public static object UsageName(Ctx context) { $(Body $anthropic 'usageName') }
  public static object UsageModel(Ctx context) { $(Body $trace 'usageModel') }
}
"@
$refs = @((Join-Path $PSHOME 'Newtonsoft.Json.dll'), 'System.Collections', 'System.Runtime', 'System.Text.RegularExpressions', 'System.Linq', 'System.Linq.Expressions', 'System.ComponentModel.TypeConverter', 'System.ObjectModel', 'System.Private.CoreLib', 'netstandard')
Add-Type -TypeDefinition $code -ReferencedAssemblies $refs -IgnoreWarnings

function B64($s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function Token($claims) { (B64 '{"alg":"none"}') + '.' + (B64 ($claims | ConvertTo-Json -Compress)) + '.sig' }
function Context($auth) {
    $c = New-Object Ctx
    if ($null -ne $auth) { $c.Request.Headers.d['Authorization'] = $auth }
    return $c
}
$oid = '3F2A9C10-AAAA-4BBB-8CCC-0123456789AB'
$user = Token @{ oid = $oid; name = 'Ada Lovelace'; azp = '11111111-1111-1111-1111-111111111111'; scp = 'access_as_user' }
$app = Token @{ oid = $oid; idtyp = 'app'; azp = '22222222-2222-2222-2222-222222222222'; azpacr = '2'; roles = @('Inference.Invoke') }

# Which branch the token takes.
Check ([Pol]::CallerIsApp((Context "Bearer $app")) -eq $true) 'app-only token takes the service principal branch'
Check ([Pol]::CallerIsApp((Context "bearer $app")) -eq $true) 'the Bearer scheme is matched without regard to case'
Check ([Pol]::CallerIsApp((Context "Bearer $user")) -eq $false) 'delegated token takes the person branch'
Check ([Pol]::CallerIsApp((Context (('Bearer ' + (Token @{ oid = $oid; idtyp = 'user' }))))) -eq $false) 'idtyp user takes the person branch'
Check ([Pol]::CallerIsApp((Context $null)) -eq $false) 'no Authorization header takes the person branch (and then fails validation)'
Check ([Pol]::CallerIsApp((Context 'Bearer not.a.token')) -eq $false) 'garbage takes the person branch (and then fails validation)'
Check ([Pol]::CallerIsApp((Context "Basic $app")) -eq $false) 'a non-Bearer scheme is not read as a token'

# The caller named from a validated token.
function WithToken($t, $isApp) {
    $c = Context "Bearer $t"
    $c.Variables.d['callerJwt'] = ($t | ForEach-Object { [Ext]::AsJwt($_) })
    $c.Variables.d['callerIsApp'] = [bool]$isApp
    return $c
}
$c = WithToken $user $false
Check ([Pol]::CallerId($c) -eq $oid.ToLowerInvariant()) 'object id is read and lower-cased'
$c.Variables.d['callerId'] = [Pol]::CallerId($c)
Check ([Pol]::CallerClient($c) -eq '11111111-1111-1111-1111-111111111111') 'client app is azp'
$c.Variables.d['callerClient'] = [Pol]::CallerClient($c)
Check ([Pol]::CallerName($c) -eq 'Ada Lovelace') 'a person is named by the name claim'
$c = WithToken $app $true
$c.Variables.d['callerId'] = [Pol]::CallerId($c)
$c.Variables.d['callerClient'] = [Pol]::CallerClient($c)
Check ([Pol]::CallerName($c) -eq 'app:22222222-2222-2222-2222-222222222222') 'a service principal is named by its client app'
Check ([Pol]::CallerId((WithToken (Token @{ name = 'x' }) $false)) -eq '') 'a token with no oid has no identity (the request is refused)'
Check ([Pol]::CallerId((WithToken (Token @{ oid = 'not-a-guid' }) $false)) -eq '') 'an oid that is not a GUID has no identity (the request is refused)'
Check ([Pol]::CallerId((WithToken (Token @{ oid = "$oid\nX" }) $false)) -eq '') 'an oid with extra text has no identity (the request is refused)'

function NameFor($claims, $isApp = $false) {
    $c = WithToken (Token $claims) $isApp
    $c.Variables.d['callerId'] = [Pol]::CallerId($c)
    $c.Variables.d['callerClient'] = [Pol]::CallerClient($c)
    return [Pol]::CallerName($c)
}
Check ((NameFor @{ oid = $oid; preferred_username = 'ada@example.org' }) -eq 'ada@example.org') 'without name, preferred_username is the name'
Check ((NameFor @{ oid = $oid }) -eq $oid.ToLowerInvariant()) 'with neither, the object id is the name'
Check ((NameFor @{ oid = $oid; name = "Ada`nLovelace`t" }) -eq 'Ada_Lovelace_') 'control characters in a name are replaced'
Check ((NameFor @{ oid = $oid; name = ('x' * 300) }).Length -eq 100) 'a long name is cut to 100 characters'
Check ((NameFor @{ oid = $oid; idtyp = 'app'; appid = 'abc' } $true) -eq 'app:abc') 'a v1 token without azp is named by appid'

# Naming the caller in an inference policy: a key wins, a keyless request uses the caller.
$c = New-Object Ctx
$c.Subscription = New-Object Sub; $c.Subscription.Id = 'sub-oid'; $c.Subscription.Name = 'Grace Hopper'
$c.Variables.d['callerId'] = 'ignored'; $c.Variables.d['callerName'] = 'ignored'
Check (([Pol]::UsageId($c) -eq 'sub-oid') -and ([Pol]::UsageName($c) -eq 'Grace Hopper')) 'a keyed request is named by its subscription'
$c = New-Object Ctx
$c.Variables.d['callerId'] = $oid.ToLowerInvariant(); $c.Variables.d['callerName'] = 'Ada Lovelace'
Check (([Pol]::UsageId($c) -eq $oid.ToLowerInvariant()) -and ([Pol]::UsageName($c) -eq 'Ada Lovelace')) 'a keyless request is named by the token caller'
$c = New-Object Ctx
Check (([Pol]::UsageId($c) -eq '') -and ([Pol]::UsageName($c) -eq '')) 'no subscription and no caller gives an empty name (and does not throw)'

# The model in the usage record comes from the client.
$c = New-Object Ctx; $c.Variables.d['requestModel'] = 'claude sonnet`n<x>'
Check ([Pol]::UsageModel($c) -eq 'claude_sonnet_n_x_') 'a model name is limited to a safe character set'
$c = New-Object Ctx; $c.Variables.d['requestModel'] = ('m' * 200)
Check ([Pol]::UsageModel($c).Length -eq 64) 'a long model name is cut to 64 characters'
$c = New-Object Ctx; $c.Variables.d['deploymentName'] = 'gpt-5'
Check ([Pol]::UsageModel($c) -eq 'gpt-5') 'the deployment name is the fallback model'
$c = New-Object Ctx
Check ([Pol]::UsageModel($c) -eq '') 'no model gives an empty model'

"failures: $bad"
if ($bad -gt 0) { exit 1 }
