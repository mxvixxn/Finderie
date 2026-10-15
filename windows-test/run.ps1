# Finderie Windows 호환성 시험
# 사용: powershell -ExecutionPolicy Bypass -File run.ps1 -Server http://<mac>:8765
param([Parameter(Mandatory = $true)][string]$Server, [switch]$SkipExplorerMany)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$base = Join-Path $env:USERPROFILE 'Desktop\FinderieTest'
if (Test-Path $base) { Remove-Item $base -Recurse -Force }
New-Item -ItemType Directory -Path $base, "$base\zips", "$base\expected", "$base\out", "$base\upload" | Out-Null
$report = "$base\upload\report.txt"

function Log([string]$s) { Write-Host $s; Add-Content -Path $report -Value $s -Encoding UTF8 }
function Url([string]$rel) { $Server.TrimEnd('/') + '/' + ((($rel -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/') }
function NFC([string]$s) { $s.Normalize([Text.NormalizationForm]::FormC) }

$md5 = [Security.Cryptography.MD5]::Create()
function Md5([string]$p) {
    $s = [IO.File]::OpenRead($p)
    try { ([BitConverter]::ToString($md5.ComputeHash($s)) -replace '-', '').ToLower() } finally { $s.Dispose() }
}

# ---------- 환경 ----------
$os = Get-CimInstance Win32_OperatingSystem
Log "=== Finderie Windows 시험 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Log "OS: $($os.Caption) $($os.Version) / $($env:PROCESSOR_ARCHITECTURE)"
Log "시스템 로캘: $((Get-WinSystemLocale).Name) / ANSI 코드페이지: $([Text.Encoding]::Default.CodePage) / OEM: $([Console]::OutputEncoding.CodePage)"
$utf8Beta = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage').ACP
Log "레지스트리 ACP: $utf8Beta (65001이면 'UTF-8 베타' 켜짐)"
Log "PowerShell: $($PSVersionTable.PSVersion)"
Log ""

# ---------- 내려받기 ----------
$list = (Invoke-WebRequest -UseBasicParsing (Url 'list.txt')).Content
if ($list -is [byte[]]) { $list = [Text.Encoding]::UTF8.GetString($list) }
foreach ($rel in ($list -split "`n" | Where-Object { $_.Trim() })) {
    $rel = $rel.Trim()
    $dest = Join-Path $base ($rel -replace '/', '\')
    Invoke-WebRequest -UseBasicParsing (Url $rel) -OutFile $dest
}
Log "내려받기 완료: $((Get-ChildItem "$base\zips").Count)개 ZIP"
Log ""

# ---------- 비교 ----------
function Compare-Result([string]$zipName, [string]$dest, [string]$engine) {
    $exp = Get-Content "$base\expected\$([IO.Path]::GetFileNameWithoutExtension($zipName)).tsv" -Encoding UTF8 |
        Where-Object { $_ } | ForEach-Object { $c = $_ -split "`t"; [pscustomobject]@{ Kind = $c[0]; Name = (NFC $c[1]); Md5 = $c[2] } }
    $expFiles = @{}; $exp | Where-Object Kind -eq 'F' | ForEach-Object { $expFiles[$_.Name] = $_.Md5 }
    $expDirs = $exp | Where-Object Kind -eq 'D' | ForEach-Object Name

    $actual = @{}
    if (Test-Path $dest) {
        Get-ChildItem -LiteralPath $dest -Recurse -Force -File | ForEach-Object {
            $actual[(NFC $_.FullName.Substring($dest.Length + 1))] = $_.FullName
        }
    }
    $nameOk = 0; $hashOk = 0; $missing = @(); $badHash = @()
    foreach ($k in $expFiles.Keys) {
        if ($actual.ContainsKey($k)) {
            $nameOk++
            if ((Md5 $actual[$k]) -eq $expFiles[$k]) { $hashOk++ } else { $badHash += $k }
        } else { $missing += $k }
    }
    $extra = @($actual.Keys | Where-Object { -not $expFiles.ContainsKey($_) })
    $dirOk = @($expDirs | Where-Object { Test-Path -LiteralPath (Join-Path $dest $_) }).Count

    $total = $expFiles.Count
    $verdict = if ($nameOk -eq $total -and $hashOk -eq $total -and $extra.Count -eq 0 -and $dirOk -eq @($expDirs).Count) { '통과' } else { '실패' }
    Log ("  [{0}] {1}: 이름 {2}/{3}, 내용(MD5) {4}/{3}, 폴더 {5}/{6}, 예상 밖 파일 {7}개" -f $engine, $verdict, $nameOk, $total, $hashOk, $dirOk, @($expDirs).Count, $extra.Count)
    if ($total -le 50) { foreach ($k in ($actual.Keys | Sort-Object)) { Log "      보이는 이름: $k" } }
    foreach ($m in ($missing | Select-Object -First 5)) { Log "      없음: $m" }
    foreach ($m in ($extra | Select-Object -First 5)) { Log "      예상 밖: $m" }
    foreach ($m in ($badHash | Select-Object -First 5)) { Log "      내용 다름: $m" }
    return $verdict
}

# 탐색기와 같은 엔진(Shell.Application)으로 풀기. 비동기라 파일 수가 멈출 때까지 기다린다.
$shell = New-Object -ComObject Shell.Application
function Expand-WithExplorer([string]$zip, [string]$dest, [int]$expectCount, [int]$timeoutSec) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $shell.NameSpace($dest).CopyHere($shell.NameSpace($zip).Items(), 4 + 16 + 512 + 1024)
    $last = -1; $stable = 0
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        Start-Sleep -Milliseconds 700
        $n = @(Get-ChildItem -LiteralPath $dest -Recurse -Force -File -ErrorAction SilentlyContinue).Count
        $size = (Get-ChildItem -LiteralPath $dest -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        # 다 풀렸으면 바로 끝. 이름이 깨져 일부가 안 만들어지는 경우를 대비해, 6초 넘게 그대로면 끝난 것으로 본다.
        if ("$n/$size" -eq $last) { $stable++ } else { $stable = 0 }
        if (($n -ge $expectCount -and $stable -ge 2) -or ($n -lt $expectCount -and $stable -ge 9)) { break }
        $last = "$n/$size"
    }
    return [math]::Round($sw.Elapsed.TotalSeconds, 1)
}

$results = @()
foreach ($zip in (Get-ChildItem "$base\zips\*.zip" | Sort-Object Name)) {
    $name = $zip.Name
    $exp = Get-Content "$base\expected\$($zip.BaseName).tsv" -Encoding UTF8 | Where-Object { $_ -like "F`t*" }
    Log "■ $name ($([math]::Round($zip.Length / 1MB, 1)) MB, 파일 $($exp.Count)개)"

    # 1) 탐색기 엔진
    if ($SkipExplorerMany -and $exp.Count -gt 10000) {
        Log "  [탐색기] 건너뜀"
    } else {
        $d = "$base\out\explorer\$($zip.BaseName)"
        $timeout = if ($exp.Count -gt 10000) { 1800 } else { 600 }
        try {
            $sec = Expand-WithExplorer $zip.FullName $d $exp.Count $timeout
            Log "  [탐색기] 풀기 $sec 초"
            $results += [pscustomobject]@{ Zip = $name; Engine = '탐색기'; Verdict = (Compare-Result $name $d '탐색기') }
        } catch { Log "  [탐색기] 오류: $($_.Exception.Message)"; $results += [pscustomobject]@{ Zip = $name; Engine = '탐색기'; Verdict = '오류' } }
        if ($zip.Length -gt 1GB -or $exp.Count -gt 10000 -or $name -like '6_*') { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # 2) .NET 엔진 (Expand-Archive)
    $d = "$base\out\dotnet\$($zip.BaseName)"
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Expand-Archive -LiteralPath $zip.FullName -DestinationPath $d -Force
        Log "  [.NET] 풀기 $([math]::Round($sw.Elapsed.TotalSeconds, 1)) 초"
        $results += [pscustomobject]@{ Zip = $name; Engine = '.NET'; Verdict = (Compare-Result $name $d '.NET') }
    } catch { Log "  [.NET] 오류: $($_.Exception.Message)"; $results += [pscustomobject]@{ Zip = $name; Engine = '.NET'; Verdict = '오류' } }
    if ($name -like '6_*' -or $exp.Count -gt 10000) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    Log ""
}

# ---------- Windows → Mac: Windows에서 한글 ZIP 만들기 ----------
Log "■ Windows에서 만든 ZIP (Mac에서 Finderie로 풀어 볼 것)"
$src = "$base\win_src\윈도우 폴더"
New-Item -ItemType Directory -Path "$src\사진", "$src\빈 폴더" -Force | Out-Null
$samples = @{
    '회의록 최종본.txt'      = "회의 내용`r`n"
    '뷁 똠 햏 쀍.txt'         = "드문 글자`r`n"
    '한자 漢字 ひらがな.txt'  = "한자와 가나`r`n"
    '이모지 😀.txt'           = "이모지`r`n"
    '괄호 (1) [대괄호].txt'   = "특수문자`r`n"
}
foreach ($k in $samples.Keys) { [IO.File]::WriteAllText((Join-Path $src $k), $samples[$k], [Text.Encoding]::UTF8) }
$bytes = New-Object byte[] 3000000; (New-Object Random 7).NextBytes($bytes); [IO.File]::WriteAllBytes("$src\사진\가족 여행.jpg", $bytes)

# 기대 결과 (Mac 쪽 확인용)
$lines = Get-ChildItem -LiteralPath "$base\win_src" -Recurse -Force | ForEach-Object {
    $rel = (NFC $_.FullName.Substring("$base\win_src".Length + 1)) -replace '\\', '/'
    if ($_.PSIsContainer) { "D`t$rel`t-`t0" } else { "F`t$rel`t$(Md5 $_.FullName)`t$($_.Length)" }
}
[IO.File]::WriteAllLines("$base\upload\win_expected.tsv", $lines, (New-Object Text.UTF8Encoding $false))

# 탐색기 '압축(ZIP) 폴더로 보내기'와 같은 방법
$exZip = "$base\upload\win_explorer.zip"
[IO.File]::WriteAllBytes($exZip, [byte[]](@(80, 75, 5, 6) + (@(0) * 18)))
$shell.NameSpace($exZip).CopyHere($src, 4 + 16 + 1024)
$sw = [Diagnostics.Stopwatch]::StartNew(); $last = -1; $stable = 0
while ($sw.Elapsed.TotalSeconds -lt 120) {
    Start-Sleep -Milliseconds 800
    $len = (Get-Item $exZip).Length
    $locked = $false; try { $f = [IO.File]::Open($exZip, 'Open', 'Read', 'None'); $f.Close() } catch { $locked = $true }
    if (-not $locked -and $len -eq $last -and $len -gt 22) { $stable++; if ($stable -ge 2) { break } } else { $stable = 0 }
    $last = $len
}
Log "  탐색기로 압축: $([math]::Round((Get-Item $exZip).Length / 1KB)) KB"
Compress-Archive -LiteralPath $src -DestinationPath "$base\upload\win_dotnet.zip" -Force
Log "  Compress-Archive로 압축: $([math]::Round((Get-Item "$base\upload\win_dotnet.zip").Length / 1KB)) KB"
Log ""

# ---------- 요약 ----------
Log "=== 요약 ==="
foreach ($r in $results) { Log ("  {0,-8} {1,-6} {2}" -f $r.Verdict, $r.Engine, $r.Zip) }

# ---------- Mac으로 올리기 ----------
foreach ($f in Get-ChildItem "$base\upload") {
    Invoke-WebRequest -UseBasicParsing -Method Put -InFile $f.FullName -Uri (Url "upload/$($f.Name)") | Out-Null
}
Write-Host ""
Write-Host "Mac으로 결과를 보냈어요. 이 창은 닫아도 돼요."
