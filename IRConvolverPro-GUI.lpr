program IRConvolverPro_GUI;

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, uMainForm_GUI;

{$R *.res}

begin
  Application.Scaled:=True;
  Application.Initialize;
  Application.CreateForm(TMainForm_GUI, MainForm_GUI);
  Application.Run;
end.
