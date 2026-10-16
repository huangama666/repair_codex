#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('detect', 'preview', 'apply', 'restore')][string]$Action,
    [ValidateRange(1, 65535)][int]$Port,
    [switch]$Yes,
    [string]$ConfigHome,
    [switch]$LibraryOnly
)
$ErrorActionPreference = 'Stop'

function Test-RunningOnWindows { return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT }
function Get-BytesSha256 {
    param([AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Resolve-CodexConfigHome {
    param([string]$ConfigHome)
    if ([string]::IsNullOrWhiteSpace($ConfigHome)) { $ConfigHome = $env:CODEX_HOME }
    if ([string]::IsNullOrWhiteSpace($ConfigHome)) { $ConfigHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }
    return [IO.Path]::GetFullPath($ConfigHome)
}
function Assert-SafePath {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.LinkType)) {
            throw "拒绝符号链接或重解析点 (link/reparse): $cursor"
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Assert-CurrentEnv {
    param([string]$Target, [bool]$Existed, [AllowNull()][string]$Sha256)
    Assert-SafePath $Target
    if ([IO.Directory]::Exists($Target)) { throw "目标不是普通文件: $Target" }
    $exists = [IO.File]::Exists($Target)
    if ($exists -ne $Existed) { throw '文件在预览后已被修改 (changed)。请重新预览。' }
    if ($exists -and (Get-BytesSha256 ([IO.File]::ReadAllBytes($Target))) -ne $Sha256) {
        throw '文件已被修改 (changed)，当前指纹不匹配；拒绝覆盖。'
    }
}
function Protect-HelperItem {
    param([string]$Path, [switch]$Directory)
    if (-not (Test-RunningOnWindows)) { return }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($Directory) { $acl = New-Object Security.AccessControl.DirectorySecurity }
    else { $acl = New-Object Security.AccessControl.FileSecurity }
    $acl.SetOwner($identity)
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [Security.AccessControl.InheritanceFlags]::None
    if ($Directory) { $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' }
    foreach ($sid in @($identity, (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'), (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule $sid, 'FullControl', $inherit, 'None', 'Allow'
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Write-NewBytes {
    param([string]$Path, [AllowEmptyCollection()][byte[]]$Bytes)
    Assert-SafePath $Path
    $stream = New-Object IO.FileStream $Path, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Write-AtomicBytes {
    param([string]$Path, [AllowEmptyCollection()][byte[]]$Bytes)
    Assert-SafePath $Path
    $temp = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.proxy-helper-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Write-NewBytes -Path $temp -Bytes $Bytes
        Protect-HelperItem -Path $temp
        Assert-SafePath $Path
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Enter-HelperLock {
    param([string]$ConfigHome)
    $lock = Join-Path $ConfigHome 'proxy-helper.lock'
    Assert-SafePath $lock
    if (-not ('CodexProxyNativeLock' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexProxyNativeLock {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CreateDirectory(string path, IntPtr attributes);
    [DllImport("libc", SetLastError = true)]
    public static extern int mkdir(string path, uint mode);
}
'@
    }
    if (Test-RunningOnWindows) { $created = [CodexProxyNativeLock]::CreateDirectory($lock, [IntPtr]::Zero) }
    else { $created = [CodexProxyNativeLock]::mkdir($lock, 448) -eq 0 }
    if (-not $created) { throw "无法取得写入锁: $lock。可能有另一个工具正在操作；异常退出后的旧锁需人工检查。" }
    try { Protect-HelperItem -Path $lock -Directory } catch { [IO.Directory]::Delete($lock); throw }
    return $lock
}
function Convert-EnvBytes {
    param([AllowEmptyCollection()][byte[]]$Bytes, [string[]]$Lines)
    $offset = 0; $prefix = [byte[]]@(); $encoding = [Text.Encoding]::GetEncoding(28591)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) { $offset = 3; $prefix = [byte[]]@(239,187,191) }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) { $offset = 2; $prefix = [byte[]]@(255,254); $encoding = New-Object Text.UnicodeEncoding $false, $false, $true }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) { $offset = 2; $prefix = [byte[]]@(254,255); $encoding = New-Object Text.UnicodeEncoding $true, $false, $true }
    $text = $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset)
    if ($text.IndexOf([char]0) -ge 0) { throw '现有 .env 含 NUL 或不支持的编码（例如 UTF32 / 无 BOM UTF16），已停止并保留原文件。' }
    $newline = "`r`n"
    $match = [regex]::Match($text, "`r`n|`n|`r")
    if ($match.Success) { $newline = $match.Value }
    $kept = New-Object Text.StringBuilder
    foreach ($line in [regex]::Matches($text, '(?s)(.*?)(\r\n|\r|\n|$)')) {
        if ($line.Length -eq 0) { continue }
        $quoted = [regex]::Match($line.Groups[1].Value, '^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*(["''])')
        if ($quoted.Success) {
            $quote = $quoted.Groups[1].Value[0]; $closed=$false; $escaped=$false
            for ($index=$quoted.Length; $index -lt $line.Groups[1].Value.Length; $index++) {
                $character=$line.Groups[1].Value[$index]
                if ($escaped) { $escaped=$false; continue }
                if ($character -eq [char]92) { $escaped=$true; continue }
                if ($character -eq $quote) { $closed=$true; break }
            }
            if (-not $closed) { throw '发现多行 (multiline) 或未闭合引号值；为保留原文件，请手动处理后重试。' }
        }
        if ($line.Groups[1].Value -notmatch '^\s*(?:export\s+)?(?:HTTP_PROXY|HTTPS_PROXY|NO_PROXY)\s*=') { [void]$kept.Append($line.Value) }
    }
    if ($kept.Length -gt 0 -and $kept.ToString() -notmatch '[\r\n]$') { [void]$kept.Append($newline) }
    [void]$kept.Append(($Lines -join $newline) + $newline)
    return ,([byte[]]($prefix + $encoding.GetBytes($kept.ToString())))
}
function New-CodexProxyPlan {
    param([string]$ConfigHome, [ValidateRange(1,65535)][int]$Port)
    $resolved = Resolve-CodexConfigHome $ConfigHome
    Assert-SafePath $resolved
    if ([IO.File]::Exists($resolved)) { throw '配置目录是文件。' }
    $target = Join-Path $resolved '.env'
    Assert-SafePath $target
    if ([IO.Directory]::Exists($target)) { throw '目标 .env 是目录。' }
    $existed = [IO.File]::Exists($target)
    $before = [byte[]]@(); $beforeSha = $null
    if ($existed) { $before = [IO.File]::ReadAllBytes($target); $beforeSha = Get-BytesSha256 $before }
    $lines = @("HTTP_PROXY=http://127.0.0.1:$Port", "HTTPS_PROXY=http://127.0.0.1:$Port", 'NO_PROXY=localhost,127.0.0.1,::1')
    $after = Convert-EnvBytes -Bytes $before -Lines $lines
    $afterSha = Get-BytesSha256 $after
    return [pscustomobject]@{ ConfigHome=$resolved; Target=$target; Port=$Port; Lines=$lines; Existed=$existed; BeforeBytes=$before; BeforeSha256=$beforeSha; AfterBytes=$after; AfterSha256=$afterSha; Changed=(-not $existed -or $beforeSha -ne $afterSha) }
}
function Test-HttpConnectProxy {
    param([ValidateRange(1,65535)][int]$Port, [ValidateRange(100,15000)][int]$TimeoutMs=1500)
    $client = New-Object Net.Sockets.TcpClient
    $result = [ordered]@{ Port=$Port; Usable=$false; StatusCode=$null; Detail='未收到 HTTP CONNECT 200' }
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        try { if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw '连接超时' }; $client.EndConnect($async) }
        finally { $async.AsyncWaitHandle.Close() }
        $stream = $client.GetStream(); $stream.ReadTimeout=$TimeoutMs; $stream.WriteTimeout=$TimeoutMs
        $request = [Text.Encoding]::ASCII.GetBytes("CONNECT chatgpt.com:443 HTTP/1.1`r`nHost: chatgpt.com:443`r`nConnection: close`r`n`r`n")
        $stream.Write($request, 0, $request.Length); $stream.Flush()
        $bytes = New-Object 'Collections.Generic.List[byte]'
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ($bytes.Count -lt 8192) {
            $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($remaining -le 0) { throw '读取超时' }; $stream.ReadTimeout = [Math]::Max(1,$remaining)
            $next = $stream.ReadByte(); if ($next -lt 0) { break }; $bytes.Add([byte]$next)
            if ($bytes.Count -ge 4 -and [Text.Encoding]::ASCII.GetString($bytes.ToArray()).EndsWith("`r`n`r`n")) { break }
            if ($bytes.Count -eq 1 -and $bytes[0] -ne 72) { break }
        }
        $header = [Text.Encoding]::ASCII.GetString($bytes.ToArray())
        $status = [regex]::Match($header, '^HTTP/1\.[01] ([0-9]{3})(?:[ \t][^\r\n]*)?\r\n')
        if ($status.Success) {
            $result.StatusCode = [int]$status.Groups[1].Value
            $result.Detail = 'HTTP CONNECT ' + $result.StatusCode
            $result.Usable = $result.StatusCode -eq 200 -and $header.EndsWith("`r`n`r`n")
        } else { $result.Detail = '不是完整的 HTTP CONNECT 响应（可能是 SOCKS 或普通 TCP 服务）' }
    } catch { $result.Detail = $_.Exception.Message }
    finally { $client.Close() }
    return [pscustomobject]$result
}
function Get-CandidateProxyPorts {
    $ports = New-Object 'Collections.Generic.List[int]'
    foreach ($p in @(7890,7897,10809,10808,1080,8080,8888)) { $ports.Add($p) }
    if (Test-RunningOnWindows) {
        $processIds = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)clash|v2ray|xray|mihomo|sing[-_]?box|surge' } | ForEach-Object { $_.Id })
        if ($processIds.Count -gt 0) {
            try {
                foreach ($connection in @(Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
                    if ($processIds -contains $connection.OwningProcess -and $connection.LocalAddress -in @('127.0.0.1','0.0.0.0','::','::1')) { $ports.Add([int]$connection.LocalPort) }
                }
            } catch {
                foreach ($line in @(& netstat.exe -ano -p tcp)) {
                    if ($line -match '^\s*TCP\s+(\S+):(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$' -and $processIds -contains [int]$matches[3]) { $ports.Add([int]$matches[2]) }
                }
            }
        }
    }
    return @($ports | Select-Object -Unique)
}
function Find-CodexHttpProxies {
    param([int[]]$Ports, [int]$TimeoutMs=1500)
    if (-not $Ports -or $Ports.Count -eq 0) { $Ports = Get-CandidateProxyPorts }
    foreach ($candidate in @($Ports | Select-Object -Unique)) { Test-HttpConnectProxy -Port $candidate -TimeoutMs $TimeoutMs }
}
function Invoke-CodexProxyApply {
    param([Parameter(Mandatory=$true)]$Plan, [switch]$Confirmed)
    if (-not $Confirmed) { return [pscustomobject]@{ Status='Cancelled' } }
    Assert-CurrentEnv -Target $Plan.Target -Existed $Plan.Existed -Sha256 $Plan.BeforeSha256
    if (-not $Plan.Changed) { return [pscustomobject]@{ Status='Unchanged'; Target=$Plan.Target } }
    $probe = Test-HttpConnectProxy -Port $Plan.Port
    if (-not $probe.Usable) { throw ('代理未通过 HTTP CONNECT 200 检查: ' + $probe.Detail) }
    Assert-SafePath $Plan.ConfigHome
    [IO.Directory]::CreateDirectory($Plan.ConfigHome) | Out-Null
    $lock = Enter-HelperLock $Plan.ConfigHome
    try {
        Assert-CurrentEnv -Target $Plan.Target -Existed $Plan.Existed -Sha256 $Plan.BeforeSha256
        $backupRoot = Join-Path $Plan.ConfigHome 'proxy-helper-backups'; Assert-SafePath $backupRoot
        if ([IO.File]::Exists($backupRoot)) { throw '备份路径是文件。' }
        [IO.Directory]::CreateDirectory($backupRoot) | Out-Null; Protect-HelperItem -Path $backupRoot -Directory
        $backup = Join-Path $backupRoot ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
        [IO.Directory]::CreateDirectory($backup) | Out-Null
        if ($Plan.Existed) { Write-NewBytes -Path (Join-Path $backup 'original.env') -Bytes $Plan.BeforeBytes }
        $manifest = [ordered]@{ schema=1; existed=[bool]$Plan.Existed; before_sha256=$Plan.BeforeSha256; after_sha256=$Plan.AfterSha256; created_at=[DateTime]::UtcNow.ToString('o'); state='pending' }
        $manifestBytes = (New-Object Text.UTF8Encoding $false).GetBytes(($manifest | ConvertTo-Json))
        Write-NewBytes -Path (Join-Path $backup 'manifest.json') -Bytes $manifestBytes
        if ($Plan.Existed -and (Get-BytesSha256 ([IO.File]::ReadAllBytes((Join-Path $backup 'original.env')))) -ne $Plan.BeforeSha256) { throw '备份校验失败。' }
        if ((Get-BytesSha256 ([IO.File]::ReadAllBytes((Join-Path $backup 'manifest.json')))) -ne (Get-BytesSha256 $manifestBytes)) { throw '备份清单校验失败。' }
        Assert-CurrentEnv -Target $Plan.Target -Existed $Plan.Existed -Sha256 $Plan.BeforeSha256
        Write-AtomicBytes -Path $Plan.Target -Bytes $Plan.AfterBytes
        $manifest.state='applied'; $manifest.applied_at=[DateTime]::UtcNow.ToString('o')
        Write-AtomicBytes -Path (Join-Path $backup 'manifest.json') -Bytes ((New-Object Text.UTF8Encoding $false).GetBytes(($manifest | ConvertTo-Json)))
        return [pscustomobject]@{ Status='Applied'; Target=$Plan.Target; Backup=$backup }
    } finally { [IO.Directory]::Delete($lock) }
}
function New-CodexRestorePlan {
    param([string]$ConfigHome)
    $resolved = Resolve-CodexConfigHome $ConfigHome
    $target = Join-Path $resolved '.env'; $root = Join-Path $resolved 'proxy-helper-backups'
    Assert-SafePath $target; Assert-SafePath $root
    if (-not [IO.Directory]::Exists($root)) { throw '没有可恢复备份。' }
    if ([IO.Directory]::Exists($target)) { throw '目标 .env 是目录。' }
    $currentExists=[IO.File]::Exists($target); $currentSha=$null
    if ($currentExists) { $currentSha=Get-BytesSha256 ([IO.File]::ReadAllBytes($target)) }
    $chosen = $null
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Force | Sort-Object Name -Descending)) {
        Assert-SafePath $dir.FullName
        $path = Join-Path $dir.FullName 'manifest.json'; Assert-SafePath $path
        if (-not [IO.File]::Exists($path)) { continue }
        $raw = [IO.File]::ReadAllBytes($path)
        $m = [Text.Encoding]::UTF8.GetString($raw).TrimStart([char]0xFEFF) | ConvertFrom-Json
        if ($m.schema -ne 1 -or $m.existed -isnot [bool] -or $m.after_sha256 -notmatch '^[a-fA-F0-9]{64}$' -or ($m.existed -and $m.before_sha256 -notmatch '^[a-fA-F0-9]{64}$') -or (-not $m.existed -and $null -ne $m.before_sha256)) { throw "备份 manifest 无效: $path" }
        if ($m.PSObject.Properties['restored_at'] -and $m.restored_at) { continue }
        if ($m.PSObject.Properties['state'] -and $m.state -notin @('pending','applied')) { throw '备份 state 无效。' }
        $beforeMatches=($currentExists -eq $m.existed) -and (-not $m.existed -or $currentSha -eq $m.before_sha256)
        $alreadyRestored=$false
        $marker=Join-Path $dir.FullName 'manifest.before-restore.json'; Assert-SafePath $marker
        if ($beforeMatches -and [IO.File]::Exists($marker)) {
            $alreadyRestored=(Get-BytesSha256 ([IO.File]::ReadAllBytes($marker))) -eq (Get-BytesSha256 $raw)
        }
        if (-not $alreadyRestored -and $m.PSObject.Properties['state'] -and $m.state -eq 'pending') {
            $beforeMatches=($currentExists -eq $m.existed) -and (-not $m.existed -or $currentSha -eq $m.before_sha256)
            if ($beforeMatches) { continue }
            if (-not $currentExists -or $currentSha -ne $m.after_sha256) { throw '待完成备份对应的文件已被修改 (changed)，拒绝恢复。' }
        }
        $chosen = [pscustomobject]@{ ConfigHome=$resolved; Target=$target; Backup=$dir.FullName; ManifestPath=$path; Manifest=$m; ManifestBytes=$raw; OriginalBytes=[byte[]]@(); EnvAlreadyRestored=$alreadyRestored }
        break
    }
    if ($null -eq $chosen) { throw '没有未恢复的备份。' }
    if (-not $chosen.EnvAlreadyRestored) { Assert-CurrentEnv -Target $target -Existed $true -Sha256 $chosen.Manifest.after_sha256 }
    if ($chosen.Manifest.existed) {
        $original = Join-Path $chosen.Backup 'original.env'; Assert-SafePath $original
        if (-not [IO.File]::Exists($original)) { throw '备份 original.env 缺失。' }
        $chosen.OriginalBytes = [IO.File]::ReadAllBytes($original)
        if ((Get-BytesSha256 $chosen.OriginalBytes) -ne $chosen.Manifest.before_sha256) { throw '原始备份 hash 校验失败，可能已损坏。' }
    }
    return $chosen
}
function Invoke-CodexProxyRestore {
    param([Parameter(Mandatory=$true)]$Plan, [switch]$Confirmed)
    if (-not $Confirmed) { return [pscustomobject]@{ Status='Cancelled' } }
    $lock = Enter-HelperLock $Plan.ConfigHome
    try {
        $fresh = New-CodexRestorePlan -ConfigHome $Plan.ConfigHome
        if ($fresh.Backup -ne $Plan.Backup -or (Get-BytesSha256 $fresh.ManifestBytes) -ne (Get-BytesSha256 $Plan.ManifestBytes)) { throw '备份在预览后已修改 (changed)。请重新预览。' }
        $archive = Join-Path $fresh.Backup 'manifest.before-restore.json'; Assert-SafePath $archive
        if ([IO.File]::Exists($archive)) {
            if ((Get-BytesSha256 ([IO.File]::ReadAllBytes($archive))) -ne (Get-BytesSha256 $fresh.ManifestBytes)) { throw '已有恢复前清单不匹配，拒绝覆盖审查记录。' }
        } else { Write-NewBytes -Path $archive -Bytes $fresh.ManifestBytes }
        if ($fresh.EnvAlreadyRestored) {
            Assert-CurrentEnv -Target $fresh.Target -Existed $fresh.Manifest.existed -Sha256 $fresh.Manifest.before_sha256
        } else {
            Assert-CurrentEnv -Target $fresh.Target -Existed $true -Sha256 $fresh.Manifest.after_sha256
            if ($fresh.Manifest.existed) { Write-AtomicBytes -Path $fresh.Target -Bytes $fresh.OriginalBytes }
            else { [IO.File]::Delete($fresh.Target) }
        }
        $fresh.Manifest | Add-Member -NotePropertyName restored_at -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Write-AtomicBytes -Path $fresh.ManifestPath -Bytes ((New-Object Text.UTF8Encoding $false).GetBytes(($fresh.Manifest | ConvertTo-Json -Depth 100)))
        return [pscustomobject]@{ Status='Restored'; Target=$fresh.Target; Backup=$fresh.Backup }
    } finally { [IO.Directory]::Delete($lock) }
}
function Format-ProxyPreview {
    param($Plan)
    return "目标文件：$($Plan.Target)`r`n`r`n$($Plan.Lines -join "`r`n")`r`n`r`n只管理这三个变量。存在原文件时先保存原字节备份；其它变量保留。"
}
function Show-CodexProxyWindow {
    param([string]$ConfigHome)
    if (-not (Test-RunningOnWindows)) { throw '图形界面需要 Windows；命令行和核心测试可在 PowerShell 运行。' }
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $form.Text='Codex 代理配置助手'; $form.Size=New-Object Drawing.Size 740, 590; $form.StartPosition='CenterScreen'; $form.MinimumSize=$form.Size
    $label = New-Object Windows.Forms.Label; $label.Text='本机 HTTP / mixed 代理端口：'; $label.SetBounds(18,20,220,22)
    $portInput = New-Object Windows.Forms.TextBox; $portInput.SetBounds(240,18,95,25)
    $detect = New-Object Windows.Forms.Button; $detect.Text='检测本机代理'; $detect.SetBounds(350,16,145,30)
    $preview = New-Object Windows.Forms.Button; $preview.Text='预览配置'; $preview.SetBounds(510,16,120,30)
    $list = New-Object Windows.Forms.ListBox; $list.SetBounds(18,62,685,135)
    $text = New-Object Windows.Forms.TextBox; $text.Multiline=$true; $text.ReadOnly=$true; $text.ScrollBars='Vertical'; $text.SetBounds(18,213,685,225)
    $text.Text="目标文件：$(Join-Path (Resolve-CodexConfigHome $ConfigHome) '.env')`r`n`r`n先检测或手填端口，再预览。检测只向 127.0.0.1 发送 chatgpt.com:443 的 HTTP CONNECT；仅 200 视为可用。"
    $apply = New-Object Windows.Forms.Button; $apply.Text='确认写入预览配置'; $apply.Enabled=$false; $apply.SetBounds(18,454,225,36)
    $restore = New-Object Windows.Forms.Button; $restore.Text='恢复最近一次配置'; $restore.SetBounds(258,454,225,36)
    $status = New-Object Windows.Forms.Label; $status.SetBounds(18,504,685,35); $status.Text='修改后请完全退出并重新启动 Codex。不会修改系统或其它软件代理。'
    $form.Controls.AddRange(@($label,$portInput,$detect,$preview,$list,$text,$apply,$restore,$status))
    $state = @{ Plan=$null; Results=@() }
    $portInput.add_TextChanged({ $state.Plan=$null; $apply.Enabled=$false })
    $detect.add_Click({
        $detect.Enabled=$false; $status.Text='正在检查本机端口，请稍候…'; $form.Refresh(); $list.Items.Clear(); $state.Results=@()
        try {
            foreach ($candidate in @(Get-CandidateProxyPorts)) {
                $r=Test-HttpConnectProxy -Port $candidate; $state.Results+=,$r
                $mark='不可用'; if ($r.Usable) { $mark='HTTP CONNECT 200 可用' }
                [void]$list.Items.Add("$($r.Port)  $mark  $($r.Detail)"); $form.Refresh()
            }
            $first=@($state.Results | Where-Object {$_.Usable} | Select-Object -First 1)
            if ($first.Count) { $portInput.Text=[string]$first[0].Port; $status.Text='已填入通过 CONNECT 的端口。点击预览，再确认写入。' }
            else { $status.Text='未发现 HTTP CONNECT 200 代理。可手填 HTTP/mixed 端口后重试。' }
        } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'检测失败') | Out-Null }
        finally { $detect.Enabled=$true }
    })
    $list.add_SelectedIndexChanged({ if ($list.SelectedIndex -ge 0 -and $state.Results.Count -gt $list.SelectedIndex -and $state.Results[$list.SelectedIndex].Usable) { $portInput.Text=[string]$state.Results[$list.SelectedIndex].Port } })
    $preview.add_Click({
        try {
            $value=0; if (-not [int]::TryParse($portInput.Text,[ref]$value) -or $value -lt 1 -or $value -gt 65535) { throw '请输入 1–65535 的 HTTP/mixed 端口。' }
            $probe=Test-HttpConnectProxy -Port $value; if (-not $probe.Usable) { throw ('代理检查失败：'+$probe.Detail) }
            $state.Plan=New-CodexProxyPlan -ConfigHome $ConfigHome -Port $value
            $text.Text=Format-ProxyPreview $state.Plan; $apply.Enabled=$true; $status.Text='已生成预览。点击确认写入按钮后仍会显示最终确认。'
        } catch { $state.Plan=$null; $apply.Enabled=$false; [Windows.Forms.MessageBox]::Show($_.Exception.Message,'预览失败') | Out-Null }
    })
    $apply.add_Click({
        if ($null -eq $state.Plan) { return }
        $answer=[Windows.Forms.MessageBox]::Show((Format-ProxyPreview $state.Plan)+"`r`n`r`n确认写入？",'确认配置',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { $status.Text='已取消，没有写入。'; return }
        try { $r=Invoke-CodexProxyApply -Plan $state.Plan -Confirmed; $status.Text="$($r.Status)：$($r.Target)。请完全退出并重启 Codex。"; $apply.Enabled=$false }
        catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'写入失败') | Out-Null }
    })
    $restore.add_Click({
        try {
            $plan=New-CodexRestorePlan -ConfigHome $ConfigHome
            $message="目标文件：$($plan.Target)`r`n备份：$($plan.Backup)`r`n`r`n恢复原始字节（原文件不存在时删除 .env）。确认恢复？"
            if ([Windows.Forms.MessageBox]::Show($message,'确认恢复',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question) -eq [Windows.Forms.DialogResult]::Yes) {
                $r=Invoke-CodexProxyRestore -Plan $plan -Confirmed; $status.Text="已恢复：$($r.Target)。请完全退出并重启 Codex。"; $state.Plan=$null; $apply.Enabled=$false
            }
        } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'恢复失败') | Out-Null }
    })
    [void]$form.ShowDialog(); $form.Dispose()
}

