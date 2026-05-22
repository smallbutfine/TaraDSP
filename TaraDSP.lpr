program TaraDSP;

{$MODE OBJFPC}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WINDOWS}Windows, dynlibs,{$ENDIF}
  {$IFDEF DARWIN}dynlibs,{$ENDIF}
  SysUtils, Classes, Math, CustApp, IniFiles, dspengine, resampleengine;

const
  {$IFDEF WINDOWS} 
    LIB_SOXR = 'libsoxr.dll'; 
  {$ELSE}
    {$IFDEF DARWIN} 
      LIB_SOXR = 'libsoxr.dylib'; 
    {$ELSE} 
      LIB_SOXR = 'libsoxr.so.0'; 
    {$ENDIF}
  {$ENDIF}
  
  PFFFT_FORWARD = 0; 
  PFFFT_BACKWARD = 1;

type
  TWavHeader = packed record
    RIFFID, WavID, FmtID: array[0..3] of Char; 
    Size, FmtSize: LongInt;
    FormatTag, Channels: Word; 
    SampleRate, BytesPerSec: LongInt;
    BlockAlign, BitsPerSample: Word; 
    DataID: array[0..3] of Char; 
    DataSize: LongInt;
  end;

  TTaraDSPApp = class(TCustomApplication)
  private
    FErrorMem: array of Single;
    FArtist: string;
    procedure LoadConfig;
    function  LogExtract(Value: Single): Single; inline;
    function  LoadWav(const FileName: string; out SR: Integer): TAudioData;
    function  ApplyMasteringDither(Sample: Single; Chan: Integer; Amount: Single): Single;
    procedure ResetMasteringEngine(Channels: Integer);
    procedure Normalize(var Data: TAudioData);
    procedure WriteInfoChunk(Stream: TStream; const ID: string; const Value: string);
    procedure ShowUsage;
  public
    procedure SaveWav(const FileName: string; const Data: TAudioData; SR, Bits: Integer; ForceMono: Boolean);
    function  ConvolveFFT(const Sig, Ker: TFloatBuffer): TFloatBuffer;
    function  ConvertToMinimumPhase(const Data: TFloatBuffer): TFloatBuffer;
  protected
    procedure DoRun; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

type
  TPffftNew = function(N: Integer; t: Integer): Pointer; cdecl;
  TPffftDst = procedure(s: Pointer); cdecl;
  TPffftTrf = procedure(s: Pointer; input, output, work: PSingle; d: Integer); cdecl;
  TPffftZCn = procedure(s: Pointer; a, b, ab: PSingle; scaling: Single); cdecl;
  TPffftMal = function(b: NativeUInt): Pointer; cdecl;
  TPffftFre = procedure(p: Pointer); cdecl;

var
  _pffft_new_setup: TPffftNew = nil;
  _pffft_destroy_setup: TPffftDst = nil;
  _pffft_transform_ordered: TPffftTrf = nil;
  _pffft_zconvolve_accumulate: TPffftZCn = nil;
  _pffft_aligned_malloc: TPffftMal = nil;
  _pffft_aligned_free: TPffftFre = nil;
