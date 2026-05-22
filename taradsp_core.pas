unit taradsp_core;

{$MODE OBJFPC}{$H+}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WINDOWS}Windows, dynlibs,{$ENDIF}
  {$IFDEF DARWIN}dynlibs,{$ENDIF}
  SysUtils, Classes, Math;

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

procedure InitDynamicLibraries;

implementation

{$IFDEF LINUX}
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
procedure MockPffftTrf(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl; begin if (input <> nil) and (output <> nil) then Move(input^, output^, 4096); end;
procedure MockPffftZCn(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl; begin if (dft_a <> nil) and (dft_ab <> nil) then Move(dft_a^, dft_ab^, 4096); end;
function MockPffftMal(nb_bytes: NativeUInt): Pointer; cdecl; begin GetMem(Result, nb_bytes); FillChar(Result^, nb_bytes, 0); end;
procedure MockPffftFre(p: Pointer); cdecl; begin if p <> nil then FreeMem(p); end;
function MockSoxrCreate(in_rate, out_rate: Double; num_chans: Cardinal; error: PInteger; io_spec, q_spec, runtime_spec: Pointer): Pointer; cdecl; begin Result := Pointer(1); end;
function MockSoxrProcess(resampler: Pointer; in_buf: PSingle; in_len: Cardinal; done_in: PCardinal; out_buf: PSingle; out_len: Cardinal; done_out: PCardinal): Integer; cdecl; begin if done_in <> nil then done_in^ := in_len; if done_out <> nil then done_out^ := in_len; Result := 0; end;
procedure MockSoxrDelete(resampler: Pointer); cdecl; begin end;
{$ENDIF}

procedure InitDynamicLibraries;
{$IFNDEF LINUX}
var SoxrLibHandle, PffftLibHandle, R8BrainLibHandle: TLibHandle;
{$ENDIF}
begin
  {$IFDEF LINUX}
  _soxr_create := @soxr_create; _soxr_process := @soxr_process; _soxr_delete := @soxr_delete;
  _pffft_new_setup := @pffft_new_setup; _pffft_destroy_setup := @pffft_destroy_setup;
  _pffft_transform_ordered := @pffft_transform_ordered; _pffft_zconvolve_accumulate := @pffft_zconvolve_accumulate;
  _pffft_aligned_malloc := @pffft_aligned_malloc; _pffft_aligned_free := @pffft_aligned_free;
  {$ELSE}
  SoxrLibHandle := LoadLibrary(LIB_SOXR);
  if SoxrLibHandle <> NilHandle then begin
    _soxr_create  := TFuncSoxrCreate(GetProcAddress(SoxrLibHandle, 'soxr_create'));
    _soxr_process := TFuncSoxrProcess(GetProcAddress(SoxrLibHandle, 'soxr_process'));
    _soxr_delete  := TFuncSoxrDelete(GetProcAddress(SoxrLibHandle, 'soxr_delete'));
  end else begin
    _soxr_create := @MockSoxrCreate; _soxr_process := @MockSoxrProcess; _soxr_delete := @MockSoxrDelete;
  end;
  {$IFDEF WINDOWS} 
  PffftLibHandle := LoadLibrary('libpffft.dll'); 
  R8BrainLibHandle := LoadLibrary('r8bsrc.dll');
  if R8BrainLibHandle <> NilHandle then begin
    _r8b_create  := TR8B_Create(GetProcAddress(R8BrainLibHandle, 'r8b_create'));
    _r8b_process := TR8B_Process(GetProcAddress(R8BrainLibHandle, 'r8b_process'));
    _r8b_delete  := TR8B_Delete(GetProcAddress(R8BrainLibHandle, 'r8b_delete'));
  end;
  {$ENDIF}
  {$IFDEF DARWIN} PffftLibHandle := LoadLibrary('libpffft.dylib'); {$ENDIF}
  if PffftLibHandle <> NilHandle then begin
    _pffft_new_setup            := TFuncPffftNewSetup(GetProcAddress(PffftLibHandle, 'pffft_new_setup'));
    _pffft_destroy_setup        := TFuncPffftDestroy(GetProcAddress(PffftLibHandle, 'pffft_destroy_setup'));
    _pffft_transform_ordered    := TFuncPffftTransform(GetProcAddress(PffftLibHandle, 'pffft_transform_ordered'));
    _pffft_zconvolve_accumulate := TFuncPffftZConvolve(GetProcAddress(PffftLibHandle, 'pffft_zconvolve_accumulate'));
    _pffft_aligned_malloc       := TFuncPffftAlignedMalloc(GetProcAddress(PffftLibHandle, 'pffft_aligned_malloc'));
    _pffft_aligned_free         := TFuncPffftAlignedFree(GetProcAddress(PffftLibHandle, 'pffft_aligned_free'));
  end else begin
    _pffft_new_setup            := @MockPffftNew; _pffft_destroy_setup := @MockPffftDst;
    _pffft_transform_ordered    := @MockPffftTrf; _pffft_zconvolve_accumulate := @MockPffftZCn;
    _pffft_aligned_malloc       := @MockPffftMal; _pffft_aligned_free := @MockPffftFre;
  end;
  {$ENDIF}
end;

end.
