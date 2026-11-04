#Requires -Version 5.1
# 确认制公共库：解析用户文字回信里的「提交 / 不提交」指令（不依赖审批页面/服务）
# 依赖：先 dot-source lib.ps1（需要 Write-Log / Get-Cfg / Invoke-AgentlyCli / Read-CliJson /
#       Get-PauseMailOwnText / ConvertTo-UtcDateTimeSafe / Test-PauseMailInWindow）

function ConvertTo-ApprovalDecisionList {
    # 从用户自己写的正文里解析「提交 / 不提交」指令。
    # 返回 [{ Repo = 项目名 或 '*'; Decision = submit|skip }]，按出现顺序。
    param([string]$Text, [string[]]$RepoNames = @())
    $events = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $names = @($RepoNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Property Length -Descending)
    $actionSubmit = '(?<!不)提交|放行|推送|通过'
    $actionSkip = '不提交|别提交|不要提交|先不提交|暂停提交|暂停推送|取消推送|取消提交|跳过'
    $globalSubmit = '全部提交|提交全部|全提交|都提交|全部放行|全部推送|都推送|所有都提交'
    $globalSkip = '全部不提交|全部跳过|都不提交|全不提交|全部取消|都跳过|所有都不提交'

    foreach ($rawLine in (@($Text -split "`n"))) {
        $line = ([string]$rawLine).Trim()
        $line = $line.TrimStart([char[]]@('>', '-', '*', ' ')).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match $globalSkip) { $events.Add([pscustomobject]@{ Repo = '*'; Decision = 'skip' }); continue }
        if ($line -match $globalSubmit) { $events.Add([pscustomobject]@{ Repo = '*'; Decision = 'submit' }); continue }

        $repoMatched = $false
        foreach ($name in $names) {
            $escName = [regex]::Escape($name)
            $skipPatterns = @(
                ('(?:{0})\s*[:：]?\s*{1}' -f $actionSkip, $escName),
                ('{0}\s*[:：]?\s*(?:待|要|请|确认|先)?\s*(?:{1})' -f $escName, $actionSkip)
            )
            $isSkip = $false
            foreach ($pattern in $skipPatterns) {
                if ($line -match $pattern) { $isSkip = $true; break }
            }
            if ($isSkip) {
                $events.Add([pscustomobject]@{ Repo = $name; Decision = 'skip' })
                $repoMatched = $true
                continue
            }

            $submitPatterns = @(
                ('(?:{0})\s*[:：]?\s*{1}' -f $actionSubmit, $escName),
                ('{0}\s*[:：]?\s*(?:待|要|请|确认|先)?\s*(?:{1})' -f $escName, $actionSubmit)
            )
            $isSubmit = $false
            foreach ($pattern in $submitPatterns) {
                if ($line -match $pattern) { $isSubmit = $true; break }
            }
            if ($isSubmit) {
                $events.Add([pscustomobject]@{ Repo = $name; Decision = 'submit' })
                $repoMatched = $true
            }
        }
        if ($repoMatched) { continue }

        # 单独一行只写「提交 / 不提交」等明确动作时，才视为对全部项目生效。
        # 注意：不能把「放行 / 推送 / 通过」这类词单独当全局指令——邮件签名、页脚里可能出现「通过」。
        if ($line -match '^(?:不提交|别提交|不要提交|先不提交|跳过|暂停|暂停提交|暂停推送|取消|取消提交|取消推送)$') {
            $events.Add([pscustomobject]@{ Repo = '*'; Decision = 'skip' })
        } elseif ($line -match '^(?:提交|可以提交|确认提交|放行全部|全部放行)$') {
            $events.Add([pscustomobject]@{ Repo = '*'; Decision = 'submit' })
        }
    }
    return @($events.ToArray())
}

