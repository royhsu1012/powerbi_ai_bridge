# =============================================================================
# Build-ShareBundle.ps1 —— 打包給同事用的分享版 zip（白名單＋外洩掃描）
# =============================================================================
# 用法（在專案根目錄）：
#   .\tools\Build-ShareBundle.ps1                     # → dist\PBI_AI_Bridge_<yyyyMMdd>.zip
#   .\tools\Build-ShareBundle.ps1 -IncludeMoxaSkill   # 連同 .claude\skills\moxa-pbi-style（公司內部分享才用）
#   .\tools\Build-ShareBundle.ps1 -Version 1.2        # 自訂版本字串
#   .\tools\Build-ShareBundle.ps1 -SelfTest           # 只測外洩掃描本身有沒有效，不打包
#
# 為什麼要這支：專案資料夾裡有你操作過的模型產物 —— pbi\、snapshots\（模型結構）、PowerQuery_Scripts\
# （M 腳本，含連線字串與伺服器位址）、audit\（查詢紀錄）。.gitignore 擋得住 GitHub，擋不住「直接壓縮資料夾」。
#
# 設計：
#   1. 白名單複製 —— 只帶走下面列出的檔案。以後專案多了新檔案（包括敏感的），預設不會被帶走；要分享就加進白名單。
#      白名單外、但在工具資料夾裡的檔案會列出來，提醒你有沒有漏掉該分享的
#   2. 複製完再做一次外洩掃描，命中就中止、刪掉暫存、不產生 zip。
#      只印「檔名:行號:規則名」，絕不印出命中的內容 —— 掃描本身不該變成外洩管道
#   3. 防毒相容：只讀專案資料夾裡指定的檔案；遞迴只發生在 docs\、skill 資料夾與 dist\ 的暫存區；
#      不啟動任何程式（版本來源直接讀 .git 的檔案，不呼叫 git）
#
# 參考另一份 PBI AI Bridge 分支的同名腳本（2026-10-21 版）的做法。
# =============================================================================

