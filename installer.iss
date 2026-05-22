[Setup]
AppName=TaraDSP
AppVersion=1.0.0
DefaultDirName={autopf}\TaraDSP
DefaultGroupName=TaraDSP
Compression=lzma2
SolidCompression=yes
OutputDir=.\installer_out
OutputBaseFilename=TaraDSP_Setup
ArchitecturesInstallIn64BitMode=x64

[Files]
; Installiert standardmäßig die optimierte AVX2 Version als Haupt-Anwendung
Source: "dist\TaraDSP.exe"; DestDir: "{app}"; DestName: "TaraDSP.exe"; Flags: ignoreversion
Source: "dist\TaraDSP-noAVX2.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\settings.ini"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\TaraDSP (AVX2)"; Filename: "{app}\TaraDSP.exe"
Name: "{group}\TaraDSP (no-AVX2)"; Filename: "{app}\TaraDSP-noAVX2.exe"
