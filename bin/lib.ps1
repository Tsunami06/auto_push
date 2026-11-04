#Requires -Version 5.1
# 公共库：配置读取、日志、进程调用、git 采集、邮件发送、暂停检测、Cursor commit message 生成
# 目标环境为 Windows PowerShell 5.1（本机未安装 PowerShell 7）
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BinDir    = $PSScriptRoot
$script:RootDir   = Split-Path -Parent $PSScriptRoot
$script:ConfigPath = Join-Path $script:RootDir 'config.json'
$script:StateDir  = Join-Path $script:RootDir 'state'
$script:LogDir    = Join-Path $script:RootDir 'logs'

$env:GIT_PAGER = 'cat'
$env:GIT_TERMINAL_PROMPT = '0'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

# ---------------------------------------------------------------- 日志 / 配置

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $now = Get-Date
    $line = '[{0}] [{1}] {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        $logFile = Join-Path $script:LogDir ('{0}.log' -f $now.ToString('yyyy-MM-dd'))
        Add-Content -LiteralPath $logFile -Value $line -Encoding utf8
    } catch { }
    Write-Host $line
}

function Clear-OldLogs {
    param([int]$KeepDays = 30)
    if ($KeepDays -le 0 -or -not (Test-Path -LiteralPath $script:LogDir)) { return }
    $cutoff = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem -LiteralPath $script:LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Get-Cfg {
    param($Object, [string]$KeyPath, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $cur = $Object
    foreach ($seg in $KeyPath.Split('.')) {
        if ($null -eq $cur) { return $Default }
        $prop = $cur.PSObject.Properties[$seg]
        if ($null -eq $prop) { return $Default }
        $cur = $prop.Value
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "config.json not found: $($script:ConfigPath)"
    }
    $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding utf8
    return ($raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------- 进程调用

function ConvertTo-ProcessArgument {
    # 按 Windows CommandLineToArgvW 规则转义单个参数（PowerShell 5.1 的 ProcessStartInfo 没有 ArgumentList）
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }
        if ($ch -eq '"') {
            [void]$sb.Append(('\' * ($backslashes * 2 + 1)))
            [void]$sb.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$sb.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$sb.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$sb.Append(('\' * ($backslashes * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-Process {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $null,
        [int]$TimeoutSeconds = 300,
        [hashtable]$Environment = @{}
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $quoted = @()
    foreach ($a in $Arguments) { $quoted += (ConvertTo-ProcessArgument -Value ([string]$a)) }
    $psi.Arguments = ($quoted -join ' ')

    foreach ($k in $Environment.Keys) {
        $psi.EnvironmentVariables[[string]$k] = [string]$Environment[$k]
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
    } catch {
        return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = $_.Exception.Message; TimedOut = $false }
    }

    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
        try { $proc.Kill() } catch { }
        $stdout = ''
        $stderr = 'timeout'
        try { $stdout = $outTask.Result } catch { }
        try { $stderr = $errTask.Result + ' timeout' } catch { }
        try { $proc.Dispose() } catch { }
        return [pscustomobject]@{ ExitCode = -1; StdOut = $stdout; StdErr = $stderr; TimedOut = $true }
    }

    $stdout = ''
    $stderr = ''
    try { $stdout = $outTask.Result } catch { }
    try { $stderr = $errTask.Result } catch { }
    $code = $proc.ExitCode
    try { $proc.Dispose() } catch { }
    return [pscustomobject]@{ ExitCode = $code; StdOut = $stdout; StdErr = $stderr; TimedOut = $false }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 120
    )
    $argList = @('-C', $Repo, '-c', 'core.quotepath=false', '--no-pager') + $Arguments
    return Invoke-Process -FileName 'git.exe' -Arguments $argList -WorkingDirectory $Repo -TimeoutSeconds $TimeoutSeconds
}

function Get-GitText {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFail
    )
    $r = Invoke-Git -Repo $Repo -Arguments $Arguments
    if ($r.ExitCode -ne 0) {
        if ($AllowFail) { return '' }
        throw "git $($Arguments -join ' ') failed in [$Repo] exit=$($r.ExitCode): $($r.StdErr)"
    }
    return $r.StdOut.TrimEnd()
}

function Test-GitOk {
    param([string]$Repo, [string[]]$Arguments)
    $r = Invoke-Git -Repo $Repo -Arguments $Arguments
    return ($r.ExitCode -eq 0)
}

# ---------------------------------------------------------------- 仓库发现

function Resolve-ConfigPath {
    param([string]$Path, [string]$BaseDir = $script:RootDir)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $Path))
}

# Get-WatchedRepos 会把「配置了但用不了」的路径记在这里，供调用方在日志/邮件里提示
$script:SkippedScopeEntries = [System.Collections.Generic.List[string]]::new()

function Get-WatchedRepos {
    param($Config)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $repos = [System.Collections.Generic.List[object]]::new()
    $script:SkippedScopeEntries.Clear()

    $addRepo = {
        param([string]$candidate)
        if ([string]::IsNullOrWhiteSpace($candidate)) { return }
        $full = [System.IO.Path]::GetFullPath($candidate)
        if (-not (Test-Path -LiteralPath (Join-Path $full '.git'))) { return }
        if (-not $seen.Add($full)) { return }
        $repos.Add([pscustomobject]@{ Path = $full; Name = (Split-Path -Leaf $full) })
    }

    foreach ($entry in @(Get-Cfg $Config 'scope.repos' @())) {
        if ($null -eq $entry) { continue }
        if ($entry -is [string]) {
            $p = $entry
        } else {
            $p = [string](Get-Cfg $entry 'path' '')
            if ((Get-Cfg $entry 'enabled' $true) -eq $false) { continue }
        }
        if ($p) {
            $resolved = Resolve-ConfigPath -Path $p
            if (-not (Test-Path -LiteralPath $resolved)) {
                $script:SkippedScopeEntries.Add(('{0}（路径不存在）' -f $resolved))
                Write-Log ('配置的仓库路径不存在，已跳过: {0}' -f $resolved) 'WARN'
                continue
            }
            if (-not (Test-Path -LiteralPath (Join-Path $resolved '.git'))) {
                $script:SkippedScopeEntries.Add(('{0}（不是 git 仓库）' -f $resolved))
                Write-Log ('配置的仓库不是 git 仓库，已跳过: {0}' -f $resolved) 'WARN'
                continue
            }
            & $addRepo $resolved
        }
    }

    $ad = Get-Cfg $Config 'scope.autoDiscover'
    if ($ad -and ((Get-Cfg $ad 'enabled' $false) -eq $true)) {
        $maxDepth = [int](Get-Cfg $ad 'maxDepth' 2)
        foreach ($root in @(Get-Cfg $ad 'roots' @())) {
            if (-not $root) { continue }
            $rootFull = Resolve-ConfigPath -Path $root
            if (-not (Test-Path -LiteralPath $rootFull)) { continue }
            & $addRepo $rootFull

            $queue = [System.Collections.Generic.Queue[object]]::new()
            $queue.Enqueue([pscustomobject]@{ Path = $rootFull; Depth = 0 })
            while ($queue.Count -gt 0) {
                $item = $queue.Dequeue()
                if ($item.Depth -ge $maxDepth) { continue }
                $children = Get-ChildItem -LiteralPath $item.Path -Directory -Force -ErrorAction SilentlyContinue
                foreach ($child in $children) {
                    if ($child.Name -eq 'node_modules') { continue }
                    & $addRepo $child.FullName
                    $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = $item.Depth + 1 })
                }
            }
        }
    }

    $namePatterns = @(Get-Cfg $Config 'scope.excludeNamePatterns' @())
    $pathPrefixes = @(Get-Cfg $Config 'scope.excludePaths' @())
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $repos) {
        $skip = $false
        foreach ($pat in $namePatterns) {
            if ($pat -and ($r.Name -like $pat)) { $skip = $true; break }
        }
        if (-not $skip) {
            foreach ($prefix in $pathPrefixes) {
                if (-not $prefix) { continue }
                $pf = Resolve-ConfigPath -Path $prefix
                if ($r.Path.StartsWith($pf, [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
            }
        }
        if (-not $skip) { $result.Add($r) }
    }

    $maxRepos = [int](Get-Cfg $Config 'scope.maxRepos' 100)
    if ($result.Count -gt $maxRepos) {
        return @($result | Select-Object -First $maxRepos)
    }
    return @($result.ToArray())
}

# ---------------------------------------------------------------- git 采集

function Get-RepoBranch {
    param([string]$Repo)
    $b = Get-GitText -Repo $Repo -Arguments @('rev-parse', '--abbrev-ref', 'HEAD') -AllowFail
    if ([string]::IsNullOrWhiteSpace($b) -or $b -eq 'HEAD') { return '(detached)' }
    return $b
}

function ConvertTo-ExcludeRegex {
    # 把 glob（支持 ** / *）转成正则；不含 / 的模式匹配任意层级
    param([string]$Glob)
    if ([string]::IsNullOrWhiteSpace($Glob)) { return $null }
    $normalized = $Glob.Trim() -replace '\\', '/'
    $hasSlash = $normalized.Contains('/')
    $special = '\.+()[]{}^$|?\'
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $normalized.Length) {
        $c = $normalized[$i]
        if ($c -eq '*') {
            if (($i + 2 -lt $normalized.Length) -and ($normalized[$i + 1] -eq '*') -and ($normalized[$i + 2] -eq '/')) {
                [void]$sb.Append('.*')
                $i += 3
                continue
            }
            if (($i + 1 -lt $normalized.Length) -and ($normalized[$i + 1] -eq '*')) {
                [void]$sb.Append('.*')
                $i += 2
                continue
            }
            [void]$sb.Append('[^/]*')
            $i += 1
            continue
        }
        if ($special.Contains([string]$c)) { [void]$sb.Append('\') }
        [void]$sb.Append($c)
        $i += 1
    }
    $body = $sb.ToString()
    if ($hasSlash) { return ('^' + $body.TrimStart('/') + '$') }
    return ('(^|.*/)' + $body + '$')
}

function Get-CompiledExcludes {
    param([string[]]$Patterns)
    $list = New-Object System.Collections.ArrayList
    foreach ($p in $Patterns) {
        $rx = ConvertTo-ExcludeRegex -Glob $p
        if ($rx) { [void]$list.Add($rx) }
    }
    return $list
}

function Get-PushExcludePatterns {
    param($Config)
    return @(Get-Cfg $Config 'push.guard.excludePathPatterns' @())
}

function Get-RepoDirtyFiles {
    param(
        [string]$Repo,
        [string[]]$ExcludePatterns = @()
    )
    $sets = @(
        (Get-GitText -Repo $Repo -Arguments @('diff', '--name-only', '-z') -AllowFail),
        (Get-GitText -Repo $Repo -Arguments @('diff', '--cached', '--name-only', '-z') -AllowFail),
        (Get-GitText -Repo $Repo -Arguments @('ls-files', '-o', '--exclude-standard', '-z') -AllowFail)
    )
    $unique = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($blob in $sets) {
        if ([string]::IsNullOrEmpty($blob)) { continue }
        foreach ($p in $blob.Split([char]0)) {
            $t = $p.Trim()
            if ($t) { [void]$unique.Add($t) }
        }
    }

    $regexes = Get-CompiledExcludes -Patterns $ExcludePatterns
    $files = [System.Collections.Generic.List[object]]::new()
    $excludedCount = 0
    foreach ($rel in $unique) {
        $skip = $false
        foreach ($rx in $regexes) {
            if ([regex]::IsMatch($rel, $rx)) { $skip = $true; break }
        }
        if ($skip) {
            $excludedCount++
            continue
        }
        $full = Join-Path $Repo $rel
        $stamp = $null
        try {
            if (Test-Path -LiteralPath $full) { $stamp = (Get-Item -LiteralPath $full).LastWriteTime }
        } catch { }
        $files.Add([pscustomobject]@{ RelativePath = $rel; FullPath = $full; LastWriteTime = $stamp })
    }
    return [pscustomobject]@{ Files = @($files.ToArray()); ExcludedCount = $excludedCount }
}

function Get-RepoCommits {
    param(
        [string]$Repo,
        [datetime]$Start,
        [datetime]$End,
        [string[]]$Author = @()
    )
    $sep = [char]9
    $pretty = '--pretty=format:%h' + $sep + '%ad' + $sep + '%s'
    $gitArgs = @(
        'log', '--all', '--no-merges',
        '--date=format:%H:%M',
        $pretty,
        ('--since={0}' -f $Start.ToString('yyyy-MM-dd HH:mm:ss')),
        ('--until={0}' -f $End.ToString('yyyy-MM-dd HH:mm:ss'))
    )
    # 支持多个作者（git log 多个 --author 之间是 OR 关系；不要拼成 a|b 正则）
    foreach ($a in @($Author)) {
        if (-not [string]::IsNullOrWhiteSpace($a)) { $gitArgs += ('--author={0}' -f $a) }
    }

    $text = Get-GitText -Repo $Repo -Arguments $gitArgs -AllowFail
    $commits = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in ($text -split "`n")) {
        $clean = $line.TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }
        $parts = $clean.Split($sep)
        if ($parts.Count -lt 3) { continue }
        if (-not $seen.Add($parts[0])) { continue }
        $commits.Add([pscustomobject]@{ Hash = $parts[0]; Time = $parts[1]; Subject = $parts[2] })
    }
    return @($commits.ToArray())
}

function Get-RepoUpstream {
    param([string]$Repo)
    $name = Get-GitText -Repo $Repo -Arguments @('rev-parse', '--abbrev-ref', '@{u}') -AllowFail
    if ([string]::IsNullOrWhiteSpace($name)) {
        return [pscustomobject]@{ Exists = $false; Name = ''; Ahead = 0; AheadCommits = @() }
    }
    $countText = Get-GitText -Repo $Repo -Arguments @('rev-list', '--count', ('{0}..HEAD' -f $name)) -AllowFail
    $count = 0
    [int]::TryParse(($countText -replace '[^\d]', ''), [ref]$count) | Out-Null
    $aheadText = Get-GitText -Repo $Repo -Arguments @('log', '--oneline', ('{0}..HEAD' -f $name)) -AllowFail
    $ahead = @()
    if (-not [string]::IsNullOrWhiteSpace($aheadText)) {
        $ahead = @($aheadText -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ })
    }
    return [pscustomobject]@{ Exists = $true; Name = $name; Ahead = $count; AheadCommits = $ahead }
}

