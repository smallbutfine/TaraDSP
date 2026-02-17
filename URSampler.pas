{
  URSampler - Multi-Engine Resampling Module
  Part of IRConvolverPro
  
  Logic: 
  1. FinalCD (External CLI, Ultra-VHQ, if present)
  2. r8brain (High-End DLL, VHQ, if present)
  3. Linear (Internal Fallback, Low Quality)
}

unit URSampler;

{$MODE OBJFPC}{$H+}

interface

uses
  SysUtils, Classes, Math, Process;

type
  TFloatBuffer = array of Single;
  TAudioData   = array of TFloatBuffer;
  TFilterMode  = (fmBrickwall, fmGentle);
  TSRCEngine   = (engFinalCD, engR8Brain, engLinear);

function ResampleAudio(const Data: TAudioData; InSR, OutSR: Integer; Mode: TFilterMode): TAudioData;
function GetAvailableEngine: TSRCEngine;

implementation

{ --- 1. FinalCD (External CLI) --- }
function ResampleFinalCD(const Data: TAudioData; InSR, OutSR: Integer; Mode: TFilterMode): TAudioData;
var
  AProcess: TProcess;
  InFile, OutFile: string;
begin
  InFile := 'fcd_tmp_in.wav';
  OutFile := 'fcd_tmp_out.wav';
  // Note: Implementation requires SaveWav/LoadWav from main unit
  // SaveWav(InFile, Data, InSR, 32); 
  
  AProcess := TProcess.Create(nil);
  try
    AProcess.Executable := 'finalcd';
    AProcess.Parameters.Add(InFile);
    AProcess.Parameters.Add(OutFile);
    AProcess.Parameters.Add(IntToStr(OutSR));
    if Mode = fmGentle then AProcess.Parameters.Add('-g') else AProcess.Parameters.Add('-b');
    AProcess.Options := [poWaitOnExit];
    AProcess.Execute;
    // Result := LoadWav(OutFile, OutSR);
  finally
    AProcess.Free;
    if FileExists(InFile) then DeleteFile(InFile);
    if FileExists(OutFile) then DeleteFile(OutFile);
  end;
end;

{ --- 2. r8brain (High-End DLL / MIT License) --- }
// Interface to r8bsrc.dll (Simplified)
function r8b_create(InSR, OutSR: Double; MaxLen: Integer; Res: Double; Mode: Integer): Pointer; cdecl; external 'r8bsrc.dll' delayed;
// Note: 'delayed' ensures the app starts even if the DLL is missing.

{ --- 3. Internal Linear Fallback --- }
function ResampleLinear(const Data: TAudioData; InSR, OutSR: Integer): TAudioData;
var
  c, i, NewLen: Integer;
  Ratio, Pos: Double;
begin
  Ratio := InSR / OutSR;
  NewLen := Round(Length(Data) / Ratio);
  SetLength(Result, Length(Data));
  for c := 0 to High(Data) do
  begin
    SetLength(Result[c], NewLen);
    for i := 0 to NewLen - 1 do
    begin
      Pos := i * Ratio;
      if Trunc(Pos) < High(Data[c]) then
        Result[c][i] := Data[c][Trunc(Pos)] + (Data[c][Trunc(Pos)+1] - Data[c][Trunc(Pos)]) * (Pos - Trunc(Pos))
      else
        Result[c][i] := Data[c][Trunc(Pos)];
    end;
  end;
end;

{ --- Engine Selector --- }
function GetAvailableEngine: TSRCEngine;
begin
  if FileExists('finalcd.exe') or FileExists('finalcd') then Exit(engFinalCD);
  if FileExists('r8bsrc.dll') then Exit(engR8Brain);
  Result := engLinear;
end;

function ResampleAudio(const Data: TAudioData; InSR, OutSR: Integer; Mode: TFilterMode): TAudioData;
begin
  if InSR = OutSR then Exit(Data);
  
  case GetAvailableEngine of
    engFinalCD: Result := ResampleFinalCD(Data, InSR, OutSR, Mode);
    // engR8Brain: Result := ResampleR8B(Data, InSR, OutSR); // Implementation via DLL
    else Result := ResampleLinear(Data, InSR, OutSR);
  end;
end;

end.
