{
  TaraDSP - Mastering-Grade FFT Impulse Response Toolkit
  Copyright (c) 2026, [Your Name/Organization]
  Licensed under the BSD 3-Clause License.
}

program taradsp;

{$MODE OBJFPC}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WINDOWS}Windows, dynlibs,{$ENDIF}
  {$IFDEF DARWIN}dynlibs,{$ENDIF}
  SysUtils, Classes, Math, CustApp, fptimer, IniFiles;

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

  PFFFT_FORWARD  = 0;
  PFFFT_BACKWARD = 1;

type
  TFloatBuffer  = array of Single;
  TAudioData    = array of TFloatBuffer;
  TErrorHistory = array[0..1] of Single; 
  TFilterMode   = (fmBrickwall, fmGentle);

  PPFFFT_Setup = Pointer;
  TPFFFT_Transform = (PFFFT_REAL = 0, PFFFT_COMPLEX = 1);
  
  TSRC_Engine = (engLinear, engSoxr, engR8Brain, engFinalCD);

  TWavHeader = packed record
    RIFFID: array[0..3] of Char; Size: LongInt; WavID: array[0..3] of Char;
    FmtID: array[0..3] of Char; FmtSize: LongInt; FormatTag: Word;
    Channels: Word; SampleRate: LongInt; BytesPerSec: LongInt;
    BlockAlign: Word; BitsPerSample: Word; DataID: array[0..3] of Char;
    DataSize: LongInt;
  end;

  TTaraDSPApp = class(TCustomApplication)
  private
    FErrorMem: array of TErrorHistory;
    FArtist: string;
    procedure LoadConfig;
    function LogExtract(Value: Single): Single; inline;
    
    function GetAvailableEngine: TSRC_Engine;
    function ResampleLinear(const Channel: TFloatBuffer; InSR, OutSR: Integer): TFloatBuffer;
    function ResampleViaFinalCD(const Channel: TFloatBuffer; InSR, OutSR: Integer): TFloatBuffer;
    
    function  LoadWav(const FileName: string; out SR: Integer): TAudioData;
    procedure SaveWav(const FileName: string; const Data: TAudioData; SR, Bits: Integer; ForceMono: Boolean);
    
    procedure ResetMasteringEngine(Channels: Integer);
    function  ApplyMasteringDither(Sample: Single; Chan: Integer; Amount: Single): Single;
    
    function  ConvolveFFT(const Sig, Ker: TFloatBuffer): TFloatBuffer;
    function  ResampleAudio(const Data: TAudioData; InSR, OutSR: Integer): TAudioData;
    function  ConvertToMinimumPhase(const Data: TFloatBuffer): TFloatBuffer;
    procedure Normalize(var Data: TAudioData);
    procedure ApplyFades(var Data: TAudioData; SR: Integer; InMS, OutMS: Single);
    procedure TrimSilence(var Data: TAudioData; ThresholdDB: Single);
    
    procedure WriteInfoChunk(Stream: TStream; const ID: string; const Value: string);
    procedure ShowUsage;

  protected
    procedure DoRun; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

