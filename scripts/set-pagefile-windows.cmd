@echo off
rem ============================================================
rem  Strix Halo / Ryzen AI Max: raise Windows commit limit
rem  Sets the pagefile on C: to a fixed 112 GB.
rem  Why: a large UMA VRAM carveout (96 GB) needs a big commit
rem  limit, or models that fit in VRAM still fail to load.
rem  Run as administrator, then REBOOT (pagefile activates at boot).
rem  Keep it on the SYSTEM drive. Non-system drives may be
rem  silently ignored by Windows (observed on two partitions).
rem ============================================================
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Not elevated. Right-click this file and choose "Run as administrator".
  pause
  exit /b 1
)

echo [1/3] Disable automatic pagefile management
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v AutomaticManagedPagefile /t REG_DWORD /d 0 /f >nul
if errorlevel 1 goto fail

echo [2/3] Set pagefile: C: fixed 112 GB (114688 MB)
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v PagingFiles /t REG_MULTI_SZ /d "c:\pagefile.sys 114688 114688" /f >nul
if errorlevel 1 goto fail

echo [3/3] Current values
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v AutomaticManagedPagefile
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v PagingFiles
echo.
echo ==== DONE. Reboot once, then verify ====
echo   powershell -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).TotalVirtualMemorySize/1MB"
echo   powershell -NoProfile -Command "Get-CimInstance Win32_PageFileUsage ^| Select Name,AllocatedBaseSize"
echo Expected: commit limit about 143.6 GB with 32 GB visible RAM.
pause
exit /b 0

:fail
echo [ERROR] Registry write failed, code %errorlevel%
pause
exit /b 1
