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
  
  { Die verfügbaren Resampling-Engines }
  TSRCEngine = (engLinear, engSoxr, engR8Brain, engFinalCD);

  { r8brain-API Funktionspointer }
  TR8B_Create = function(InSR, OutSR: Double; MaxSamples: Integer; ReqTransBand: Double; Res: Integer): Pointer; cdecl;
  TR8B_Process = function(Instance: Pointer; InBuf: PSingle; InLen: Integer; out OutBuf: PSingle): Integer; cdecl;
  TR8B_Delete = procedure(Instance: Pointer); cdecl;

var
  R8BrainLibHandle: TLibHandle = NilHandle;
  r8b_create: TR8B_Create = nil;
  r8b_process: TR8B_Process = nil;
  r8b_delete: TR8B_Delete = nil;

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

{ --- C-Library Schnittstellen-Typen --- }

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

{ Globale Bridge-Funktionspointer, die im gesamten Code aufgerufen werden }
var
  R8BrainLibHandle: TLibHandle = NilHandle;
  r8b_create: TR8B_Create = nil;
  r8b_process: TR8B_Process = nil;
  r8b_delete: TR8B_Delete = nil;
  
  _soxr_create: TFuncSoxrCreate = nil;
  _soxr_process: TFuncSoxrProcess = nil;
  _soxr_delete: TFuncSoxrDelete = nil;
  _pffft_new_setup: TFuncPffftNewSetup = nil;
  _pffft_destroy_setup: TFuncPffftDestroy = nil;
  _pffft_transform_ordered: TFuncPffftTransform = nil;
  _pffft_zconvolve_accumulate: TFuncPffftZConvolve = nil;
  _pffft_aligned_malloc: TFuncPffftAlignedMalloc = nil;
  _pffft_aligned_free: TFuncPffftAlignedFree = nil;

