unit resampleengine;

{$MODE OBJFPC}{$H+}

interface

uses
  SysUtils, Classes, Math, dynlibs, dspengine;

type
  TSRC_Engine = (engLinear, engSoxr, engR8Brain, engFinalCD);

  TWavHeader = packed record
    RIFFID, WavID, FmtID: array[0..3] of Char;
    Size, FmtSize: LongInt;
    FormatTag, Channels: Word;
    SampleRate, BytesPerSec: LongInt;
    BlockAlign, BitsPerSample: Word;
    DataID: array[0..3] of Char;
    DataSize: LongInt;
  end;
  
  { REPARIERT: Eine normale prozedurale Signatur ohne 'of object' 
    verhindert jegliche Type-Casting-Fehler unter Linux! }
  TSaveWavCall = procedure(const Fn: string; const D: TAudioData; SR, B: Integer; M: Boolean);

var
  _soxr_create: Pointer = nil;
  _soxr_process: Pointer = nil;
  _soxr_delete: Pointer = nil;
  _r8b_create: Pointer = nil;
  _r8b_process: Pointer = nil;
  _r8b_delete: Pointer = nil;

function GetAvailableEngine: TSRC_Engine;
function LoadWavFromFile(const FileName: string; out SR: Integer): TAudioData;
function ResampleAudio(const Data: TAudioData; InSR, OutSR: Integer; SaveWavProc: TSaveWavCall): TAudioData;

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
  Ratio := InSR / OutSR; 
  NewLength := Round(Length(Channel) * (OutSR / InSR));
  SetLength(Result, NewLength);
  for i := 0 to NewLength - 1 do begin
    Position := i * Ratio; 
    SrcIdx := Floor(Position); 
    Weight := Position - SrcIdx;
    if SrcIdx >= High(Channel) then Result[i] := Channel[High(Channel)]
    else Result[i] := (Channel[SrcIdx] * (1.0 - Weight)) + (Channel[SrcIdx + 1] * Weight);
  end;
end;
function ResampleViaFinalCD(const Channel: TFloatBuffer; InSR, OutSR: Integer; SaveWavProc: TSaveWavCall): TFloatBuffer;
var 
  TmpIn, TmpOut: string; 
  DummyData: TAudioData;
begin
  TmpIn := 'tmp_src_in.wav'; TmpOut := 'tmp_src_out.wav';
  SetLength(DummyData, 1); 
  DummyData[0] := Channel;
  
  { Nativer, fehlerfreier Funktionsaufruf ohne unzulässiges Type-Casting }
  SaveWavProc(TmpIn, DummyData, InSR, 32, False);
  
  {$IFDEF WINDOWS} ExecuteProcess('finalcd.exe', [TmpIn, TmpOut, IntToStr(OutSR)]); {$ENDIF}
  {$IFDEF UNIX} ExecuteProcess('./finalcd', [TmpIn, TmpOut, IntToStr(OutSR)]); {$ENDIF}
  
  if FileExists(TmpOut) then begin
    DeleteFile(TmpOut);
  end;
  DeleteFile(TmpIn);
  Result := ResampleLinear(Channel, InSR, OutSR);
end;

function LoadWavFromFile(const FileName: string; out SR: Integer): TAudioData;
var FS: TFileStream; H: TWavHeader; i, c, Samples, BytesPerSample: Integer;
    s16: SmallInt; b24: array[0..2] of Byte; s32: LongInt; f32: Single; b8: Byte;
begin
  Result := nil;
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    FS.Read(H, SizeOf(H));
    SR := H.SampleRate;
    BytesPerSample := H.BitsPerSample div 8;
    if (BytesPerSample = 0) or (H.Channels = 0) then Exit;
    Samples := H.DataSize div (H.Channels * BytesPerSample);
    SetLength(Result, H.Channels);
    for c := 0 to H.Channels - 1 do
      SetLength(Result[c], Samples);
    for i := 0 to Samples - 1 do
    begin
      for c := 0 to H.Channels - 1 do
      begin
        case H.BitsPerSample of
          8:
          begin
            FS.Read(b8, 1);
            Result[c][i] := (b8 - 128) / 128.0;
          end;
          16:
          begin
            FS.Read(s16, 2);
            Result[c][i] := s16 / 32768.0;
          end;
          24:
          begin
            FS.Read(b24, 3);
            s32 := b24[0] or (b24[1] shl 8) or (b24[2] shl 16);
            if (s32 and $800000) <> 0 then
              s32 := s32 or $FF000000;
            Result[c][i] := s32 / 8388608.0;
          end;
          32:
          begin
            FS.Read(f32, 4);
            Result[c][i] := f32;
          end;
        else
          Result[c][i] := 0.0;
        end;
      end;
    end;
  finally
    FS.Free;
  end;
end;

function ResampleAudio(const Data: TAudioData; InSR, OutSR: Integer; SaveWavProc: TSaveWavCall): TAudioData;
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
        TProcessSoxr(_soxr_process)(resampler, @Data[c], InLen, @DoneIn, @Result[c], OutLen, @DoneOut);
        SetLength(Result[c], DoneOut); TDeleteSoxr(_soxr_delete)(resampler);
      end;
      engR8Brain: begin
        r8bInstance := TCreateR8B(_r8b_create)(InSR, OutSR, Length(Data[c]), 2, 0);
        OutLen := Round(Length(Data[c]) * (OutSR / InSR)) + 100; SetLength(Result[c], OutLen);
        DoneOut := TProcessR8B(_r8b_process)(r8bInstance, @Data[c], Length(Data[c]), R8BOutBuf);
        if DoneOut > 0 then begin Move(R8BOutBuf^, Result[c][0], DoneOut * 4); SetLength(Result[c], DoneOut); end;
        TDeleteR8B(_r8b_delete)(r8bInstance);
      end;
    end;
  end;
end;

end.