procedure InitDynamicLibraries;
var SHandle, PHandle, RHandle: TLibHandle;
begin
  SHandle := LoadLibrary(LIB_SOXR);
  if SHandle <> NilHandle then begin
    _soxr_create := GetProcAddress(SHandle, 'soxr_create');
    _soxr_process := GetProcAddress(SHandle, 'soxr_process');
    _soxr_delete := GetProcAddress(SHandle, 'soxr_delete');
  end;
  PHandle := NilHandle;
  {$IFDEF WINDOWS}
  PHandle := LoadLibrary('libpffft.dll');
  RHandle := LoadLibrary('r8bsrc.dll');
  if RHandle <> NilHandle then begin
    _r8b_create := GetProcAddress(RHandle, 'r8b_create');
    _r8b_process := GetProcAddress(RHandle, 'r8b_process');
    _r8b_delete := GetProcAddress(RHandle, 'r8b_delete');
  end;
  {$ENDIF}
  {$IFDEF DARWIN} PHandle := LoadLibrary('libpffft.dylib'); {$ENDIF}
  if PHandle <> NilHandle then begin
    _pffft_new_setup := TPffftNew(GetProcAddress(PHandle, 'pffft_new_setup'));
    _pffft_destroy_setup := TPffftDst(GetProcAddress(PHandle, 'pffft_destroy_setup'));
    _pffft_transform_ordered := TPffftTrf(GetProcAddress(PHandle, 'pffft_transform_ordered'));
    _pffft_zconvolve_accumulate := TPffftZCn(GetProcAddress(PHandle, 'pffft_zconvolve_accumulate'));
    _pffft_aligned_malloc := TPffftMal(GetProcAddress(PHandle, 'pffft_aligned_malloc'));
    _pffft_aligned_free := TPffftFre(GetProcAddress(PHandle, 'pffft_aligned_free'));
  end;
end;

constructor TTaraDSPApp.Create(AOwner: TComponent);
begin inherited Create(AOwner); Randomize; InitDynamicLibraries; end;

procedure TTaraDSPApp.LoadConfig;
begin FArtist := GetOptionValue('x', 'in1'); end;

function TTaraDSPApp.LogExtract(Value: Single): Single; inline;
begin if Value < 1e-10 then Value := 1e-10; Result := Ln(Value); end;

procedure TTaraDSPApp.ResetMasteringEngine(Channels: Integer);
var i: Integer;
begin
  SetLength(FErrorMem, Channels * 2);
  for i := 0 to High(FErrorMem) do FErrorMem[i] := 0.0;
end;

function TTaraDSPApp.ApplyMasteringDither(Sample: Single; Chan: Integer; Amount: Single): Single;
var Dither, ResVal, Error, LSB: Single; Idx: Integer;
begin
  LSB := 1.0 / 32767.0; 
  Dither := ((Random - 0.5) + (Random - 0.5)) * LSB * Amount;
  if Abs(Sample) < (LSB * 2) then Dither := Dither * 0.7;
  
  Idx := Chan * 2;
  ResVal := Sample + Dither + (FErrorMem[Idx] * 1.5) - (FErrorMem[Idx + 1] * 0.5);
  ResVal := EnsureRange(ResVal, -1.0, 1.0); 
  ResVal := Round(ResVal * 32767) / 32767.0;

  Error := Sample - ResVal; 
  FErrorMem[Idx + 1] := FErrorMem[Idx]; 
  FErrorMem[Idx] := Error;
  Result := ResVal;
end;
function TTaraDSPApp.LoadWav(const FileName: string; out SR: Integer): TAudioData;
var FS: TFileStream; H: TWavHeader; i, c, Samples: Integer; s16: SmallInt; b24: array[0..2] of Byte; s32: LongInt;
begin
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    FS.Read(H, SizeOf(H)); 
    SR := H.SampleRate; 
    Samples := H.DataSize div (H.Channels * (H.BitsPerSample div 8));
    SetLength(Result, H.Channels); 
    for c := 0 to H.Channels - 1 do 
    begin
      SetLength(Result[c], Samples);
    end;
    for i := 0 to Samples - 1 do 
    begin
      for c := 0 to H.Channels - 1 do 
      begin
        if H.BitsPerSample = 16 then 
        begin 
          FS.Read(s16, 2); 
          Result[c][i] := s16 / 32768.0; 
        end
        else 
        begin
          FS.Read(b24, 3);
          s32 := b24[0] or (b24[1] shl 8) or (b24[2] shl 16);
          if (s32 and $800000) <> 0 then 
          begin
            s32 := s32 or $FF000000;
          end;
          Result[c][i] := s32 / 8388608.0;
        end;
      end;
    end;
  finally 
    FS.Free; 
  end;
end;

