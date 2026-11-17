# ACG 윈도우 배포 빌드
#  - Rust 엔진 테스트 → Flutter 릴리스 빌드 → dist\ACG 폴더와 zip 생성 → 바탕화면 바로가기
# 사용: 이 파일을 우클릭 → "PowerShell에서 실행", 또는 build_windows.bat 더블클릭

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Step($msg) { Write-Host "`n== $msg ==" -ForegroundColor Cyan }

# 새로 설치한 도구가 현재 창 PATH에 없을 수 있어 보완
foreach ($p in @("$env:USERPROFILE\.cargo\bin", "C:\src\flutter\bin")) {
  if ((Test-Path $p) -and ($env:Path -notlike "*$p*")) { $env:Path = "$p;$env:Path" }
}

Step "엔진 테스트 (Rust)"
Push-Location engine
cargo test --release -q
if ($LASTEXITCODE -ne 0) { throw "엔진 테스트 실패" }
Pop-Location

Step "앱 빌드 (Flutter, Release)"
Push-Location app
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get 실패" }
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build 실패" }
Pop-Location

Step "배포 폴더 만들기"
$release = Join-Path $root "app\build\windows\x64\runner\Release"
$dist = Join-Path $root "dist\ACG"
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dist | Out-Null
Copy-Item "$release\*" $dist -Recurse
if (-not (Test-Path "$dist\photo_grade_engine.dll")) {
  Copy-Item (Join-Path $root "engine\target\release\photo_grade_engine.dll") $dist
}
$zip = Join-Path $root "dist\ACG-windows.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$dist\*" -DestinationPath $zip

Step "바탕화면 바로가기"
$exe = Join-Path $dist "acg.exe"
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut((Join-Path $desktop "ACG 색보정.lnk"))
$lnk.TargetPath = $exe
$lnk.WorkingDirectory = $dist
$lnk.IconLocation = "$exe,0"
$lnk.Save()

Write-Host "`n완료!" -ForegroundColor Green
Write-Host "실행: 바탕화면 'ACG 색보정' 또는 $exe"
Write-Host "배포용 zip: $zip"
