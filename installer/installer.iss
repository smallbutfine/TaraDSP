[Setup]
AppId={{#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={code:GetPfDir}\{#MyAppName}

OutputBaseFilename={#MyAppName}_Setup_{#MyAppVersion}
OutputDir=..
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
AppPublisher={#MyAppPublisher}
PrivilegesRequired=none
PrivilegesRequiredOverridesAllowed=dialog
DisableDirPage=no
DisableProgramGroupPage=yes
Compression=lzma
SolidCompression=yes

LicenseFile=..\LICENSE
WizardStyle=modern

[Files]
; TEMPLATE: Adjust the source paths to match your project's executables and assets.
Source: "..\{#MyAppName}.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\libpffft.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Assets\*"; DestDir: "{app}\Assets"; Flags: ignoreversion
Source: "..\*.ini"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\NAME"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; TEMPLATE: Adjust the program group name.
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppName}.exe"

[Run]
Filename: "{app}\README.md"; Description: "View README"; Flags: postinstall shellexec skipifsilent unchecked

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ReadmeLines: TArrayOfString;
  ReadmeText: String;
  I: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    SetArrayLength(ReadmeLines, 14);
    ReadmeLines[0]  := '==================================================';
    ReadmeLines[1]  := ' ' + ExpandConstant('{#MyAppName}') + ' v' + ExpandConstant('{#MyAppVersion}') ;
    ReadmeLines[2]  := '==================================================';
    ReadmeLines[3]  := '';
    ReadmeLines[4]  := 'Thank you for installing this software!';
    ReadmeLines[5]  := '';
    ReadmeLines[11] := 'INSTALLATION PATH:';
    ReadmeLines[12] := ExpandConstant('{app}');
    ReadmeLines[13] := '';
    ReadmeText := '';
    for I := 0 to GetArrayLength(ReadmeLines) - 1 do
    begin
      if I > 0 then
        ReadmeText := ReadmeText + #13#10;
      ReadmeText := ReadmeText + ReadmeLines[I];
    end;
    SuppressibleMsgBox(
      ReadmeText,
      mbInformation,
      MB_OK,
      IDOK
    );
  end;
end;

function GetPfDir(S: String): String;
begin
  if IsWin64 then
    Result := ExpandConstant('{pf64}')
  else
    Result := ExpandConstant('{pf32}');
end;