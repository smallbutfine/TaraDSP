{
  TaraDSP - Mastering-Grade FFT Impulse Response / Mastering Toolkit
  Copyright (c) 2024, Martin Haverland
  Licensed under the BSD 3-Clause License.
}

program TaraDSP;

{$MODE OBJFPC}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF DARWIN}dynlibs,{$ENDIF}
  SysUtils, Classes, Math, CustApp, fptimer, IniFiles;

const
  // Plattformunabhängige Bibliotheksnamen für den Linker
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

  { PFFFT Kerntypen - JETZT GLOBAL FÜR ALLE SYSTEME ERREICHBAR }
  PPFFFT_Setup = Pointer;
  TPFFFT_Transform = (PFFFT_REAL = 0, PFFFT_COMPLEX = 1);

  TWavHeader = packed record
    RIFFID: array[0..3] of Char; Size: LongInt; WavID: array[0..3] of Char;
    FmtID: array[0..3] of Char; FmtSize: LongInt; FormatTag: Word;
    Channels: Word; SampleRate: LongInt; BytesPerSec: LongInt;
    BlockAlign: Word; BitsPerSample: Word; DataID: array[0..3] of Char;
    DataSize: LongInt;
  end;

  TIRConvolverApp = class(TCustomApplication)
  private
    FErrorMem: array of TErrorHistory;
    FArtist: string;
    procedure LoadConfig;
    
    { I/O }
    function  LoadWav(const FileName: string; out SR: Integer): TAudioData;
    procedure SaveWav(const FileName: string; const Data: TAudioData; SR, Bits: Integer; ForceMono: Boolean);
    
    { Mastering Engine }
    procedure ResetMasteringEngine(Channels: Integer);
    function  ApplyMasteringDither(Sample: Single; Chan: Integer; Amount: Single): Single;
    
    { DSP Core }
    function  ConvolveFFT(const Sig, Ker: TFloatBuffer): TFloatBuffer;
    function  ResampleSoxr(const Data: TAudioData; InSR, OutSR: Integer): TAudioData;
    function  ConvertToMinimumPhase(const Data: TFloatBuffer): TFloatBuffer;
    procedure Normalize(var Data: TAudioData);
    procedure ApplyFades(var Data: TAudioData; SR: Integer; InMS, OutMS: Single);
    procedure TrimSilence(var Data: TAudioData; ThresholdDB: Single);
    
    { Helpers }
    procedure WriteInfoChunk(Stream: TStream; const ID: string; const Value: string);
    procedure ShowUsage;

  protected
    procedure DoRun; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

{ --- Externe Bibliothekseinbindung (libsoxr) --- }

{$IFDEF DARWIN}
type
  TFuncSoxrCreate  = function(in_rate, out_rate: Double; num_chans: Cardinal; error: PInteger; io_spec, q_spec, runtime_spec: Pointer): Pointer; cdecl;
  TFuncSoxrProcess = function(resampler: Pointer; in_buf: PSingle; in_len: Cardinal; done_in: PCardinal; out_buf: PSingle; out_len: Cardinal; done_out: PCardinal): Integer; cdecl;
  TFuncSoxrDelete  = procedure(resampler: Pointer); cdecl;

var
  SoxrLibHandle: TLibHandle = NilHandle;
  soxr_create: TFuncSoxrCreate = nil;
  soxr_process: TFuncSoxrProcess = nil;
  soxr_delete: TFuncSoxrDelete = nil;

procedure InitSoxrMacOS;
begin
  if SoxrLibHandle = NilHandle then begin
    SoxrLibHandle := LoadLibrary(LIB_SOXR);
    if SoxrLibHandle = NilHandle then SoxrLibHandle := LoadLibrary('/usr/local/lib/' + LIB_SOXR);
    if SoxrLibHandle = NilHandle then SoxrLibHandle := LoadLibrary('/opt/homebrew/lib/' + LIB_SOXR);
    
    if SoxrLibHandle <> NilHandle then begin
      soxr_create  := TFuncSoxrCreate(GetProcAddress(SoxrLibHandle, 'soxr_create'));
      soxr_process := TFuncSoxrProcess(GetProcAddress(SoxrLibHandle, 'soxr_process'));
      soxr_delete  := TFuncSoxrDelete(GetProcAddress(SoxrLibHandle, 'soxr_delete'));
    end;
  end;