function Get-RepoInfo {
    param(
        [string]$Repo,
        [datetime]$Start,
        [datetime]$End,
        [string[]]$Author = @(),
        [string[]]$ExcludePatterns = @()
    )
    $branch = Get-RepoBranch -Repo $Repo
    $dirtyReport = Get-RepoDirtyFiles -Repo $Repo -ExcludePatterns $ExcludePatterns
    $dirty = @($dirtyReport.Files)
    $commits = @(Get-RepoCommits -Repo $Repo -Start $Start -End $End -Author $Author)
    $upstream = Get-RepoUpstream -Repo $Repo
    $dirtyToday = @($dirty | Where-Object { $null -ne $_.LastWriteTime -and $_.LastWriteTime -ge $Start -and $_.LastWriteTime -lt $End })
    return [pscustomobject]@{
        Path               = $Repo
        Name               = (Split-Path -Leaf $Repo)
        Branch             = $branch
        Commits            = $commits
        Dirty              = $dirty
        DirtyToday         = $dirtyToday
        DirtyExcludedCount = $dirtyReport.ExcludedCount
        Upstream           = $upstream
        HasActivity        = (($commits.Count -gt 0) -or ($dirtyToday.Count -gt 0))
    }
}

# ---------------------------------------------------------------- 时间窗口

