unit UIRCore;

{$MODE OBJFPC}{$H+}

interface

uses
  SysUtils, Classes, Math, IniFiles, dynlibs;

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
procedure InitPFFFT;
function  LoadWav(const FileName: string; out SR: Integer): TAudioData;
procedure SaveWav(const FileName: string; const Data: TAudioData; SR, Bits: Integer; ForceMono: Boolean; Artist: string = '');
function  ConvolveFFT(const Sig, Ker: TFloatBuffer): TFloatBuffer;
procedure Normalize(var Data: TAudioData);
procedure TruncateToLength(var Data: TAudioData; TargetLen: Integer);
function  ConvertToMinimumPhase(const Data: TFloatBuffer): TFloatBuffer;
procedure ApplyFades(var Data: TAudioData; SR: Integer; InMS, OutMS: Single);
procedure TrimSilence(var Data: TAudioData; ThresholdDB: Single);
function  ResampleLinear(const Channel: TFloatBuffer; InSR, OutSR: Integer): TFloatBuffer;
procedure ResetMasteringEngine(Channels: Integer);
function  ApplyMasteringDither(Sample: Single; Chan: Integer; Amount: Single; Scale: Single): Single;

implementation

type
  TPffftNew = function(N: Integer; t: Integer): Pointer; cdecl;
  TPffftDst = procedure(s: Pointer); cdecl;
  TPffftTrf = procedure(s: Pointer; input, output, work: PSingle; d: Integer); cdecl;
  TPffftZCn = procedure(s: Pointer; a, b, ab: PSingle; scaling: Single); cdecl;
  TPffftMal = function(b: NativeUInt): Pointer; cdecl;
  TPffftFre = procedure(p: Pointer); cdecl;

var
  FErrorMem: array of Single;

  // PFFFT dynamic loading
  _pffft_new_setup: TPffftNew = nil;
  _pffft_destroy_setup: TPffftDst = nil;
  _pffft_transform: TPffftTrf = nil;
  _pffft_zconvolve_accumulate: TPffftZCn = nil;
  _pffft_aligned_malloc: TPffftMal = nil;
  _pffft_aligned_free: TPffftFre = nil;

procedure InitPFFFT;
var H: TLibHandle;
begin
  if Assigned(_pffft_new_setup) then Exit;

  {$IFDEF WINDOWS}
  H := LoadLibrary('libpffft.dll');
  {$ENDIF}
  {$IFDEF DARWIN}
  H := LoadLibrary('libpffft.dylib');
  {$ENDIF}
  {$IFDEF LINUX}
  H := LoadLibrary('libpffft.so');
  {$ENDIF}

  if H <> NilHandle then begin
    _pffft_new_setup := TPffftNew(GetProcAddress(H, 'pffft_new_setup'));
    _pffft_destroy_setup := TPffftDst(GetProcAddress(H, 'pffft_destroy_setup'));
    _pffft_transform := TPffftTrf(GetProcAddress(H, 'pffft_transform'));
    _pffft_zconvolve_accumulate := TPffftZCn(GetProcAddress(H, 'pffft_zconvolve_accumulate'));
    _pffft_aligned_malloc := TPffftMal(GetProcAddress(H, 'pffft_aligned_malloc'));
    _pffft_aligned_free := TPffftFre(GetProcAddress(H, 'pffft_aligned_free'));
  end;
end;

procedure LoadCoreConfig;
var Ini: TIniFile; Path: string;
begin
  InitPFFFT;
  Path := ChangeFileExt(ParamStr(0), '.ini');
  if not FileExists(Path) then Path := 'settings.ini';
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
  SetLength(FErrorMem, Channels * 2);
  for c := 0 to High(FErrorMem) do FErrorMem[c] := 0.0;
end;

function ApplyMasteringDither(Sample: Single; Chan: Integer; Amount: Single; Scale: Single): Single;
var Dither, ResVal, Error, LSB: Single; Idx: Integer;
begin
  LSB := 1.0 / Scale;
  Dither := ((Random - 0.5) + (Random - 0.5)) * LSB * Amount;
  if Abs(Sample) < (LSB * 2) then Dither := Dither * 0.7;
  Idx := Chan * 2;
  ResVal := Sample + Dither + (FErrorMem[Idx] * 1.5) - (FErrorMem[Idx + 1] * 0.5);
  ResVal := EnsureRange(ResVal, -1.0, 1.0);
  ResVal := Round(ResVal * Scale) / Scale;
  Error := Sample - ResVal;
  FErrorMem[Idx + 1] := FErrorMem[Idx]; FErrorMem[Idx] := Error;
  Result := ResVal;
end;

