#Requires -Version 5.1
<#
    自动提交与推送（默认 07:00 由计划任务触发）

    流程（确认制）：
      1. 检查应急暂停：state\PAUSE 文件存在 -> 跳过当天全部提交推送
      2. 读取当天 00:00 之后你自己的文字回信（引用原文不算），解析「提交 / 不提交」指令
         - required 模式：只有明确回信「提交」的项目才处理；未确认 = 默认不提交
         - auto 模式：默认提交，只有明确「不提交」的项目跳过
      3. 对确认的项目：Cursor 生成 commit message -> git add -> git commit -> git push
      4. 发送结果邮件（成功 / 未确认跳过 / 失败）

    用法：
      powershell -File .\bin\morning-push.ps1 -DryRun   # 只打印计划，不改动仓库
      powershell -File .\bin\morning-push.ps1           # 真实执行
#>
param(
    [switch]$DryRun,
    [string]$ConfigFile = ''
)

. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'approval-lib.ps1')

if (-not [string]::IsNullOrWhiteSpace($ConfigFile)) {
    $script:ConfigPath = [System.IO.Path]::GetFullPath($ConfigFile)
    Write-Host ('[INFO] 使用配置: {0}' -f $script:ConfigPath)
}

$lock = Get-SingleInstance -Name 'morning-push'
if ($null -eq $lock) {
    Write-Log '已有推送任务在运行，本次跳过' 'WARN'
    exit 0
}

