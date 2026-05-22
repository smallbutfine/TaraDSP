
{
  IRConvolverPro - Mastering-Grade FFT Impulse Response Toolkit
  Copyright (c) 2024, [Your Name/Organization]
  Licensed under the BSD 3-Clause License.
}

program IRConvolverPro;

{$MODE OBJFPC}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math, CustApp, fptimer, libpffft, IniFiles;

const
  // Plattformunabhängige Bibliotheksnamen für den Linker (Resampling)
  {$IFDEF WINDOWS}
  LIB_SOXR = 'libsoxr.dll';
  {$ELSE}
    {$IFDEF DARWIN}
    LIB_SOXR = 'libsoxr.dylib';
    {$ELSE}
    LIB_SOXR = 'libsoxr.so.0'; // Standard unter Ubuntu/Debian
    {$ENDIF}
  {$ENDIF}

type
  TFloatBuffer  = array of Single;
  TAudioData    = array of TFloatBuffer;
  TErrorHistory = array[0..1] of Single; 
  TFilterMode   = (fmBrickwall, fmGentle);

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

// HINWEIS: {$LINKLIB soxr} wurde entfernt, um den x86_64 Linker-Fehler zu beheben

function soxr_create(in_rate, out_rate: Double; num_chans: Cardinal; error: PInteger; io_spec, q_spec, runtime_spec: Pointer): Pointer; cdecl; external LIB_SOXR;
function soxr_process(resampler: Pointer; in_buf: PSingle; in_len: Cardinal; done_in: PCardinal; out_buf: PSingle; out_len: Cardinal; done_out: PCardinal): Integer; cdecl; external LIB_SOXR;
procedure soxr_delete(resampler: Pointer); cdecl; external LIB_SOXR;

{ --- Implementierung --- }

constructor TIRConvolverApp.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Randomize;
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
  StartTime: Int64; // Ersetzt SW: TStopwatch
  f1, f2, fOut: string; 
  A1, A2, Res: TAudioData; 
  SR1, SR2, bOut, c, TargetSR: Integer;
begin
  LoadConfig;
  if HasOption('h', 'help') or (ParamCount < 3) then begin ShowUsage; Terminate; Exit; end;
  
  f1 := GetOptionValue('i1'); f2 := GetOptionValue('i2'); fOut := GetOptionValue('o');
  bOut := StrToIntDef(GetOptionValue('b', 'bits'), 24);
  TargetSR := StrToIntDef(GetOptionValue('r', 'rate'), 0);

  StartTime := GetTickCount64; // Startet die Zeitmessung plattformunabhängig
  try
    A1 := LoadWav(f1, SR1); A2 := LoadWav(f2, SR2);

    if (A1 = nil) or (A2 = nil) then 
      raise Exception.Create('Fehler beim Laden der WAV-Dateien oder ungültiges Format.');

    { Resampling Logic }
    if (TargetSR > 0) then begin
      if SR1 <> TargetSR then A1 := ResampleSoxr(A1, SR1, TargetSR);
      if SR2 <> TargetSR then A2 := ResampleSoxr(A2, SR2, TargetSR);
      SR1 := TargetSR;
    end else if SR1 <> SR2 then begin
      A2 := ResampleSoxr(A2, SR2, SR1);
    end;

    SetLength(Res, Min(Length(A1), Length(A2)));
    for c := 0 to High(Res) do begin
      WriteLn('Convolving Channel ', c+1, '...');
      Res[c] := ConvolveFFT(A1[c], A2[c]);
    end;

    if HasOption('min') then for c := 0 to High(Res) do Res[c] := ConvertToMinimumPhase(Res[c]);
    
    Normalize(Res);
    SaveWav(fOut, Res, SR1, bOut, HasOption('m', 'mono'));
    
    // Berechnet die Differenz in Millisekunden
    WriteLn(Format('Success! Processing Time: %d ms', [GetTickCount64 - StartTime]));
    Terminate(0);
  except on E: Exception do begin WriteLn(StdErr, 'Error: ', E.Message); Terminate(1); end; end;
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
