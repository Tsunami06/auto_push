#Requires -Version 5.1
# 每日工作报告的 HTML 邮件模板：项目卡片（只展示内容，确认通过直接回信）
# 依赖：lib.ps1 已 dot-source

function ConvertTo-ReportHtmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function New-ReportHtml {
    param(
        $Config,
        $Window,
        [object[]]$Infos = @(),
        [string[]]$SkippedScope = @(),
        [datetime]$GeneratedAt = (Get-Date),
        [switch]$Preview
    )

    $dateLabel = [string]$Window.DateLabel
    $generatedText = $GeneratedAt.ToString('yyyy-MM-dd HH:mm')
    $fileLimit = [int](Get-Cfg $Config 'report.fileListLimit' 40)
    $pushTime = [string](Get-Cfg $Config 'approval.pushTimeLabel' '07:00')
    $required = ((Get-Cfg $Config 'approval.enabled' $true) -eq $true) -and ((Get-Cfg $Config 'approval.mode' 'required') -eq 'required')

    $totalCommits = 0
    $totalPending = 0
    $totalAhead = 0
    $totalExcluded = 0
    foreach ($info in $Infos) {
        if ($null -eq $info) { continue }
        $totalCommits += @($info.Commits).Count
        $totalPending += @($info.Dirty).Count
        $totalAhead += [int](Get-Cfg $info 'Upstream.Ahead' 0)
        $totalExcluded += [int](Get-Cfg $info 'DirtyExcludedCount' 0)
    }

    $statusLabel = if ($required) { '默认不提交 · 请回信确认' } else { '默认提交 · 可回信取消' }

    # ---------- 概览统计块
    $stats = @(
        @{ Label = '项目'; Value = [string]@($Infos).Count; Color = '#0f172a' },
        @{ Label = '今日提交'; Value = [string]$totalCommits; Color = '#0f766e' },
        @{ Label = '未提交文件'; Value = [string]$totalPending; Color = '#b45309' },
        @{ Label = '待推送'; Value = [string]$totalAhead; Color = '#1d4ed8' }
    )
    $statCells = New-Object System.Text.StringBuilder
    [void]$statCells.AppendLine('<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>')
    foreach ($s in $stats) {
        [void]$statCells.AppendLine('<td width="25%" valign="top" style="padding:6px;">')
        [void]$statCells.AppendLine((('<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:12px;padding:14px 10px;text-align:center;">' +
                '<div style="font-size:24px;font-weight:700;color:{0};line-height:1.2;">{1}</div>' +
                '<div style="font-size:12px;color:#64748b;margin-top:4px;">{2}</div></div>') -f $s.Color, $s.Value, $s.Label))
        [void]$statCells.AppendLine('</td>')
    }
    [void]$statCells.AppendLine('</tr></table>')

    # ---------- 项目卡片
    $cards = New-Object System.Text.StringBuilder
    if (@($Infos).Count -eq 0) {
        [void]$cards.AppendLine('<table role="presentation" width="100%" style="border:1px dashed #cbd5e1;border-radius:14px;background:#fbfdff;"><tr><td style="padding:26px 22px;text-align:center;color:#64748b;font-size:14px;">今天没有需要处理的项目。</td></tr></table>')
    }

    foreach ($info in $Infos) {
        if ($null -eq $info) { continue }
        $name = [string]$info.Name
        $branch = [string]$info.Branch
        $commits = @($info.Commits)
        $dirty = @($info.Dirty)
        $dirtyToday = @($info.DirtyToday)
        $excluded = [int](Get-Cfg $info 'DirtyExcludedCount' 0)
        $ahead = [int](Get-Cfg $info 'Upstream.Ahead' 0)
        $pendingCount = $dirty.Count
        $actionable = (($pendingCount -gt 0) -or ($ahead -gt 0))

        $chips = @()
        if ($commits.Count -gt 0) { $chips += ('今日提交 {0}' -f $commits.Count) }
        if ($pendingCount -gt 0) { $chips += ('未提交 {0}' -f $pendingCount) }
        if ($ahead -gt 0) { $chips += ('待推送 {0}' -f $ahead) }
        if ($chips.Count -eq 0) { $chips += '已同步' }

        [void]$cards.AppendLine('<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border:1px solid #e5e7eb;border-radius:16px;background:#fbfdff;margin-bottom:14px;"><tr><td style="padding:18px 20px 6px;">')
        [void]$cards.AppendLine(('<div style="font-size:18px;font-weight:700;color:#0f172a;">{0}<span style="display:inline-block;margin-left:8px;font-size:11px;font-weight:600;color:#475569;background:#f1f5f9;border-radius:999px;padding:3px 9px;vertical-align:2px;">{1}</span></div>' -f (ConvertTo-ReportHtmlText $name), (ConvertTo-ReportHtmlText $branch)))
        [void]$cards.AppendLine(('<div style="font-size:12px;color:#64748b;margin-top:6px;">{0}</div>' -f ((@($chips | ForEach-Object { ConvertTo-ReportHtmlText $_ })) -join ' · ')))
        [void]$cards.AppendLine('</td></tr>')

        # 已完成的工作
        [void]$cards.AppendLine('<tr><td style="padding:8px 20px 0;">')
        [void]$cards.AppendLine('<div style="font-size:12px;font-weight:700;color:#0f766e;letter-spacing:1px;margin-bottom:6px;">已完成的工作</div>')
        if ($commits.Count -eq 0) {
            [void]$cards.AppendLine('<div style="font-size:13px;color:#94a3b8;padding:2px 0 6px;">今天没有新提交。</div>')
        } else {
            [void]$cards.AppendLine('<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">')
            foreach ($c in $commits) {
                [void]$cards.AppendLine(('<tr><td style="padding:5px 0;font-size:13px;color:#334155;line-height:1.6;"><span style="color:#94a3b8;font-size:12px;">{0}</span><span style="margin-left:8px;">{1}</span><span style="color:#94a3b8;font-size:12px;"> · {2}</span></td></tr>' -f
                        (ConvertTo-ReportHtmlText ([string]$c.Time)), (ConvertTo-ReportHtmlText ([string]$c.Subject)), (ConvertTo-ReportHtmlText ([string]$c.Hash))))
            }
            [void]$cards.AppendLine('</table>')
        }
        [void]$cards.AppendLine('</td></tr>')

        # 未提交改动
        if ($pendingCount -gt 0 -or $excluded -gt 0) {
            [void]$cards.AppendLine('<tr><td style="padding:10px 20px 0;">')
            $dirtyTitle = if ($dirtyToday.Count -gt 0) { ('未提交改动（{0} 个文件，其中今天修改 {1} 个）' -f $pendingCount, $dirtyToday.Count) } else { ('未提交改动（{0} 个文件，历史遗留）' -f $pendingCount) }
            [void]$cards.AppendLine(('<div style="font-size:12px;font-weight:700;color:#b45309;letter-spacing:1px;margin-bottom:6px;">{0}</div>' -f (ConvertTo-ReportHtmlText $dirtyTitle)))
            [void]$cards.AppendLine('<div style="font-size:12px;color:#475569;line-height:1.9;">')
            $shown = 0
            foreach ($f in $dirty) {
                if ($shown -ge $fileLimit) { break }
                $path = [string]$f.RelativePath
                $stamp = ''
                if ($null -ne $f.LastWriteTime) {
                    $stamp = if ($f.LastWriteTime -ge $Window.Start) { $f.LastWriteTime.ToString('HH:mm') } else { $f.LastWriteTime.ToString('yyyy-MM-dd') }
                }
                [void]$cards.AppendLine(('<span style="display:inline-block;background:#fff7ed;border:1px solid #fed7aa;color:#9a3412;border-radius:6px;padding:2px 8px;margin:2px 4px 2px 0;font-family:Consolas,Menlo,monospace;font-size:11px;">{0}{1}</span>' -f (ConvertTo-ReportHtmlText $path), $(if ($stamp) { ' · ' + (ConvertTo-ReportHtmlText $stamp) } else { '' })))
                $shown++
            }
            [void]$cards.AppendLine('</div>')
            if ($pendingCount -gt $shown) {
                [void]$cards.AppendLine(('<div style="font-size:12px;color:#94a3b8;margin-top:4px;">… 另有 {0} 个文件未列出</div>' -f ($pendingCount - $shown)))
            }
            if ($excluded -gt 0) {
                [void]$cards.AppendLine(('<div style="font-size:12px;color:#94a3b8;margin-top:4px;">另有 {0} 个构建产物 / IDE 配置类文件，自动任务会跳过。</div>' -f $excluded))
            }
            [void]$cards.AppendLine('</td></tr>')
        }

        if ($ahead -gt 0) {
            [void]$cards.AppendLine('<tr><td style="padding:8px 20px 0;">')
            [void]$cards.AppendLine(('<div style="font-size:12px;color:#1d4ed8;">已有 {0} 个本地提交等待推送。</div>' -f $ahead))
            [void]$cards.AppendLine('</td></tr>')
        }

        # 该项目如何回信确认
        [void]$cards.AppendLine('<tr><td style="padding:14px 20px 18px;">')
        if ($actionable) {
            [void]$cards.AppendLine(('<div style="font-size:12px;color:#64748b;line-height:1.8;background:#f8fafc;border:1px dashed #cbd5e1;border-radius:10px;padding:10px 12px;">要放行这个项目，直接回复本邮件写：<b style="color:#0f172a;">提交 {0}</b></div>' -f (ConvertTo-ReportHtmlText $name)))
        } else {
            [void]$cards.AppendLine('<div style="font-size:12px;color:#16a34a;font-weight:600;">✓ 该项目当前没有需要提交或推送的内容。</div>')
        }
        [void]$cards.AppendLine('</td></tr></table>')
    }

    # ---------- 页脚说明
    $scopeNote = ''
    if (@($SkippedScope).Count -gt 0) {
        $scopeNote = ('<div style="margin:0 0 14px;padding:12px 16px;background:#f8fafc;border:1px dashed #cbd5e1;border-radius:10px;font-size:12px;color:#64748b;">注意：以下路径当前无法管理，已跳过：{0}</div>' -f (ConvertTo-ReportHtmlText ((@($SkippedScope)) -join '；')))
    }

    $previewBanner = ''
    if ($Preview) {
        $previewBanner = '<table role="presentation" width="100%"><tr><td style="background:#fef3c7;padding:12px 32px;font-size:13px;color:#92400e;font-weight:600;">样式预览邮件：用于确认版式，不影响真实计划。</td></tr></table>'
    }

    $ruleText = if ($required) {
        '默认不提交：只有回信确认「提交」的项目，才会在 {0} 自动 commit + push；没回复的项目保持原样。' -f (ConvertTo-ReportHtmlText $pushTime)
    } else {
        '默认提交：没有回信「不提交」的项目会在 {0} 自动提交推送。' -f (ConvertTo-ReportHtmlText $pushTime)
    }

    $summaryLine = ('{0} 个项目 · 今日提交 {1} 个 · 未提交 {2} 个文件 · 待推送 {3} 个' -f @($Infos).Count, $totalCommits, $totalPending, $totalAhead)

    return @"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>每日工作报告 · $dateLabel</title>
</head>
<body style="margin:0;padding:0;background:#eef2f7;">
<div style="display:none;max-height:0;overflow:hidden;font-size:1px;color:#eef2f7;">$statusLabel · $summaryLine</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#eef2f7;">
<tr><td align="center" style="padding:24px 12px;">
<table role="presentation" width="680" cellpadding="0" cellspacing="0" border="0" style="width:680px;max-width:100%;background:#ffffff;border-radius:18px;overflow:hidden;border:1px solid #e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC','Microsoft YaHei',Arial,sans-serif;color:#0f172a;">
$previewBanner
<tr><td style="background:#0f172a;padding:30px 32px 24px;">
  <div style="font-size:11px;letter-spacing:3px;color:#93c5fd;font-weight:700;">DAILY WORK REPORT</div>
  <div style="font-size:26px;font-weight:700;color:#ffffff;margin-top:8px;line-height:1.3;">每日工作报告</div>
  <div style="font-size:14px;color:#cbd5e1;margin-top:8px;">$dateLabel · 生成于 $generatedText</div>
  <div style="margin-top:16px;padding:12px 14px;background:#1e293b;border-left:4px solid #f59e0b;border-radius:10px;font-size:13px;color:#fde68a;line-height:1.7;">$ruleText</div>
</td></tr>
<tr><td style="padding:18px 26px 0;">
  $statCells
</td></tr>
<tr><td style="padding:6px 32px 0;">
  $scopeNote
</td></tr>
<tr><td style="padding:10px 32px 4px;">
  <div style="font-size:13px;color:#475569;line-height:1.8;">请在 <b style="color:#0f172a;">$pushTime</b> 前直接回复本邮件确认。写「提交」= 全部放行；写「提交 项目名」= 只放行该项目。</div>
</td></tr>
<tr><td style="padding:14px 26px 26px;">
  $cards
</td></tr>
<tr><td style="padding:0 32px 26px;">
  <div style="background:#f8fafc;border:1px dashed #cbd5e1;border-radius:14px;padding:16px 18px;font-size:13px;color:#475569;line-height:1.9;">
    <b style="color:#0f172a;">怎么确认？</b><br>
    · 直接回复本邮件：写「提交」放行全部，或「提交 项目名」只放行该项目；<br>
    · 写「不提交」或「不提交 项目名」= 明确跳过；<br>
    · 不回复 = 默认不提交，改动保持原样，不会提交、不会推送；<br>
    · 已忽略的构建产物 / IDE 配置不会进入提交。
  </div>
  <div style="text-align:center;margin-top:20px;font-size:12px;color:#94a3b8;line-height:1.8;">本邮件由 E:\auto_push 自动任务生成 · $generatedText</div>
</td></tr>
</table>
</td></tr></table>
</body>
</html>
"@
}
