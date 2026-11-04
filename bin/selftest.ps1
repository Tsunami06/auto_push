#Requires -Version 5.1
<#
    自检脚本：验证自动任务运行环境是否就绪。
    建议通过计划任务运行一次（计划任务环境与沙箱不同，才能真实验证 Cursor / 邮件）。

    用法：
      powershell -File .\bin\selftest.ps1                 # 环境自检，不发邮件
      powershell -File .\bin\selftest.ps1 -SendMail       # 额外发送一封自检邮件
#>
param(
    [switch]$SendMail
)

. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'approval-lib.ps1')

$failures = [System.Collections.Generic.List[string]]::new()

function Report-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        Write-Host ('[PASS] {0} {1}' -f $Name, $Detail)
        Write-Log ('[SELFTEST PASS] {0} {1}' -f $Name, $Detail)
    } else {
        Write-Host ('[FAIL] {0} {1}' -f $Name, $Detail)
        Write-Log ('[SELFTEST FAIL] {0} {1}' -f $Name, $Detail) 'ERROR'
        $failures.Add($Name) | Out-Null
    }
}

Write-Log '=== 自检开始 ==='

# 1. git
$git = Invoke-Process -FileName 'git.exe' -Arguments @('--version')
Report-Result -Name 'git' -Ok ($git.ExitCode -eq 0) -Detail $git.StdOut.Trim()

# 2. powershell
Report-Result -Name 'powershell' -Ok ($PSVersionTable.PSVersion.Major -ge 5) -Detail $PSVersionTable.PSVersion.ToString()

# 3. 配置
$config = $null
try {
    $config = Read-Config
    Report-Result -Name 'config.json' -Ok $true -Detail (Join-Path $script:RootDir 'config.json')
} catch {
    Report-Result -Name 'config.json' -Ok $false -Detail $_.Exception.Message
}

# 4. 暂停邮件时间窗换算（回归：created_at 为 UTC、检测窗口为本地时间）
try {
    $since = [datetime]::new(2026, 11, 4, 0, 0, 0, [System.DateTimeKind]::Local)
    $until = [datetime]::new(2026, 11, 4, 7, 0, 0, [System.DateTimeKind]::Local)
    $cases = @(
        @{ Name = 'UTC 17:22Z→本地次日 01:22'; Created = '2026-11-03T17:22:51Z'; Expect = $true },
        @{ Name = '+08:00 01:00'; Created = '2026-11-04T01:00:00+08:00'; Expect = $true },
        @{ Name = '无时区 00:30'; Created = '2026-11-04 00:30:00'; Expect = $true },
        @{ Name = '窗口前 本地 20:00'; Created = '2026-11-03T12:00:00Z'; Expect = $false },
        @{ Name = '窗口后 本地 08:30'; Created = '2026-11-04T00:30:00Z'; Expect = $false },
        @{ Name = '不可解析'; Created = 'not-a-date'; Expect = $false }
    )
    $bad = @()
    foreach ($c in $cases) {
        $got = Test-PauseMailInWindow -CreatedAt $c.Created -Since $since -Until $until
        if ($got -ne $c.Expect) { $bad += $c.Name }
    }
    Report-Result -Name '暂停邮件时间窗' -Ok ($bad.Count -eq 0) -Detail $(if ($bad.Count -eq 0) { ('{0}/{0} 通过' -f $cases.Count) } else { '不符: ' + ($bad -join ', ') })
} catch {
    Report-Result -Name '暂停邮件时间窗' -Ok $false -Detail $_.Exception.Message
}

# 5. 引用原文不触发暂停（回归：只认用户自己写的正文）
try {
    $quoteOnly = '<div>收到，谢谢</div><div id="original-content"><div class="mailplugin_quote_type">----------回复的邮件信息----------</div><div>直接回复本邮件，正文写「不提交」即可</div></div>'
    $pauseBody = '<div>不提交</div><div><br /></div><div id="original-content"><div class="mailplugin_quote_type">----------回复的邮件信息----------</div><div>正文写「不提交」即可</div></div>'
    $ownA = ConvertTo-PauseReplyText -Body $quoteOnly
    $ownB = ConvertTo-PauseReplyText -Body $pauseBody
    $ok = (-not (Test-TextContainsKeyword -Text $ownA -Keyword '不提交')) -and (Test-TextContainsKeyword -Text $ownB -Keyword '不提交')
    Report-Result -Name '引用原文不误判' -Ok $ok -Detail ('仅引用→「{0}」；自己写→「{1}」' -f ($ownA -replace "`n", ' '), ($ownB -replace "`n", ' '))
} catch {
    Report-Result -Name '引用原文不误判' -Ok $false -Detail $_.Exception.Message
}

