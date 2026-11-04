#Requires -Version 5.1
<#
    每日工作报告（默认 00:00 由计划任务触发）
    汇总指定时间窗口内每个仓库的：已提交内容、未提交改动、待推送提交，并发送 HTML 邮件。
    邮件只做展示；如果要放行某个项目，直接回复本邮件写「提交」或「提交 项目名」。
    07:00 只推送被文字回复确认的项目（默认不提交）。

    用法：
      powershell -File .\bin\nightly-report.ps1                # 正常发送（窗口 = 昨天 00:00 ~ 今天 00:00）
      powershell -File .\bin\nightly-report.ps1 -DryRun        # 只生成预览，不发邮件
      powershell -File .\bin\nightly-report.ps1 -ForDate 2026-11-03   # 指定报告哪一天（测试用）
      powershell -File .\bin\nightly-report.ps1 -SendPreview   # 发一封「样式预览」邮件到邮箱（不影响真实计划）
      powershell -File .\bin\nightly-report.ps1 -ConfigFile .\state\preview\demo-config.json  # 测试用配置
#>
param(
    [switch]$DryRun,
    [string]$ForDate = '',
    [switch]$SendPreview,
    [string]$ConfigFile = ''
)

. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'report-html.ps1')

if (-not [string]::IsNullOrWhiteSpace($ConfigFile)) {
    $script:ConfigPath = [System.IO.Path]::GetFullPath($ConfigFile)
    Write-Host ('[INFO] 使用配置: {0}' -f $script:ConfigPath)
}

$lock = Get-SingleInstance -Name 'nightly-report'
if ($null -eq $lock) {
    Write-Log '已有报告任务在运行，本次跳过' 'WARN'
    exit 0
}

