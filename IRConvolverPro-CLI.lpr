program IRConvolverPro_CLI;

{$MODE OBJFPC}{$H+}

uses
  SysUtils, CustApp, UIRCore, Math, Diagnostics;

type
  TIRConvolverCLI = class(TCustomApplication)
  protected
    procedure DoRun; override;
  public
    procedure ShowUsage;
  end;

procedure TIRConvolverCLI.ShowUsage;
begin
  WriteLn('IRConvolverPro-CLI v1.2');
  WriteLn('Usage: -i1 <src> [-i2 <ir>] -o <out> [-b bits] [-l len]');
end;

procedure TIRConvolverCLI.DoRun;
var A1, A2, Res: TAudioData; SR1, SR2, bOut, c: Integer; SW: TStopwatch;
begin
  DetectCPUFeatures;
  WriteLn('--- Hardware Diagnostics ---');
  WriteLn('CPU: ', CPUCaps.CPUName);
  Write('Features: ');
  if CPUCaps.HasSSE then Write('SSE ');
  if CPUCaps.HasSSE2 then Write('SSE2 ');
  if CPUCaps.HasAVX then Write('AVX ');
  WriteLn;
  
  if not CPUCaps.HasSSE then
  begin
    WriteLn(StdErr, 'Warning: Your CPU does not support SSE. PFFFT may fail!');
  end;
  WriteLn('----------------------------');
  LoadCoreConfig;
  if HasOption('h', 'help') or not HasOption('i1') or not HasOption('o') then begin ShowUsage; Terminate; Exit; end;
  
  bOut := StrToIntDef(GetOptionValue('b', 'bits'), CoreConfig.DefaultBits);
  SW := TStopwatch.StartNew;
  try
    A1 := LoadWav(GetOptionValue('i1'), SR1);
    if HasOption('i2') then begin
      A2 := LoadWav(GetOptionValue('i2'), SR2);
      SetLength(Res, Min(Length(A1), Length(A2)));
      for c := 0 to High(Res) do Res[c] := ConvolveFFT(A1[c], A2[c]);
    end else Res := A1;

    Normalize(Res);
    if HasOption('l') then TruncateToLength(Res, StrToInt(GetOptionValue('l')));
    
    SaveWav(GetOptionValue('o'), Res, SR1, bOut, HasOption('m'), CoreConfig.Artist);
    WriteLn('Success! Time: ', SW.ElapsedMilliseconds, ' ms');
    Terminate(0);
  except on E: Exception do begin WriteLn(StdErr, 'Error: ', E.Message); Terminate(1); end; end;
end;

var App: TIRConvolverCLI;
begin App := TIRConvolverCLI.Create(nil); App.Run; App.Free; end.