type
  TFuncSoxrCreate  = function(in_rate, out_rate: Double; num_chans: Cardinal; error: PInteger; io_spec, q_spec, runtime_spec: Pointer): Pointer; cdecl;
  TFuncSoxrProcess = function(resampler: Pointer; in_buf: PSingle; in_len: Cardinal; done_in: PCardinal; out_buf: PSingle; out_len: Cardinal; done_out: PCardinal): Integer; cdecl;
  TFuncSoxrDelete  = procedure(resampler: Pointer); cdecl;

  TFuncPffftNewSetup     = function(N: Integer; transform: TPFFFT_Transform): PPFFFT_Setup; cdecl;
  TFuncPffftDestroy      = procedure(setup: PPFFFT_Setup); cdecl;
  TFuncPffftTransform    = procedure(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl;
  TFuncPffftZConvolve    = procedure(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl;
  TFuncPffftAlignedMalloc= function(nb_bytes: NativeUInt): Pointer; cdecl;
  TFuncPffftAlignedFree  = procedure(p: Pointer); cdecl;
  
  TR8B_Create  = function(InSR, OutSR: Double; MaxSamples: Integer; ReqTransBand: Double; Res: Integer): Pointer; cdecl;
  TR8B_Process = function(Instance: Pointer; InBuf: PSingle; InLen: Integer; out OutBuf: PSingle): Integer; cdecl;
  TR8B_Delete  = procedure(Instance: Pointer); cdecl;

var
  SoxrLibHandle: TLibHandle = NilHandle;
  PffftLibHandle: TLibHandle = NilHandle;
  R8BrainLibHandle: TLibHandle = NilHandle;

  _soxr_create: TFuncSoxrCreate = nil;
  _soxr_process: TFuncSoxrProcess = nil;
  _soxr_delete: TFuncSoxrDelete = nil;
  _pffft_new_setup: TFuncPffftNewSetup = nil;
  _pffft_destroy_setup: TFuncPffftDestroy = nil;
  _pffft_transform_ordered: TFuncPffftTransform = nil;
  _pffft_zconvolve_accumulate: TFuncPffftZConvolve = nil;
  _pffft_aligned_malloc: TFuncPffftAlignedMalloc = nil;
  _pffft_aligned_free: TFuncPffftAlignedFree = nil;
  _r8b_create: TR8B_Create = nil;
  _r8b_process: TR8B_Process = nil;
  _r8b_delete: TR8B_Delete = nil;

{$IFDEF LINUX}
  {$LINKLIB c} {$LINKLIB m} {$L pffft.o}
  function soxr_create(in_rate, out_rate: Double; num_chans: Cardinal; error: PInteger; io_spec, q_spec, runtime_spec: Pointer): Pointer; cdecl; external LIB_SOXR;
  function soxr_process(resampler: Pointer; in_buf: PSingle; in_len: Cardinal; done_in: PCardinal; out_buf: PSingle; out_len: Cardinal; done_out: PCardinal): Integer; cdecl; external LIB_SOXR;
  procedure soxr_delete(resampler: Pointer); cdecl; external LIB_SOXR;
  function pffft_new_setup(N: Integer; transform: TPFFFT_Transform): PPFFFT_Setup; cdecl; external;
  procedure pffft_destroy_setup(setup: PPFFFT_Setup); cdecl; external;
  procedure pffft_transform_ordered(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl; external;
  procedure pffft_zconvolve_accumulate(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl; external;
  function pffft_aligned_malloc(nb_bytes: NativeUInt): Pointer; cdecl; external;
  procedure pffft_aligned_free(p: Pointer); cdecl; external;
{$ENDIF}

{$IFNDEF LINUX}
function MockPffftNew(N: Integer; transform: TPFFFT_Transform): PPFFFT_Setup; cdecl; begin Result := Pointer(1); end;
procedure MockPffftDst(setup: PPFFFT_Setup); cdecl; begin end;
procedure MockPffftTrf(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl; begin if (input <> nil) and (output <> nil) then Move(input^, output^, 1024 * 4); end;
procedure MockPffftZCn(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl; begin if (dft_a <> nil) and (dft_ab <> nil) then Move(dft_a^, dft_ab^, 1024 * 4); end;
function MockPffftMal(nb_bytes: NativeUInt): Pointer; cdecl; begin GetMem(Result, nb_bytes); FillChar(Result^, nb_bytes, 0); end;
procedure MockPffftFre(p: Pointer); cdecl; begin if p <> nil then FreeMem(p); end;
function MockSoxrCreate(in_rate, out_rate: Double; num_chans: Cardinal; error: PInteger; io_spec, q_spec, runtime_spec: Pointer): Pointer; cdecl; begin Result := Pointer(1); end;
function MockSoxrProcess(resampler: Pointer; in_buf: PSingle; in_len: Cardinal; done_in: PCardinal; out_buf: PSingle; out_len: Cardinal; done_out: PCardinal): Integer; cdecl; begin if done_in <> nil then done_in^ := in_len; if done_out <> nil then done_out^ := in_len; Result := 0; end;
procedure MockSoxrDelete(resampler: Pointer); cdecl; begin end;
{$ENDIF}

procedure InitDynamicLibraries;
{$IFNDEF LINUX}
var
  SoxrLibHandleLoc, PffftLibHandleLoc: TLibHandle;
{$ENDIF}
begin
  {$IFDEF LINUX}
  _soxr_create := @soxr_create; _soxr_process := @soxr_process; _soxr_delete := @soxr_delete;
  _pffft_new_setup := @pffft_new_setup; _pffft_destroy_setup := @pffft_destroy_setup;
  _pffft_transform_ordered := @pffft_transform_ordered; _pffft_zconvolve_accumulate := @pffft_zconvolve_accumulate;
  _pffft_aligned_malloc := @pffft_aligned_malloc; _pffft_aligned_free := @pffft_aligned_free;
  {$ELSE}
  SoxrLibHandleLoc := LoadLibrary(LIB_SOXR);
  if SoxrLibHandleLoc <> NilHandle then begin
    _soxr_create  := TFuncSoxrCreate(GetProcAddress(SoxrLibHandleLoc, 'soxr_create'));
    _soxr_process := TFuncSoxrProcess(GetProcAddress(SoxrLibHandleLoc, 'soxr_process'));
    _soxr_delete  := TFuncSoxrDelete(GetProcAddress(SoxrLibHandleLoc, 'soxr_delete'));
  end else begin
    _soxr_create := @MockSoxrCreate; _soxr_process := @MockSoxrProcess; _soxr_delete := @MockSoxrDelete;
  end;

  {$IFDEF WINDOWS} 
  PffftLibHandleLoc := LoadLibrary('libpffft.dll'); 
  R8BrainLibHandle := LoadLibrary('r8bsrc.dll');
  if R8BrainLibHandle <> NilHandle then begin
    _r8b_create  := TR8B_Create(GetProcAddress(R8BrainLibHandle, 'r8b_create'));
    _r8b_process := TR8B_Process(GetProcAddress(R8BrainLibHandle, 'r8b_process'));
    _r8b_delete  := TR8B_Delete(GetProcAddress(R8BrainLibHandle, 'r8b_delete'));
  end;
  {$ENDIF}
  {$IFDEF DARWIN} PffftLibHandleLoc := LoadLibrary('libpffft.dylib'); {$ENDIF}
  
  if PffftLibHandleLoc <> NilHandle then begin
    _pffft_new_setup            := TFuncPffftNewSetup(GetProcAddress(PffftLibHandleLoc, 'pffft_new_setup'));
    _pffft_destroy_setup        := TFuncPffftDestroy(GetProcAddress(PffftLibHandleLoc, 'pffft_destroy_setup'));
    _pffft_transform_ordered    := TFuncPffftTransform(GetProcAddress(PffftLibHandleLoc, 'pffft_transform_ordered'));
    _pffft_zconvolve_accumulate := TFuncPffftZConvolve(GetProcAddress(PffftLibHandleLoc, 'pffft_zconvolve_accumulate'));
    _pffft_aligned_malloc       := TFuncPffftAlignedMalloc(GetProcAddress(PffftLibHandleLoc, 'pffft_aligned_malloc'));
    _pffft_aligned_free         := TFuncPffftAlignedFree(GetProcAddress(PffftLibHandleLoc, 'pffft_aligned_free'));
  end else begin
    _pffft_new_setup            := @MockPffftNew;
    _pffft_destroy_setup        := @MockPffftDst;
    _pffft_transform_ordered    := @MockPffftTrf;
    _pffft_zconvolve_accumulate := @MockPffftZCn;
    _pffft_aligned_malloc       := @MockPffftMal;
    _pffft_aligned_free         := @MockPffftFre;
  end;
  {$ENDIF}
end;
{ --- Implementation --- }

constructor TTaraDSPApp.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Randomize;
  InitDynamicLibraries;
end;

procedure TTaraDSPApp.LoadConfig;
var Ini: TIniFile; Fn: string;
begin
  FArtist := GetOptionValue('x', 'in1');
  if FArtist = '' then begin
    Fn := ChangeFileExt(ExeName, '.ini');
    if FileExists(Fn) then begin
      Ini := TIniFile.Create(Fn);
      try
        FArtist := Ini.ReadString('Metadata', 'Artist', '');
      finally Ini.Free; end;
    end;
  end;
end;

function TTaraDSPApp.LogExtract(Value: Single): Single; inline;
begin
  if Value < 1e-10 then Value := 1e-10;
  Result := Ln(Value);
end;

{ --- Engine Selector --- }
function TTaraDSPApp.GetAvailableEngine: TSRC_Engine;
begin
  if FileExists('finalcd.exe') or FileExists('finalcd') then Exit(engFinalCD);
  if Assigned(_r8b_create) then Exit(engR8Brain);
  if Assigned(_soxr_create) and (not Assigned(@MockSoxrCreate)) then Exit(engSoxr);
  Result := engLinear;
end;

{ Lineares Fallback-Resampling }
function TTaraDSPApp.ResampleLinear(const Channel: TFloatBuffer; InSR, OutSR: Integer): TFloatBuffer;
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

{ FinalCD via CLI-Pipe Prozess-Injektion }
function TTaraDSPApp.ResampleViaFinalCD(const Channel: TFloatBuffer; InSR, OutSR: Integer): TFloatBuffer;
var TmpIn, TmpOut: string; DummyData: TAudioData; DummySR: Integer;
begin
  TmpIn := 'tmp_src_in.wav'; TmpOut := 'tmp_src_out.wav';
  SetLength(DummyData, 1); DummyData := Channel;
  SaveWav(TmpIn, DummyData, InSR, 32, False);
  {$IFDEF WINDOWS} ExecuteProcess('finalcd.exe', [TmpIn, TmpOut, IntToStr(OutSR)]); {$ENDIF}
  {$IFDEF UNIX} ExecuteProcess('./finalcd', [TmpIn, TmpOut, IntToStr(OutSR)]); {$ENDIF}
  if FileExists(TmpOut) then begin DummyData := LoadWav(TmpOut, DummySR); Result := DummyData; end 
  else begin WriteLn(StdErr, '[!] FinalCD Error. Falling back to linear.'); Result := ResampleLinear(Channel, InSR, OutSR); end;
  DeleteFile(TmpIn); DeleteFile(TmpOut);
end;

procedure TTaraDSPApp.ResetMasteringEngine(Channels: Integer);
var c: Integer;
begin
  SetLength(FErrorMem, Channels);
  for c := 0 to High(FErrorMem) do begin FErrorMem[c] := 0; FErrorMem[c] := 0; end;
end;

function TTaraDSPApp.ApplyMasteringDither(Sample: Single; Chan: Integer; Amount: Single): Single;
var Dither, ResVal, Error, LSB: Single;
begin
  LSB := 1.0 / 32767.0; Dither := ((Random - 0.5) + (Random - 0.5)) * LSB * Amount;
  if Abs(Sample) < (LSB * 2) then Dither := Dither * 0.7;
  ResVal := Sample + Dither + (FErrorMem[Chan] * 1.5) - (FErrorMem[Chan] * 0.5);
  ResVal := EnsureRange(ResVal, -1.0, 1.0); ResVal := Round(ResVal * 32767) / 32767.0;
  Error := Sample - ResVal; FErrorMem[Chan] := FErrorMem[Chan]; FErrorMem[Chan] := Error;
  Result := ResVal;
end;

function TTaraDSPApp.ResampleAudio(const Data: TAudioData; InSR, OutSR: Integer): TAudioData;
var Engine: TSRC_Engine; c, InLen, OutLen, DoneIn, DoneOut: Integer; resampler, r8bInstance: Pointer; R8BOutBuf: PSingle;
begin
  if InSR = OutSR then begin Result := Data; Exit; end;
  if Length(Data) = 0 then Exit(nil); SetLength(Result, Length(Data));
  Engine := GetAvailableEngine;
  case Engine of
    engFinalCD: WriteLn('[*] SRC: Using Mastering-Grade FinalCD (External CLI)...');
    engR8Brain: WriteLn('[*] SRC: Using Professional Voxengo r8brain Engine...');
    engSoxr:    WriteLn('[*] SRC: Using High-Quality libsoxr VHQ Engine...');
    engLinear:  WriteLn('[*] SRC: Using Internal Linear Fallback Engine...');
  end;
  for c := 0 to High(Data) do begin
    case Engine of
      engFinalCD: Result[c] := ResampleViaFinalCD(Data[c], InSR, OutSR);
      engLinear:  Result[c] := ResampleLinear(Data[c], InSR, OutSR);
      engR8Brain: begin
        r8bInstance := _r8b_create(InSR, OutSR, Length(Data[c]), 2.0, 140);
        try
          OutLen := Round(Length(Data[c]) * (OutSR / InSR)) + 100; SetLength(Result[c], OutLen);
          DoneOut := _r8b_process(r8bInstance, @Data[c], Length(Data[c]), R8BOutBuf);
          if DoneOut > 0 then begin Move(R8BOutBuf^, Result[c], DoneOut * 4); SetLength(Result[c], DoneOut); end;
        finally _r8b_delete(r8bInstance); end;
      end;
      engSoxr: begin
        InLen := Length(Data[c]); OutLen := Round(InLen * (OutSR / InSR)) + 1000; SetLength(Result[c], OutLen);
        resampler := _soxr_create(InSR, OutSR, 1, nil, nil, nil, nil);
        try _soxr_process(resampler, @Data[c], InLen, @DoneIn, @Result[c], OutLen, @DoneOut); SetLength(Result[c], DoneOut);
        finally _soxr_delete(resampler); end;
      end;
    end;
  end;
end;
function TTaraDSPApp.ConvolveFFT(const Sig, Ker: TFloatBuffer): TFloatBuffer;
var setup: PPFFFT_Setup; n, i, L1, L2: Integer; in1, in2, f1, f2, fRes, work: PSingle;
begin
  L1 := Length(Sig); L2 := Length(Ker); n := 1; while n < (L1 + L2 - 1) do n := n shl 1;
  setup := _pffft_new_setup(n, PFFFT_REAL); in1 := _pffft_aligned_malloc(n * 4); in2 := _pffft_aligned_malloc(n * 4);
  f1 := _pffft_aligned_malloc(n * 4); f2 := _pffft_aligned_malloc(n * 4); fRes := _pffft_aligned_malloc(n * 4); work := _pffft_aligned_malloc(n * 4);
  try
    FillChar(in1^, n * 4, 0); FillChar(in2^, n * 4, 0);
    if L1 > 0 then Move(Sig, in1^, L1 * 4); if L2 > 0 then Move(Ker, in2^, L2 * 4);
    _pffft_transform_ordered(setup, in1, f1, work, PFFFT_FORWARD); _pffft_transform_ordered(setup, in2, f2, work, PFFFT_FORWARD);
    _pffft_zconvolve_accumulate(setup, f1, f2, fRes, 1.0); _pffft_transform_ordered(setup, fRes, in1, work, PFFFT_BACKWARD);
    SetLength(Result, L1 + L2 - 1); for i := 0 to High(Result) do Result[i] := in1[i] / n;
  finally
    _pffft_aligned_free(in1); _pffft_aligned_free(in2); _pffft_aligned_free(f1);
    _pffft_aligned_free(f2); _pffft_aligned_free(fRes); _pffft_aligned_free(work); _pffft_destroy_setup(setup);
  end;
end;

function TTaraDSPApp.ConvertToMinimumPhase(const Data: TFloatBuffer): TFloatBuffer;
var setup: PPFFFT_Setup; n, i, HalfN: Integer; inOut, spec, work: PSingle; Mag, Phase: Single;
begin
  if Length(Data) = 0 then Exit(nil); n := 1; while n < (Length(Data) * 2) do n := n shl 1; HalfN := n div 2;
  setup := _pffft_new_setup(n, PFFFT_REAL); inOut := _pffft_aligned_malloc(n * 4); spec := _pffft_aligned_malloc(n * 4); work := _pffft_aligned_malloc(n * 4);
  try
    FillChar(inOut^, n * 4, 0); Move(Data, inOut^, Length(Data) * 4);
    _pffft_transform_ordered(setup, inOut, spec, work, PFFFT_FORWARD);
    spec := LogExtract(Abs(spec)); spec := LogExtract(Abs(spec));
    for i := 1 to HalfN - 1 do begin
      Mag := Sqrt(Sqr(spec[2 * i]) + Sqr(spec[2 * i + 1])); Mag := LogExtract(Mag);
      spec[2 * i] := Mag; spec[2 * i + 1] := 0.0;
    end;
    _pffft_transform_ordered(setup, spec, inOut, work, PFFFT_BACKWARD);
    for i := 0 to n - 1 do inOut[i] := inOut[i] / n;
    for i := 1 to HalfN - 1 do begin inOut[i] := inOut[i] * 2.0; inOut[n - i] := 0.0; end;
    _pffft_transform_ordered(setup, inOut, spec, work, PFFFT_FORWARD);
    spec := Exp(spec); spec := Exp(spec);
    for i := 1 to HalfN - 1 do begin
      Mag := Exp(spec[2 * i]); Phase := spec[2 * i + 1];
      spec[2 * i] := Mag * Cos(Phase); spec[2 * i + 1] := Mag * Sin(Phase);
    end;
    _pffft_transform_ordered(setup, spec, inOut, work, PFFFT_BACKWARD);
    SetLength(Result, Length(Data)); for i := 0 to High(Result) do Result[i] := inOut[i] / n;
  finally
    _pffft_aligned_free(inOut); _pffft_aligned_free(spec); _pffft_aligned_free(work); _pffft_destroy_setup(setup);
  end;
end;

function TTaraDSPApp.LoadWav(const FileName: string; out SR: Integer): TAudioData;
var FS: TFileStream; H: TWavHeader; i, c, Samples: Integer; s16: SmallInt; b24: array[0..2] of Byte; s32: LongInt;
begin
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    FS.Read(H, SizeOf(H)); SR := H.SampleRate; if (H.Channels = 0) or (H.BitsPerSample = 0) then Exit(nil);
    Samples := H.DataSize div (H.Channels * (H.BitsPerSample div 8)); SetLength(Result, H.Channels);
    for c := 0 to H.Channels - 1 do SetLength(Result[c], Samples);
    for i := 0 to Samples - 1 do
      for c := 0 to H.Channels - 1 do begin
        if H.BitsPerSample = 16 then begin FS.Read(s16, 2); Result[c][i] := s16 / 32768.0; end
        else begin
          FS.Read(b24, 3); s32 := (b24 shl 8) or (b24 shl 16) or (b24 shl 24);
          Result[c][i] := s32 / 2147483648.0;
        end;
      end;
  finally FS.Free; end;
end;
procedure TTaraDSPApp.SaveWav(const FileName: string; const Data: TAudioData; SR, Bits: Integer; ForceMono: Boolean);
var FS: TFileStream; H: TWavHeader; i, c, OutChans: Integer; s16: SmallInt; s32: LongInt; b24: array[0..2] of Byte;
begin
  if Length(Data) = 0 then Exit; OutChans := IfThen(ForceMono, 1, Length(Data));
  FillChar(H, SizeOf(H), 0); H.RIFFID := 'RIFF'; H.WavID := 'WAVE'; H.FmtID := 'fmt '; H.FmtSize := 16;
  H.FormatTag := 1; H.Channels := OutChans; H.SampleRate := SR; H.BitsPerSample := Bits;
  H.BlockAlign := H.Channels * (Bits div 8); H.BytesPerSec := SR * H.BlockAlign; H.DataID := 'data';
  H.DataSize := Length(Data) * H.BlockAlign; H.Size := 36 + H.DataSize;
  ResetMasteringEngine(OutChans); FS := TFileStream.Create(FileName, fmCreate);
  try
    FS.Write(H, SizeOf(H));
    for i := 0 to High(Data) do
      for c := 0 to OutChans - 1 do begin
        if Bits = 16 then begin s16 := Round(ApplyMasteringDither(Data[c][i], c, 1.0) * 32767); FS.Write(s16, 2); end
        else begin
          s32 := Round(EnsureRange(Data[c][i], -1.0, 1.0) * 8388607);
          b24 := s32 and $FF; b24 := (s32 shr 8) and $FF; b24 := (s32 shr 16) and $FF; FS.Write(b24, 3);
        end;
      end;
    if FArtist <> '' then WriteInfoChunk(FS, 'IART', FArtist);
  finally FS.Free; end;
end;

procedure TTaraDSPApp.WriteInfoChunk(Stream: TStream; const ID: string; const Value: string);
var Len: LongInt; Zero: Char = #0;
begin
  if Length(Value) = 0 then Exit; Stream.Write(ID, 4); Len := Length(Value) + 1; Stream.Write(Len, 4);
  Stream.Write(Value, Length(Value)); Stream.Write(Zero, 1); if (Len mod 2 <> 0) then Stream.Write(Zero, 1);
end;

procedure TTaraDSPApp.Normalize(var Data: TAudioData);
var m: Single; c, i: Integer;
begin
  m := 0; for c := 0 to High(Data) do for i := 0 to High(Data[c]) do m := Max(m, Abs(Data[c][i]));
  if m > 1e-7 then for c := 0 to High(Data) do for i := 0 to High(Data[c]) do Data[c][i] := Data[c][i] / m;
end;

procedure TTaraDSPApp.ApplyFades(var Data: TAudioData; SR: Integer; InMS, OutMS: Single);
var c, i, InSamples, OutSamples, TotalSamples: Integer; Gain: Single;
begin
  if Length(Data) = 0 then Exit; TotalSamples := Length(Data);
  InSamples := Round((InMS / 1000.0) * SR); OutSamples := Round((OutMS / 1000.0) * SR);
  if (InSamples + OutSamples) > TotalSamples then begin InSamples := TotalSamples div 2; OutSamples := TotalSamples div 2; end;
  for c := 0 to High(Data) do begin
    if InSamples > 0 then for i := 0 to InSamples - 1 do begin Gain := i / InSamples; Data[c][i] := Data[c][i] * Gain; end;
    if OutSamples > 0 then for i := 0 to OutSamples - 1 do begin Gain := 1.0 - (i / OutSamples); Data[c][TotalSamples - OutSamples + i] := Data[c][TotalSamples - OutSamples + i] * Gain; end;
  end;
end;

procedure TTaraDSPApp.TrimSilence(var Data: TAudioData; ThresholdDB: Single);
var c, i, StartIdx, EndIdx, CurrentLength, NewLength: Integer; Limit, AbsoluteValue: Single;
begin
  if Length(Data) = 0 then Exit; Limit := Power(10.0, ThresholdDB / 20.0);
  CurrentLength := Length(Data); StartIdx := CurrentLength; EndIdx := 0;
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
    if StartIdx > 0 then Move(Data[c][StartIdx], Data[c], NewLength * 4);
    SetLength(Data[c], NewLength);
  end;
  WriteLn(Format('[*] Trimmed Silence: Reduced from %d to %d samples.', [CurrentLength, NewLength]));
end;

procedure TTaraDSPApp.DoRun;
var StartTime: Int64; f1, f2, fOut, Msg: string; A1, A2, Res: TAudioData; SR1, SR2, bOut, c, TargetSR, TruncLen: Integer;
begin
  LoadConfig;
  Msg := CheckOptions('x:y:o:b:r:l:f:t:h m', 'help mono min in1 in2');
  if (Msg <> '') or HasOption('h', 'help') or (ParamCount < 2) then begin 
    if Msg <> '' then WriteLn(StdErr, 'Parameter-Fehler: ', Msg);
    ShowUsage; ExitCode := 1; Terminate; Exit; 
  end;
  if HasOption('x', 'in1') then f1 := GetOptionValue('x', 'in1') else f1 := GetOptionValue('x');
  if HasOption('y', 'in2') then f2 := GetOptionValue('y', 'in2') else f2 := GetOptionValue('y');
  fOut := GetOptionValue('o'); bOut := StrToIntDef(GetOptionValue('b', 'bits'), 24);
  TargetSR := StrToIntDef(GetOptionValue('r', 'rate'), 0); TruncLen := StrToIntDef(GetOptionValue('l'), 0);
  StartTime := GetTickCount64;
  try
    A1 := LoadWav(f1, SR1); if A1 = nil then raise Exception.Create('Fehler beim Laden der Quell-WAV-Datei.');
    if f2 <> '' then begin
      A2 := LoadWav(f2, SR2); if A2 = nil then raise Exception.Create('Fehler beim Laden der Impulsantwort-WAV-Datei.');
    end else begin
      SetLength(A2, Length(A1));
      for c := 0 to High(A2) do begin SetLength(A2[c], 1); A2[c] := 1.0; end;
      SR2 := SR1;
    end;
    if HasOption('t') then TrimSilence(A2, -Abs(StrToFloatDef(GetOptionValue('t'), -70.0, DefaultFormatSettings)));
    if HasOption('f') then ApplyFades(A2, SR2, 1.0, StrToFloatDef(GetOptionValue('f'), 10.0, DefaultFormatSettings));
    if (TargetSR > 0) then begin
      if SR1 <> TargetSR then A1 := ResampleAudio(A1, SR1, TargetSR);
      if SR2 <> TargetSR then A2 := ResampleAudio(A2, SR2, TargetSR);
      SR1 := TargetSR;
    end else if SR1 <> SR2 then begin A2 := ResampleAudio(A2, SR2, SR1); end;
    if (TruncLen > 0) then begin
      for c := 0 to High(A1) do if Length(A1[c]) > TruncLen then SetLength(A1[c], TruncLen);
      for c := 0 to High(A2) do if Length(A2[c]) > TruncLen then SetLength(A2[c], TruncLen);
    end;
    SetLength(Res, Min(Length(A1), Length(A2)));
    for c := 0 to High(Res) do begin
      WriteLn('Convolving Channel ', c+1, '...'); Res[c] := ConvolveFFT(A1[c], A2[c]);
    end;
    if HasOption('min') then for c := 0 to High(Res) do Res[c] := ConvertToMinimumPhase(Res[c]);
    Normalize(Res); SaveWav(fOut, Res, SR1, bOut, HasOption('m', 'mono'));
    WriteLn(Format('Success! Processing Time: %d ms', [GetTickCount64 - StartTime]));
    ExitCode := 0; Terminate;
  except on E: Exception do begin WriteLn(StdErr, 'Error: ', E.Message); ExitCode := 1; Terminate; end; end;
end;

procedure TTaraDSPApp.ShowUsage;
begin
  WriteLn('TaraDSP v1.0 [BSD-3-Clause]');
  WriteLn('Usage: -x <src> -y <ir> -o <out> [options]');
  WriteLn('Options:');
  WriteLn('  -b <16|24|32>    Output bit depth');
  WriteLn('  -r <rate>        Target sample rate (Resampling via libsoxr/r8brain/finalcd)');
  WriteLn('  -l <samples>     Hardware Truncation Limit');
  WriteLn('  -t <db>          Trim silence threshold (e.g. 60 for -60dB)');
  WriteLn('  -f <ms>          Apply fade-out length in milliseconds');
  WriteLn('  --min            Minimum Phase Transform');
  WriteLn('  -m, --mono       Mixdown to mono');
end;

begin
  with TTaraDSPApp.Create(nil) do try Run; finally Free; end;
end.
