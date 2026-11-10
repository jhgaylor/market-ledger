; Market Ledger installer for Windows (NSIS 3). Built by release.sh:
;   makensis -DVERSION=0.2.0 installer.nsi
; Per-user install, no admin rights: %LOCALAPPDATA%\Programs\Market Ledger, a Start menu entry,
; start at login (HKCU Run), and an entry in Settings > Apps with an uninstaller.

Unicode true
!include "MUI2.nsh"

!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!define APPNAME "Market Ledger"
!define EXE "MarketLedger.exe"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\MarketLedger"
!define RUNKEY "Software\Microsoft\Windows\CurrentVersion\Run"

Name "${APPNAME}"
OutFile "dist\MarketLedger-Setup.exe"
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\Programs\Market Ledger"
SetCompressor /SOLID lzma
BrandingText "${APPNAME} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=1033 "ProductName" "${APPNAME}"
VIAddVersionKey /LANG=1033 "CompanyName" "Jake Gaylor"
VIAddVersionKey /LANG=1033 "FileDescription" "${APPNAME} Setup"
VIAddVersionKey /LANG=1033 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=1033 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "© 2026 Jake Gaylor"

!define MUI_ICON "icon.ico"
!define MUI_UNICON "icon.ico"
!define MUI_WELCOMEPAGE_TITLE "Install ${APPNAME}"
!define MUI_WELCOMEPAGE_TEXT "Market Ledger keeps your guild's auction prices in World of Warcraft Forever up to date.$\r$\n$\r$\nIt runs in the system tray, installs the Market Ledger addon, shares your Auctionator scans, and brings back everyone's prices.$\r$\n$\r$\nClick Install to continue."
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Start Market Ledger"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; Ask a running copy to close (it listens for this), so its files can be replaced.
!macro QuitRunning
  IfFileExists "$INSTDIR\${EXE}" 0 +2
    ExecWait '"$INSTDIR\${EXE}" --quit'
!macroend

Section "Install"
  !insertmacro QuitRunning
  SetOutPath "$INSTDIR"
  File "dist\${EXE}"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateShortcut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\${EXE}"
  WriteRegStr HKCU "${RUNKEY}" "MarketLedger" '"$INSTDIR\${EXE}"'

  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "Jake Gaylor"
  WriteRegStr HKCU "${UNINSTKEY}" "URLInfoAbout" "https://wow-market.apps.inevitable.fyi"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\${EXE}"
  WriteRegStr HKCU "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "EstimatedSize" 12000
SectionEnd

Section "Uninstall"
  !insertmacro QuitRunning
  Delete "$INSTDIR\${EXE}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\${APPNAME}.lnk"
  DeleteRegValue HKCU "${RUNKEY}" "MarketLedger"
  DeleteRegKey HKCU "${UNINSTKEY}"
  ; Settings and logs in %APPDATA%\MarketLedger are left, so a reinstall keeps its identity.
SectionEnd