try {
    $config = Read-Config
    Clear-OldLogs -KeepDays ([int](Get-Cfg $config 'logging.keepDays' 30))
    $now = Get-Date
    Write-Log ('=== 自动提交推送开始 ({0}) ===' -f $now.ToString('yyyy-MM-dd HH:mm:ss'))

    $identity = Get-MachineGitIdentity
    $author = [string](Get-Cfg $config 'report.authorFilter' '')
    if ([string]::IsNullOrWhiteSpace($author)) { $author = $identity.Email }

    # 活动窗口：昨天 00:00 ~ 现在（覆盖前一天的工作 + 当天凌晨的改动）
    $windowStart = $now.Date.AddDays(-1)
    $windowEnd = $now
    $todayStart = $now.Date

    # 确认制：默认不提交；确认制下不启用关键词暂停检测（「不提交」按审批事件逐项解析）
    $approvalEnabled = ((Get-Cfg $config 'approval.enabled' $false) -eq $true)
    $approvalMode = [string](Get-Cfg $config 'approval.mode' 'required')
    $requiredMode = ($approvalEnabled -and ($approvalMode -eq 'required'))

    # ---------------- 1. 暂停信号
    $pauseReason = ''
    $pauseDetail = $null
    $pauseCheckError = ''

    $flagRel = [string](Get-Cfg $config 'pause.flagFile' 'state\PAUSE')
    if ($flagRel) {
        $flagPath = Resolve-ConfigPath -Path $flagRel
        if (Test-Path -LiteralPath $flagPath) {
            $pauseReason = 'flag'
            Write-Log ('检测到暂停开关文件: {0}' -f $flagPath)
        }
    }

    if (-not $pauseReason) {
        if ($requiredMode) {
            Write-Log '确认制模式：跳过关键词暂停检测（回复「不提交」会按审批事件逐项处理）'
        } else {
            $pauseSince = $todayStart
            $pauseUntil = $now
            Write-Log ('暂停检测窗口（本地时间） {0} ~ {1}' -f $pauseSince.ToString('yyyy-MM-dd HH:mm:ss'), $pauseUntil.ToString('yyyy-MM-dd HH:mm:ss'))
            try {
                $hit = Find-PauseRequest -Config $config -Since $pauseSince -Until $pauseUntil
                if ($hit) {
                    $pauseReason = 'mail'
                    $pauseDetail = $hit
                    Write-Log ('检测到暂停邮件: {0} / {1} / 关键词={2} / created_at={3}' -f $hit.From, $hit.Subject, $hit.Keyword, $hit.CreatedAt)
                }
            } catch {
                $pauseCheckError = $_.Exception.Message
                if ((Get-Cfg $config 'pause.failClosed' $true) -eq $true) {
                    $pauseReason = 'checkfailed'
                    Write-Log ('暂停信号检测失败，failClosed=true：今日保守跳过提交与推送: {0}' -f $pauseCheckError) 'ERROR'
                } else {
                    Write-Log ('暂停邮件检测失败（failClosed=false，按未暂停处理）: {0}' -f $pauseCheckError) 'WARN'
                }
            }
        }
    }

    $repos = @(Get-WatchedRepos -Config $config)
    if ($script:SkippedScopeEntries.Count -gt 0) {
        Write-Log ('配置中无法管理的路径: {0}' -f ($script:SkippedScopeEntries -join '；')) 'WARN'
    }
    $pushMode = [string](Get-Cfg $config 'push.mode' 'active')
    $remote = [string](Get-Cfg $config 'push.remote' 'origin')
    $pushTimeout = [int](Get-Cfg $config 'push.pushTimeoutSeconds' 180)
    $excludePatterns = @(Get-PushExcludePatterns -Config $config)
    $maxFiles = [int](Get-Cfg $config 'push.guard.maxFiles' 100)

    # ---------------- 2. 暂停则回信并退出
    if ($pauseReason) {
        $planned = [System.Collections.Generic.List[string]]::new()
        foreach ($repo in $repos) {
            $dirtyInfo = Get-RepoDirtyFiles -Repo $repo.Path -ExcludePatterns $excludePatterns
            $dirty = @($dirtyInfo.Files)
            if ($dirty.Count -gt 0) { $planned.Add(('{0}（{1} 个文件）' -f $repo.Name, $dirty.Count)) }
        }
        if ($planned.Count -eq 0) { $planned.Add('（没有待处理的未提交改动）') }

        $needConfirm = (Get-Cfg $config 'pause.confirmByMail' $true) -eq $true
        if ($needConfirm -and -not $DryRun) {
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine(('# 已取消今天的自动提交与推送 · {0}' -f $now.ToString('yyyy-MM-dd')))
            [void]$sb.AppendLine()
            if ($pauseReason -eq 'checkfailed') {
                [void]$sb.AppendLine('暂停信号检测失败（邮件通道异常），无法确认是否收到「不提交」回复。')
                [void]$sb.AppendLine('为避免误提交，今天 07:00 的自动提交与推送**已保守跳过**，没有对任何仓库做改动。')
                [void]$sb.AppendLine()
                [void]$sb.AppendLine(('错误信息：{0}' -f $pauseCheckError))
            } else {
                [void]$sb.AppendLine('按你的要求，今天 07:00 的自动提交与推送**已放弃**，没有对任何仓库做改动。')
            }
            [void]$sb.AppendLine()
            if ($pauseDetail) {
                [void]$sb.AppendLine(('触发原因：收到 {0} 的邮件《{1}》，命中关键词「{2}」。' -f $pauseDetail.From, $pauseDetail.Subject, $pauseDetail.Keyword))
            } elseif ($pauseReason -ne 'checkfailed') {
                [void]$sb.AppendLine('触发原因：检测到暂停开关文件 `state\PAUSE`。')
            }
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('原本会处理的仓库：')
            [void]$sb.AppendLine()
            foreach ($p in $planned) { [void]$sb.AppendLine(('- {0}' -f $p)) }
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('这些改动仍原样保留在工作区，明天默认继续自动提交与推送。')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('---')
            [void]$sb.AppendLine(('本邮件由 E:\auto_push 自动任务生成 · {0}' -f $now.ToString('yyyy-MM-dd HH:mm:ss')))
            try {
                $pauseSubject = if ($pauseReason -eq 'checkfailed') {
                    ('【已跳过】暂停检测失败，今日自动提交与推送未执行 · {0}' -f $now.ToString('yyyy-MM-dd'))
                } else {
                    ('【已取消】今日自动提交与推送已放弃 · {0}' -f $now.ToString('yyyy-MM-dd'))
                }
                Send-AgentMail -Config $config -Subject $pauseSubject -BodyMarkdown $sb.ToString() | Out-Null
                Write-Log '已发送暂停确认邮件'
            } catch {
                Write-Log ('暂停确认邮件发送失败: {0}' -f $_.Exception.Message) 'ERROR'
            }
        }
        Write-Log ('今日已按暂停处理（原因: {0}），未执行任何提交或推送' -f $pauseReason)
        exit 0
    }

    # ---------------- 3. 审批（文字回信）
    $approvalEvents = @()
    if ($requiredMode) {
        $repoNames = @($repos | ForEach-Object { [string]$_.Name })
        try {
            $approvalEvents = @(Find-ApprovalMailEvents -Config $config -RepoNames $repoNames -Since $todayStart -Until $now)
            Write-Log ('审批邮件：解析到 {0} 条确认记录（监控项目 {1} 个）' -f $approvalEvents.Count, $repoNames.Count)
            foreach ($e in $approvalEvents) {
                Write-Log ('  确认记录: {0} -> {1}（时间 {2}）' -f $e.Repo, $e.Decision, $e.TimeUtc.ToString('yyyy-MM-dd HH:mm:ss'))
            }
        } catch {
            Write-Log ('审批邮件解析失败（按默认不提交处理）: {0}' -f $_.Exception.Message) 'WARN'
        }
    }

    # ---------------- 4. 收集待处理仓库
    $results = [System.Collections.Generic.List[object]]::new()
    $plannedRepos = [System.Collections.Generic.List[object]]::new()

    foreach ($repo in $repos) {
        try {
            $info = Get-RepoInfo -Repo $repo.Path -Start $windowStart -End $windowEnd -Author $author -ExcludePatterns $excludePatterns
        } catch {
            Write-Log ('采集失败 [{0}]: {1}' -f $repo.Name, $_.Exception.Message) 'WARN'
            continue
        }

        $shouldHandle = if ($pushMode -eq 'all') {
            (@($info.Dirty).Count -gt 0) -or ([int](Get-Cfg $info 'Upstream.Ahead' 0) -gt 0)
        } else {
            $info.HasActivity -or ([int](Get-Cfg $info 'Upstream.Ahead' 0) -gt 0)
        }
        if (-not $shouldHandle) { continue }

        # 安全跳过：merge / rebase 进行中
        $gitDir = Join-Path $repo.Path '.git'
        $inProgress = @()
        foreach ($marker in 'MERGE_HEAD', 'rebase-merge', 'rebase-apply', 'CHERRY_PICK_HEAD') {
            if (Test-Path -LiteralPath (Join-Path $gitDir $marker)) { $inProgress += $marker }
        }
        if ($inProgress.Count -gt 0) {
            Write-Log ('[{0}] 检测到 {1}，跳过自动提交' -f $repo.Name, ($inProgress -join ',')) 'WARN'
            $results.Add([pscustomobject]@{ Name = $info.Name; Branch = $info.Branch; Status = 'skipped'; Detail = ('仓库操作进行中（{0}），未自动处理' -f ($inProgress -join ',')); Commit = ''; Message = '' })
            continue
        }

        # 确认制：默认不提交，只有明确确认的项目才处理
        $decision = 'submit'
        $decisionSource = 'config'
        if ($approvalEnabled -and $approvalMode -eq 'required') {
            $resolved = Resolve-ApprovalDecision -Events $approvalEvents -RepoName $info.Name -Default 'skip'
            $decision = [string]$resolved.Decision
            $decisionSource = [string]$resolved.Source
        }
        if ($decision -ne 'submit') {
            $dirtyCount = @($info.Dirty).Count
            $aheadCount = [int](Get-Cfg $info 'Upstream.Ahead' 0)
            $detail = ('未确认提交（默认不提交），已跳过：{0} 个未提交文件、{1} 个待推送提交' -f $dirtyCount, $aheadCount)
            Write-Log ('[{0}] {1}（来源: {2}）' -f $info.Name, $detail, $decisionSource)
            $results.Add([pscustomobject]@{ Name = $info.Name; Branch = $info.Branch; Status = 'unconfirmed'; Detail = $detail; Commit = ''; Message = '' })
            continue
        }

        Write-Log ('[{0}] 已确认提交（来源: {1}）' -f $info.Name, $decisionSource)
        $plannedRepos.Add($info)
    }

    Write-Log ('已确认待处理仓库 {0} 个' -f $plannedRepos.Count)

    foreach ($info in $plannedRepos) {
        $result = [pscustomobject]@{
            Name    = $info.Name
            Branch  = $info.Branch
            Status  = 'ok'
            Detail  = ''
            Commit  = ''
            Message = ''
        }
        try {
            $dirty = @($info.Dirty)
            if ($dirty.Count -gt 0) {
                $files = @($dirty | ForEach-Object { $_.RelativePath })
                if ($files.Count -gt $maxFiles) {
                    $result.Status = 'skipped'
                    $result.Detail = ('未提交文件 {0} 个，超过安全上限 {1} 个，为避免误提交已跳过，请人工处理' -f $files.Count, $maxFiles)
                    Write-Log ('[{0}] {1}' -f $info.Name, $result.Detail) 'WARN'
                    $results.Add($result)
                    continue
                }
                if ($DryRun) {
                    $preview = New-CommitMessage -Config $config -Repo $info.Path -Branch $info.Branch -DirtyFiles $files
                    $result.Message = $preview
                    $result.Detail = ('DryRun：将提交 {0} 个文件，commit message 预览「{1}」' -f $dirty.Count, $preview)
                    Write-Log ('[{0}] {1}' -f $info.Name, $result.Detail)
                    $results.Add($result)
                    continue
                }

                Write-Log ('[{0}] 生成 commit message（{1} 个改动文件）' -f $info.Name, $dirty.Count)
                $message = New-CommitMessage -Config $config -Repo $info.Path -Branch $info.Branch -DirtyFiles $files
                Write-Log ('[{0}] commit message: {1}' -f $info.Name, $message)
                $result.Message = $message

                $addArgs = @('add', '-A', '--') + $files
                $add = Invoke-Git -Repo $info.Path -Arguments $addArgs
                if ($add.ExitCode -ne 0) { throw ('git add 失败: ' + $add.StdErr) }

                $stagedText = Get-GitText -Repo $info.Path -Arguments @('diff', '--cached', '--name-only') -AllowFail
                if ([string]::IsNullOrWhiteSpace($stagedText)) {
                    $result.Status = 'skipped'
                    $result.Detail = '暂存后没有可提交内容（可能已被忽略），跳过'
                    Write-Log ('[{0}] {1}' -f $info.Name, $result.Detail) 'WARN'
                    $results.Add($result)
                    continue
                }

                $commit = Invoke-Git -Repo $info.Path -Arguments @('commit', '-m', $message)
                if ($commit.ExitCode -ne 0) {
                    $merged = ($commit.StdOut + $commit.StdErr)
                    if ($merged -match 'nothing to commit|no changes added') {
                        Write-Log ('[{0}] 无实际变更可提交，跳过提交' -f $info.Name) 'WARN'
                    } else {
                        throw ('git commit 失败: ' + $commit.StdErr + $commit.StdOut)
                    }
                } else {
                    $hash = Get-GitText -Repo $info.Path -Arguments @('rev-parse', '--short', 'HEAD') -AllowFail
                    $result.Commit = $hash
                    Write-Log ('[{0}] 已提交 {1}: {2}' -f $info.Name, $hash, $message)
                }
            } else {
                $result.Detail = '无未提交改动，只处理已有提交的推送'
            }

            # 推送
            $upstream = Get-RepoUpstream -Repo $info.Path
            if ($DryRun) {
                $target = if ($upstream.Exists) { $upstream.Name } else { ('{0}/HEAD' -f $remote) }
                $result.Detail += ('；DryRun：将 push 到 {0}（待推送 {1} 个提交）' -f $target, ($upstream.Ahead + $(if ($result.Commit) { 1 } else { 0 })))
                Write-Log ('[{0}] {1}' -f $info.Name, $result.Detail)
                $results.Add($result)
                continue
            }

            if ($upstream.Exists) {
                $push = Invoke-Git -Repo $info.Path -Arguments @('push', $remote) -TimeoutSeconds $pushTimeout
            } else {
                Write-Log ('[{0}] 未配置上游分支，使用 git push -u {1} HEAD' -f $info.Name, $remote)
                $push = Invoke-Git -Repo $info.Path -Arguments @('push', '-u', $remote, 'HEAD') -TimeoutSeconds $pushTimeout
            }
            if ($push.ExitCode -ne 0) {
                throw ('git push 失败: ' + ($push.StdErr + $push.StdOut).Trim())
            }
            $result.Detail += '；推送成功'
            Write-Log ('[{0}] 推送成功' -f $info.Name)
        } catch {
            $result.Status = 'failed'
            $result.Detail = $_.Exception.Message
            Write-Log ('[{0}] 处理失败: {1}' -f $info.Name, $_.Exception.Message) 'ERROR'
        }
        $results.Add($result)
    }

    # ---------------- 5. 结果邮件
    $okList = @($results | Where-Object { $_.Status -eq 'ok' })
    $unconfirmedList = @($results | Where-Object { $_.Status -eq 'unconfirmed' })
    $badList = @($results | Where-Object { ($_.Status -ne 'ok') -and ($_.Status -ne 'unconfirmed') })
    $okCount = $okList.Count
    $failCount = $badList.Count
    $unconfirmedCount = $unconfirmedList.Count

    if ($DryRun) {
        Write-Host ''
        Write-Host '===== DRY RUN 结果 ====='
        foreach ($r in $results) {
            Write-Host ('- [{0}] {1} · {2}：{3}' -f $r.Status, $r.Name, $r.Branch, $r.Detail)
            if ($r.Message) { Write-Host ('    message: {0}' -f $r.Message) }
        }
        Write-Host '========================'
        Write-Log ('DryRun 完成，未做任何提交或推送（成功 {0} / 未确认 {1} / 跳过或失败 {2}）' -f $okCount, $unconfirmedCount, $failCount)
    } elseif ((Get-Cfg $config 'mail.sendMorningResult' $true) -eq $true) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine(('# 自动提交与推送结果 · {0}' -f $now.ToString('yyyy-MM-dd HH:mm')))
        [void]$sb.AppendLine()
        if ($approvalEnabled -and $approvalMode -eq 'required') {
            [void]$sb.AppendLine('本次为**确认制**：只有回信确认「提交」的项目才会自动提交推送，未确认的项目保持原样。')
        }
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| 结果 | 数量 |')
        [void]$sb.AppendLine('| --- | --- |')
        [void]$sb.AppendLine(('| 处理成功 | {0} |' -f $okCount))
        [void]$sb.AppendLine(('| 未确认（默认不提交） | {0} |' -f $unconfirmedCount))
        [void]$sb.AppendLine(('| 跳过 / 失败 | {0} |' -f $failCount))
        [void]$sb.AppendLine()

        [void]$sb.AppendLine('## 处理成功的仓库')
        [void]$sb.AppendLine()
        if ($okList.Count -eq 0) {
            [void]$sb.AppendLine('无。')
        } else {
            foreach ($r in $okList) {
                [void]$sb.AppendLine(('### {0} · `{1}`' -f $r.Name, $r.Branch))
                if ($r.Commit) {
                    [void]$sb.AppendLine(('- 提交 `{0}`：{1}' -f $r.Commit, $r.Message))
                } else {
                    [void]$sb.AppendLine('- 无新提交（只推送已有提交）')
                }
                [void]$sb.AppendLine(('- 推送：{0}' -f $(if ($r.Detail -like '*推送成功*') { '成功' } else { '已处理' })))
                [void]$sb.AppendLine()
            }
        }

        if ($unconfirmedList.Count -gt 0) {
            [void]$sb.AppendLine('## 未确认，已跳过（默认不提交）')
            [void]$sb.AppendLine()
            foreach ($r in $unconfirmedList) {
                [void]$sb.AppendLine(('- **{0}**（`{1}`）：{2}' -f $r.Name, $r.Branch, $r.Detail))
            }
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('> 如需补提交，可回复当天的报告邮件写「提交」或「提交 项目名」，或手动运行 morning-push。')
            [void]$sb.AppendLine()
        }

        if ($badList.Count -gt 0) {
            [void]$sb.AppendLine('## 跳过 / 失败')
            [void]$sb.AppendLine()
            foreach ($r in $badList) {
                [void]$sb.AppendLine(('- **{0}**（`{1}`）：{2}' -f $r.Name, $r.Branch, $r.Detail))
            }
            [void]$sb.AppendLine()
        }

        [void]$sb.AppendLine('---')
        [void]$sb.AppendLine(('本邮件由 E:\auto_push 自动任务生成 · {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))

        $subjectTemplate = [string](Get-Cfg $config 'mail.morningSubject' '【自动推送】{date}')
        $subject = $subjectTemplate.Replace('{date}', $now.ToString('yyyy-MM-dd')).
            Replace('{pushed}', [string]$okCount).
            Replace('{failed}', [string]$failCount)

        try {
            Send-AgentMail -Config $config -Subject $subject -BodyMarkdown $sb.ToString() | Out-Null
            Write-Log ('结果邮件已发送: {0}' -f $subject)
        } catch {
            Write-Log ('结果邮件发送失败: {0}' -f $_.Exception.Message) 'ERROR'
        }
    }

    Write-Log ('=== 自动提交推送结束：成功 {0} / 未确认 {1} / 跳过或失败 {2} ===' -f $okCount, $unconfirmedCount, $failCount)
    if ($failCount -gt 0) { exit 1 }
} catch {
    Write-Log ('推送任务异常: {0}' -f $_.Exception.Message) 'ERROR'
    Write-Log ($_.ScriptStackTrace) 'ERROR'
    exit 1
} finally {
    if ($lock) { $lock.Dispose() }
}
exit 0