procedure TTaraDSPApp.SaveWav(const FileName: string; const Data: TAudioData; SR, Bits: Integer; ForceMono: Boolean);
var FS: TFileStream; H: TWavHeader; i, c, OutChans: Integer; s16: SmallInt; s32: LongInt; b24: array[0..2] of Byte;
begin
  if Length(Data) = 0 then Exit; 
  OutChans := IfThen(ForceMono, 1, Length(Data)); 
  FillChar(H, SizeOf(H), 0);
  H.RIFFID := 'RIFF'; H.WavID := 'WAVE'; H.FmtID := 'fmt '; H.FmtSize := 16; H.FormatTag := 1;
  H.Channels := OutChans; H.SampleRate := SR; H.BitsPerSample := Bits; H.BlockAlign := H.Channels * (Bits div 8);
  H.BytesPerSec := SR * H.BlockAlign; H.DataID := 'data'; H.DataSize := Length(Data[0]) * H.BlockAlign; H.Size := 36 + H.DataSize;
  ResetMasteringEngine(OutChans); 
  FS := TFileStream.Create(FileName, fmCreate);
  try
    FS.Write(H, SizeOf(H));
    for i := 0 to High(Data[0]) do 
    begin
      for c := 0 to OutChans - 1 do 
      begin
        if Bits = 16 then 
        begin 
          s16 := Round(ApplyMasteringDither(Data[c][i], c, 1.0) * 32767); 
          FS.Write(s16, 2); 
        end
        else 
        begin 
          s32 := Round(EnsureRange(Data[c][i], -1.0, 1.0) * 8388607); 
          b24[0] := s32 and $FF; 
          b24[1] := (s32 shr 8) and $FF; 
          b24[2] := (s32 shr 16) and $FF; 
          FS.Write(b24, 3); 
        end;
      end;
    end;
    if FArtist <> '' then 
    begin
      WriteInfoChunk(FS, 'IART', FArtist);
    end;
  finally 
    FS.Free; 
  end;
end;

procedure TTaraDSPApp.WriteInfoChunk(Stream: TStream; const ID: string; const Value: string);
var Len: LongInt; Zero: Char = #0;
begin
  if Length(Value) = 0 then Exit; 
  Stream.Write(ID[1], 4); 
  Len := Length(Value) + 1; 
  Stream.Write(Len, 4);
  Stream.Write(Value[1], Length(Value)); 
  Stream.Write(Zero, 1); 
  if (Len mod 2 <> 0) then 
  begin
    Stream.Write(Zero, 1);
  end;
end;

procedure TTaraDSPApp.Normalize(var Data: TAudioData);
var m: Single; c, i: Integer;
begin
  m := 0; 
  for c := 0 to High(Data) do 
  begin
    for i := 0 to High(Data[c]) do 
    begin
      m := Max(m, Abs(Data[c][i]));
    end;
  end;
  if m > 1e-7 then 
  begin
    for c := 0 to High(Data) do 
    begin
      for i := 0 to High(Data[c]) do 
      begin
        Data[c][i] := Data[c][i] / m;
      end;
    end;
  end;
end;
function TTaraDSPApp.ConvolveFFT(const Sig, Ker: TFloatBuffer): TFloatBuffer;
var setup: Pointer; n, i, L1, L2: Integer; in1, in2, f1, f2, fRes, work: PSingle;
begin
  L1 := Length(Sig); L2 := Length(Ker); n := 1; while n < (L1 + L2 - 1) do n := n shl 1;
  setup := _pffft_new_setup(n, 0); in1 := _pffft_aligned_malloc(n * 4); in2 := _pffft_aligned_malloc(n * 4);
  f1 := _pffft_aligned_malloc(n * 4); f2 := _pffft_aligned_malloc(n * 4); fRes := _pffft_aligned_malloc(n * 4); work := _pffft_aligned_malloc(n * 4);
  try
    FillChar(in1^, n * 4, 0); FillChar(in2^, n * 4, 0); 
    if L1 > 0 then Move(Sig, in1^, L1 * 4); 
    if L2 > 0 then Move(Ker, in2^, L2 * 4);
    _pffft_transform_ordered(setup, in1, f1, work, PFFFT_FORWARD); 
    _pffft_transform_ordered(setup, in2, f2, work, PFFFT_FORWARD);
    _pffft_zconvolve_accumulate(setup, f1, f2, fRes, 1.0); 
    _pffft_transform_ordered(setup, fRes, in1, work, PFFFT_BACKWARD);
    SetLength(Result, L1 + L2 - 1); 
    for i := 0 to High(Result) do 
    begin
      Result[i] := in1[i] / n;
    end;
  finally 
    _pffft_aligned_free(in1); _pffft_aligned_free(in2); _pffft_aligned_free(f1);
    _pffft_aligned_free(f2); _pffft_aligned_free(fRes); _pffft_aligned_free(work); 
    _pffft_destroy_setup(setup); 
  end;
