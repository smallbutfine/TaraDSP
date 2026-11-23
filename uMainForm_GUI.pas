unit uMainForm_GUI;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, EditBtn, Spin, UIRCore, Math;

type
  TMainForm_GUI = class(TForm)
    BtnRun: TButton;
    EdSrc: TFileNameEdit;
    EdIR: TFileNameEdit;
    EdOut: TEdit;
    BtnSelectOut: TButton;
    SaveDlg: TSaveDialog;
    ComboBits: TComboBox;
    SpinLen: TSpinEdit;
    MemoLog: TMemo;
    ChkMono: TCheckBox;
    ChkMinPhase: TCheckBox;
    SpinFade: TSpinEdit;
    SpinTrim: TSpinEdit;
    ComboRate: TComboBox;
    procedure BtnRunClick(Sender: TObject);
    procedure BtnSelectOutClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
  private
    FSampleRate: Integer;
  end;

var
  MainForm_GUI: TMainForm_GUI;

implementation

{$R *.lfm}

procedure TMainForm_GUI.FormCreate(Sender: TObject);
begin
  LoadCoreConfig;
  ComboBits.Text := IntToStr(CoreConfig.DefaultBits);
  SpinLen.Value := CoreConfig.TruncateLen;
  ComboRate.Text := '0';
end;

procedure TMainForm_GUI.BtnSelectOutClick(Sender: TObject);
begin
  if SaveDlg.Execute then EdOut.Text := SaveDlg.FileName;
end;

procedure TMainForm_GUI.BtnRunClick(Sender: TObject);
var
  A1, A2, Res: TAudioData;
  SR1, SR2, c, TargetSR, bOut: Integer;
begin
  MemoLog.Clear;
  try
    // --- Load input ---
    MemoLog.Lines.Add('Loading input: ' + EdSrc.FileName);
    A1 := LoadWav(EdSrc.FileName, SR1);
    MemoLog.Lines.Add(Format('  %d Hz, %d channels, %d samples', [SR1, Length(A1), Length(A1[0])]));

    // --- Load IR (optional) ---
    if EdIR.FileName <> '' then begin
      MemoLog.Lines.Add('Loading IR: ' + EdIR.FileName);
      A2 := LoadWav(EdIR.FileName, SR2);
      MemoLog.Lines.Add(Format('  %d Hz, %d channels, %d samples', [SR2, Length(A2), Length(A2[0])]));

      // --- Trim silence from IR ---
      if SpinTrim.Value < 0 then begin
        MemoLog.Lines.Add(Format('Trimming silence below %d dB...', [SpinTrim.Value]));
        TrimSilence(A2, SpinTrim.Value);
      end;

      // --- Apply fade to IR ---
      if SpinFade.Value > 0 then begin
        MemoLog.Lines.Add(Format('Applying %d ms fade-out to IR...', [SpinFade.Value]));
        ApplyFades(A2, SR2, 1.0, SpinFade.Value);
      end;

      // --- Resample if needed ---
      TargetSR := StrToIntDef(ComboRate.Text, 0);
      if TargetSR > 0 then begin
        if SR1 <> TargetSR then begin
          MemoLog.Lines.Add(Format('Resampling input: %d -> %d Hz...', [SR1, TargetSR]));
          for c := 0 to High(A1) do A1[c] := ResampleLinear(A1[c], SR1, TargetSR);
          SR1 := TargetSR;
        end;
        if SR2 <> TargetSR then begin
          MemoLog.Lines.Add(Format('Resampling IR: %d -> %d Hz...', [SR2, TargetSR]));
          for c := 0 to High(A2) do A2[c] := ResampleLinear(A2[c], SR2, TargetSR);
          SR2 := TargetSR;
        end;
      end;

      // --- Convolve ---
      MemoLog.Lines.Add('Convolving...');
      SetLength(Res, Min(Length(A1), Length(A2)));
      for c := 0 to High(Res) do begin
        MemoLog.Lines.Add(Format('  Channel %d...', [c + 1]));
        Res[c] := ConvolveFFT(A1[c], A2[c]);
      end;
    end
    else begin
      MemoLog.Lines.Add('No IR specified - passthrough mode');
      Res := A1;
    end;

    // --- Minimum phase ---
    if ChkMinPhase.Checked then begin
      MemoLog.Lines.Add('Converting to minimum phase...');
      for c := 0 to High(Res) do Res[c] := ConvertToMinimumPhase(Res[c]);
    end;

    // --- Normalize ---
    MemoLog.Lines.Add('Normalizing...');
    Normalize(Res);

    // --- Truncate ---
    if SpinLen.Value > 0 then begin
      MemoLog.Lines.Add(Format('Truncating to %d samples...', [SpinLen.Value]));
      TruncateToLength(Res, SpinLen.Value);
    end;

    // --- Save ---
    bOut := StrToIntDef(ComboBits.Text, 24);
    MemoLog.Lines.Add(Format('Saving: %s (%d-bit)...', [EdOut.Text, bOut]));
    SaveWav(EdOut.Text, Res, SR1, bOut, ChkMono.Checked, CoreConfig.Artist);

    MemoLog.Lines.Add('');
    MemoLog.Lines.Add('Success!');
  except
    on E: Exception do
      MemoLog.Lines.Add('Error: ' + E.Message);
  end;
end;

end.