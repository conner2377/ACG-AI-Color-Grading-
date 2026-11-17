@echo off
chcp 65001 >nul
rem 개발 모드 실행: 코드 수정 후 터미널에서 r 키로 바로 반영(hot reload), R로 재시작
set "PATH=%USERPROFILE%\.cargo\bin;C:\src\flutter\bin;%PATH%"
cd /d "%~dp0..\app"
flutter run -d windows
pause
