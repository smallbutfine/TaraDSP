unit UIRCore;

{$MODE OBJFPC}{$H+}

interface

uses
  SysUtils, Classes, Math, pffft, IniFiles;

type
  TFloatBuffer  = array of Single;
  TAudioData    = array of TFloatBuffer;
  TErrorHistory = array[0..1] of Single;

  TWavHeader = packed record
    RIFFID: array[0..3] of Char; Size: LongInt; WavID: array[0..3] of Char;
    FmtID: array[0..3] of Char; FmtSize: LongInt; FormatTag: Word;
    Channels: Word; SampleRate: LongInt; BytesPerSec: LongInt;
    BlockAlign: Word; BitsPerSample: Word; DataID: array[0..3] of Char;
    DataSize: LongInt;
  end;

  TIRConfig = record
    Artist: string;
    DefaultBits: Integer;
    DefaultGain: Single;
    DitherAmount: Single;
    TruncateLen: Integer;
  end;

var
  CoreConfig: TIRConfig;

{ --- Public API --- }
procedure LoadCoreConfig;
function  LoadWav(const FileName: string; out SR: Integer): TAudioData;
procedure SaveWav(const FileName: string; const Data: TAudioData; SR, Bits: Integer; ForceMono: Boolean; Artist: string = '');
function  ConvolveFFT(const Sig, Ker: TFloatBuffer): TFloatBuffer;
procedure Normalize(var Data: TAudioData);
procedure TruncateToLength(var Data: TAudioData; TargetLen: Integer);
function  ConvertToMinimumPhase(const Data: TFloatBuffer): TFloatBuffer;
procedure ResetMasteringEngine(Channels: Integer);
function  ApplyMasteringDither(Sample: Single; Chan: Integer; Amount: Single): Single;

implementation

var
  FErrorMem: array of TErrorHistory;

procedure LoadCoreConfig;
var Ini: TIniFile; Path: string;
begin
  Path := ChangeFileExt(ParamStr(0), '.ini');
  if not FileExists(Path) then begin
    CoreConfig.Artist := 'IRConvolverPro Studio'; CoreConfig.DefaultBits := 24;
    CoreConfig.DefaultGain := 0.0; CoreConfig.DitherAmount := 1.0; CoreConfig.TruncateLen := 0;
    Exit;
  end;
  Ini := TIniFile.Create(Path);
  try
    CoreConfig.Artist := Ini.ReadString('Metadata', 'Artist', 'IRConvolverPro Studio');
    CoreConfig.DefaultBits := Ini.ReadInteger('Audio', 'TargetBits', 24);
    CoreConfig.DefaultGain := Ini.ReadFloat('Audio', 'DefaultGain', 0.0);
    CoreConfig.DitherAmount := Ini.ReadFloat('Audio', 'DitherAmount', 1.0);
    CoreConfig.TruncateLen := Ini.ReadInteger('Hardware', 'TruncateLen', 0);
  finally Ini.Free; end;
end;

procedure ResetMasteringEngine(Channels: Integer);
var c: Integer;
begin
  SetLength(FErrorMem, Channels);
  for c := 0 to High(FErrorMem) do begin FErrorMem[c,0] := 0; FErrorMem[c,1] := 0; end;
end;

function GetTPDFDither: Single; inline;
begin Result := (Random - 0.5) + (Random - 0.5); end;

function ApplyMasteringDither(Sample: Single; Chan: Integer; Amount: Single): Single;
var Dither, ResVal, Error, LSB: Single;
begin
  LSB := 1.0 / 32767.0; Dither := GetTPDFDither * LSB * Amount;
  if Abs(Sample) < (LSB * 2) then Dither := Dither * 0.7;
  ResVal := Sample + Dither + (FErrorMem[Chan,0] * 1.5) - (FErrorMem[Chan,1] * 0.5);
  ResVal := EnsureRange(ResVal, -1.0, 1.0);
  ResVal := Round(ResVal * 32767) / 32767.0;
  Error := Sample - ResVal; FErrorMem[Chan,1] := FErrorMem[Chan,0]; FErrorMem[Chan,0] := Error;
  Result := ResVal;
end;