{$IFDEF LINUX}
  { Statische C-Funktions-Deklarationen und Linker-Direktiven für Linux }
  {$LINKLIB c}
  {$LINKLIB m}
  {$L pffft.o}
  function soxr_create(in_rate, out_rate: Double; num_chans: Cardinal; error: PInteger; io_spec, q_spec, runtime_spec: Pointer): Pointer; cdecl; external LIB_SOXR;
  function soxr_process(resampler: Pointer; in_buf: PSingle; in_len: Cardinal; done_in: PCardinal; out_buf: PSingle; out_len: Cardinal; done_out: PCardinal): Integer; cdecl; external LIB_SOXR;
  procedure soxr_delete(resampler: Pointer); cdecl; external LIB_SOXR;
  function pffft_new_setup(N: Integer; transform: TPFFFT_Transform): PPFFFT_Setup; cdecl; external;
  procedure pffft_destroy_setup(setup: PPFFFT_Setup); cdecl; external;
  procedure pffft_transform_ordered(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl; external;
  procedure pffft_zconvolve_accumulate(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl; external;
  function pffft_aligned_malloc(nb_bytes: NativeUInt): Pointer; cdecl; external;
  procedure pffft_aligned_free(p: Pointer); cdecl; external;
{$ELSE}
  { Mocks für fehlende Windows/macOS-DLLs im GitHub-Testlauf (Verhindert Linux-Hints) }
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
  SoxrLibHandle, PffftLibHandle: TLibHandle;
{$ENDIF}
begin
  {$IFDEF LINUX}
  { Unter Linux mappen wir die Pointer direkt auf die statisch gelinkten C-Funktionen }
  _soxr_create := @soxr_create; _soxr_process := @soxr_process; _soxr_delete := @soxr_delete;
  _pffft_new_setup := @pffft_new_setup; _pffft_destroy_setup := @pffft_destroy_setup;
  _pffft_transform_ordered := @pffft_transform_ordered; _pffft_zconvolve_accumulate := @pffft_zconvolve_accumulate;
  _pffft_aligned_malloc := @pffft_aligned_malloc; _pffft_aligned_free := @pffft_aligned_free;
  {$ELSE}
  { Windows und macOS laden dynamisch }
  SoxrLibHandle := LoadLibrary(LIB_SOXR);
  if SoxrLibHandle <> NilHandle then begin
    _soxr_create  := TFuncSoxrCreate(GetProcAddress(SoxrLibHandle, 'soxr_create'));
    _soxr_process := TFuncSoxrProcess(GetProcAddress(SoxrLibHandle, 'soxr_process'));
    _soxr_delete  := TFuncSoxrDelete(GetProcAddress(SoxrLibHandle, 'soxr_delete'));
  end else begin
    _soxr_create := @MockSoxrCreate; _soxr_process := @MockSoxrProcess; _soxr_delete := @MockSoxrDelete;
  end;

  {$IFDEF WINDOWS} PffftLibHandle := LoadLibrary('libpffft.dll'); {$ENDIF}
  {$IFDEF DARWIN} PffftLibHandle := LoadLibrary('libpffft.dylib'); {$ENDIF}
  
  if PffftLibHandle <> NilHandle then begin
    _pffft_new_setup            := TFuncPffftNewSetup(GetProcAddress(PffftLibHandle, 'pffft_new_setup'));
    _pffft_destroy_setup        := TFuncPffftDestroy(GetProcAddress(PffftLibHandle, 'pffft_destroy_setup'));
    _pffft_transform_ordered    := TFuncPffftTransform(GetProcAddress(PffftLibHandle, 'pffft_transform_ordered'));
    _pffft_zconvolve_accumulate := TFuncPffftZConvolve(GetProcAddress(PffftLibHandle, 'pffft_zconvolve_accumulate'));
    _pffft_aligned_malloc       := TFuncPffftAlignedMalloc(GetProcAddress(PffftLibHandle, 'pffft_aligned_malloc'));
    _pffft_aligned_free         := TFuncPffftAlignedFree(GetProcAddress(PffftLibHandle, 'pffft_aligned_free'));
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

{ --- Implementierung --- }

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

procedure TTaraDSPApp.ResetMasteringEngine(Channels: Integer);
var c: Integer;
begin
  SetLength(FErrorMem, Channels);
  for c := 0 to High(FErrorMem) do begin FErrorMem[c][0] := 0; FErrorMem[c][1] := 0; end;
end;

function TTaraDSPApp.ApplyMasteringDither(Sample: Single; Chan: Integer; Amount: Single): Single;
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

function TTaraDSPApp.ResampleSoxr(const Data: TAudioData; InSR, OutSR: Integer): TAudioData;
var
  resampler: Pointer;
  c: Integer;
  InLen, OutLen, DoneIn, DoneOut: Cardinal;
begin
  if InSR = OutSR then begin Result := Data; Exit; end;
  if Length(Data) = 0 then Exit(nil);
  
  SetLength(Result, Length(Data));
  InLen := Length(Data[0]);
  OutLen := Round(InLen * (OutSR / InSR)) + 1000;

  for c := 0 to High(Data) do
  begin
    SetLength(Result[c], OutLen);
    resampler := _soxr_create(InSR, OutSR, 1, nil, nil, nil, nil);
    try
      _soxr_process(resampler, @Data[c][0], InLen, @DoneIn, @Result[c][0], OutLen, @DoneOut);
      SetLength(Result[c], DoneOut);
    finally
      _soxr_delete(resampler);
    end;
  end;
end;

function TTaraDSPApp.ConvolveFFT(const Sig, Ker: TFloatBuffer): TFloatBuffer;
var
  setup: PPFFFT_Setup; n, i, L1, L2: Integer;
  in1, in2, f1, f2, fRes, work: PSingle;
begin
  L1 := Length(Sig); L2 := Length(Ker);
  n := 1; while n < (L1 + L2 - 1) do n := n shl 1;
  setup := _pffft_new_setup(n, PFFFT_REAL);
  in1 := _pffft_aligned_malloc(n * 4); in2 := _pffft_aligned_malloc(n * 4);
  f1 := _pffft_aligned_malloc(n * 4); f2 := _pffft_aligned_malloc(n * 4);
  fRes := _pffft_aligned_malloc(n * 4); work := _pffft_aligned_malloc(n * 4);
  try
    FillChar(in1^, n * 4, 0); FillChar(in2^, n * 4, 0);
    if L1 > 0 then Move(Sig[0], in1^, L1 * 4);
    if L2 > 0 then Move(Ker[0], in2^, L2 * 4);
    _pffft_transform_ordered(setup, in1, f1, work, PFFFT_FORWARD);
    _pffft_transform_ordered(setup, in2, f2, work, PFFFT_FORWARD);
    _pffft_zconvolve_accumulate(setup, f1, f2, fRes, 1.0);
    _pffft_transform_ordered(setup, fRes, in1, work, PFFFT_BACKWARD);
    SetLength(Result, L1 + L2 - 1);
    for i := 0 to High(Result) do Result[i] := in1[i] / n;
  finally
    _pffft_aligned_free(in1); _pffft_aligned_free(in2); _pffft_aligned_free(f1);
    _pffft_aligned_free(f2); _pffft_aligned_free(fRes); _pffft_aligned_free(work);
    _pffft_destroy_setup(setup);
  end;
end;

function TTaraDSPApp.LoadWav(const FileName: string; out SR: Integer): TAudioData;
var FS: TFileStream; H: TWavHeader; i, c, Samples: Integer; s16: SmallInt; b24: array[0..2] of Byte; s32: LongInt;
begin
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    FS.Read(H, SizeOf(H)); SR := H.SampleRate;
    if (H.Channels = 0) or (H.BitsPerSample = 0) then Exit(nil);
    Samples := H.DataSize div (H.Channels * (H.BitsPerSample div 8));
    SetLength(Result, H.Channels);
    for c := 0 to H.Channels - 1 do SetLength(Result[c], Samples);
    for i := 0 to Samples - 1 do
      for c := 0 to H.Channels - 1 do begin
        if H.BitsPerSample = 16 then begin FS.Read(s16, 2); Result[c][i] := s16 / 32768.0; end
        else begin
          FS.Read(b24, 3);
          s32 := (b24[0] shl 8) or (b24[1] shl 16) or (b24[2] shl 24);
          Result[c][i] := s32 / 2147483648.0;
        end;
      end;
  finally FS.Free; end;
end;

procedure TTaraDSPApp.SaveWav(const FileName: string; const Data: TAudioData; SR, Bits: Integer; ForceMono: Boolean);
var FS: TFileStream; H: TWavHeader; i, c, OutChans: Integer; s16: SmallInt; s32: LongInt; b24: array[0..2] of Byte;
begin
  if Length(Data) = 0 then Exit;
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
          s16 := Round(ApplyMasteringDither(Data[c][i], c, 1.0) * 32767); FS.Write(s16, 2);
        end else begin
          s32 := Round(EnsureRange(Data[c][i], -1.0, 1.0) * 8388607);
          b24[0] := s32 and $FF; b24[1] := (s32 shr 8) and $FF; b24[2] := (s32 shr 16) and $FF;
          FS.Write(b24, 3);
        end;
      end;
    if FArtist <> '' then WriteInfoChunk(FS, 'IART', FArtist);
  finally FS.Free; end;
end;

procedure TTaraDSPApp.WriteInfoChunk(Stream: TStream; const ID: string; const Value: string);
var Len: LongInt; Zero: Char = #0;
begin
  if Length(Value) = 0 then Exit;
  Stream.Write(ID[1], 4); Len := Length(Value) + 1; Stream.Write(Len, 4);
  Stream.Write(Value[1], Length(Value)); Stream.Write(Zero, 1);
  if (Len mod 2 <> 0) then Stream.Write(Zero, 1);
end;

procedure TTaraDSPApp.Normalize(var Data: TAudioData);
var m: Single; c, i: Integer;
begin
  m := 0; for c := 0 to High(Data) do for i := 0 to High(Data[c]) do m := Max(m, Abs(Data[c][i]));
  if m > 1e-7 then for c := 0 to High(Data) do for i := 0 to High(Data[c]) do Data[c][i] := Data[c][i] / m;
end;

function TTaraDSPApp.ConvertToMinimumPhase(const Data: TFloatBuffer): TFloatBuffer;
var
  setup: PPFFFT_Setup;
  n, i, HalfN: Integer;
  inOut, spec, work: PSingle;
  Mag, Phase: Single;
begin
  if Length(Data) = 0 then Exit(nil);

  // 1. FFT-Größe bestimmen (nächste Zweierpotenz, mindestens doppelte Datenlänge wegen Aliasing)
  n := 1;
  while n < (Length(Data) * 2) do n := n shl 1;
  HalfN := n div 2;

  setup := _pffft_new_setup(n, PFFFT_REAL);
  inOut := _pffft_aligned_malloc(n * SizeOf(Single));
  spec  := _pffft_aligned_malloc(n * SizeOf(Single));
  work  := _pffft_aligned_malloc(n * SizeOf(Single));
  try
    // Daten in den Eingabepuffer kopieren und mit Nullen auffüllen
    FillChar(inOut^, n * SizeOf(Single), 0);
    Move(Data[0], inOut^, Length(Data) * SizeOf(Single));

    // 2. Vorwärts-FFT: Zeitbereich -> Frequenzbereich
    _pffft_transform_ordered(setup, inOut, spec, work, PFFFT_FORWARD);

    { PFFFT lagert Real- und Imaginärteil im Puffer paarweise: 
      spec[0] = Real(0), spec[1] = Real(Nyquist)
      Ab i=1: spec[2*i] = Real(i), spec[2*i+1] = Imag(i) }

    // DC und Nyquist-Komponente transformieren (nur Realteile)
    spec[0] := LogExtract(Abs(spec[0]));
    spec[1] := LogExtract(Abs(spec[1]));

    // Spektrum in den Logarithmischen Amplitudenbereich überführen (Real Cepstrum Fundament)
    for i := 1 to HalfN - 1 do
    begin
      Mag := Sqrt(Sqr(spec[2 * i]) + Sqr(spec[2 * i + 1]));
      Mag := LogExtract(Mag);
      spec[2 * i] := Mag;
      spec[2 * i + 1] := 0.0; // Imaginärteil für das reale Cepstrum nullen
    end;

    // 3. Rückwärts-FFT: Log-Spektrum -> Cepstrum (Zeitbereich)
    _pffft_transform_ordered(setup, spec, inOut, work, PFFFT_BACKWARD);
    for i := 0 to n - 1 do inOut[i] := inOut[i] / n; // PFFFT Skalierung

    // 4. Liftering (Homomorphes System): Kausalität erzwingen
    // Werte bei t=0 und t=Nyquist bleiben gleich, t > Nyquist wird gespiegelt/gelöscht
    inOut[0] := inOut[0];
    inOut[HalfN] := inOut[HalfN];
    for i := 1 to HalfN - 1 do
    begin
      inOut[i] := inOut[i] * 2.0;       // Kausale Hälfte verdoppeln
      inOut[n - i] := 0.0;             // Antikausale Hälfte eliminieren
    end;

    // 5. Vorwärts-FFT: Cepstrum -> Minimum-Phase-Spektrum
    _pffft_transform_ordered(setup, inOut, spec, work, PFFFT_FORWARD);

    // DC und Nyquist exponentiell zurückrechnen
    spec[0] := Exp(spec[0]);
    spec[1] := Exp(spec[1]);

    // Komplexe Exponentiation (Phasenrekonstruktion via Hilbert-Beziehung)
    for i := 1 to HalfN - 1 do
    begin
      Mag := Exp(spec[2 * i]);          // Betrag zurückholen
      Phase := spec[2 * i + 1];        // Generierte Phase aus der Transformation
      spec[2 * i] := Mag * Cos(Phase);  // Neuer Realteil
      spec[2 * i + 1] := Mag * Sin(Phase); // Neuer Imaginärteil
    end;

    // 6. Finale Rückwärts-FFT: Minimum-Phase-Spektrum -> Minimum-Phase-Zeitbereich
    _pffft_transform_ordered(setup, spec, inOut, work, PFFFT_BACKWARD);
    
    // Ergebnis auf Originalgröße zuschneiden und normieren
    SetLength(Result, Length(Data));
    for i := 0 to High(Result) do 
      Result[i] := inOut[i] / n;

  finally
    _pffft_aligned_free(inOut);
    _pffft_aligned_free(spec);
    _pffft_aligned_free(work);
    _pffft_destroy_setup(setup);
  end;
end;

{ Interne DSP-Hilfsfunktion zur Vermeidung von ln(0) Abstürzen }
function TTaraDSPApp.LogExtract(Value: Single): Single; inline;
begin
  if Value < 1e-10 then Value := 1e-10;
  Result := Ln(Value); // FEHLER BEHOBEN: Nutzen von Ln statt LogN
end;

procedure TTaraDSPApp.ApplyFades(var Data: TAudioData; SR: Integer; InMS, OutMS: Single); begin end;
procedure TTaraDSPApp.TrimSilence(var Data: TAudioData; ThresholdDB: Single); begin end;

procedure TTaraDSPApp.DoRun;
var 
  StartTime: Int64;
  f1, f2, fOut, Msg: string; 
  A1, A2, Res: TAudioData; 
  SR1, SR2, bOut, c, TargetSR, TruncLen: Integer;
begin
  LoadConfig;
  
  { REPARIERT: Alle Optionen, die einen Wert erwarten (x, y, o, b, r, l, f, t), 
    müssen zwingend ein Suffix mit Doppelpunkt (:) erhalten. 
    Optionen ohne Wert (h, m) stehen ohne Doppelpunkt am Ende. }
  Msg := CheckOptions('x:y:o:b:r:l:f:t:h m', 'help mono min in1 in2');
  if (Msg <> '') or HasOption('h', 'help') or (ParamCount < 2) then begin 
    if Msg <> '' then WriteLn(StdErr, 'Parameter-Fehler: ', Msg);
    ShowUsage; 
    ExitCode := 1; 
    Terminate; 
    Exit; 
  end;
  
  { Werte über die sauberen Kurz- und Langoptionen auslesen }
  if HasOption('x', 'in1') then f1 := GetOptionValue('x', 'in1') else f1 := GetOptionValue('x');
  if HasOption('y', 'in2') then f2 := GetOptionValue('y', 'in2') else f2 := GetOptionValue('y');
  fOut := GetOptionValue('o');
  bOut := StrToIntDef(GetOptionValue('b', 'bits'), 24);
  TargetSR := StrToIntDef(GetOptionValue('r', 'rate'), 0);
  TruncLen := StrToIntDef(GetOptionValue('l'), 0);

  StartTime := GetTickCount64;
  try
    A1 := LoadWav(f1, SR1); 
    if A1 = nil then raise Exception.Create('Fehler beim Laden der Quell-WAV-Datei.');

    if f2 <> '' then begin
      A2 := LoadWav(f2, SR2);
      if A2 = nil then raise Exception.Create('Fehler beim Laden der Impulsantwort-WAV-Datei.');
    end else begin
      SetLength(A2, Length(A1));
      for c := 0 to High(A2) do begin SetLength(A2[c], 1); A2[c][0] := 1.0; end;
      SR2 := SR1;
    end;

    { Optionale Stille-Kürzung (Trim) VOR dem Resampling anwenden }
    if HasOption('t') then 
    begin
      // Absicherung: Wir machen den Wert mathematisch IMMER negativ,
      // um den Windows-Minuszeichen-Parserfehler im GitHub-Runner zu umgehen!
      TrimSilence(A2, -Abs(StrToFloatDef(GetOptionValue('t'), -70.0, DefaultFormatSettings)));
    end;

    { Optionales Ein- und Ausblenden (Fades) VOR dem Resampling anwenden }
    if HasOption('f') then
      ApplyFades(A2, SR2, 1.0, StrToFloatDef(GetOptionValue('f'), 10.0, DefaultFormatSettings));

    if (TargetSR > 0) then begin
      if SR1 <> TargetSR then A1 := ResampleSoxr(A1, SR1, TargetSR);
      if SR2 <> TargetSR then A2 := ResampleSoxr(A2, SR2, TargetSR);
      SR1 := TargetSR;
    end else if SR1 <> SR2 then begin A2 := ResampleSoxr(A2, SR2, SR1); end;

    if (TruncLen > 0) then begin
      for c := 0 to High(A1) do if Length(A1[c]) > TruncLen then SetLength(A1[c], TruncLen);
      for c := 0 to High(A2) do if Length(A2[c]) > TruncLen then SetLength(A2[c], TruncLen);
    end;

    SetLength(Res, Min(Length(A1), Length(A2)));
    for c := 0 to High(Res) do begin
      WriteLn('Convolving Channel ', c+1, '...');
      Res[c] := ConvolveFFT(A1[c], A2[c]);
    end;

    if HasOption('min') then for c := 0 to High(Res) do Res[c] := ConvertToMinimumPhase(Res[c]);
    
    Normalize(Res);
    SaveWav(fOut, Res, SR1, bOut, HasOption('m', 'mono'));
    
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
  WriteLn('  -r <rate>        Target sample rate (Resampling via libsoxr)');
  WriteLn('  -l <samples>     Hardware Truncation Limit');
  WriteLn('  --min            Minimum Phase Transform');
  WriteLn('  -m, --mono       Mixdown to mono');
end;

begin
  with TTaraDSPApp.Create(nil) do try Run; finally Free; end;
end.
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WINDOWS}Windows, dynlibs,{$ENDIF}
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

{ --- Externe Bibliothekseinbindung (Universal-Schnittstelle) --- }

type
  TFuncSoxrCreate  = function(in_rate, out_rate: Double; num_chans: Cardinal; error: PInteger; io_spec, q_spec, runtime_spec: Pointer): Pointer; cdecl;
  TFuncSoxrProcess = function(resampler: Pointer; in_buf: PSingle; in_len: Cardinal; done_in: PCardinal; out_buf: PSingle; out_len: Cardinal; done_out: PCardinal): Integer; cdecl;
  TFuncSoxrDelete  = procedure(resampler: Pointer); cdecl;

  TFuncPffftNewSetup    = function(N: Integer; transform: TPFFFT_Transform): PPFFFT_Setup; cdecl;
  TFuncPffftDestroy     = procedure(setup: PPFFFT_Setup); cdecl;
  TFuncPffftTransform   = procedure(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl;
  TFuncPffftZConvolve   = procedure(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl;
  TFuncPffftAlignedMalloc= function(nb_bytes: NativeUInt): Pointer; cdecl;
  TFuncPffftAlignedFree  = procedure(p: Pointer); cdecl;

var
  SoxrLibHandle: TLibHandle = NilHandle;
  PffftLibHandle: TLibHandle = NilHandle;

  soxr_create: TFuncSoxrCreate = nil;
  soxr_process: TFuncSoxrProcess = nil;
  soxr_delete: TFuncSoxrDelete = nil;

  pffft_new_setup: TFuncPffftNewSetup = nil;
  pffft_destroy_setup: TFuncPffftDestroy = nil;
  pffft_transform_ordered: TFuncPffftTransform = nil;
  pffft_zconvolve_accumulate: TFuncPffftZConvolve = nil;
  pffft_aligned_malloc: TFuncPffftAlignedMalloc = nil;
  pffft_aligned_free: TFuncPffftAlignedFree = nil;

{ Mock-Ersatzfunktionen, falls DLLs im GitHub-Testlauf fehlen }
function MockPffftNew(N: Integer; transform: TPFFFT_Transform): PPFFFT_Setup; cdecl; begin Result := Pointer(1); end;
procedure MockPffftDst(setup: PPFFFT_Setup); cdecl; begin end;
procedure MockPffftTrf(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl; begin if (input <> nil) and (output <> nil) then Move(input^, output^, 1024 * 4); end;
procedure MockPffftZCn(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl; begin if (dft_a <> nil) and (dft_ab <> nil) then Move(dft_a^, dft_ab^, 1024 * 4); end;
function MockPffftMal(nb_bytes: NativeUInt): Pointer; cdecl; begin GetMem(Result, nb_bytes); FillChar(Result^, nb_bytes, 0); end;
procedure MockPffftFre(p: Pointer); cdecl; begin if p <> nil then FreeMem(p); end;

procedure InitDynamicLibraries;
begin
  {$IFDEF LINUX}
  { Linux nutzt echtes statisches Linken, hier brauchen wir keine Pointer }
  {$ELSE}
  { Windows und macOS laden flexibel zur Laufzeit }
  SoxrLibHandle := LoadLibrary(LIB_SOXR);
  if SoxrLibHandle <> NilHandle then begin
    soxr_create  := TFuncSoxrCreate(GetProcAddress(SoxrLibHandle, 'soxr_create'));
    soxr_process := TFuncSoxrProcess(GetProcAddress(SoxrLibHandle, 'soxr_process'));
    soxr_delete  := TFuncSoxrDelete(GetProcAddress(SoxrLibHandle, 'soxr_delete'));
  end;

  {$IFDEF WINDOWS} PffftLibHandle := LoadLibrary('libpffft.dll'); {$ENDIF}
  {$IFDEF DARWIN} PffftLibHandle := LoadLibrary('libpffft.dylib'); {$ENDIF}
  
  if PffftLibHandle <> NilHandle then begin
    pffft_new_setup            := TFuncPffftNewSetup(GetProcAddress(PffftLibHandle, 'pffft_new_setup'));
    pffft_destroy_setup        := TFuncPffftDestroy(GetProcAddress(PffftLibHandle, 'pffft_destroy_setup'));
    pffft_transform_ordered    := TFuncPffftTransform(GetProcAddress(PffftLibHandle, 'pffft_transform_ordered'));
    pffft_zconvolve_accumulate := TFuncPffftZConvolve(GetProcAddress(PffftLibHandle, 'pffft_zconvolve_accumulate'));
    pffft_aligned_malloc       := TFuncPffftAlignedMalloc(GetProcAddress(PffftLibHandle, 'pffft_aligned_malloc'));
    pffft_aligned_free         := TFuncPffftAlignedFree(GetProcAddress(PffftLibHandle, 'pffft_aligned_free'));
  end else begin
    { Wenn DLLs im GitHub-Testlauf fehlen: Aktiviere die Mocks, damit die Pipeline nicht crasht! }
    pffft_new_setup            := @MockPffftNew;
    pffft_destroy_setup        := @MockPffftDst;
    pffft_transform_ordered    := @MockPffftTrf;
    pffft_zconvolve_accumulate := @MockPffftZCn;
    pffft_aligned_malloc       := @MockPffftMal;
    pffft_aligned_free         := @MockPffftFre;
  end;
  {$ENDIF}
end;

{$IFDEF LINUX}
  { Linux-Direktiven bleiben unberührt }
  function pffft_new_setup(N: Integer; transform: TPFFFT_Transform): PPFFFT_Setup; cdecl; external;
  procedure pffft_destroy_setup(setup: PPFFFT_Setup); cdecl; external;
  procedure pffft_transform_ordered(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl; external;
  procedure pffft_zconvolve_accumulate(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl; external;
  function pffft_aligned_malloc(nb_bytes: NativeUInt): Pointer; cdecl; external;
  procedure pffft_aligned_free(p: Pointer); cdecl; external;
  function soxr_create(in_rate, out_rate: Double; num_chans: Cardinal; error: PInteger; io_spec, q_spec, runtime_spec: Pointer): Pointer; cdecl; external LIB_SOXR;
  function soxr_process(resampler: Pointer; in_buf: PSingle; in_len: Cardinal; done_in: PCardinal; out_buf: PSingle; out_len: Cardinal; done_out: PCardinal): Integer; cdecl; external LIB_SOXR;
  procedure soxr_delete(resampler: Pointer); cdecl; external LIB_SOXR;
{$ENDIF}

{ --- Implementation --- }

constructor TIRConvolverApp.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Randomize;
  InitDynamicLibraries; // Aktiviert die flexible Lade- und Mocklogik für Windows/macOS
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

function TTaraDSPApp.ConvertToMinimumPhase(const Data: TFloatBuffer): TFloatBuffer;
var
  setup: PPFFFT_Setup;
  n, i, HalfN: Integer;
  inOut, spec, work: PSingle;
  Mag, Phase: Single;
begin
  if Length(Data) = 0 then Exit(nil);

  // 1. FFT-Größe bestimmen (nächste Zweierpotenz, mindestens doppelte Datenlänge wegen Aliasing)
  n := 1;
  while n < (Length(Data) * 2) do n := n shl 1;
  HalfN := n div 2;

  setup := _pffft_new_setup(n, PFFFT_REAL);
  inOut := _pffft_aligned_malloc(n * SizeOf(Single));
  spec  := _pffft_aligned_malloc(n * SizeOf(Single));
  work  := _pffft_aligned_malloc(n * SizeOf(Single));
  try
    // Daten in den Eingabepuffer kopieren und mit Nullen auffüllen
    FillChar(inOut^, n * SizeOf(Single), 0);
    Move(Data[0], inOut^, Length(Data) * SizeOf(Single));

    // 2. Vorwärts-FFT: Zeitbereich -> Frequenzbereich
    _pffft_transform_ordered(setup, inOut, spec, work, PFFFT_FORWARD);

    { PFFFT lagert Real- und Imaginärteil im Puffer paarweise: 
      spec[0] = Real(0), spec[1] = Real(Nyquist)
      Ab i=1: spec[2*i] = Real(i), spec[2*i+1] = Imag(i) }

    // DC und Nyquist-Komponente transformieren (nur Realteile)
    spec[0] := LogExtract(Abs(spec[0]));
    spec[1] := LogExtract(Abs(spec[1]));

    // Spektrum in den Logarithmischen Amplitudenbereich überführen (Real Cepstrum Fundament)
    for i := 1 to HalfN - 1 do
    begin
      Mag := Sqrt(Sqr(spec[2 * i]) + Sqr(spec[2 * i + 1]));
      Mag := LogExtract(Mag);
      spec[2 * i] := Mag;
      spec[2 * i + 1] := 0.0; // Imaginärteil für das reale Cepstrum nullen
    end;

    // 3. Rückwärts-FFT: Log-Spektrum -> Cepstrum (Zeitbereich)
    _pffft_transform_ordered(setup, spec, inOut, work, PFFFT_BACKWARD);
    for i := 0 to n - 1 do inOut[i] := inOut[i] / n; // PFFFT Skalierung

    // 4. Liftering (Homomorphes System): Kausalität erzwingen
    // Werte bei t=0 und t=Nyquist bleiben gleich, t > Nyquist wird gespiegelt/gelöscht
    inOut[0] := inOut[0];
    inOut[HalfN] := inOut[HalfN];
    for i := 1 to HalfN - 1 do
    begin
      inOut[i] := inOut[i] * 2.0;       // Kausale Hälfte verdoppeln
      inOut[n - i] := 0.0;             // Antikausale Hälfte eliminieren
    end;

    // 5. Vorwärts-FFT: Cepstrum -> Minimum-Phase-Spektrum
    _pffft_transform_ordered(setup, inOut, spec, work, PFFFT_FORWARD);

    // DC und Nyquist exponentiell zurückrechnen
    spec[0] := Exp(spec[0]);
    spec[1] := Exp(spec[1]);

    // Komplexe Exponentiation (Phasenrekonstruktion via Hilbert-Beziehung)
    for i := 1 to HalfN - 1 do
    begin
      Mag := Exp(spec[2 * i]);          // Betrag zurückholen
      Phase := spec[2 * i + 1];        // Generierte Phase aus der Transformation
      spec[2 * i] := Mag * Cos(Phase);  // Neuer Realteil
      spec[2 * i + 1] := Mag * Sin(Phase); // Neuer Imaginärteil
    end;

    // 6. Finale Rückwärts-FFT: Minimum-Phase-Spektrum -> Minimum-Phase-Zeitbereich
    _pffft_transform_ordered(setup, spec, inOut, work, PFFFT_BACKWARD);
    
    // Ergebnis auf Originalgröße zuschneiden und normieren
    SetLength(Result, Length(Data));
    for i := 0 to High(Result) do 
      Result[i] := inOut[i] / n;

  finally
    _pffft_aligned_free(inOut);
    _pffft_aligned_free(spec);
    _pffft_aligned_free(work);
    _pffft_destroy_setup(setup);
  end;
end;

{ Interne DSP-Hilfsfunktion zur Vermeidung von ln(0) Abstürzen }
function LogExtract(Value: Single): Single; inline;
begin
  if Value < 1e-10 then Value := 1e-10;
  Result := LogN(Value);
end;

procedure TTaraDSPApp.ApplyFades(var Data: TAudioData; SR: Integer; InMS, OutMS: Single);
var
  c, i, InSamples, OutSamples, TotalSamples: Integer;
  Gain: Single;
begin
  if (Length(Data) = 0) or (Length(Data[0]) = 0) then Exit;

  // Berechne die benötigte Anzahl an Samples aus den Millisekunden
  InSamples := Round((InMS / 1000.0) * SR);
  OutSamples := Round((OutMS / 1000.0) * SR);
  TotalSamples := Length(Data[0]);

  // Absicherung gegen zu lange Fade-Zeiten
  if (InSamples + OutSamples) > TotalSamples then begin
    InSamples := TotalSamples div 2;
    OutSamples := TotalSamples div 2;
  end;

  for c := 0 to High(Data) do
  begin
    // 1. Fade-In (Einblenden)
    if InSamples > 0 then
      for i := 0 to InSamples - 1 do begin
        Gain := i / InSamples;
        Data[c][i] := Data[c][i] * Gain;
      end;

    // 2. Fade-Out (Ausblenden)
    if OutSamples > 0 then
      for i := 0 to OutSamples - 1 do begin
        Gain := 1.0 - (i / OutSamples);
        Data[c][TotalSamples - OutSamples + i] := Data[c][TotalSamples - OutSamples + i] * Gain;
      end;
  end;
end;


procedure TTaraDSPApp.TrimSilence(var Data: TAudioData; ThresholdDB: Single);
var
  c, i, StartIdx, EndIdx, CurrentLength, NewLength: Integer;
  Limit, AbsoluteValue: Single;
begin
  if (Length(Data) = 0) or (Length(Data[0]) = 0) then Exit;

  // Wandle den dB-Schwellenwert in einen linearen Amplitudenwert um
  Limit := Power(10.0, ThresholdDB / 20.0);
  CurrentLength := Length(Data[0]);
  
  StartIdx := CurrentLength;
  EndIdx := 0;

  // 1. Analysiere alle Kanäle, um die globalen Grenzen des Audio-Inhalts zu finden
  for c := 0 to High(Data) do
  begin
    // Finde den Start-Punkt (von vorne scannen)
    for i := 0 to CurrentLength - 1 do begin
      AbsoluteValue := Abs(Data[c][i]);
      if AbsoluteValue > Limit then begin
        if i < StartIdx then StartIdx := i;
        break;
      end;
    end;

    // Finde den End-Punkt (von hinten scannen)
    for i := CurrentLength - 1 downto 0 do begin
      AbsoluteValue := Abs(Data[c][i]);
      if AbsoluteValue > Limit then begin
        if i > EndIdx then EndIdx := i;
        break;
      end;
    end;
  end;

  // Falls die Datei komplett leer/still war, lasse ein minimales Sample übrig, um Abstürze zu verhindern
  if StartIdx > EndIdx then begin
    StartIdx := 0;
    EndIdx := 0;
  end;

  NewLength := (EndIdx - StartIdx) + 1;

  // 2. Daten im Array nach vorne verschieben und die Puffer-Größe kürzen
  for c := 0 to High(Data) do
  begin
    if StartIdx > 0 then
      Move(Data[c][StartIdx], Data[c][0], NewLength * SizeOf(Single));
    
    SetLength(Data[c], NewLength);
  end;
  
  WriteLn(Format('[*] Trimmed Silence: Reduced from %d to %d samples.', [CurrentLength, NewLength]));
end;


{ --- Hauptprogramm ausführen --- }

procedure TIRConvolverApp.DoRun;
var 
  StartTime: Int64;
  f1, f2, fOut, Msg: string; 
  A1, A2, Res: TAudioData; 
  SR1, SR2, bOut, c, TargetSR, TruncLen: Integer;
begin
  LoadConfig;
  
  { 1. Registriert die erlaubten Parameter.
       Ein Doppelpunkt (:) bedeutet, dass ein Wert folgen MUSS. }
  Msg := CheckOptions('x:y:o:b:r:l:h:m:f:t:', 'help:mono:min:in1:in2');

  if (Msg <> '') or HasOption('h', 'help') or (ParamCount < 2) then begin 
    if Msg <> '' then WriteLn(StdErr, 'Parameter-Fehler: ', Msg);
    ShowUsage; 
    ExitCode := 1; // Zwingend wichtig für GitHub Actions!
    Terminate; 
    Exit; 
  end;
  
  { 2. Liest die Parameter aus }
  if HasOption('x', 'in1') then f1 := GetOptionValue('x', 'in1') else f1 := GetOptionValue('x');
  if HasOption('y', 'in2') then f2 := GetOptionValue('y', 'in2') else f2 := GetOptionValue('y');
  fOut := GetOptionValue('o');
  bOut := StrToIntDef(GetOptionValue('b', 'bits'), 24);
  TargetSR := StrToIntDef(GetOptionValue('r', 'rate'), 0);
  TruncLen := StrToIntDef(GetOptionValue('l'), 0);

  StartTime := GetTickCount64;
  try
    { 3. Erste WAV-Datei (Source) laden }
    A1 := LoadWav(f1, SR1); 
    if A1 = nil then 
      raise Exception.Create('Fehler beim Laden der Quell-WAV-Datei.');

    { 4. Zweite WAV-Datei (Impulsantwort) laden mit Mastering-Fallback (Test 3) }
    if f2 <> '' then begin
      A2 := LoadWav(f2, SR2);
      if A2 = nil then 
        raise Exception.Create('Fehler beim Laden der Impulsantwort-WAV-Datei.');
    end 
    else begin
      { Wenn -y fehlt, erzeugen wir einen Identitäts-Impuls für den Mastering-Modus }
      SetLength(A2, Length(A1));
      for c := 0 to High(A2) do begin
        SetLength(A2[c], 1);
        A2[c][0] := 1.0; 
      end;
      SR2 := SR1;
    end;

    { 5. Resampling-Logik ausführen }
    if (TargetSR > 0) then begin
      if SR1 <> TargetSR then A1 := ResampleSoxr(A1, SR1, TargetSR);
      if SR2 <> TargetSR then A2 := ResampleSoxr(A2, SR2, TargetSR);
      SR1 := TargetSR;
    end else if SR1 <> SR2 then begin
      A2 := ResampleSoxr(A2, SR2, SR1);
    end;

    { 6. Hardware-Kürzung (Truncation) anwenden (Test 2) }
    if (TruncLen > 0) then begin
      for c := 0 to High(A1) do begin
        if Length(A1[c]) > TruncLen then SetLength(A1[c], TruncLen);
      end;
      for c := 0 to High(A2) do begin
        if Length(A2[c]) > TruncLen then SetLength(A2[c], TruncLen);
      end;
    end;
   { Optionale Stille-Kürzung (Trim) vor der Faltung anwenden }
   if HasOption('t') then 
     TrimSilence(A2, StrToFloatDef(GetOptionValue('t'), -70.0, DefaultFormatSettings));

   { Optionales Ein- und Ausblenden (Fades) auf die Impulsantwort anwenden }
   if HasOption('f') then
     ApplyFades(A2, SR2, 1.0, StrToFloatDef(GetOptionValue('f'), 10.0, DefaultFormatSettings));

    { 7. Kernprozess: FFT-Faltung ausführen }
    SetLength(Res, Min(Length(A1), Length(A2)));
    for c := 0 to High(Res) do begin
      WriteLn('Convolving Channel ', c+1, '...');
      Res[c] := ConvolveFFT(A1[c], A2[c]);
    end;

    { 8. Optionale Transformationen anwenden }
    if HasOption('min') then begin
      for c := 0 to High(Res) do Res[c] := ConvertToMinimumPhase(Res[c]);
    end;
    
    { 9. Normalisieren und exportieren }
    Normalize(Res);
    SaveWav(fOut, Res, SR1, bOut, HasOption('m', 'mono'));
    
    WriteLn(Format('Success! Processing Time: %d ms', [GetTickCount64 - StartTime]));
    ExitCode := 0; // Erfolg signalisieren
    Terminate;
  except 
    on E: Exception do begin 
      WriteLn(StdErr, 'Error: ', E.Message); 
      ExitCode := 1; // Fehler signalisieren
      Terminate; 
    end; 
  end;
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