function Get-ReportWindow {
    param([string]$ForDate = '')
    if ($ForDate) {
        $day = [datetime]::ParseExact($ForDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        return [pscustomobject]@{ Start = $day; End = $day.AddDays(1); DateLabel = $day.ToString('yyyy-MM-dd') }
    }
    $today = (Get-Date).Date
    return [pscustomobject]@{ Start = $today.AddDays(-1); End = $today; DateLabel = $today.AddDays(-1).ToString('yyyy-MM-dd') }
}

# ---------------------------------------------------------------- 邮件

function Get-AgentlyEntry {
    param($Config)
    $node = [string](Get-Cfg $Config 'mail.nodeExe' '')
    $js = [string](Get-Cfg $Config 'mail.agentlyJs' '')
    if ((Test-Path -LiteralPath $node) -and (Test-Path -LiteralPath $js)) {
        return [pscustomobject]@{ Node = $node; Js = $js }
    }
    return $null
}

function Read-CliJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $candidates = @($Text.Trim())
    $firstBrace = $Text.IndexOf('{')
    $lastBrace = $Text.LastIndexOf('}')
    if ($firstBrace -ge 0 -and $lastBrace -gt $firstBrace) {
        $candidates += $Text.Substring($firstBrace, $lastBrace - $firstBrace + 1)
    }
    foreach ($c in $candidates) {
        try { return ($c | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Invoke-AgentlyCli {
    param(
        $Config,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $null,
        [int]$TimeoutSeconds = 120
    )
    $entry = Get-AgentlyEntry -Config $Config
    if ($null -eq $entry) {
        throw "agently-cli 入口不可用，请检查 config.json 的 mail.nodeExe / mail.agentlyJs"
    }
    $argList = @($entry.Js) + $Arguments
    return Invoke-Process -FileName $entry.Node -Arguments $argList -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
}

function Send-AgentMail {
    param(
        $Config,
        [Parameter(Mandatory)][string]$Subject,
        [string]$BodyMarkdown = '',
        [string]$BodyHtml = '',
        [string[]]$To = $null
    )
    $isHtml = -not [string]::IsNullOrWhiteSpace($BodyHtml)
    $body = if ($isHtml) { $BodyHtml } else { $BodyMarkdown }
    if ([string]::IsNullOrWhiteSpace($body)) { throw "Send-AgentMail 需要 BodyMarkdown 或 BodyHtml" }

    $toList = @()
    if ($null -ne $To -and @($To).Count -gt 0) {
        $toList = @($To)
    } else {
        $toList = @(Get-Cfg $Config 'mail.to' @())
    }
    if (@($toList).Count -eq 0) { throw "config.json 未配置收件人 mail.to" }

    $mailDir = Join-Path $script:StateDir 'mail'
    New-Item -ItemType Directory -Path $mailDir -Force | Out-Null
    $ext = if ($isHtml) { 'html' } else { 'md' }
    $bodyFormat = if ($isHtml) { 'html' } else { 'markdown' }
    $fileName = 'body-{0}-{1}.{2}' -f (Get-Date).ToString('yyyyMMdd-HHmmss-fff'), ([guid]::NewGuid().ToString('N').Substring(0, 6)), $ext
    $fullPath = Join-Path $mailDir $fileName
    [System.IO.File]::WriteAllText($fullPath, $body, [System.Text.UTF8Encoding]::new($false))

    $cliArgs = @('message', '+send')
    foreach ($t in $toList) { $cliArgs += @('--to', $t) }
    $cliArgs += @('--subject', $Subject, '--body-file', ('./{0}' -f $fileName), '--body-format', $bodyFormat)
    if ((Get-Cfg $Config 'mail.autoConfirm' $false) -eq $true) { $cliArgs += '--confirmed' }

    try {
        $r = Invoke-AgentlyCli -Config $Config -Arguments $cliArgs -WorkingDirectory $mailDir -TimeoutSeconds 120
        $json = Read-CliJson -Text $r.StdOut
        if ($r.ExitCode -ne 0) {
            $msg = if ($json -and $json.error -and $json.error.message) { $json.error.message } else { $r.StdErr }
            throw "发送邮件失败 (exit=$($r.ExitCode)): $msg"
        }
        if ($null -eq $json) { throw "发送邮件返回无法解析: $($r.StdOut)" }
        if ($json.ok -ne $true) {
            $msg = if ($json.error -and $json.error.message) { $json.error.message } else { 'unknown' }
            throw "发送邮件被拒绝: $msg"
        }
        return $json
    } finally {
        Remove-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- 暂停检测辅助
# 注意：接口返回的 created_at 是 UTC（例如 2026-11-03T17:22:51Z = 本地 2026-11-04 01:22:51），
# 而检测窗口用的是本地时间。2026-11-04 的漏判就是两者直接比大小造成的（凌晨回复被当成前一天）。
function ConvertTo-UtcDateTimeSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $trimmed = $Text.Trim()
    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    $dto = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($trimmed, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dto)) {
        return $dto.UtcDateTime
    }

    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($trimmed, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) {
            $dt = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Local)
        }
        return $dt.ToUniversalTime()
    }
    return $null
}

function Test-PauseMailInWindow {
    # 把 created_at 统一换算成 UTC 再和窗口比较，避免时区错位
    param([string]$CreatedAt, [datetime]$Since, [datetime]$Until)
    $createdUtc = ConvertTo-UtcDateTimeSafe -Text $CreatedAt
    if ($null -eq $createdUtc) { return $false }
    return (($createdUtc -ge $Since.ToUniversalTime()) -and ($createdUtc -lt $Until.ToUniversalTime()))
}

function ConvertTo-PauseReplyText {
    # 只保留用户自己写的部分：截掉引用的原始邮件，再去掉 HTML 标签/实体
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return '' }
    $cut = $Body
    foreach ($marker in @('回复的邮件信息', 'original-content', 'mailplugin_quote', '-----Original Message-----')) {
        $i = $cut.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
        if ($i -ge 0) { $cut = $cut.Substring(0, $i) }
    }
    # 截断处可能留下半个标签（例如 <div id="），先清掉再转纯文本
    $cut = [regex]::Replace($cut, '<[^>]*$', '')
    $text = [regex]::Replace($cut, '<[^>]+>', "`n")
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = $text -replace "`r", ''
    $lines = @($text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return (($lines -join "`n").Trim())
}

function Test-TextContainsKeyword {
    param([string]$Text, [string]$Keyword)
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Keyword)) { return $false }
    return ($Text.IndexOf($Keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Get-PauseMailOwnText {
    param($Config, [string]$MessageId)
    $r = Invoke-AgentlyCli -Config $Config -Arguments @('message', '+read', '--id', $MessageId) -TimeoutSeconds 60
    if ($r.ExitCode -ne 0) { return $null }
    $json = Read-CliJson -Text $r.StdOut
    if ($null -eq $json -or (Get-Cfg $json 'ok' $false) -ne $true) { return $null }
    return (ConvertTo-PauseReplyText -Body ([string](Get-Cfg $json 'data.body' '')))
}

function Find-PauseRequest {
    param(
        $Config,
        [datetime]$Since,
        [datetime]$Until
    )
    $keywords = @(Get-Cfg $Config 'pause.keywords' @())
    $allow = @(Get-Cfg $Config 'pause.fromAllowlist' @())
    $hits = [System.Collections.Generic.List[object]]::new()
    $seenIds = [System.Collections.Generic.HashSet[string]]::new()
    $sinceIso = $Since.ToString('yyyy-MM-ddTHH:mm:sszzz')
    $untilIso = $Until.ToString('yyyy-MM-ddTHH:mm:sszzz')
    $kwCount = 0
    $searchOkCount = 0
    $candidateCount = 0
    $inWindowCount = 0

    foreach ($kw in $keywords) {
        if (-not $kw) { continue }
        $kwCount++
        $cliArgs = @(
            'message', '+search',
            '--q', $kw,
            '--dir', 'inbox',
            '--limit', '20',
            '--after', $sinceIso,
            '--before', $untilIso
        )
        try {
            $r = Invoke-AgentlyCli -Config $Config -Arguments $cliArgs -TimeoutSeconds 60
        } catch {
            Write-Log ("暂停检测搜索失败（关键词 {0}）: {1}" -f $kw, $_.Exception.Message) 'WARN'
            continue
        }
        if ($r.ExitCode -ne 0) {
            Write-Log ("暂停检测搜索失败（关键词 {0}）exit={1}: {2}" -f $kw, $r.ExitCode, $r.StdErr.Trim()) 'WARN'
            continue
        }
        $json = Read-CliJson -Text $r.StdOut
        if ($null -eq $json) {
            Write-Log ("暂停检测搜索返回无法解析（关键词 {0}）" -f $kw) 'WARN'
            continue
        }
        if ((Get-Cfg $json 'ok' $false) -ne $true) {
            Write-Log ("暂停检测搜索被拒绝（关键词 {0}）: {1}" -f $kw, (Get-Cfg $json 'error.message' 'unknown')) 'WARN'
            continue
        }
        $searchOkCount++
        $items = @(Get-Cfg $json 'data.data' @())
        Write-Log ("暂停检测：关键词「{0}」返回 {1} 封候选" -f $kw, $items.Count)

        foreach ($m in $items) {
            if ($null -eq $m) { continue }
            $id = [string](Get-Cfg $m 'message_id' '')
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if (-not $seenIds.Add($id)) { continue }
            $candidateCount++

            $from = [string](Get-Cfg $m 'from.email' '')
            if ($allow.Count -gt 0 -and ($allow -notcontains $from)) {
                Write-Log ("暂停检测：忽略邮件 {0}（发件人 {1} 不在白名单）" -f $id, $from)
                continue
            }

            $createdRaw = [string](Get-Cfg $m 'created_at' '')
            if (-not (Test-PauseMailInWindow -CreatedAt $createdRaw -Since $Since -Until $Until)) {
                Write-Log ("暂停检测：忽略邮件 {0}（created_at={1} 不在 {2} ~ {3}）" -f $id, $createdRaw, $sinceIso, $untilIso)
                continue
            }
            $inWindowCount++

            $subject = [string](Get-Cfg $m 'subject' '')
            $snippet = [string](Get-Cfg $m 'snippet' '')

            # 只认用户自己写的正文：日报正文里本来就写着「不提交」，回复里引用原文不算指令
            $ownText = $null
            try { $ownText = Get-PauseMailOwnText -Config $Config -MessageId $id } catch { $ownText = $null }
            if ($null -eq $ownText) {
                Write-Log ("暂停检测：读取邮件 {0} 正文失败，回退按标题/摘要判断" -f $id) 'WARN'
                $ownText = $snippet
            }

            $matched = (Test-TextContainsKeyword -Text $subject -Keyword $kw) -or
                       (Test-TextContainsKeyword -Text $ownText -Keyword $kw)
            if (-not $matched) {
                Write-Log ("暂停检测：邮件 {0} 仅引用原文中含「{1}」，不算暂停指令" -f $id, $kw)
                continue
            }

            $hits.Add([pscustomobject]@{
                MessageId = $id
                Keyword   = $kw
                From      = $from
                Subject   = $subject
                CreatedAt = $createdRaw
            })
            Write-Log ("暂停检测：命中暂停邮件（关键词「{0}」 发件人 {1} created_at={2}）" -f $kw, $from, $createdRaw)
        }
    }

    if ($kwCount -gt 0 -and $searchOkCount -eq 0) {
        throw '暂停检测无法执行：所有关键词搜索都失败（邮件通道/授权异常），无法确认是否收到「不提交」回复'
    }

    if ($hits.Count -eq 0) {
        Write-Log ("暂停检测完成：未发现暂停邮件（关键词 {0} 个，候选 {1} 封，窗口内 {2} 封）" -f $kwCount, $candidateCount, $inWindowCount)
        return $null
    }
    Write-Log ("暂停检测完成：命中 {0} 封（候选 {1} 封，窗口内 {2} 封），按暂停处理" -f $hits.Count, $candidateCount, $inWindowCount)
    return $hits[0]
}

# ---------------------------------------------------------------- Cursor commit message

function Get-CursorEntry {
    param($Config)
    $cursorHome = [string](Get-Cfg $Config 'push.commitMessage.cursorAgentHome' '')
    if (-not $cursorHome) {
        $cursorHome = Join-Path $env:LOCALAPPDATA 'cursor-agent'
    }
    $versions = Join-Path $cursorHome 'versions'
    if (-not (Test-Path -LiteralPath $versions)) { return $null }
    $dir = Get-ChildItem -LiteralPath $versions -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'node.exe')) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'index.js'))
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $dir) { return $null }
    return [pscustomobject]@{
        Node = (Join-Path $dir.FullName 'node.exe')
        Js   = (Join-Path $dir.FullName 'index.js')
    }
}