if ($LibraryOnly) { return }
try {
    if (-not $Action) { Show-CodexProxyWindow -ConfigHome $ConfigHome; return }
    if ($Action -eq 'detect') { Find-CodexHttpProxies | Format-Table Port,Usable,Detail -AutoSize; return }
    if ($Action -eq 'restore') {
        $plan=New-CodexRestorePlan -ConfigHome $ConfigHome
        Write-Host "目标文件：$($plan.Target)`n备份目录：$($plan.Backup)`n恢复原始字节；原文件不存在时删除 .env。"
        $confirmed=$Yes.IsPresent
        if (-not $confirmed) { $confirmed=(Read-Host '输入 YES 确认恢复；其它输入取消') -ceq 'YES' }
        $r=Invoke-CodexProxyRestore -Plan $plan -Confirmed:$confirmed
        Write-Host "$($r.Status)：$($r.Target)"; return
    }
    if (-not $Port) {
        $available=@(Find-CodexHttpProxies | Where-Object {$_.Usable})
        if ($available.Count -eq 0) { throw '未发现通过 HTTP CONNECT 200 的端口。请启动代理并指定 -Port。' }
        $Port=$available[0].Port
    }
    $plan=New-CodexProxyPlan -ConfigHome $ConfigHome -Port $Port
    Write-Host (Format-ProxyPreview $plan)
    if ($Action -eq 'preview') { return }
    $confirmed=$Yes.IsPresent
    if (-not $confirmed) { $confirmed=(Read-Host '输入 YES 确认写入；其它输入取消') -ceq 'YES' }
    $r=Invoke-CodexProxyApply -Plan $plan -Confirmed:$confirmed
    Write-Host "$($r.Status)：$($r.Target)"
    if ($r.Status -ne 'Cancelled') { Write-Host '请完全退出并重新启动 Codex。' }
} catch { Write-Error $_.Exception.Message; exit 1 }