function ConvolveFFT(const Sig, Ker: TFloatBuffer): TFloatBuffer;
var setup: PPFFFT_Setup; n, i, L1, L2: Integer; in1, in2, f1, f2, fRes, work: PSingle;
begin
  L1 := Length(Sig); L2 := Length(Ker); n := 1; while n < (L1 + L2 - 1) do n := n shl 1;
  setup := pffft_new_setup(n, PFFFT_REAL);
  in1 := pffft_aligned_malloc(n * 4); in2 := pffft_aligned_malloc(n * 4);
  f1 := pffft_aligned_malloc(n * 4); f2 := pffft_aligned_malloc(n * 4);
  fRes := pffft_aligned_malloc(n * 4); work := pffft_aligned_malloc(n * 4);
  try
    FillChar(in1^, n * 4, 0); FillChar(in2^, n * 4, 0);
    Move(Sig[0], in1^, L1 * 4); Move(Ker[0], in2^, L2 * 4);
    pffft_transform_ordered(setup, in1, f1, work, PFFFT_FORWARD);
    pffft_transform_ordered(setup, in2, f2, work, PFFFT_FORWARD);
    pffft_zconvolve_accumulate(setup, f1, f2, fRes, 1.0);
    pffft_transform_ordered(setup, fRes, in1, work, PFFFT_BACKWARD);
    SetLength(Result, L1 + L2 - 1); for i := 0 to High(Result) do Result[i] := in1[i] / n;
  finally
    pffft_aligned_free(in1); pffft_aligned_free(in2); pffft_aligned_free(f1);
    pffft_aligned_free(f2); pffft_aligned_free(fRes); pffft_aligned_free(work);
    pffft_destroy_setup(setup);
  end;
end;

procedure Normalize(var Data: TAudioData);
var m: Single; c, i: Integer;
begin
  m := 0; for c := 0 to High(Data) do for i := 0 to High(Data[c]) do m := Max(m, Abs(Data[c][i]));
  if m > 1e-7 then for c := 0 to High(Data) do for i := 0 to High(Data[c]) do Data[c][i] := Data[c][i] / m;
end;

procedure TruncateToLength(var Data: TAudioData; TargetLen: Integer);
var c, i, FadeSamples: Integer; f: Single;
begin
  for c := 0 to High(Data) do if Length(Data[c]) > TargetLen then begin
    FadeSamples := Min(20, TargetLen);
    for i := 0 to FadeSamples - 1 do begin f := (FadeSamples - i) / FadeSamples; Data[c][TargetLen - 1 - i] := Data[c][TargetLen - 1 - i] * f; end;
    SetLength(Data[c], TargetLen);
  end;
end;

function LoadWav(const FileName: string; out SR: Integer): TAudioData;
var FS: TFileStream; H: TWavHeader; i, c, Samples: Integer; s16: SmallInt; b24: array[0..2] of Byte; s32: LongInt;
begin
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    FS.Read(H, SizeOf(H)); SR := H.SampleRate;
    Samples := H.DataSize div (H.Channels * (H.BitsPerSample div 8));
    SetLength(Result, H.Channels); for c := 0 to H.Channels - 1 do SetLength(Result[c], Samples);
    for i := 0 to Samples - 1 do for c := 0 to H.Channels - 1 do begin
      if H.BitsPerSample = 16 then begin FS.Read(s16, 2); Result[c][i] := s16 / 32768.0; end
      else begin FS.Read(b24, 3); s32 := (b24 shl 8) or (b24 shl 16) or (b24 shl 24); Result[c][i] := s32 / 2147483648.0; end;
    end;
  finally FS.Free; end;
end;

procedure SaveWav(const FileName: string; const Data: TAudioData; SR, Bits: Integer; ForceMono: Boolean; Artist: string = '');
var FS: TFileStream; H: TWavHeader; i, c, OutChans: Integer; s16: SmallInt; s32: LongInt; b24: array[0..2] of Byte;
begin
  OutChans := IfThen(ForceMono, 1, Length(Data));
  FillChar(H, SizeOf(H), 0); H.RIFFID := 'RIFF'; H.WavID := 'WAVE'; H.FmtID := 'fmt '; H.FmtSize := 16;
  H.FormatTag := 1; H.Channels := OutChans; H.SampleRate := SR; H.BitsPerSample := Bits;
  H.BlockAlign := H.Channels * (Bits div 8); H.BytesPerSec := SR * H.BlockAlign;
  H.DataID := 'data'; H.DataSize := Length(Data[0]) * H.BlockAlign; H.Size := 36 + H.DataSize;
  ResetMasteringEngine(OutChans); FS := TFileStream.Create(FileName, fmCreate);
  try
    FS.Write(H, SizeOf(H));
    for i := 0 to High(Data[0]) do for c := 0 to OutChans - 1 do begin
      if Bits = 16 then begin s16 := Round(ApplyMasteringDither(Data[c][i], c, CoreConfig.DitherAmount) * 32767); FS.Write(s16, 2); end
      else begin s32 := Round(EnsureRange(Data[c][i], -1.0, 1.0) * 8388607); b24 := s32 and $FF; b24 := (s32 shr 8) and $FF; b24 := (s32 shr 16) and $FF; FS.Write(b24, 3); end;
    end;
  finally FS.Free; end;
end;

function ConvertToMinimumPhase(const Data: TFloatBuffer): TFloatBuffer;
begin Result := Data; end;

end.
