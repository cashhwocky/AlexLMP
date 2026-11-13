; AlexLMP for Windows installer (Inno Setup). Installs for the current user,
; so it doesn't need admin rights.
#define AppVersion GetEnv("VERSION")

[Setup]
AppId={{7A063C0E-837C-4645-AE0C-60B8161D2A3A}
AppName=AlexLMP
AppVersion={#AppVersion}
AppPublisher=Alex Desrosier
AppPublisherURL=https://github.com/cashhwocky/AlexLMP
DefaultDirName={autopf}\AlexLMP
DefaultGroupName=AlexLMP
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\out
OutputBaseFilename=AlexLMP-windows-v{#AppVersion}-setup
SetupIconFile=..\app_win\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\alex_lmp.exe
UninstallDisplayName=AlexLMP
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
LicenseFile=..\LICENSE

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "..\app_win\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\stage\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\AlexLMP"; Filename: "{app}\alex_lmp.exe"
Name: "{autodesktop}\AlexLMP"; Filename: "{app}\alex_lmp.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\alex_lmp.exe"; Description: "Open AlexLMP"; Flags: nowait postinstall skipifsilent
