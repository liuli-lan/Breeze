@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

set PARTS=
for /f "delims=" %%f in ('dir /b /on mangajanai-win.7z.0* 2^>nul') do (
  if "!PARTS!"=="" (set PARTS=%%f) else (set PARTS=!PARTS!+%%f)
)
if "!PARTS!"=="" goto fail

echo Merging volumes: !PARTS!
copy /b !PARTS! mangajanai-win.7z >nul
if errorlevel 1 goto fail

echo.
echo Done: mangajanai-win.7z
echo.
echo SHA-256 (compare with SHA256SUMS.txt):
certutil -hashfile mangajanai-win.7z SHA256
echo.
echo Next steps:
echo   Breeze ^> Settings ^> Super resolution ^> Super resolution engine
echo   ^> MangaJaNai (local) ^> Runtime ^> Import runtime archive
echo   ^> pick the merged mangajanai-win.7z
echo.
pause
exit /b 0

:fail
echo.
echo Failed. Make sure ALL volumes (mangajanai-win.7z.001, .002, ...) are in this same folder.
echo.
pause
exit /b 1
