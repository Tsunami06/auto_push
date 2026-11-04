#Requires -Version 5.1
<#
    注册 Windows 计划任务：
      AutoPush-NightlyReport  每天 00:00  生成并发送当日工作报告
      AutoPush-MorningPush    每天 07:00  检查暂停信号 -> 自动提交 -> 推送

    用法：powershell -File .\bin\install-tasks.ps1
    卸载：powershell -File .\bin\uninstall-tasks.ps1
#>
param(
    [string]$ReportTime = '00:00',
    [string]$PushTime = '07:00'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershellExe)) { throw '未找到 powershell.exe' }

$reportScript = Join-Path $root 'bin\nightly-report.ps1'
$pushScript = Join-Path $root 'bin\morning-push.ps1'
foreach ($s in @($reportScript, $pushScript)) {
    if (-not (Test-Path -LiteralPath $s)) { throw "脚本不存在: $s" }
}

function New-AutoPushTask {
    param(
        [string]$TaskName,
        [string]$ScriptPath,
        [string]$AtTime,
        [string]$Description,
        [int]$TimeoutMinutes
    )
    $action = New-ScheduledTaskAction -Execute $powershellExe `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath) `
        -WorkingDirectory $root

    $trigger = New-ScheduledTaskTrigger -Daily -At $AtTime

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $TimeoutMinutes) `
        -RestartCount 1 `
        -RestartInterval (New-TimeSpan -Minutes 5)

    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description $Description -Force | Out-Null

    $info = Get-ScheduledTask -TaskName $TaskName -TaskPath '\'
    $next = (Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath '\').NextRunTime
    Write-Host ('[OK] {0}  每天 {1}  下次运行: {2}' -f $TaskName, $AtTime, $next)
    Write-Host ('     {0}' -f $Description)
    Write-Host ('     {0} -File "{1}"' -f $powershellExe, $ScriptPath)
    return $info
}

Write-Host '=== 注册自动提交计划任务 ==='
New-AutoPushTask -TaskName 'AutoPush-NightlyReport' -ScriptPath $reportScript -AtTime $ReportTime `
    -Description '每日工作报告：汇总当天提交与未提交改动并发送邮件' -TimeoutMinutes 20
New-AutoPushTask -TaskName 'AutoPush-MorningPush' -ScriptPath $pushScript -AtTime $PushTime `
    -Description '自动提交与推送：检查暂停信号后提交并推送到各仓库 origin' -TimeoutMinutes 45

Write-Host ''
Write-Host '注册完成。可用以下命令立即测试：'
Write-Host '  Start-ScheduledTask -TaskName ''AutoPush-NightlyReport'''
Write-Host '  Start-ScheduledTask -TaskName ''AutoPush-MorningPush'''
Write-Host '查看日志：Get-Content ''E:\auto_push\logs\<日期>.log'''
