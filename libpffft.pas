unit libpffft; // Muss exakt dem Dateinamen libpffft.pas entsprechen

interface

uses
  SysUtils;

const
  PFFFT_FORWARD  = 0;
  PFFFT_BACKWARD = 1;

type
  { Opaque-Struktur für das Setup-Handle }
  PPFFFT_Setup = Pointer;

  { Transformationstypen }
  TPFFFT_Transform = (
    PFFFT_REAL = 0,
    PFFFT_COMPLEX = 1
  );

{$IFDEF WINDOWS}
  const LibName = 'libpffft.dll';
  
  function pffft_new_setup(N: Integer; transform: TPFFFT_Transform): PPFFFT_Setup; cdecl; external LibName;
  procedure pffft_destroy_setup(setup: PPFFFT_Setup); cdecl; external LibName;
  procedure pffft_transform_ordered(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl; external LibName;
  procedure pffft_zconvolve_accumulate(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl; external LibName;
  procedure pffft_zconvolve_no_accu(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl; external LibName;
  function pffft_aligned_malloc(nb_bytes: NativeUInt): Pointer; cdecl; external LibName;
  procedure pffft_aligned_free(p: Pointer); cdecl; external LibName;
{$ELSE}
  { Statisches Linken unter Linux/macOS }
  {$LINKLIB c}
  {$LINKLIB m}
  {$L pffft.o}

  function pffft_new_setup(N: Integer; transform: TPFFFT_Transform): PPFFFT_Setup; cdecl; external;
  procedure pffft_destroy_setup(setup: PPFFFT_Setup); cdecl; external;
  procedure pffft_transform_ordered(setup: PPFFFT_Setup; const input: PSingle; output: PSingle; work: PSingle; direction: Integer); cdecl; external;
  procedure pffft_zconvolve_accumulate(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl; external;
  procedure pffft_zconvolve_no_accu(setup: Pointer; const dft_a, dft_b: PSingle; dft_ab: PSingle; scaling: Single); cdecl; external;
  function pffft_aligned_malloc(nb_bytes: NativeUInt): Pointer; cdecl; external;
  procedure pffft_aligned_free(p: Pointer); cdecl; external;
{$ENDIF}

implementation

end.