function ConvolveFFT(const Sig, Ker: TFloatBuffer): TFloatBuffer;
var setup: Pointer; n, i, L1, L2: Integer; in1, in2, f1, f2, fRes, work: PSingle;
begin
  if not Assigned(_pffft_new_setup) then begin
    SetLength(Result, Length(Sig));
    for i := 0 to High(Sig) do Result[i] := Sig[i];
    Exit;
  end;

  L1 := Length(Sig); L2 := Length(Ker); n := 1;
  while n < (L1 + L2 - 1) do n := n shl 1;
  while n mod 32 <> 0 do n := n + 1;

  setup := _pffft_new_setup(n, 0);
  in1 := _pffft_aligned_malloc(n * 4); in2 := _pffft_aligned_malloc(n * 4);
  f1 := _pffft_aligned_malloc(n * 4); f2 := _pffft_aligned_malloc(n * 4);
  fRes := _pffft_aligned_malloc(n * 4); work := _pffft_aligned_malloc(n * 4);
  try
    FillChar(in1^, n * 4, 0); FillChar(in2^, n * 4, 0);
    if L1 > 0 then for i := 0 to L1 - 1 do (in1 + i)^ := Sig[i];
    if L2 > 0 then for i := 0 to L2 - 1 do (in2 + i)^ := Ker[i];
    _pffft_transform(setup, in1, f1, work, 0);
    _pffft_transform(setup, in2, f2, work, 0);
    FillChar(fRes^, n * 4, 0);
    _pffft_zconvolve_accumulate(setup, f1, f2, fRes, 1.0);
    _pffft_transform(setup, fRes, in1, work, 1);
    SetLength(Result, L1 + L2 - 1);
    for i := 0 to High(Result) do Result[i] := (in1 + i)^ / n;
  finally
    _pffft_aligned_free(in1); _pffft_aligned_free(in2); _pffft_aligned_free(f1);
    _pffft_aligned_free(f2); _pffft_aligned_free(fRes); _pffft_aligned_free(work);
    _pffft_destroy_setup(setup);
  end;
end;

procedure Normalize(var Data: TAudioData);
var m: Single; c, i: Integer;
begin
  m := 0;
  for c := 0 to High(Data) do for i := 0 to High(Data[c]) do m := Max(m, Abs(Data[c][i]));
  if m > 1e-7 then
    for c := 0 to High(Data) do for i := 0 to High(Data[c]) do Data[c][i] := Data[c][i] / m;
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

function ConvertToMinimumPhase(const Data: TFloatBuffer): TFloatBuffer;
var setup: Pointer; n, i, HalfN: Integer; inOut, spec, work: PSingle; Mag, Phase: Single;
begin
  if Length(Data) = 0 then Exit(nil);
  if not Assigned(_pffft_new_setup) then begin Result := Data; Exit; end;

  n := 1; while n < (Length(Data) * 2) do n := n shl 1;
  while n mod 32 <> 0 do n := n + 1;
  HalfN := n div 2;
  setup := _pffft_new_setup(n, 0);
  inOut := _pffft_aligned_malloc(n * 4); spec := _pffft_aligned_malloc(n * 4); work := _pffft_aligned_malloc(n * 4);
  try
    FillChar(inOut^, n * 4, 0); Move(Data[0], inOut^, Length(Data) * 4);
    _pffft_transform(setup, inOut, spec, work, 0);
    spec[0] := Ln(Max(Abs(spec[0]), 1e-10)); spec[1] := Ln(Max(Abs(spec[1]), 1e-10));
    for i := 1 to HalfN - 1 do begin
      Mag := Sqrt(spec[2*i]*spec[2*i] + spec[2*i+1]*spec[2*i+1]);
      spec[2*i] := Ln(Max(Mag, 1e-10)); spec[2*i+1] := 0;
    end;
    _pffft_transform(setup, spec, inOut, work, 1);
    for i := 0 to n - 1 do inOut[i] := inOut[i] / n;
    for i := 1 to HalfN - 1 do begin inOut[i] := inOut[i] * 2.0; inOut[n-i] := 0; end;
    _pffft_transform(setup, inOut, spec, work, 0);
    spec[0] := Exp(spec[0]); spec[1] := Exp(spec[1]);
    for i := 1 to HalfN - 1 do begin
      Mag := Exp(spec[2*i]); Phase := spec[2*i+1];
      spec[2*i] := Mag * Cos(Phase); spec[2*i+1] := Mag * Sin(Phase);
    end;
    _pffft_transform(setup, spec, inOut, work, 1);
    SetLength(Result, Length(Data));
    for i := 0 to High(Result) do Result[i] := inOut[i] / n;
  finally
    _pffft_aligned_free(inOut); _pffft_aligned_free(spec); _pffft_aligned_free(work);
    _pffft_destroy_setup(setup);
  end;
end;

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
    if StartIdx > 0 then Move(Data[c][StartIdx], Data[c][0], NewLength * SizeOf(Single));
    SetLength(Data[c], NewLength);
  end;
