@echo off
chcp 65001 >nul
rem 엔진 + 앱 테스트. 사진 하나를 이 파일 위로 끌어다 놓으면 그 사진으로 엔진 연동 테스트까지 합니다.
set "PATH=%USERPROFILE%\.cargo\bin;C:\src\flutter\bin;%PATH%"
cd /d "%~dp0..\engine"
cargo test --release || goto :fail
cargo build --release || goto :fail
set "PATH=%~dp0..\engine\target\release;%PATH%"
if not "%~1"=="" set "ACG_SAMPLE=%~1"
cd /d "%~dp0..\app"
call flutter test || goto :fail
echo.
echo 모든 테스트 통과
pause
exit /b 0
:fail
echo.
echo 테스트 실패 - 위 오류를 확인하세요
pause
exit /b 1