param(
    [string]$Version = (Get-Date -Format 'yyyyMMdd'),
    [switch]$IncludeMoxaSkill,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$DistDir     = Join-Path $ProjectRoot 'dist'
$BundleName  = 'PBI_AI_Bridge'

# --- 白名單 -------------------------------------------------------------------
# 單一檔案（相對專案根）
$Whitelist = @(
    'README.md'
    'CLAUDE.md'
    'AGENTS.md'
    '.gitignore'
    '.gitattributes'
    'API_Documentation.html'
    'PowerBI_Visualizer.html'
    'tools\PBI-Bridge.ps1'
    'tools\Test-DataGuard.ps1'
    'tools\Test-BridgeClient.ps1'
    'tools\Build-ShareBundle.ps1'
    'tools\launcher-text.txt'
    'pbibridge_csharp\Program.cs'
    'pbibridge_csharp\pbibridge_csharp.csproj'
    'pbibridge_csharp\appsettings.template.json'    # 不是 appsettings.json —— 那份是這台電腦的設定
    '.claude\settings.json'
    '.claude\hooks\guard-data-access.ps1'
)
# 整個資料夾（相對專案根，連同子資料夾）
$WhitelistDirs = @('docs')
# MOXA 報表風格：同事寫的、含公司內部資訊 —— 只在公司內部分享時明確要求才帶
if ($IncludeMoxaSkill) { $WhitelistDirs += '.claude\skills\moxa-pbi-style' }
# 根目錄的啟動檔用萬用字元找：檔名含 emoji，寫成字串常值容易在編碼轉換中損毀
$BatPattern   = '*.bat'
$ExpectedBats = 1

# --- 外洩掃描規則 -------------------------------------------------------------
# 本腳本自己也會被打包、被掃描，所以每條樣式都寫成「原文不會命中自己」的形式：
# 關鍵字後面接的是反斜線（\s、\.、\(）或括號，不是等號、句點本身。
# 連線字串規則要求「key=值;」而且等號兩邊沒有空白（真正的連線字串都這樣寫），才不會誤判程式碼的
# server = new Server()、host = Request.Host；連到本機（localhost）的不算 —— 服務本來就連本機的 Power BI。
$ForbiddenFileNames  = @('appsettings.json', 'api-key.txt')
$ForbiddenExtensions = @('.pbix', '.pbip', '.pbit', '.abf', '.pq', '.tsv', '.dll', '.exe', '.pdb', '.zip')
$ContentRules = [ordered]@{
    '32 位十六進位（疑似金鑰）' = '(?<![0-9A-Fa-f])[0-9A-Fa-f]{32}(?![0-9A-Fa-f])'
    '連線字串（伺服器）'        = '(?i)\b(Server|Data Source|Host)=(?!localhost\b|127\.0\.0\.1\b)[^\s;=]+;'
    '連線字串（密碼）'          = '(?i)\b(Password|Pwd)\s*=\s*[^\s;=]+;'
    'AWS 主機'                  = '(?i)\.amazonaws\.com'
    'M 的資料來源函式'          = '(?i)\b(AmazonRedshift\.Database|Sql\.Database|Odbc\.DataSource|Oracle\.Database|Snowflake\.Databases)\s*\('
    '電子郵件地址'              = '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.-]*[A-Za-z]{2,}'
}

function Get-LiteralSecrets {
    # 執行期才取得，只放在記憶體，不輸出
    $list = @()
    try {
        $env:PBI_BRIDGE_QUIET = '1'
        . (Join-Path $PSScriptRoot 'PBI-Bridge.ps1')
        $key = Get-PbiApiKey
        if ($key) { $list += @{ Name = '你的 API 金鑰'; Value = [string]$key } }
    } catch {
        Write-Host '   （這台電腦還沒有 API 金鑰檔，略過「金鑰原文」這條檢查；32 位十六進位的規則照樣檢查）' -ForegroundColor Gray
    }
    if ($env:USERPROFILE) { $list += @{ Name = '你的家目錄路徑'; Value = $env:USERPROFILE } }
    if ($env:USERNAME -and $env:USERNAME.Length -ge 4) { $list += @{ Name = '你的使用者名稱'; Value = $env:USERNAME } }
    return , $list
}

function Find-BundleLeaks {
    param([string]$Dir, [array]$LiteralSecrets)
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force)) {
        $rel = $file.FullName.Substring($Dir.Length).TrimStart('\')
        if ($ForbiddenFileNames -contains $file.Name.ToLowerInvariant()) { $hits.Add("$rel : 禁止的檔名"); continue }
        if ($ForbiddenExtensions -contains $file.Extension.ToLowerInvariant()) { $hits.Add("$rel : 禁止的副檔名 $($file.Extension)"); continue }
        $lines = [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8)
        for ($n = 0; $n -lt $lines.Length; $n++) {
            $text = $lines[$n]
            foreach ($secret in $LiteralSecrets) {
                if ($text.IndexOf($secret.Value, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits.Add("${rel}:$($n + 1) : $($secret.Name)") }
            }
            foreach ($rule in $ContentRules.GetEnumerator()) {
                if ($text -match $rule.Value) { $hits.Add("${rel}:$($n + 1) : $($rule.Key)") }
            }
        }
    }
    return , $hits
}

function Remove-StageDir([string]$Path) {
    if (Test-Path -LiteralPath $Path) { [System.IO.Directory]::Delete($Path, $true) }
}

function Get-SourceCommit {
    # 直接讀 .git 的檔案（不啟動 git）。讀不到就回 $null —— 例如這份資料夾本身就是解壓縮出來的
    try {
        $gitDir = Join-Path $ProjectRoot '.git'
        if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) { return $null }
        $head = (Get-Content -LiteralPath (Join-Path $gitDir 'HEAD') -Raw).Trim()
        if ($head -match '^[0-9a-f]{40}$') { return "（未在分支上）@$($head.Substring(0, 7))" }
        if ($head -notmatch '^ref:\s*(\S+)$') { return $null }
        $ref = $Matches[1]
        $refFile = Join-Path $gitDir ($ref -replace '/', '\')
        $sha = $null
        if (Test-Path -LiteralPath $refFile) { $sha = (Get-Content -LiteralPath $refFile -Raw).Trim() }
        else {
            $packed = Join-Path $gitDir 'packed-refs'
            if (Test-Path -LiteralPath $packed) {
                $line = Get-Content -LiteralPath $packed | Where-Object { $_ -match (' ' + [regex]::Escape($ref) + '$') } | Select-Object -First 1
                if ($line) { $sha = $line.Split(' ')[0] }
            }
        }
        if ($sha -match '^[0-9a-f]{40}$') { return "$($ref -replace '^refs/heads/', '')@$($sha.Substring(0, 7))" }
    } catch { }
    return $null
}

# =============================================================================
# -SelfTest：每條規則都要抓得到假的外洩，乾淨的檔案不能被誤判
# =============================================================================
if ($SelfTest) {
    $dir = Join-Path $DistDir '_selftest'
    Remove-StageDir $dir
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    # 觸發字串在執行期才組出來，本腳本的原文裡沒有（否則打包時會命中自己）
    $samples = [ordered]@{
        '32 位十六進位（疑似金鑰）' = ('ab' * 16)
        '連線字串（伺服器）'        = ('Ser' + 'ver=db.example.local;Database=x')
        '連線字串（密碼）'          = ('User=x;Pass' + 'word=hunter2;')
        'AWS 主機'                  = ('cluster.' + 'amazonaws' + '.com:5439')
        'M 的資料來源函式'          = ('Source = AmazonRedshift' + '.Database("h", "d")')
        '電子郵件地址'              = ('someone' + '@' + 'example.com')
    }
    $i = 0
    foreach ($k in $samples.Keys) { $i++; [IO.File]::WriteAllText((Join-Path $dir "leak$i.txt"), "前面`n$($samples[$k])`n後面", $utf8) }
    $local = 'conn.Open("Data Sou' + 'rce=localhost:51876;");'
    [IO.File]::WriteAllText((Join-Path $dir 'clean.cs'),
        "var server = new Server();`nvar host = context.Request.Host.Host;`n$local`nvar id = ""ID_3FA2B81C07"";`n// Server = 名稱（不是連線字串）", $utf8)
    [IO.File]::WriteAllText((Join-Path $dir 'model.pbix'), 'x', $utf8)
    [IO.File]::WriteAllText((Join-Path $dir 'appsettings.json'), '{}', $utf8)
    $literal = Get-LiteralSecrets
    $nameRule = $literal | Where-Object { $_.Name -eq '你的使用者名稱' } | Select-Object -First 1
    if ($nameRule) { [IO.File]::WriteAllText((Join-Path $dir 'user.txt'), "作者：$($nameRule.Value)", $utf8) }

    $hits = Find-BundleLeaks -Dir $dir -LiteralSecrets $literal
    $fail = 0
    $i = 0
    foreach ($k in $samples.Keys) {
        $i++
        $ok = @($hits | Where-Object { $_ -like "leak$i.txt:*" -and $_ -like "*$k" }).Count -gt 0
        Write-Host ("   {0} {1}" -f $(if ($ok) { '✅' } else { '❌' }), $k); if (-not $ok) { $fail++ }
    }
    foreach ($pair in @(@('model.pbix', '禁止的副檔名'), @('appsettings.json', '禁止的檔名'))) {
        $ok = @($hits | Where-Object { $_ -like "$($pair[0])*$($pair[1])*" }).Count -gt 0
        Write-Host ("   {0} {1}" -f $(if ($ok) { '✅' } else { '❌' }), $pair[1]); if (-not $ok) { $fail++ }
    }
    if ($nameRule) {
        $ok = @($hits | Where-Object { $_ -like 'user.txt:*你的使用者名稱' }).Count -gt 0
        Write-Host ("   {0} 你的使用者名稱" -f $(if ($ok) { '✅' } else { '❌' })); if (-not $ok) { $fail++ }
    }
    $falsePos = @($hits | Where-Object { $_ -like 'clean.cs*' })
    Write-Host ("   {0} 乾淨的檔案沒有被誤判" -f $(if ($falsePos.Count -eq 0) { '✅' } else { '❌' })); if ($falsePos.Count) { $fail++ }
    Remove-StageDir $dir
    if ($fail -gt 0) { Write-Host "自我測試：$fail 項失敗" -ForegroundColor Red; exit 1 }
    Write-Host '自我測試：全部通過' -ForegroundColor Green
    exit 0
}

# =============================================================================
# 打包
# =============================================================================
$stageRoot = Join-Path $DistDir '_stage'
$stage     = Join-Path $stageRoot $BundleName
Remove-StageDir $stageRoot
[void](New-Item -ItemType Directory -Path $stage -Force)

try {
    Write-Host "① 依白名單複製"
    foreach ($rel in $Whitelist) {
        $src = Join-Path $ProjectRoot $rel
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            throw "白名單上的檔案不存在：$rel（專案結構改了的話，更新本腳本的白名單）"
        }
        $dst = Join-Path $stage $rel
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force)
        Copy-Item -LiteralPath $src -Destination $dst
    }
    foreach ($rel in $WhitelistDirs) {
        $src = Join-Path $ProjectRoot $rel
        if (-not (Test-Path -LiteralPath $src -PathType Container)) { throw "白名單上的資料夾不存在：$rel" }
        $dst = Join-Path $stage $rel
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force)
        Copy-Item -LiteralPath $src -Destination $dst -Recurse
    }
    $bats = @(Get-ChildItem -LiteralPath $ProjectRoot -Filter $BatPattern -File)
    if ($bats.Count -ne $ExpectedBats) { throw "根目錄的 .bat 應該有 $ExpectedBats 個，實際 $($bats.Count) 個" }
    foreach ($b in $bats) { Copy-Item -LiteralPath $b.FullName -Destination (Join-Path $stage $b.Name) }

    # 工具資料夾裡、白名單外的檔案：列出來提醒（不打包）
    $known = @($Whitelist | ForEach-Object { $_.ToLowerInvariant() })
    $skipNames = @('appsettings.json')
    $missed = @()
    foreach ($sub in @('', 'tools', 'pbibridge_csharp', '.claude', '.claude\hooks')) {
        $d = if ($sub) { Join-Path $ProjectRoot $sub } else { $ProjectRoot }
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Force)) {
            $rel = if ($sub) { "$sub\$($f.Name)" } else { $f.Name }
            if ($known -contains $rel.ToLowerInvariant() -or $f.Extension -eq '.bat' -or $skipNames -contains $f.Name.ToLowerInvariant()) { continue }
            $missed += $rel
        }
    }

    $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($stage.Length).TrimStart('\') } | Sort-Object)
    $source = Get-SourceCommit
    $versionText = @(
        'PBI AI Bridge 分享版'
        "版本：$Version"
        "打包時間：$(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        $(if ($source) { "來源：$source（打包時有還沒提交的修改的話，內容會比這個版本新）" })
        ''
        '第一次使用：雙擊根目錄的啟動檔（🚀啟動PBI終極儀表板.bat），細節見 README.md 第 3 節。'
        ''
        "內含檔案（$($files.Count + 1) 個）："
        ($files + 'VERSION.txt' | Sort-Object | ForEach-Object { "  $_" })
    ) | Where-Object { $null -ne $_ }
    [IO.File]::WriteAllLines((Join-Path $stage 'VERSION.txt'), [string[]]$versionText, (New-Object System.Text.UTF8Encoding $true))

    Write-Host "② 外洩掃描（$($files.Count + 1) 個檔案）"
    $hits = Find-BundleLeaks -Dir $stage -LiteralSecrets (Get-LiteralSecrets)
    if ($hits.Count -gt 0) {
        Write-Host "⛔ 掃到 $($hits.Count) 處可能外洩，不產生 zip：" -ForegroundColor Red
        $hits | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
        Write-Host "   打開那幾個檔案的那幾行看一下：是真的機密就拿掉；是範例文字就改寫成不像機密的樣子。" -ForegroundColor Yellow
        exit 1
    }

    Write-Host "③ 壓縮"
    [void](New-Item -ItemType Directory -Path $DistDir -Force)
    $zip = Join-Path $DistDir "${BundleName}_$Version.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
    # 不用 ZipFile.CreateFromDirectory：Windows PowerShell 5.1 底下的 .NET 會把路徑寫成反斜線（PBI_AI_Bridge\docs\…），
    # 其他解壓縮工具會解出檔名含反斜線的檔案。逐一加入、路徑一律用正斜線
    $fs = [System.IO.File]::Open($zip, [System.IO.FileMode]::CreateNew)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force)) {
                $entry = "$BundleName/" + ($f.FullName.Substring($stage.Length).TrimStart('\') -replace '\\', '/')
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entry, [System.IO.Compression.CompressionLevel]::Optimal)
            }
        } finally { $archive.Dispose() }
    } finally { $fs.Dispose() }

    Write-Host ""
    Write-Host "✅ $zip（$([math]::Round((Get-Item -LiteralPath $zip).Length / 1KB)) KB，$($files.Count + 1) 個檔案）" -ForegroundColor Green
    if ($IncludeMoxaSkill) { Write-Host "   含 MOXA 報表風格 skill：只在公司內部分享" -ForegroundColor Yellow }
    if ($missed.Count -gt 0) {
        Write-Host "   以下檔案不在白名單、沒有打包（該分享的話加進本腳本的白名單）：" -ForegroundColor Gray
        $missed | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray }
    }
} finally {
    Remove-StageDir $stageRoot
}