try {
    $config = Read-Config
    Clear-OldLogs -KeepDays ([int](Get-Cfg $config 'logging.keepDays' 30))
    Write-Log '=== 每日工作报告开始 ==='

    $window = Get-ReportWindow -ForDate $ForDate
    $identity = Get-MachineGitIdentity
    $author = [string](Get-Cfg $config 'report.authorFilter' '')
    if ([string]::IsNullOrWhiteSpace($author)) { $author = $identity.Email }
    Write-Log ("报告窗口 {0} ~ {1}，作者过滤={2}" -f $window.Start.ToString('yyyy-MM-dd HH:mm'), $window.End.ToString('yyyy-MM-dd HH:mm'), $author)

    $repos = @(Get-WatchedRepos -Config $config)
    Write-Log ("发现仓库 {0} 个" -f $repos.Count)
    $skippedScope = @($script:SkippedScopeEntries)
    if ($skippedScope.Count -gt 0) {
        Write-Log ('配置中无法管理的路径: {0}' -f ($skippedScope -join '；')) 'WARN'
    }

    $infos = [System.Collections.Generic.List[object]]::new()
    foreach ($repo in $repos) {
        try {
            $info = Get-RepoInfo -Repo $repo.Path -Start $window.Start -End $window.End -Author $author -ExcludePatterns (Get-PushExcludePatterns -Config $config)
        } catch {
            Write-Log ("采集失败 [{0}]: {1}" -f $repo.Name, $_.Exception.Message) 'WARN'
            continue
        }
        $onlyActive = (Get-Cfg $config 'report.onlyActiveRepos' $true) -eq $true
        $hasPendingPush = ([int](Get-Cfg $info 'Upstream.Ahead' 0)) -gt 0
        if ($onlyActive -and (-not $info.HasActivity) -and (-not $hasPendingPush)) { continue }
        $infos.Add($info)
    }

    $totalCommits = (@($infos | ForEach-Object { @($_.Commits).Count } | Measure-Object -Sum).Sum)
    $totalPending = (@($infos | ForEach-Object { @($_.Dirty).Count } | Measure-Object -Sum).Sum)
    $totalAhead = (@($infos | ForEach-Object { [int](Get-Cfg $_ 'Upstream.Ahead' 0) } | Measure-Object -Sum).Sum)
    $totalExcluded = (@($infos | ForEach-Object { [int](Get-Cfg $_ 'DirtyExcludedCount' 0) } | Measure-Object -Sum).Sum)
    if ($null -eq $totalCommits) { $totalCommits = 0 }
    if ($null -eq $totalPending) { $totalPending = 0 }
    if ($null -eq $totalAhead) { $totalAhead = 0 }
    if ($null -eq $totalExcluded) { $totalExcluded = 0 }

    $fileLimit = [int](Get-Cfg $config 'report.fileListLimit' 40)
    $approvalMode = [string](Get-Cfg $config 'approval.mode' 'required')

    # ---------------- HTML 邮件
    $html = New-ReportHtml -Config $config -Window $window -Infos @($infos.ToArray()) -SkippedScope $skippedScope `
        -GeneratedAt (Get-Date) -Preview:$SendPreview

    $previewDir = Join-Path $script:StateDir 'preview'
    New-Item -ItemType Directory -Path $previewDir -Force | Out-Null
    $htmlPreviewPath = Join-Path $previewDir ('report-{0}.html' -f $window.DateLabel)
    [System.IO.File]::WriteAllText($htmlPreviewPath, $html, [System.Text.UTF8Encoding]::new($false))
    Write-Log ('HTML 预览已写入: {0}' -f $htmlPreviewPath)

    # ---------------- Markdown 版本（仅用于本地预览 / 排查）
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine(('# 每日工作报告 · {0}' -f $window.DateLabel))
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## 概览')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| 项目 | 数值 |')
    [void]$sb.AppendLine('| --- | --- |')
    [void]$sb.AppendLine(('| 待处理项目 | {0} 个 |' -f @($infos).Count))
    [void]$sb.AppendLine(('| 今日提交 | {0} 个 |' -f $totalCommits))
    [void]$sb.AppendLine(('| 未提交文件（今天改动） | {0} 个 |' -f $totalPending))
    [void]$sb.AppendLine(('| 待推送提交 | {0} 个 |' -f $totalAhead))
    if ($totalExcluded -gt 0) {
        [void]$sb.AppendLine(('| 自动忽略的构建产物/配置 | {0} 个 |' -f $totalExcluded))
    }
    [void]$sb.AppendLine()
    if ($skippedScope.Count -gt 0) {
        [void]$sb.AppendLine(('> 注意：配置里的这些路径当前无法管理（已跳过）：{0}' -f ($skippedScope -join '；')))
        [void]$sb.AppendLine()
    }

    $withCommits = @($infos | Where-Object { @($_.Commits).Count -gt 0 })
    [void]$sb.AppendLine('## 一、已提交')
    [void]$sb.AppendLine()
    if ($withCommits.Count -eq 0) {
        [void]$sb.AppendLine('当天没有提交记录。')
    } else {
        foreach ($info in $withCommits) {
            [void]$sb.AppendLine(('### {0} · `{1}`' -f $info.Name, $info.Branch))
            [void]$sb.AppendLine()
            foreach ($c in @($info.Commits)) {
                [void]$sb.AppendLine(('- `{0}` **{1}**' -f $c.Time, $c.Subject))
                [void]$sb.AppendLine(('  - commit `{0}`' -f $c.Hash))
            }
            if ([int](Get-Cfg $info 'Upstream.Ahead' 0) -gt 0) {
                [void]$sb.AppendLine()
                [void]$sb.AppendLine(('> 其中 **{0} 个提交尚未推送**，07:00 会一起推送。' -f $info.Upstream.Ahead))
            }
            [void]$sb.AppendLine()
        }
    }
    [void]$sb.AppendLine()

    $withDirty = @($infos | Where-Object { @($_.Dirty).Count -gt 0 })
    [void]$sb.AppendLine('## 二、未提交')
    [void]$sb.AppendLine()
    if ($withDirty.Count -eq 0) {
        [void]$sb.AppendLine('所有改动都已提交，工作区干净。')
    } else {
        foreach ($info in $withDirty) {
            $dirtyToday = @($info.DirtyToday)
            $dirtyOther = @($info.Dirty | Where-Object { $null -eq $_.LastWriteTime -or $_.LastWriteTime -lt $window.Start })
            [void]$sb.AppendLine(('### {0} · `{1}` — {2} 个文件' -f $info.Name, $info.Branch, @($info.Dirty).Count))
            [void]$sb.AppendLine()
            if ($dirtyToday.Count -eq 0) {
                [void]$sb.AppendLine('（今天没有新改动，以下是历史遗留的未提交文件）')
                [void]$sb.AppendLine()
            }
            $shown = [System.Math]::Min($fileLimit, $dirtyToday.Count + $dirtyOther.Count)
            $index = 0
            foreach ($f in $dirtyToday) {
                if ($index -ge $shown) { break }
                $stamp = if ($f.LastWriteTime) { $f.LastWriteTime.ToString('HH:mm') } else { '--:--' }
                [void]$sb.AppendLine(('- `{0}`（今天 {1}）' -f $f.RelativePath, $stamp))
                $index++
            }
            foreach ($f in $dirtyOther) {
                if ($index -ge $shown) { break }
                $stamp = if ($f.LastWriteTime) { $f.LastWriteTime.ToString('yyyy-MM-dd') } else { '未知时间' }
                [void]$sb.AppendLine(('- `{0}`（{1}）' -f $f.RelativePath, $stamp))
                $index++
            }
            if (@($info.Dirty).Count -gt $shown) {
                [void]$sb.AppendLine(('... 另有 {0} 个文件未列出' -f (@($info.Dirty).Count - $shown)))
            }
            if ([int](Get-Cfg $info 'DirtyExcludedCount' 0) -gt 0) {
                [void]$sb.AppendLine(('> 另有 {0} 个构建产物/IDE 配置类文件，自动任务会跳过，不会提交。' -f $info.DirtyExcludedCount))
            }
            [void]$sb.AppendLine()
        }
    }
    [void]$sb.AppendLine()

    [void]$sb.AppendLine('## 三、早上 07:00（确认制）')
    [void]$sb.AppendLine()
    if ($approvalMode -eq 'required') {
        [void]$sb.AppendLine('默认**不提交**：只有你回复「提交」的项目才会自动 commit + push；没回复的项目保持原样。')
    } else {
        [void]$sb.AppendLine('默认**提交**：没有回复「不提交」的项目会在 07:00 自动 commit + push。')
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('回复方式：直接回复本邮件，写「提交」放行全部，或「提交 项目名」只放行该项目；写「不提交」或不回复则跳过。')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine(('本邮件由 E:\auto_push 自动任务生成 · {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))

    $mdPreviewPath = Join-Path $previewDir ('report-{0}.md' -f $window.DateLabel)
    [System.IO.File]::WriteAllText($mdPreviewPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    Write-Log ('Markdown 预览已写入: {0}' -f $mdPreviewPath)

    # ---------------- 发送
    $subjectTemplate = [string](Get-Cfg $config 'mail.reportSubject' '【每日工作报告】{date}')
    $subject = $subjectTemplate.Replace('{date}', $window.DateLabel).
        Replace('{commits}', [string]$totalCommits).
        Replace('{pending}', [string]$totalPending)
    if ($SendPreview) {
        $subject = ('【样式预览】每日工作报告 · {0}｜{1} 个项目 · {2} 个提交 · {3} 个未提交文件' -f $window.DateLabel, @($infos).Count, $totalCommits, $totalPending)
    }

    if ($DryRun) {
        Write-Host ''
        Write-Host '===== DRY RUN ====='
        Write-Host ('Subject: {0}' -f $subject)
        Write-Host ('HTML Preview: {0}' -f $htmlPreviewPath)
        Write-Host ('Markdown Preview: {0}' -f $mdPreviewPath)
        Write-Host '-------------------'
        Write-Host $sb.ToString()
        Write-Log 'DryRun 完成，未发送邮件'
    } else {
        Send-AgentMail -Config $config -Subject $subject -BodyHtml $html | Out-Null
        Write-Log ('报告邮件已发送: {0}' -f $subject)
    }

    Write-Log '=== 每日工作报告结束 ==='
} catch {
    Write-Log ('报告任务异常: {0}' -f $_.Exception.Message) 'ERROR'
    Write-Log ($_.ScriptStackTrace) 'ERROR'
    exit 1
} finally {
    if ($lock) { $lock.Dispose() }
}
exit 0
