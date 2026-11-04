#Requires -Version 5.1
<#
    卸载由 install-tasks.ps1 注册的计划任务。
    用法：powershell -File .\bin\uninstall-tasks.ps1
#>
$ErrorActionPreference = 'Stop'

$names = @('AutoPush-NightlyReport', 'AutoPush-MorningPush')
foreach ($n in $names) {
    $task = Get-ScheduledTask -TaskName $n -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $n -TaskPath '\' -Confirm:$false
        Write-Host ('[OK] 已删除 {0}' -f $n)
    } else {
        Write-Host ('[--] 未找到 {0}' -f $n)
    }
}
Write-Host '卸载完成。'