function Limit-Text {
    param([string]$Text, [int]$Max)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + "`n...(已截断)"
}

function Get-FallbackCommitMessage {
    param([string]$Repo, [int]$FileCount, [string]$Type = 'chore')
    $name = Split-Path -Leaf $Repo
    return ('{0}({1}): 自动提交 {2} 个改动文件（{3}）' -f $Type, $name, $FileCount, (Get-Date).ToString('yyyy-MM-dd'))
}

function New-CommitMessage {
    param(
        $Config,
        [string]$Repo,
        [string]$Branch,
        [string[]]$DirtyFiles = @()
    )
    $provider = [string](Get-Cfg $Config 'push.commitMessage.provider' 'cursor')
    $timeout = [int](Get-Cfg $Config 'push.commitMessage.timeoutSeconds' 240)
    $maxDiff = [int](Get-Cfg $Config 'push.commitMessage.maxDiffChars' 12000)
    $language = [string](Get-Cfg $Config 'push.commitMessage.language' 'zh')

    $fallback = Get-FallbackCommitMessage -Repo $Repo -FileCount $DirtyFiles.Count
    if ($provider -ne 'cursor') { return $fallback }

    $entry = Get-CursorEntry -Config $Config
    if ($null -eq $entry) {
        Write-Log '未找到 cursor-agent 可执行文件，使用模板 commit message' 'WARN'
        return $fallback
    }

    try {
        $statusText = Limit-Text -Text (Get-GitText -Repo $Repo -Arguments @('status', '--short') -AllowFail) -Max 3000
        $statText = Limit-Text -Text ((Get-GitText -Repo $Repo -Arguments @('diff', '--stat') -AllowFail) + "`n" + (Get-GitText -Repo $Repo -Arguments @('diff', '--cached', '--stat') -AllowFail)) -Max 3000
        $diffText = Limit-Text -Text ((Get-GitText -Repo $Repo -Arguments @('diff', '--unified=1') -AllowFail) + "`n" + (Get-GitText -Repo $Repo -Arguments @('diff', '--cached', '--unified=1') -AllowFail)) -Max $maxDiff
        $recent = Limit-Text -Text (Get-GitText -Repo $Repo -Arguments @('log', '-8', '--pretty=format:%s') -AllowFail) -Max 1200
        $repoName = Split-Path -Leaf $Repo

        $prompt = @"
你是资深软件工程师。请根据下面给出的仓库改动，生成一条符合 Conventional Commits 规范的 commit message。

仓库：$repoName
分支：$Branch

硬性要求：
1. 只输出一行 commit message，不要解释、不要代码块、不要引号、不要前后缀。
2. 格式：<type>(<scope>): <summary>
3. type 只能是：feat | fix | docs | style | refactor | perf | test | build | ci | chore | revert
4. scope 可省略；summary 用中文，不超过 50 字，不以句号结尾。
5. 改动涉及多个不相关模块时，选择最主要的一个类型与范围。

该仓库最近提交风格参考（保持语气一致）：
$recent

改动文件列表：
$statusText

改动统计：
$statText

改动内容（可能被截断）：
$diffText
"@

        $cursorArgs = @($entry.Js, '-p', $prompt, '--output-format', 'text', '--trust', '--mode', 'ask')
        $r = Invoke-Process -FileName $entry.Node -Arguments $cursorArgs -WorkingDirectory $Repo -TimeoutSeconds $timeout
        if ($r.TimedOut) {
            Write-Log 'cursor-agent 超时，使用模板 commit message' 'WARN'
            return $fallback
        }
        $raw = ($r.StdOut + "`n" + $r.StdErr).Trim()
        if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            Write-Log ("cursor-agent 失败 (exit=$($r.ExitCode))，使用模板 commit message: {0}" -f (Limit-Text -Text $raw -Max 400)) 'WARN'
            return $fallback
        }

        $pattern = '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?:\s*(.+)$'
        foreach ($line in ($raw -split "`n")) {
            $candidate = $line.Trim().Trim('`').Trim('"').Trim("'").Trim()
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            if ($candidate.StartsWith('```')) { continue }
            if ($candidate -match $pattern) {
                if ($candidate.Length -gt 120) { $candidate = $candidate.Substring(0, 120) }
                return $candidate
            }
        }
        Write-Log 'cursor-agent 输出不符合格式，使用模板 commit message' 'WARN'
        return $fallback
    } catch {
        Write-Log ("生成 commit message 异常: {0}" -f $_.Exception.Message) 'WARN'
        return $fallback
    }
}

# ---------------------------------------------------------------- 杂项

function Get-SingleInstance {
    param([string]$Name)
    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    $lockPath = Join-Path $script:StateDir ('{0}.lock' -f $Name)
    try {
        $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        return $stream
    } catch {
        return $null
    }
}

function Get-MachineGitIdentity {
    $name = ''
    $email = ''
    $r1 = Invoke-Process -FileName 'git.exe' -Arguments @('config', '--global', 'user.name')
    if ($r1.ExitCode -eq 0) { $name = $r1.StdOut.Trim() }
    $r2 = Invoke-Process -FileName 'git.exe' -Arguments @('config', '--global', 'user.email')
    if ($r2.ExitCode -eq 0) { $email = $r2.StdOut.Trim() }
    return [pscustomobject]@{ Name = $name; Email = $email }
}
