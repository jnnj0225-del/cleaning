<#
.SYNOPSIS
    Windows PC上の不要な一時ファイル/キャッシュと、ダウンロードフォルダ内の古いファイルを削除します。

.DESCRIPTION
    既定ではドライラン（削除対象の一覧と合計サイズを表示するだけ）で動作します。
    実際にファイルを削除するには -Execute スイッチを指定してください。
    -Execute 指定時も、最終確認（y/n）を求めます。確認をスキップするには -Force を追加してください。

.PARAMETER DownloadsDays
    ダウンロードフォルダ内で「最終更新日からこの日数以上経過したファイル」を削除対象にします。既定値: 30

.PARAMETER IncludeSystemTemp
    ユーザー一時フォルダ（$env:TEMP）に加えて、Windowsシステム一時フォルダ（C:\Windows\Temp）も対象にします。
    管理者権限が必要な場合があります。

.PARAMETER IncludeBrowserCache
    Edge / Chrome / Firefox のキャッシュフォルダも対象にします。
    ブラウザを閉じた状態で実行することを推奨します。

.PARAMETER Execute
    指定すると実際に削除を実行します（未指定時はドライランのみ）。

.PARAMETER Force
    -Execute と併用時、最終確認プロンプトをスキップします。

.EXAMPLE
    # まずはドライランで、何が削除されるか確認する
    .\Clean-PC.ps1

.EXAMPLE
    # ブラウザキャッシュも含めてドライラン確認
    .\Clean-PC.ps1 -IncludeBrowserCache

.EXAMPLE
    # 実際に削除する（確認プロンプトあり）
    .\Clean-PC.ps1 -IncludeBrowserCache -Execute

.EXAMPLE
    # 確認なしで即実行（自己責任で）
    .\Clean-PC.ps1 -Execute -Force
#>

[CmdletBinding()]
param(
    [int]$DownloadsDays = 30,
    [switch]$IncludeSystemTemp,
    [switch]$IncludeBrowserCache,
    [switch]$Execute,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

# 削除対象ファイルを1件のオブジェクトリストとして集計する
$targets = New-Object System.Collections.Generic.List[Object]

function Add-TargetFiles {
    param(
        [string]$Path,
        [string]$Category,
        [int]$OlderThanDays = -1
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }

    $cutoff = if ($OlderThanDays -ge 0) { (Get-Date).AddDays(-$OlderThanDays) } else { $null }

    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($null -eq $cutoff -or $_.LastWriteTime -lt $cutoff) {
                $targets.Add([PSCustomObject]@{
                    Category = $Category
                    FullName = $_.FullName
                    Length   = $_.Length
                })
            }
        }
}

Write-Host "=== 削除対象をスキャン中 ===" -ForegroundColor Cyan

# 1. ユーザー一時フォルダ
Add-TargetFiles -Path $env:TEMP -Category 'ユーザー一時ファイル'

# 2. システム一時フォルダ（オプション）
if ($IncludeSystemTemp) {
    Add-TargetFiles -Path "$env:WINDIR\Temp" -Category 'システム一時ファイル'
}

# 3. ブラウザキャッシュ（オプション）
if ($IncludeBrowserCache) {
    $localAppData = $env:LOCALAPPDATA
    $edgeCache    = Join-Path $localAppData 'Microsoft\Edge\User Data\Default\Cache'
    $chromeCache  = Join-Path $localAppData 'Google\Chrome\User Data\Default\Cache'
    $firefoxRoot  = Join-Path $localAppData 'Mozilla\Firefox\Profiles'

    Add-TargetFiles -Path $edgeCache   -Category 'Edgeキャッシュ'
    Add-TargetFiles -Path $chromeCache -Category 'Chromeキャッシュ'

    if (Test-Path -LiteralPath $firefoxRoot) {
        Get-ChildItem -LiteralPath $firefoxRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Add-TargetFiles -Path (Join-Path $_.FullName 'cache2') -Category 'Firefoxキャッシュ'
        }
    }
}

# 4. ダウンロードフォルダ内の古いファイル
$downloadsPath = Join-Path $env:USERPROFILE 'Downloads'
Add-TargetFiles -Path $downloadsPath -Category "ダウンロード（$DownloadsDays 日以上経過）" -OlderThanDays $DownloadsDays

# --- 集計結果を表示 ---
if ($targets.Count -eq 0) {
    Write-Host "削除対象のファイルは見つかりませんでした。" -ForegroundColor Green
    return
}

$summary = $targets | Group-Object Category | ForEach-Object {
    [PSCustomObject]@{
        カテゴリ   = $_.Name
        ファイル数 = $_.Count
        合計サイズ = Format-Size ( ($_.Group | Measure-Object -Property Length -Sum).Sum )
    }
}

Write-Host "`n=== 削除対象サマリー ===" -ForegroundColor Cyan
$summary | Format-Table -AutoSize | Out-String | Write-Host

$totalBytes = ($targets | Measure-Object -Property Length -Sum).Sum
Write-Host "合計: $($targets.Count) ファイル / $(Format-Size $totalBytes)" -ForegroundColor Yellow

if (-not $Execute) {
    Write-Host "`n[ドライラン] 実際には削除していません。削除するには -Execute を付けて再実行してください。" -ForegroundColor Yellow
    return
}

if (-not $Force) {
    $answer = Read-Host "`n上記のファイルを本当に削除しますか？ (y/N)"
    if ($answer -notin @('y', 'Y', 'yes', 'Yes')) {
        Write-Host "キャンセルしました。何も削除していません。" -ForegroundColor Yellow
        return
    }
}

Write-Host "`n=== 削除を実行中 ===" -ForegroundColor Cyan

$logDir = Join-Path $env:USERPROFILE 'Desktop'
$logPath = Join-Path $logDir ("Clean-PC_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$deleted = 0
$failed = 0
$freedBytes = 0
$logLines = New-Object System.Collections.Generic.List[string]

foreach ($item in $targets) {
    try {
        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
        $deleted++
        $freedBytes += $item.Length
        $logLines.Add("DELETED `t$($item.Category)`t$($item.FullName)")
    }
    catch {
        $failed++
        $logLines.Add("FAILED  `t$($item.Category)`t$($item.FullName)`t$($_.Exception.Message)")
    }
}

try {
    $logLines | Set-Content -LiteralPath $logPath -Encoding UTF8
} catch {
    Write-Host "ログの書き込みに失敗しました: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n=== 完了 ===" -ForegroundColor Green
Write-Host "削除成功: $deleted 件 / 失敗: $failed 件"
Write-Host "解放された容量: $(Format-Size $freedBytes)"
Write-Host "ログファイル: $logPath"