end;

function ResampleLinear(const Channel: TFloatBuffer; InSR, OutSR: Integer): TFloatBuffer;
var i, NewLength, SrcIdx: Integer; Ratio, Position, Weight: Double;
begin
  if Length(Channel) = 0 then Exit(nil);
  Ratio := InSR / OutSR;
  NewLength := Round(Length(Channel) * (OutSR / InSR));
  SetLength(Result, NewLength);
  for i := 0 to NewLength - 1 do begin
    Position := i * Ratio; SrcIdx := Floor(Position); Weight := Position - SrcIdx;
    if SrcIdx >= High(Channel) then Result[i] := Channel[High(Channel)]
    else Result[i] := (Channel[SrcIdx] * (1.0 - Weight)) + (Channel[SrcIdx + 1] * Weight);
  end;
end;

procedure LoadWavFromFile(const FileName: string; out SR: Integer; out Data: TAudioData);
var FS: TFileStream; H: TWavHeader; i, c, Samples, BytesPerSample: Integer;
    s16: SmallInt; b24: array[0..2] of Byte; s32: LongInt; f32: Single; b8: Byte;
begin
  Data := nil;
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    FS.Read(H, SizeOf(H)); SR := H.SampleRate;
    BytesPerSample := H.BitsPerSample div 8;
    if (BytesPerSample = 0) or (H.Channels = 0) then Exit;
    Samples := H.DataSize div (H.Channels * BytesPerSample);
    SetLength(Data, H.Channels);
    for c := 0 to H.Channels - 1 do SetLength(Data[c], Samples);
    for i := 0 to Samples - 1 do for c := 0 to H.Channels - 1 do begin
      case H.BitsPerSample of
        8: begin FS.Read(b8, 1); Data[c][i] := (b8 - 128) / 128.0; end;
        16: begin FS.Read(s16, 2); Data[c][i] := s16 / 32768.0; end;
        24: begin
          FS.Read(b24, 3); s32 := b24[0] or (b24[1] shl 8) or (b24[2] shl 16);
          if (s32 and $800000) <> 0 then s32 := s32 or $FF000000;
          Data[c][i] := s32 / 8388608.0;
        end;
        32: begin FS.Read(f32, 4); Data[c][i] := f32; end;
      else Data[c][i] := 0.0;
      end;
    end;
  finally FS.Free; end;
end;

function LoadWav(const FileName: string; out SR: Integer): TAudioData;
begin
  LoadWavFromFile(FileName, SR, Result);
end;

procedure SaveWav(const FileName: string; const Data: TAudioData; SR, Bits: Integer; ForceMono: Boolean; Artist: string = '');
var FS: TFileStream; H: TWavHeader; i, c, OutChans: Integer;
    s16: SmallInt; s32: LongInt; b24: array[0..2] of Byte; f32: Single;
begin
  if Length(Data) = 0 then Exit;
  OutChans := IfThen(ForceMono, 1, Length(Data));
  FillChar(H, SizeOf(H), 0); H.RIFFID := 'RIFF'; H.WavID := 'WAVE'; H.FmtID := 'fmt '; H.FmtSize := 16;
  H.FormatTag := 1; H.Channels := OutChans; H.SampleRate := SR; H.BitsPerSample := Bits;
  H.BlockAlign := H.Channels * (Bits div 8); H.BytesPerSec := SR * H.BlockAlign;
  H.DataID := 'data'; H.DataSize := Length(Data[0]) * H.BlockAlign; H.Size := 36 + H.DataSize;
  ResetMasteringEngine(OutChans); FS := TFileStream.Create(FileName, fmCreate);
  try
    FS.Write(H, SizeOf(H));
    for i := 0 to High(Data[0]) do for c := 0 to OutChans - 1 do begin
      case Bits of
        16: begin s16 := Round(ApplyMasteringDither(Data[c][i], c, CoreConfig.DitherAmount, 32767) * 32767); FS.Write(s16, 2); end;
        24: begin
          s32 := Round(ApplyMasteringDither(Data[c][i], c, CoreConfig.DitherAmount, 8388607) * 8388607);
          b24[0] := s32 and $FF; b24[1] := (s32 shr 8) and $FF; b24[2] := (s32 shr 16) and $FF;
          FS.Write(b24, 3);
        end;
        32: begin f32 := EnsureRange(Data[c][i], -1.0, 1.0); FS.Write(f32, 4); end;
      end;
    end;
    if Artist <> '' then begin
      FS.Write('IART'[1], 4); s32 := Length(Artist) + 1; FS.Write(s32, 4);
      FS.Write(Artist[1], Length(Artist)); b24[0] := 0; FS.Write(b24[0], 1);
      if (Length(Artist) + 1) mod 2 <> 0 then FS.Write(b24[0], 1);
    end;
  finally FS.Free; end;
end;

end.