if ($config) {
    # 6. agently-cli 入口
    $agently = Get-AgentlyEntry -Config $config
    Report-Result -Name 'agently-cli' -Ok ($null -ne $agently) -Detail $(if ($agently) { $agently.Js } else { '未找到 node.exe / run.js' })

    # 7. cursor-agent 入口
    $cursor = Get-CursorEntry -Config $config
    Report-Result -Name 'cursor-agent' -Ok ($null -ne $cursor) -Detail $(if ($cursor) { $cursor.Js } else { '未找到 cursor-agent 版本目录' })

    # 8. 仓库发现
    try {
        $repos = @(Get-WatchedRepos -Config $config)
        Report-Result -Name '仓库发现' -Ok ($repos.Count -gt 0) -Detail ('共 {0} 个: {1}' -f $repos.Count, (($repos | Select-Object -First 8 | ForEach-Object { $_.Name }) -join ', '))
    } catch {
        Report-Result -Name '仓库发现' -Ok $false -Detail $_.Exception.Message
    }

    # 9. Cursor 生成 commit message（在临时仓库里验证，不碰真实仓库）
    if ($cursor) {
        try {
            $scratch = Join-Path $script:StateDir 'selftest-repo'
            if (-not (Test-Path -LiteralPath (Join-Path $scratch '.git'))) {
                New-Item -ItemType Directory -Path $scratch -Force | Out-Null
                $r = Invoke-Process -FileName 'git.exe' -Arguments @('init', '-q') -WorkingDirectory $scratch
                if ($r.ExitCode -ne 0) { throw 'git init 失败' }
                Set-Content -LiteralPath (Join-Path $scratch 'demo.txt') -Value '自检用文件' -Encoding utf8
            } else {
                Add-Content -LiteralPath (Join-Path $scratch 'demo.txt') -Value ('自检时间 {0}' -f (Get-Date).ToString('HH:mm:ss')) -Encoding utf8
            }
            $dirtyReport = Get-RepoDirtyFiles -Repo $scratch
            $dirty = @($dirtyReport.Files)
            $msg = New-CommitMessage -Config $config -Repo $scratch -Branch 'selftest' -DirtyFiles (@($dirty | ForEach-Object { $_.RelativePath }))
            $ok = $msg -match '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?:\s*.+$'
            Report-Result -Name 'Cursor 生成 commit message' -Ok $ok -Detail $msg
        } catch {
            Report-Result -Name 'Cursor 生成 commit message' -Ok $false -Detail $_.Exception.Message
        }
    }

    # 10. 文字回信确认：指令解析 / 最新优先
    try {
        $parsed = @(ConvertTo-ApprovalDecisionList -Text "提交 demo-a`n不提交 demo-b" -RepoNames @('demo-a', 'demo-b'))
        $okA = (@($parsed | Where-Object { $_.Repo -eq 'demo-a' -and $_.Decision -eq 'submit' }).Count -gt 0)
        $okB = (@($parsed | Where-Object { $_.Repo -eq 'demo-b' -and $_.Decision -eq 'skip' }).Count -gt 0)
        $globalParse = @(ConvertTo-ApprovalDecisionList -Text '提交' -RepoNames @('demo-a', 'demo-b'))
        $okGlobal = ($globalParse.Count -eq 1) -and ($globalParse[0].Repo -eq '*') -and ($globalParse[0].Decision -eq 'submit')
        $events = @(
            [pscustomobject]@{ Repo = 'demo-a'; Decision = 'skip'; TimeUtc = [datetime]::SpecifyKind([datetime]'2026-11-04T06:00:00', 'Utc'); Source = 'mail' },
            [pscustomobject]@{ Repo = 'demo-a'; Decision = 'submit'; TimeUtc = [datetime]::SpecifyKind([datetime]'2026-11-04T06:30:00', 'Utc'); Source = 'mail' }
        )
        $resolved = Resolve-ApprovalDecision -Events $events -RepoName 'demo-a' -Default 'skip'
        $okResolve = ($resolved.Decision -eq 'submit')
        Report-Result -Name '回信指令解析' -Ok ($okA -and $okB -and $okGlobal) -Detail ('解析 {0} 条；全局提交={1}' -f $parsed.Count, $okGlobal)
        Report-Result -Name '回信最新优先' -Ok $okResolve -Detail ('最终决定={0}' -f $resolved.Decision)
    } catch {
        Report-Result -Name '文字回信确认' -Ok $false -Detail $_.Exception.Message
    }

    # 11. 邮件发送
    if ($SendMail) {
        try {
            $body = "# 自检邮件`n`n自动提交系统环境自检通过。`n`n- 时间：{0}`n- 主机：{1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME
            $to = @(Get-Cfg $config 'mail.to' @())
            Send-AgentMail -Config $config -Subject '【自检】自动提交系统邮件通道正常' -BodyMarkdown $body | Out-Null
            Report-Result -Name '邮件发送' -Ok $true -Detail (($to) -join ', ')
        } catch {
            Report-Result -Name '邮件发送' -Ok $false -Detail $_.Exception.Message
        }
    }
}

Write-Log ('=== 自检结束：失败 {0} 项 ===' -f $failures.Count)
if ($failures.Count -gt 0) {
    Write-Host ('失败项: {0}' -f ($failures -join ', '))
    exit 1
}
Write-Host '全部检查通过。'
exit 0
