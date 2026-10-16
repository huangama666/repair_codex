param([string]$HelperPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'CodexProxy.ps1'))
$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-proxy-tests-' + [Guid]::NewGuid().ToString('N'))
if ($script:TestRoot.StartsWith('/var/')) { $script:TestRoot = '/private' + $script:TestRoot }
[IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Equal($Actual, $Expected, [string]$Message) { if ($Actual -cne $Expected) { throw ($Message + "`nExpected: $Expected`nActual: $Actual") } }
function Assert-Bytes([byte[]]$Actual, [byte[]]$Expected, [string]$Message) { Assert-Equal ([Convert]::ToBase64String($Actual)) ([Convert]::ToBase64String($Expected)) $Message }
function Assert-Throws([scriptblock]$Code, [string]$Pattern) {
    $caught = $null
    try { & $Code | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-True ($null -ne $caught) 'Expected a refusal, but operation succeeded.'
    Assert-True ($caught -match $Pattern) ("Unexpected error: " + $caught)
}
function New-TestHome([string]$Name) { $p = Join-Path $script:TestRoot $Name; [IO.Directory]::CreateDirectory($p) | Out-Null; return $p }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host ('PASS ' + $Name) }
    catch { $script:Failed++; Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red }
}
if (-not ('CodexTestProxyFixture' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class CodexTestProxyFixture : IDisposable {
    private TcpListener listener;
    private Thread worker;
    private volatile bool stop;
    private byte[] response;
    public int Port { get; private set; }
    public string Directory { get; private set; }
    public CodexTestProxyFixture(string directory, byte[] responseBytes) {
        Directory=directory; response=responseBytes;
        listener=new TcpListener(IPAddress.Loopback,0); listener.Start();
        Port=((IPEndPoint)listener.LocalEndpoint).Port;
        worker=new Thread(Run); worker.IsBackground=true; worker.Start();
    }
    private void Run() {
        while (!stop) {
            TcpClient client=null;
            try {
                client=listener.AcceptTcpClient();
                using (NetworkStream stream=client.GetStream()) {
                    stream.ReadTimeout=1500;
                    using (MemoryStream data=new MemoryStream()) {
                        while (data.Length<8192) {
                            int value=stream.ReadByte(); if (value<0) break; data.WriteByte((byte)value);
                            if (data.Length>=4 && Encoding.ASCII.GetString(data.ToArray()).EndsWith("\r\n\r\n")) break;
                        }
                        File.WriteAllBytes(Path.Combine(Directory,"request"),data.ToArray());
                    }
                    if (response.Length>0) { stream.Write(response,0,response.Length); stream.Flush(); }
                }
            } catch { } finally { if(client!=null) client.Close(); }
        }
    }
    public void Dispose() { stop=true; listener.Stop(); worker.Join(3000); }
}
'@
}
function Start-TestProxy([byte[]]$Response) {
    $fixture = New-TestHome ([Guid]::NewGuid().ToString('N'))
    return (New-Object CodexTestProxyFixture $fixture, $Response)
}
function Stop-TestProxy($Proxy) { if ($null -ne $Proxy) { $Proxy.Dispose() } }
try {
    if (-not (Test-Path -LiteralPath $HelperPath)) { throw 'Expected implementation file is missing: CodexProxy.ps1' }
    . $HelperPath -LibraryOnly
    $good = Start-TestProxy ([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection established`r`nProxy-Agent: fixture`r`n`r`n"))
    Test-Case 'HTTP CONNECT 200 is usable and request uses fixed target without credentials' {
        $r = Test-HttpConnectProxy -Port $good.Port -TimeoutMs 1000
        Assert-True $r.Usable 'Expected HTTP 200 tunnel to be usable.'
        $request = [IO.File]::ReadAllText((Join-Path $good.Directory 'request'))
        Assert-True ($request.StartsWith("CONNECT chatgpt.com:443 HTTP/1.1`r`n")) 'Must send HTTP CONNECT to chatgpt.com:443.'
        Assert-True ($request -notmatch 'Proxy-Authorization') 'Must not send credentials.'
    }
    Test-Case '403 HTTP page is not a usable CONNECT tunnel' {
        $proxy = Start-TestProxy ([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 403 Forbidden`r`nContent-Length: 0`r`n`r`n"))
        try { Assert-True (-not (Test-HttpConnectProxy -Port $proxy.Port -TimeoutMs 1000).Usable) '403 must not pass.' } finally { Stop-TestProxy $proxy }
    }
    Test-Case 'SOCKS-only response is not selected' {
        $proxy = Start-TestProxy ([byte[]]@(5, 255))
        try {
            Assert-True (-not (Test-HttpConnectProxy -Port $proxy.Port -TimeoutMs 1000).Usable) 'SOCKS response must not pass.'
            $detected = @(Find-CodexHttpProxies -Ports @($proxy.Port) -TimeoutMs 1000)
            Assert-True (@($detected | Where-Object { $_.Usable }).Count -eq 0) 'SOCKS port must not be auto-selected.'
        } finally { Stop-TestProxy $proxy }
    }
    Test-Case 'TCP-only listener is not usable' {
        $proxy = Start-TestProxy ([byte[]]@())
        try { Assert-True (-not (Test-HttpConnectProxy -Port $proxy.Port -TimeoutMs 1000).Usable) 'TCP connection alone must not pass.' } finally { Stop-TestProxy $proxy }
    }
    Test-Case 'preview and cancellation do not create config directory or backup' {
        $caseHome = Join-Path $script:TestRoot 'cancel-missing'
        $plan = New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port
        $r = Invoke-CodexProxyApply -Plan $plan -Confirmed:$false
        Assert-Equal $r.Status 'Cancelled' 'Cancellation status.'
        Assert-True (-not [IO.Directory]::Exists($caseHome)) 'Cancelled operation created a directory.'
        Assert-Equal $plan.Lines.Count 3 'Preview must contain three managed lines.'
        Assert-True ($plan.Target -eq (Join-Path $caseHome '.env')) 'Preview target path missing.'
    }
    Test-Case 'preserve unrelated raw bytes and CRLF while removing case duplicates' {
        $caseHome = New-TestHome 'raw'
        $envPath = Join-Path $caseHome '.env'
        $raw = [byte[]]@(35, 32, 255, 254, 13, 10) + [Text.Encoding]::ASCII.GetBytes("OTHER=keep`r`nhttp_proxy = old`r`nHTTPS_PROXY=old2`r`nNo_Proxy=old3`r`nexport HTTP_PROXY=old4`r`nTAIL=last")
        [IO.File]::WriteAllBytes($envPath, $raw)
        $plan = New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port
        $expected = [byte[]]@(35, 32, 255, 254, 13, 10) + [Text.Encoding]::ASCII.GetBytes("OTHER=keep`r`nTAIL=last`r`nHTTP_PROXY=http://127.0.0.1:$($good.Port)`r`nHTTPS_PROXY=http://127.0.0.1:$($good.Port)`r`nNO_PROXY=localhost,127.0.0.1,::1`r`n")
        Assert-Bytes $plan.AfterBytes $expected 'Unrelated bytes or newline style changed.'
        $result = Invoke-CodexProxyApply -Plan $plan -Confirmed
        Assert-Equal $result.Status 'Applied' 'Apply result.'
        Assert-Bytes ([IO.File]::ReadAllBytes((Join-Path $result.Backup 'original.env'))) $raw 'Backup is not original bytes.'
        $manifest = [IO.File]::ReadAllText((Join-Path $result.Backup 'manifest.json')) | ConvertFrom-Json
        Assert-Equal $manifest.schema 1 'Manifest schema.'
        Assert-True $manifest.existed 'Manifest existence flag.'
        Assert-Equal $manifest.before_sha256 (Get-BytesSha256 $raw) 'Manifest before hash.'
        Assert-Equal $manifest.after_sha256 (Get-BytesSha256 $expected) 'Manifest after hash.'
        $restore = New-CodexRestorePlan -ConfigHome $caseHome
        Invoke-CodexProxyRestore -Plan $restore -Confirmed | Out-Null
        Assert-Bytes ([IO.File]::ReadAllBytes($envPath)) $raw 'Restoration must be byte-for-byte.'
        Assert-True ([IO.File]::Exists((Join-Path $result.Backup 'manifest.before-restore.json'))) 'Original manifest was not retained.'
    }
    Test-Case 'Chinese and dollar signs in config path are literal' {
        $caseHome = New-TestHome '配置 $literal'
        $r = Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port) -Confirmed
        Assert-True ([IO.File]::Exists((Join-Path $caseHome '.env'))) 'Literal config path was not used.'
        Invoke-CodexProxyRestore -Plan (New-CodexRestorePlan -ConfigHome $caseHome) -Confirmed | Out-Null
    }
    Test-Case 'existing transaction lock prevents writes' {
        $caseHome = New-TestHome 'locked'
        [IO.Directory]::CreateDirectory((Join-Path $caseHome 'proxy-helper.lock')) | Out-Null
        Assert-Throws { Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port) -Confirmed } '锁|lock'
        Assert-True (-not [IO.File]::Exists((Join-Path $caseHome '.env'))) 'Locked operation wrote env.'
        Assert-True (-not [IO.Directory]::Exists((Join-Path $caseHome 'proxy-helper-backups'))) 'Locked operation created backup.'
    }
    Test-Case 'GUI does not assign PowerShell automatic input variable' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($HelperPath, [ref]$tokens, [ref]$errors)
        $bad = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -ieq 'input' }, $true))
        Assert-Equal $bad.Count 0 'GUI control must not use automatic variable input.'
    }
    Test-Case 'multiline quoted env is refused without modifying original values' {
        $caseHome = New-TestHome 'multiline'
        $raw = [Text.Encoding]::UTF8.GetBytes("OTHER=`"line1`nHTTP_PROXY=literal`nline3`"`n")
        [IO.File]::WriteAllBytes((Join-Path $caseHome '.env'), $raw)
        Assert-Throws { New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port } '多行|multiline'
        Assert-Bytes ([IO.File]::ReadAllBytes((Join-Path $caseHome '.env'))) $raw 'Multiline content changed.'
    }
    Test-Case 'unapplied pending backup does not block previous applied restore' {
        $caseHome = New-TestHome 'pending-before'
        [IO.File]::WriteAllText((Join-Path $caseHome '.env'), 'START=pending')
        $first = Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port) -Confirmed
        $pending = Join-Path (Join-Path $caseHome 'proxy-helper-backups') '99999999T999999999-deadbeef'
        [IO.Directory]::CreateDirectory($pending) | Out-Null
        $before = [IO.File]::ReadAllBytes((Join-Path $caseHome '.env'))
        [IO.File]::WriteAllBytes((Join-Path $pending 'original.env'), $before)
        $m = @{schema=1; existed=$true; before_sha256=(Get-BytesSha256 $before); after_sha256=('a'*64); created_at=[DateTime]::UtcNow.ToString('o'); state='pending'}
        [IO.File]::WriteAllText((Join-Path $pending 'manifest.json'), ($m | ConvertTo-Json))
        $plan = New-CodexRestorePlan -ConfigHome $caseHome
        Assert-Equal $plan.Backup $first.Backup 'Unapplied pending backup blocked older applied backup.'
        Invoke-CodexProxyRestore -Plan $plan -Confirmed | Out-Null
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $caseHome '.env'))) 'START=pending' 'Previous applied backup did not restore.'
    }
    Test-Case 'pending manifest after successful env replacement can be restored' {
        $caseHome = New-TestHome 'pending-after'
        $r = Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port) -Confirmed
        $manifestPath = Join-Path $r.Backup 'manifest.json'
        $m = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        $m | Add-Member -NotePropertyName state -NotePropertyValue 'pending' -Force
        [IO.File]::WriteAllText($manifestPath, ($m | ConvertTo-Json))
        Invoke-CodexProxyRestore -Plan (New-CodexRestorePlan -ConfigHome $caseHome) -Confirmed | Out-Null
        Assert-True (-not [IO.File]::Exists((Join-Path $caseHome '.env'))) 'Post-replacement crash recovery failed.'
    }
    Test-Case 'restore interrupted after env replacement finalizes only the manifest' {
        $caseHome = New-TestHome 'restore-interrupted'
        $r = Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port) -Confirmed
        $manifestPath = Join-Path $r.Backup 'manifest.json'
        [IO.File]::WriteAllBytes((Join-Path $r.Backup 'manifest.before-restore.json'), [IO.File]::ReadAllBytes($manifestPath))
        [IO.File]::Delete((Join-Path $caseHome '.env'))
        $plan = New-CodexRestorePlan -ConfigHome $caseHome
        Assert-True $plan.EnvAlreadyRestored 'Interrupted restoration was not recognized.'
        Invoke-CodexProxyRestore -Plan $plan -Confirmed | Out-Null
        Assert-True (-not [IO.File]::Exists((Join-Path $caseHome '.env'))) 'Finalization recreated env.'
        $m = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        Assert-True ($null -ne $m.restored_at) 'Finalization did not record restored_at.'
    }
    Test-Case 'matching original state without restore marker remains an external change' {
        $caseHome = New-TestHome 'restore-no-marker'
        Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port) -Confirmed | Out-Null
        [IO.File]::Delete((Join-Path $caseHome '.env'))
        Assert-Throws { New-CodexRestorePlan -ConfigHome $caseHome } 'changed|修改|指纹'
    }
    Test-Case 'UTF-8 BOM and LF are retained' {
        $caseHome = New-TestHome 'bom'
        $raw = [byte[]]@(239,187,191) + [Text.Encoding]::UTF8.GetBytes("NAME=中文`nHTTP_PROXY=old`n")
        [IO.File]::WriteAllBytes((Join-Path $caseHome '.env'), $raw)
        $plan = New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port
        $expected = [byte[]]@(239,187,191) + [Text.Encoding]::UTF8.GetBytes("NAME=中文`nHTTP_PROXY=http://127.0.0.1:$($good.Port)`nHTTPS_PROXY=http://127.0.0.1:$($good.Port)`nNO_PROXY=localhost,127.0.0.1,::1`n")
        Assert-Bytes $plan.AfterBytes $expected 'BOM/LF preservation.'
    }
    Test-Case 'UTF-16LE BOM and CRLF are retained' {
        $caseHome = New-TestHome 'utf16'
        $raw = [byte[]]@(255,254) + [Text.Encoding]::Unicode.GetBytes("NAME=中文`r`nhttps_proxy=old`r`n")
        [IO.File]::WriteAllBytes((Join-Path $caseHome '.env'), $raw)
        $plan = New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port
        $expected = [byte[]]@(255,254) + [Text.Encoding]::Unicode.GetBytes("NAME=中文`r`nHTTP_PROXY=http://127.0.0.1:$($good.Port)`r`nHTTPS_PROXY=http://127.0.0.1:$($good.Port)`r`nNO_PROXY=localhost,127.0.0.1,::1`r`n")
        Assert-Bytes $plan.AfterBytes $expected 'UTF-16LE preservation.'
    }
    Test-Case 'same-content apply is idempotent and unknown manifest fields survive restore' {
        $caseHome = New-TestHome 'idempotent'
        $first = Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port) -Confirmed
        $second = Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port) -Confirmed
        Assert-Equal $second.Status 'Unchanged' 'Repeated apply must be unchanged.'
        Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $caseHome 'proxy-helper-backups') -Directory).Count 1 'Repeated apply created backup.'
        $manifestPath = Join-Path $first.Backup 'manifest.json'
        $m = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        $m | Add-Member -NotePropertyName reviewer_note -NotePropertyValue 'keep-me'
        [IO.File]::WriteAllText($manifestPath, ($m | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
        Invoke-CodexProxyRestore -Plan (New-CodexRestorePlan -ConfigHome $caseHome) -Confirmed | Out-Null
        $restored = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        Assert-Equal $restored.reviewer_note 'keep-me' 'Unknown field lost.'
        Assert-True ($null -ne $restored.restored_at) 'Restore was not recorded.'
        Assert-True (-not [IO.File]::Exists((Join-Path $caseHome '.env'))) 'Originally absent env must be removed.'
    }
    Test-Case 'restore refuses external edits and leaves current file unchanged' {
        $caseHome = New-TestHome 'external'
        Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port) -Confirmed | Out-Null
        $edited = [Text.Encoding]::UTF8.GetBytes("USER_ADDITION=keep`n")
        [IO.File]::WriteAllBytes((Join-Path $caseHome '.env'), $edited)
        Assert-Throws { New-CodexRestorePlan -ConfigHome $caseHome } 'changed|修改|指纹'
        Assert-Bytes ([IO.File]::ReadAllBytes((Join-Path $caseHome '.env'))) $edited 'Refusal changed file.'
    }
    Test-Case 'restore rejects corrupted original backup' {
        $caseHome = New-TestHome 'corrupt'
        [IO.File]::WriteAllText((Join-Path $caseHome '.env'), 'ORIGINAL=yes')
        $r = Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port) -Confirmed
        [IO.File]::WriteAllText((Join-Path $r.Backup 'original.env'), 'tampered')
        Assert-Throws { New-CodexRestorePlan -ConfigHome $caseHome } 'hash|损坏|校验'
    }
    Test-Case 'stale preview cannot overwrite edits made after confirmation preview' {
        $caseHome = New-TestHome 'stale'
        $plan = New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port
        [IO.File]::WriteAllText((Join-Path $caseHome '.env'), 'NEW=value')
        Assert-Throws { Invoke-CodexProxyApply -Plan $plan -Confirmed } 'changed|修改|指纹'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $caseHome '.env'))) 'NEW=value' 'Stale preview overwrote edit.'
    }
    Test-Case 'latest already-restored backup is skipped for earlier pending backup' {
        $caseHome = New-TestHome 'chain'
        [IO.File]::WriteAllText((Join-Path $caseHome '.env'), 'START=1')
        $a = Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port) -Confirmed
        $other = Start-TestProxy ([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`n`r`n"))
        try {
            $b = Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome -Port $other.Port) -Confirmed
            Invoke-CodexProxyRestore -Plan (New-CodexRestorePlan -ConfigHome $caseHome) -Confirmed | Out-Null
            $prior = New-CodexRestorePlan -ConfigHome $caseHome
            Assert-Equal $prior.Backup $a.Backup 'Did not skip restored latest record.'
            Invoke-CodexProxyRestore -Plan $prior -Confirmed | Out-Null
            Assert-Equal ([IO.File]::ReadAllText((Join-Path $caseHome '.env'))) 'START=1' 'Restore chain failed.'
        } finally { Stop-TestProxy $other }
    }
    Test-Case 'UTF32 and BOMless UTF16 are refused without changing bytes' {
        $formats=@(
            [byte[]]([Text.Encoding]::UTF32.GetPreamble()+[Text.Encoding]::UTF32.GetBytes('KEEP=1')),
            [byte[]][Text.Encoding]::Unicode.GetBytes('KEEP=1')
        )
        $number=0
        foreach ($bytes in $formats) {
            $caseHome=New-TestHome ('unsupported-encoding-'+$number); $number++
            $target=Join-Path $caseHome '.env'; [IO.File]::WriteAllBytes($target,$bytes)
            Assert-Throws { New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port } 'NUL|编码'
            Assert-Bytes ([IO.File]::ReadAllBytes($target)) $bytes 'Unsupported input was changed.'
        }
    }
    Test-Case 'symlink env and backup root are refused' {
        $target = Join-Path $script:TestRoot 'outside.env'; [IO.File]::WriteAllText($target, 'OUTSIDE=untouched')
        $caseHome = New-TestHome 'symlink-env'
        try { New-Item -ItemType SymbolicLink -Path (Join-Path $caseHome '.env') -Target $target -ErrorAction Stop | Out-Null }
        catch { Write-Host 'SKIP symlink creation unavailable on this account'; return }
        Assert-Throws { New-CodexProxyPlan -ConfigHome $caseHome -Port $good.Port } 'link|链接|重解析'
        Assert-Equal ([IO.File]::ReadAllText($target)) 'OUTSIDE=untouched' 'Symlink target changed.'
        $caseHome2 = New-TestHome 'symlink-backup'
        $backupTarget = New-TestHome 'outside-backups'
        New-Item -ItemType SymbolicLink -Path (Join-Path $caseHome2 'proxy-helper-backups') -Target $backupTarget | Out-Null
        Assert-Throws { Invoke-CodexProxyApply -Plan (New-CodexProxyPlan -ConfigHome $caseHome2 -Port $good.Port) -Confirmed } 'link|链接|重解析'
    }
} catch { $script:Failed++; Write-Host ('FAIL setup: ' + $_.Exception.Message) -ForegroundColor Red }
finally {
    if (Get-Variable good -ErrorAction SilentlyContinue) { Stop-TestProxy $good }
    if ([IO.Directory]::Exists($script:TestRoot)) { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force }
}
Write-Host ("Results: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