end;

function TTaraDSPApp.ConvertToMinimumPhase(const Data: TFloatBuffer): TFloatBuffer;
var setup: Pointer; n, i, HalfN: Integer; inOut, spec, work: PSingle; Mag, Phase: Single;
begin
  if Length(Data) = 0 then Exit(nil); n := 1; while n < (Length(Data) * 2) do n := n shl 1; HalfN := n div 2;
  setup := _pffft_new_setup(n, 0); inOut := _pffft_aligned_malloc(n * 4); spec := _pffft_aligned_malloc(n * 4); work := _pffft_aligned_malloc(n * 4);
  try
    FillChar(inOut^, n * 4, 0); Move(Data, inOut^, Length(Data) * 4); _pffft_transform_ordered(setup, inOut, spec, work, PFFFT_FORWARD);
    spec[0] := LogExtract(Abs(spec[0])); spec[1] := LogExtract(Abs(spec[1]));
    for i := 1 to HalfN - 1 do 
    begin 
      Mag := Sqrt(Sqr(spec[2*i]) + Sqr(spec[2*i+1])); Mag := LogExtract(Mag); 
      spec[2*i] := Mag; spec[2*i+1] := 0.0; 
    end;
    _pffft_transform_ordered(setup, spec, inOut, work, PFFFT_BACKWARD); 
    for i := 0 to n - 1 do 
    begin
      inOut[i] := inOut[i] / n;
    end;
    for i := 1 to HalfN - 1 do 
    begin 
      inOut[i] := inOut[i] * 2.0; inOut[n-i] := 0.0; 
    end;
    _pffft_transform_ordered(setup, inOut, spec, work, PFFFT_FORWARD); 
    spec[0] := Exp(spec[0]); spec[1] := Exp(spec[1]);
    for i := 1 to HalfN - 1 do 
    begin 
      Mag := Exp(spec[2*i]); Phase := spec[2*i+1]; 
      spec[2*i] := Mag * Cos(Phase); spec[2*i+1] := Mag * Sin(Phase); 
    end;
    _pffft_transform_ordered(setup, spec, inOut, work, PFFFT_BACKWARD); 
    SetLength(Result, Length(Data)); 
    for i := 0 to High(Result) do 
    begin
      Result[i] := inOut[i] / n;
    end;
  finally 
    _pffft_aligned_free(inOut); _pffft_aligned_free(spec); _pffft_aligned_free(work); _pffft_destroy_setup(setup); 
  end;
end;

procedure ToBridgeSaveWav(const Fn: string; const D: TAudioData; SR, B: Integer; M: Boolean);
begin
  if CustomApplication <> nil then
  begin
    if CustomApplication is TTaraDSPApp then
    begin
      // REPARIERT: Übergibt die Audio-Daten als vollständiges TAudioData-Array
      TTaraDSPApp(CustomApplication).SaveWav(Fn, D, SR, B, M);
    end;
  end;
end;

