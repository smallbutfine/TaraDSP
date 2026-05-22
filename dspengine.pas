unit dspengine;

{$MODE OBJFPC}{$H+}

interface

uses
  SysUtils, Classes, Math;

type
  TFloatBuffer  = array of Single;
  TAudioData    = array of TFloatBuffer;
  PPFFFT_Setup  = Pointer;

{ DSP-Kernfunktionen exportieren }
procedure ApplyFades(var Data: TAudioData; SR: Integer; InMS, OutMS: Single);
procedure TrimSilence(var Data: TAudioData; ThresholdDB: Single);

implementation

procedure ApplyFades(var Data: TAudioData; SR: Integer; InMS, OutMS: Single);
var c, i, InSamples, OutSamples, TotalSamples: Integer; Gain: Single;
begin
  if Length(Data) = 0 then Exit;
  TotalSamples := Length(Data[0]);
  InSamples := Round((InMS / 1000.0) * SR); 
  OutSamples := Round((OutMS / 1000.0) * SR); 
  if (InSamples + OutSamples) > TotalSamples then begin InSamples := TotalSamples div 2; OutSamples := TotalSamples div 2; end;
  for c := 0 to High(Data) do begin
    if InSamples > 0 then for i := 0 to InSamples - 1 do begin Gain := i / InSamples; Data[c][i] := Data[c][i] * Gain; end;
    if OutSamples > 0 then for i := 0 to OutSamples - 1 do begin Gain := 1.0 - (i / OutSamples); Data[c][TotalSamples - OutSamples + i] := Data[c][TotalSamples - OutSamples + i] * Gain; end;
  end;
end;

procedure TrimSilence(var Data: TAudioData; ThresholdDB: Single);
var c, i, StartIdx, EndIdx, CurrentLength, NewLength: Integer; Limit, AbsoluteValue: Single;
begin
  if Length(Data) = 0 then Exit;
  Limit := Power(10.0, ThresholdDB / 20.0);
  CurrentLength := Length(Data[0]); StartIdx := CurrentLength; EndIdx := 0;
  for c := 0 to High(Data) do begin
    for i := 0 to CurrentLength - 1 do begin
      AbsoluteValue := Abs(Data[c][i]);
      if AbsoluteValue > Limit then begin if i < StartIdx then StartIdx := i; break; end;
    end;
    for i := CurrentLength - 1 downto 0 do begin
      AbsoluteValue := Abs(Data[c][i]);
      if AbsoluteValue > Limit then begin if i > EndIdx then EndIdx := i; break; end;
    end;
  end;
  if StartIdx > EndIdx then begin StartIdx := 0; EndIdx := 0; end;
  NewLength := (EndIdx - StartIdx) + 1;
  for c := 0 to High(Data) do begin
    if StartIdx > 0 then Move(Data[c][StartIdx], Data[c][0], NewLength * 4);
    SetLength(Data[c], NewLength);
  end;
end;

end.
