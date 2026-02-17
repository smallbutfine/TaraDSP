# IRConvolverPro Master Build Script (CLI & GUI)
# Automates C-compilation for PFFFT and Pascal-linking for FPC

# Project Names
PROJ_CLI = IRConvolverPro-CLI
PROJ_GUI = IRConvolverPro-GUI

# Tools
CC = gcc
FPC = lazbuild
FPC_FLAGS = --build-mode=Release

# Platform Detection
ifeq ($(OS),Windows_NT)
    OBJ_EXT = .obj
    EXE_EXT = .exe
    C_FLAGS = -O3 -msse -mfpmath=sse -c
else
    OBJ_EXT = .o
    EXE_EXT =
    C_FLAGS = -O3 -fPIC -msse -mfpmath=sse -c
endif

# Targets
all: pffft$(OBJ_EXT) build-cli build-gui

# Compile PFFFT C-Code to Object File
pffft$(OBJ_EXT): pffft.c pffft.h
	@echo "Compiling PFFFT static object..."
	$(CC) $(C_FLAGS) pffft.c -o pffft$(OBJ_EXT)

# Build Pascal CLI Edition
build-cli:
	@echo "Building CLI Edition..."
	$(FPC) $(FPC_FLAGS) $(PROJ_CLI).lpi

# Build Pascal GUI Edition
build-gui:
	@echo "Building GUI Edition..."
	$(FPC) $(FPC_FLAGS) $(PROJ_GUI).lpi

clean:
	@echo "Cleaning up..."
	rm -f *$(OBJ_EXT) *.exe lib/*/*.*
