program TaraDSP_gui;

{$mode objfpc}{$H+}


uses
  Interfaces,
  Forms,
  uMainForm_GUI;

begin
  Application.Scaled := True;
  Application.Title := 'TaraDSP';
  Application.Initialize;
  Application.CreateForm(TMainForm_GUI, MainForm_GUI);
  Application.Run;
end.