procedure TTaraDSPApp.DoRun;
var StartTime: Int64; f1, f2, fOut, Msg: string; A1, A2, Res: TAudioData; SR1, SR2, bOut, c, TargetSR, TruncLen: Integer;
begin
  LoadConfig; Msg := CheckOptions('x:y:o:b:r:l:f:t:h m', 'help mono min in1 in2');
  if (Msg <> '') or HasOption('h', 'help') or (ParamCount < 2) then begin ShowUsage; ExitCode := 1; Terminate; Exit; end;
  if HasOption('x', 'in1') then f1 := GetOptionValue('x', 'in1') else f1 := GetOptionValue('x');
  if HasOption('y', 'in2') then f2 := GetOptionValue('y', 'in2') else f2 := GetOptionValue('y');
  fOut := GetOptionValue('o'); bOut := StrToIntDef(GetOptionValue('b', 'bits'), 24); TargetSR := StrToIntDef(GetOptionValue('r', 'rate'), 0); TruncLen := StrToIntDef(GetOptionValue('l'), 0);
  StartTime := GetTickCount64;
  try
    A1 := LoadWav(f1, SR1); 
    if f2 <> '' then 
    begin
      A2 := LoadWav(f2, SR2); 
    end 
    else 
    begin 
      SetLength(A2, Length(A1)); 
      for c := 0 to High(A2) do 
      begin 
        SetLength(A2[c], 1);
         // FIX: Der Index [0] ist jetzt über feste Zeichenketten erzwungen
        A2[c][0] := 1.0;
      end; 
      SR2 := SR1; 
    end;
    if HasOption('t') then TrimSilence(A2, -Abs(StrToFloatDef(GetOptionValue('t'), -70.0, DefaultFormatSettings)));
    if HasOption('f') then ApplyFades(A2, SR2, 1.0, StrToFloatDef(GetOptionValue('f'), 10.0, DefaultFormatSettings));
    if (TargetSR > 0) then 
    begin 
      if SR1 <> TargetSR then A1 := ResampleAudio(A1, SR1, TargetSR, @ToBridgeSaveWav); 
      if SR2 <> TargetSR then A2 := ResampleAudio(A2, SR2, TargetSR, @ToBridgeSaveWav); 
      SR1 := TargetSR; 
    end
    else if SR1 <> SR2 then 
    begin 
      A2 := ResampleAudio(A2, SR2, SR1, @ToBridgeSaveWav); 
    end;
    if (TruncLen > 0) then 
    begin 
      for c := 0 to High(A1) do if Length(A1[c]) > TruncLen then SetLength(A1[c], TruncLen); 
      for c := 0 to High(A2) do if Length(A2[c]) > TruncLen then SetLength(A2[c], TruncLen); 
    end;
    SetLength(Res, Min(Length(A1), Length(A2))); 
    for c := 0 to High(Res) do 
    begin
      Res[c] := ConvolveFFT(A1[c], A2[c]);
    end;
    if HasOption('min') then 
    begin
      for c := 0 to High(Res) do 
      begin
        Res[c] := ConvertToMinimumPhase(Res[c]);
      end;
    end;
    Normalize(Res); 
    SaveWav(fOut, Res, SR1, bOut, HasOption('m', 'mono'));
    WriteLn(Format('Success! Processing Time: %d ms', [GetTickCount64 - StartTime])); ExitCode := 0; Terminate;
  except on E: Exception do begin WriteLn(StdErr, 'Error: ', E.Message); ExitCode := 1; Terminate; end; end;
end;

procedure TTaraDSPApp.ShowUsage;
begin
  WriteLn('TaraDSP v1.0 [BSD-3-Clause]'); WriteLn('Usage: -x <src> -y <ir> -o <out> [options]');
  WriteLn('Options:  -b <16|24|32> Bit depth; -r <rate> Resampling; -t <db> Trim; -f <ms> Fades; --min Minimum Phase; -m Mono');
end;

begin 
  with TTaraDSPApp.Create(nil) do 
  begin
    try 
      Run; 
    finally 
      Free; 
    end; 
  end; 
end.

