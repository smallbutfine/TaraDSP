unit resampleengine;

{$MODE OBJFPC}{$H+}

interface

uses
  SysUtils, Classes, Math, dynlibs, dspengine;

type 
  // Definiert den Methodenzeiger exakt als prozedurale Objekt-Variable
  TSaveWavCall = procedure(const Fn: string; const D: TAudioData; SR, B: Integer; M: Boolean) of object;
  TSRC_Engine = (engLinear, engSoxr, engR8Brain, engFinalCD);

var
  _soxr_create: Pointer = nil;
  _soxr_process: Pointer = nil;
  _soxr_delete: Pointer = nil;
  _r8b_create: Pointer = nil;
  _r8b_process: Pointer = nil;
  _r8b_delete: Pointer = nil;

function GetAvailableEngine: TSRC_Engine;
function ResampleAudio(const Data: TAudioData; InSR, OutSR: Integer; SaveWavProc: Pointer): TAudioData;

implementation

function GetAvailableEngine: TSRC_Engine;
begin
  if FileExists('finalcd.exe') or FileExists('finalcd') then Exit(engFinalCD);
  if Assigned(_r8b_create) then Exit(engR8Brain);
  if Assigned(_soxr_create) then Exit(engSoxr);
  Result := engLinear;
end;

function ResampleLinear(const Channel: TFloatBuffer; InSR, OutSR: Integer): TFloatBuffer;
var i, NewLength, SrcIdx: Integer; Ratio, Position, Weight: Double;
begin
  if Length(Channel) = 0 then Exit(nil);
  Ratio := InSR / OutSR; NewLength := Round(Length(Channel) * (OutSR / InSR));
  SetLength(Result, NewLength);
  for i := 0 to NewLength - 1 do begin
    Position := i * Ratio; SrcIdx := Floor(Position); Weight := Position - SrcIdx;
    if SrcIdx >= High(Channel) then Result[i] := Channel[High(Channel)]
    else Result[i] := (Channel[SrcIdx] * (1.0 - Weight)) + (Channel[SrcIdx + 1] * Weight);
  end;
end;

type TSaveWavCall = procedure(const Fn: string; const D: TAudioData; SR, B: Integer; M: Boolean) of object;

function ResampleViaFinalCD(const Channel: TFloatBuffer; InSR, OutSR: Integer; SaveWavProc: Pointer): TFloatBuffer;
function ResampleViaFinalCD(const Channel: TFloatBuffer; InSR, OutSR: Integer; SaveWavProc: Pointer): TFloatBuffer;
var 
  TmpIn, TmpOut: string; 
  DummyData: TAudioData;
  MethodCall: TSaveWavCall;
begin
  TmpIn := 'tmp_src_in.wav'; TmpOut := 'tmp_src_out.wav';
  SetLength(DummyData, 1); DummyData := Channel;
  
  // FEHLER BEHOBEN: Wir mappen den rohen Datenpointer absolut typensicher 
  // über ein internes TMethod-Konstrukt auf den Pascal-Methodenaufruf.
  TMethod(MethodCall) := TMethod(SaveWavProc^);
  MethodCall(TmpIn, DummyData, InSR, 32, False);
  
  {$IFDEF WINDOWS} ExecuteProcess('finalcd.exe', [TmpIn, TmpOut, IntToStr(OutSR)]); {$ENDIF}
  {$IFDEF UNIX} ExecuteProcess('./finalcd', [TmpIn, TmpOut, IntToStr(OutSR)]); {$ENDIF}
  
  DeleteFile(TmpIn); DeleteFile(TmpOut);
  Result := ResampleLinear(Channel, InSR, OutSR);
end;

function ResampleAudio(const Data: TAudioData; InSR, OutSR: Integer; SaveWavProc: Pointer): TAudioData;
var Engine: TSRC_Engine; c, InLen, OutLen, DoneIn, DoneOut: Integer; resampler, r8bInstance: Pointer; R8BOutBuf: PSingle;
type
  TCreateSoxr = function(i, o: Double; n: Cardinal; e, io, q, r: Pointer): Pointer; cdecl;
  TProcessSoxr = function(r: Pointer; ib: PSingle; il: Cardinal; di: Pointer; ob: PSingle; ol: Cardinal; do_out: Pointer): Integer; cdecl;
  TDeleteSoxr = procedure(r: Pointer); cdecl;
  TCreateR8B = function(i, o: Double; m, r: Integer; res: Integer): Pointer; cdecl;
  TProcessR8B = function(i: Pointer; ib: PSingle; il: Integer; out ob: PSingle): Integer; cdecl;
  TDeleteR8B = procedure(i: Pointer); cdecl;
begin
  if InSR = OutSR then begin Result := Data; Exit; end;
  SetLength(Result, Length(Data)); Engine := GetAvailableEngine;
  for c := 0 to High(Data) do begin
    case Engine of
      engLinear:  Result[c] := ResampleLinear(Data[c], InSR, OutSR);
      engFinalCD: Result[c] := ResampleViaFinalCD(Data[c], InSR, OutSR, SaveWavProc);
      engSoxr: begin
        InLen := Length(Data[c]); OutLen := Round(InLen * (OutSR / InSR)) + 1000; SetLength(Result[c], OutLen);
        resampler := TCreateSoxr(_soxr_create)(InSR, OutSR, 1, nil, nil, nil, nil);
        TProcessSoxr(_soxr_process)(resampler, @Data[c][0], InLen, @DoneIn, @Result[c][0], OutLen, @DoneOut);
        SetLength(Result[c], DoneOut); TDeleteSoxr(_soxr_delete)(resampler);
      end;
      engR8Brain: begin
        r8bInstance := TCreateR8B(_r8b_create)(InSR, OutSR, Length(Data[c]), 2, 0);
        OutLen := Round(Length(Data[c]) * (OutSR / InSR)) + 100; SetLength(Result[c], OutLen);
        DoneOut := TProcessR8B(_r8b_process)(r8bInstance, @Data[c][0], Length(Data[c]), R8BOutBuf);
        if DoneOut > 0 then begin Move(R8BOutBuf^, Result[c][0], DoneOut * 4); SetLength(Result[c], DoneOut); end;
        TDeleteR8B(_r8b_delete)(r8bInstance);
      end;
    end;
  end;
end;

end.