end;
{$ELSE}
function soxr_create(in_rate, out_rate: Double; num_chans: Cardinal; error: PInteger; io_spec, q_spec, runtime_spec: Pointer): Pointer; cdecl; external LIB_SOXR;
function soxr_process(resampler: Pointer; in_buf: PSingle; in_len: Cardinal; done_in: PCardinal; out_buf: PSingle; out_len: Cardinal; done_out: PCardinal): Integer; cdecl; external LIB_SOXR;
procedure soxr_delete(resampler: Pointer); cdecl; external LIB_SOXR;
{$ENDIF}

{ --- Externe Bibliothekseinbindung (PFFFT FFT Engine) --- }

{$IFDEF DARWIN}
type
  TFuncPffftNewSetup    = function(N: Integer; transform: TPFFFT_Transform): PPFFFT_Setup; cdecl;
  TFuncPffftDestroy     = procedure(setup: PPFFFT_Setup); cdecl;
  TFuncPffftTransform   = procedure(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl;
  TFuncPffftZConvolve   = procedure(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl;
  TFuncPffftAlignedMalloc= function(nb_bytes: NativeUInt): Pointer; cdecl;
  TFuncPffftAlignedFree  = procedure(p: Pointer); cdecl;

var
  PffftLibHandle: TLibHandle = NilHandle;
  pffft_new_setup: TFuncPffftNewSetup = nil;
  pffft_destroy_setup: TFuncPffftDestroy = nil;
  pffft_transform_ordered: TFuncPffftTransform = nil;
  pffft_zconvolve_accumulate: TFuncPffftZConvolve = nil;
  pffft_aligned_malloc: TFuncPffftAlignedMalloc = nil;
  pffft_aligned_free: TFuncPffftAlignedFree = nil;

procedure InitPffftMacOS;
begin
  if PffftLibHandle = NilHandle then begin
    PffftLibHandle := LoadLibrary('libpffft.dylib');
    if PffftLibHandle = NilHandle then PffftLibHandle := LoadLibrary('./libpffft.dylib');
    
    if PffftLibHandle <> NilHandle then begin
      pffft_new_setup            := TFuncPffftNewSetup(GetProcAddress(PffftLibHandle, 'pffft_new_setup'));
      pffft_destroy_setup        := TFuncPffftDestroy(GetProcAddress(PffftLibHandle, 'pffft_destroy_setup'));
      pffft_transform_ordered    := TFuncPffftTransform(GetProcAddress(PffftLibHandle, 'pffft_transform_ordered'));
      pffft_zconvolve_accumulate := TFuncPffftZConvolve(GetProcAddress(PffftLibHandle, 'pffft_zconvolve_accumulate'));
      pffft_aligned_malloc       := TFuncPffftAlignedMalloc(GetProcAddress(PffftLibHandle, 'pffft_aligned_malloc'));
      pffft_aligned_free         := TFuncPffftAlignedFree(GetProcAddress(PffftLibHandle, 'pffft_aligned_free'));
    end;
  end;
end;
{$ENDIF}

{$IFDEF WINDOWS}
  const LIB_PFFFT = 'libpffft.dll';
  function pffft_new_setup(N: Integer; transform: TPFFFT_Transform): PPFFFT_Setup; cdecl; external LIB_PFFFT;
  procedure pffft_destroy_setup(setup: PPFFFT_Setup); cdecl; external LIB_PFFFT;
  procedure pffft_transform_ordered(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl; external LIB_PFFFT;
  procedure pffft_zconvolve_accumulate(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl; external LIB_PFFFT;
  function pffft_aligned_malloc(nb_bytes: NativeUInt): Pointer; cdecl; external LIB_PFFFT;
  procedure pffft_aligned_free(p: Pointer); cdecl; external LIB_PFFFT;
{$ENDIF}

{$IFDEF LINUX}
  {$LINKLIB c} // Zwingend erforderlich für C-Standardfunktionen (malloc/free)
  {$LINKLIB m} // Zwingend erforderlich für C-Mathematikfunktionen (sin/cos für FFT)
  {$L pffft.o} // Bindet das in GitHub Actions kompilierte C-Objekt ein
  
  function pffft_new_setup(N: Integer; transform: TPFFFT_Transform): PPFFFT_Setup; cdecl; external;
  procedure pffft_destroy_setup(setup: PPFFFT_Setup); cdecl; external;
  procedure pffft_transform_ordered(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl; external;
  procedure pffft_zconvolve_accumulate(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl; external;
  function pffft_aligned_malloc(nb_bytes: NativeUInt): Pointer; cdecl; external;
  procedure pffft_aligned_free(p: Pointer); cdecl; external;
{$ENDIF}

{ --- Implementation --- }

constructor TIRConvolverApp.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Randomize;
  {$IFDEF DARWIN}
  InitSoxrMacOS;
  InitPffftMacOS;
  {$ENDIF}
end;



procedure TIRConvolverApp.LoadConfig;
var Ini: TIniFile; Fn: string;
begin
  // Erst den Standard-Wert von der Kommandozeile holen
  FArtist := GetOptionValue('artist');
  
  // Wenn auf der Kommandozeile nichts übergeben wurde, aus der INI lesen
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


{ --- Mastering Dither Engine (2nd Order Noise Shaping) --- }

procedure TIRConvolverApp.ResetMasteringEngine(Channels: Integer);
var c: Integer;
begin
  SetLength(FErrorMem, Channels);
  for c := 0 to High(FErrorMem) do begin FErrorMem[c][0] := 0; FErrorMem[c][1] := 0; end;
end;

function TIRConvolverApp.ApplyMasteringDither(Sample: Single; Chan: Integer; Amount: Single): Single;
var Dither, ResVal, Error, LSB: Single;
begin
  LSB := 1.0 / 32767.0;
  Dither := ((Random - 0.5) + (Random - 0.5)) * LSB * Amount;
  if Abs(Sample) < (LSB * 2) then Dither := Dither * 0.7;
  
  ResVal := Sample + Dither + (FErrorMem[Chan][0] * 1.5) - (FErrorMem[Chan][1] * 0.5);
  ResVal := EnsureRange(ResVal, -1.0, 1.0);
  ResVal := Round(ResVal * 32767) / 32767.0;

  Error := Sample - ResVal;
  FErrorMem[Chan][1] := FErrorMem[Chan][0];
  FErrorMem[Chan][0] := Error;
  Result := ResVal;
end;

{ --- High-End Resampling (libsoxr VHQ) --- }

function TIRConvolverApp.ResampleSoxr(const Data: TAudioData; InSR, OutSR: Integer): TAudioData;
var
  resampler: Pointer;
  c: Integer;
  InLen, OutLen, DoneIn, DoneOut: Cardinal;
begin
  {$IFDEF DARWIN}
  if not Assigned(soxr_create) then raise Exception.Create('libsoxr konnte auf diesem Mac nicht geladen werden.');
  {$ENDIF}

  if InSR = OutSR then begin
    Result := Data; 
    Exit;
  end;
  if Length(Data) = 0 then Exit(nil);
  
  SetLength(Result, Length(Data));
  InLen := Length(Data[0]);
  OutLen := Round(InLen * (OutSR / InSR)) + 1000;

  for c := 0 to High(Data) do
  begin
    SetLength(Result[c], OutLen);
    resampler := soxr_create(InSR, OutSR, 1, nil, nil, nil, nil);
    try
      soxr_process(resampler, @Data[c][0], InLen, @DoneIn, @Result[c][0], OutLen, @DoneOut);
      SetLength(Result[c], DoneOut);
    finally
      soxr_delete(resampler);
    end;
  end;
end;

{ --- FFT Convolution (PFFFT) --- }

function TIRConvolverApp.ConvolveFFT(const Sig, Ker: TFloatBuffer): TFloatBuffer;
var
  setup: PPFFFT_Setup; n, i, L1, L2: Integer;
  in1, in2, f1, f2, fRes, work: PSingle;
begin
  {$IFDEF DARWIN}
  if not Assigned(pffft_new_setup) then raise Exception.Create('libpffft.dylib could not be loaded on this Mac.');
  {$ENDIF}

  L1 := Length(Sig); L2 := Length(Ker);
  n := 1; while n < (L1 + L2 - 1) do n := n shl 1;
  setup := pffft_new_setup(n, PFFFT_REAL);
  in1 := pffft_aligned_malloc(n * 4); in2 := pffft_aligned_malloc(n * 4);
  f1 := pffft_aligned_malloc(n * 4); f2 := pffft_aligned_malloc(n * 4);
  fRes := pffft_aligned_malloc(n * 4); work := pffft_aligned_malloc(n * 4);
  try
    FillChar(in1^, n * 4, 0); FillChar(in2^, n * 4, 0);
    if L1 > 0 then Move(Sig[0], in1^, L1 * 4);
    if L2 > 0 then Move(Ker[0], in2^, L2 * 4);
    pffft_transform_ordered(setup, in1, f1, work, PFFFT_FORWARD);
    pffft_transform_ordered(setup, in2, f2, work, PFFFT_FORWARD);
    pffft_zconvolve_accumulate(setup, f1, f2, fRes, 1.0);
    pffft_transform_ordered(setup, fRes, in1, work, PFFFT_BACKWARD);
    SetLength(Result, L1 + L2 - 1);
    for i := 0 to High(Result) do Result[i] := in1[i] / n;
  finally
    pffft_aligned_free(in1); pffft_aligned_free(in2); pffft_aligned_free(f1);
    pffft_aligned_free(f2); pffft_aligned_free(fRes); pffft_aligned_free(work);
    pffft_destroy_setup(setup);
  end;
end;

{ --- Audio I/O --- }

function TIRConvolverApp.LoadWav(const FileName: string; out SR: Integer): TAudioData;
var 
  FS: TFileStream; H: TWavHeader; i, c, Samples: Integer; s16: SmallInt; 
  b24: array[0..2] of Byte; s32: LongInt;
begin
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    FS.Read(H, SizeOf(H)); 
    SR := H.SampleRate;
    if (H.Channels = 0) or (H.BitsPerSample = 0) then Exit(nil);
    
    Samples := H.DataSize div (H.Channels * (H.BitsPerSample div 8));
    SetLength(Result, H.Channels);
    for c := 0 to H.Channels - 1 do SetLength(Result[c], Samples);
    
    for i := 0 to Samples - 1 do
      for c := 0 to H.Channels - 1 do begin
        if H.BitsPerSample = 16 then begin 
          FS.Read(s16, 2); 
          Result[c][i] := s16 / 32768.0; 
        end
        else begin 
          FS.Read(b24, 3); 
          // 24-Bit Shift mit Sign Extension für korrekte Vorzeichen im Pascal-LongInt
          s32 := (b24[0] shl 8) or (b24[1] shl 16) or (b24[2] shl 24);
          Result[c][i] := s32 / 2147483648.0; 
        end;
      end;
  finally FS.Free; end;
end;

procedure TIRConvolverApp.SaveWav(const FileName: string; const Data: TAudioData; SR, Bits: Integer; ForceMono: Boolean);
var 
  FS: TFileStream; H: TWavHeader; i, c, OutChans: Integer; s16: SmallInt; 
  s32: LongInt; b24: array[0..2] of Byte;
begin
  if (Length(Data) = 0) or (Length(Data[0]) = 0) then Exit;

  OutChans := IfThen(ForceMono, 1, Length(Data));
  FillChar(H, SizeOf(H), 0);
  H.RIFFID := 'RIFF'; H.WavID := 'WAVE'; H.FmtID := 'fmt '; H.FmtSize := 16;
  H.FormatTag := 1; H.Channels := OutChans; H.SampleRate := SR;
  H.BitsPerSample := Bits; H.BlockAlign := H.Channels * (Bits div 8);
  H.BytesPerSec := SR * H.BlockAlign; H.DataID := 'data';
  H.DataSize := Length(Data[0]) * H.BlockAlign; H.Size := 36 + H.DataSize;
  
  ResetMasteringEngine(OutChans);
  FS := TFileStream.Create(FileName, fmCreate);
  try
    FS.Write(H, SizeOf(H));
    for i := 0 to High(Data[0]) do
      for c := 0 to OutChans - 1 do begin
        if Bits = 16 then begin
          s16 := Round(ApplyMasteringDither(Data[c][i], c, 1.0) * 32767); 
          FS.Write(s16, 2);
        end else begin
          s32 := Round(EnsureRange(Data[c][i], -1.0, 1.0) * 8388607);
          b24[0] := s32 and $FF; 
          b24[1] := (s32 shr 8) and $FF; 
          b24[2] := (s32 shr 16) and $FF; 
          FS.Write(b24, 3);
        end;
      end;
    if FArtist <> '' then WriteInfoChunk(FS, 'IART', FArtist);
  finally FS.Free; end;
end;

{ --- Helpers & DSP Utility --- }

procedure TIRConvolverApp.WriteInfoChunk(Stream: TStream; const ID: string; const Value: string);
var Len: LongInt; Zero: Char = #0;
begin
  if Length(Value) = 0 then Exit;
  Stream.Write(ID, 4); Len := Length(Value) + 1; Stream.Write(Len, 4);
  Stream.Write(Value[1], Length(Value)); Stream.Write(Zero, 1);
  if (Len mod 2 <> 0) then Stream.Write(Zero, 1);
end;

procedure TIRConvolverApp.Normalize(var Data: TAudioData);
var m: Single; c, i: Integer;
begin
  m := 0; for c := 0 to High(Data) do for i := 0 to High(Data[c]) do m := Max(m, Abs(Data[c][i]));
  if m > 1e-7 then for c := 0 to High(Data) do for i := 0 to High(Data[c]) do Data[c][i] := Data[c][i] / m;
end;

function TIRConvolverApp.ConvertToMinimumPhase(const Data: TFloatBuffer): TFloatBuffer;
begin
  Result := Data;
end;

procedure TIRConvolverApp.ApplyFades(var Data: TAudioData; SR: Integer; InMS, OutMS: Single);
begin
end;

procedure TIRConvolverApp.TrimSilence(var Data: TAudioData; ThresholdDB: Single);
begin
end;

{ --- Hauptprogramm ausführen --- }

procedure TIRConvolverApp.DoRun;
var 
  StartTime: Int64;
  f1, f2, fOut, Msg: string; 
  A1, A2, Res: TAudioData; 
  SR1, SR2, bOut, c, TargetSR: Integer;
begin
  LoadConfig;
  
  { Registriert die erlaubten Parameter, damit TCustomApplication sie versteht }
  Msg := CheckOptions('i1:i2:o:b:r:l:h:m', 'help:mono:min');
  if (Msg <> '') or HasOption('h', 'help') or (ParamCount < 2) then begin 
    if Msg <> '' then WriteLn(StdErr, 'Parameter-Fehler: ', Msg);
    ShowUsage; 
    Terminate(1); // Setzt den Exit-Code auf 1 für die Actions
    Exit; 
  end;


procedure TIRConvolverApp.ShowUsage;
begin
  WriteLn('IRConvolverPro v1.0 [BSD-3-Clause]');
  WriteLn('Usage: -i1 <src> -i2 <ir> -o <out> [options]');
  WriteLn('Options:');
  WriteLn('  -b <16|24|32>    Output bit depth');
  WriteLn('  -r <rate>        Target sample rate (Resampling via libsoxr)');
  WriteLn('  --min            Minimum Phase Transform');
  WriteLn('  -m, --mono       Mixdown to mono');
end;

begin
  with TIRConvolverApp.Create(nil) do try Run; finally Free; end;
end.
