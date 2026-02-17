unit uMainForm_GUI;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, EditBtn, Spin, UIRCore, Math;

type
  TMainForm_GUI = class(TForm)
    BtnRun: TButton; EdSrc: TFileNameEdit; EdIR: TFileNameEdit; EdOut: TEdit;
    BtnSelectOut: TButton; SaveDlg: TSaveDialog; ComboBits: TComboBox;
    SpinLen: TSpinEdit; MemoLog: TMemo;
    procedure BtnRunClick(Sender: TObject);
    procedure BtnSelectOutClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
  end;

var MainForm_GUI: TMainForm_GUI;

implementation

{$R *.lfm}

procedure TMainForm_GUI.FormCreate(Sender: TObject);
begin
  LoadCoreConfig;
  ComboBits.Text := IntToStr(CoreConfig.DefaultBits);
  SpinLen.Value := CoreConfig.TruncateLen;
end;

procedure TMainForm_GUI.BtnSelectOutClick(Sender: TObject);
begin if SaveDlg.Execute then EdOut.Text := SaveDlg.FileName; end;

procedure TMainForm_GUI.BtnRunClick(Sender: TObject);
var A1, A2, Res: TAudioData; SR1, SR2, c: Integer;
begin
  MemoLog.Clear;
  try
    A1 := LoadWav(EdSrc.FileName, SR1);
    if EdIR.FileName <> '' then begin
      A2 := LoadWav(EdIR.FileName, SR2);
      SetLength(Res, Min(Length(A1), Length(A2)));
      for c := 0 to High(Res) do Res[c] := ConvolveFFT(A1[c], A2[c]);
    end else Res := A1;
    Normalize(Res);
    if SpinLen.Value > 0 then TruncateToLength(Res, SpinLen.Value);
    SaveWav(EdOut.Text, Res, SR1, StrToInt(ComboBits.Text), False, CoreConfig.Artist);
    MemoLog.Lines.Add('Success!');
  except on E: Exception do MemoLog.Lines.Add('Error: ' + E.Message); end;
end;

end.