function Find-ApprovalMailEvents {
    # 扫描当天 00:00 之后、白名单发件人的回信，解析出提交/不提交事件（按时间升序）。
    param(
        $Config,
        [string[]]$RepoNames = @(),
        [datetime]$Since,
        [datetime]$Until
    )
    $events = [System.Collections.Generic.List[object]]::new()
    if (@($RepoNames).Count -eq 0) { return @() }

    $keywords = @(Get-Cfg $Config 'approval.mailKeywords' @('提交'))
    $allow = @(Get-Cfg $Config 'pause.fromAllowlist' @())
    $sinceIso = $Since.ToString('yyyy-MM-ddTHH:mm:sszzz')
    $untilIso = $Until.ToString('yyyy-MM-ddTHH:mm:sszzz')
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $searched = 0
    $hitMessages = 0

    foreach ($kw in $keywords) {
        if ([string]::IsNullOrWhiteSpace($kw)) { continue }
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
            Write-Log ("审批邮件搜索失败（关键词 {0}）: {1}" -f $kw, $_.Exception.Message) 'WARN'
            continue
        }
        if ($r.ExitCode -ne 0) {
            Write-Log ("审批邮件搜索失败（关键词 {0}）exit={1}: {2}" -f $kw, $r.ExitCode, $r.StdErr.Trim()) 'WARN'
            continue
        }
        $json = Read-CliJson -Text $r.StdOut
        if ($null -eq $json -or ((Get-Cfg $json 'ok' $false) -ne $true)) {
            Write-Log ("审批邮件搜索返回异常（关键词 {0}）" -f $kw) 'WARN'
            continue
        }
        $searched++
        foreach ($m in @(Get-Cfg $json 'data.data' @())) {
            if ($null -eq $m) { continue }
            $id = [string](Get-Cfg $m 'message_id' '')
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if (-not $seen.Add($id)) { continue }
            $from = [string](Get-Cfg $m 'from.email' '')
            if ($allow.Count -gt 0 -and ($allow -notcontains $from)) { continue }
            $createdRaw = [string](Get-Cfg $m 'created_at' '')
            if (-not (Test-PauseMailInWindow -CreatedAt $createdRaw -Since $Since -Until $Until)) { continue }

            $ownText = $null
            try { $ownText = Get-PauseMailOwnText -Config $Config -MessageId $id } catch { $ownText = $null }
            if ($null -eq $ownText) {
                Write-Log ("审批邮件 {0} 正文读取失败，按摘要解析" -f $id) 'WARN'
                $ownText = [string](Get-Cfg $m 'snippet' '')
            }
            $createdUtc = ConvertTo-UtcDateTimeSafe -Text $createdRaw
            if ($null -eq $createdUtc) { continue }
            $parsed = @(ConvertTo-ApprovalDecisionList -Text $ownText -RepoNames $RepoNames)
            if ($parsed.Count -eq 0) { continue }
            $hitMessages++
            foreach ($e in $parsed) {
                $events.Add([pscustomobject]@{
                        Repo     = [string]$e.Repo
                        Decision = [string]$e.Decision
                        TimeUtc  = $createdUtc
                        Source   = 'mail'
                    })
            }
            Write-Log ("审批邮件 {0}：解析到 {1} 条确认（{2}）" -f $id, $parsed.Count, (($parsed | ForEach-Object { '{0}={1}' -f $_.Repo, $_.Decision }) -join '，'))
        }
    }
    Write-Log ("审批邮件解析完成：搜索关键词 {0} 个（成功 {1} 个），命中可用邮件 {2} 封" -f $keywords.Count, $searched, $hitMessages)
    return @($events.ToArray() | Sort-Object -Property TimeUtc)
}

function Resolve-ApprovalDecision {
    # 同一项目/全局指令按时间取最新一条；没有则返回默认值。
    param(
        [object[]]$Events = @(),
        [string]$RepoName,
        [string]$Default = 'skip'
    )
    $applicable = @($Events | Where-Object { $null -ne $_ -and (($_.Repo -eq $RepoName) -or ($_.Repo -eq '*')) })
    if ($applicable.Count -eq 0) {
        return [pscustomobject]@{ Decision = $Default; Source = 'default'; TimeUtc = $null }
    }
    $last = $applicable | Sort-Object -Property TimeUtc | Select-Object -Last 1
    return [pscustomobject]@{ Decision = [string]$last.Decision; Source = [string]$last.Source; TimeUtc = $last.TimeUtc }
}
