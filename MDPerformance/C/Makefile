SRC_BASE = control.c util.c
OBJ_BASE = control.o util.o

# Default compiler. On Archer2, 'cc' is typically a compiler wrapper
# that reflects the currently loaded programming environment.
CC ?= cc

# Build mode: debug, release, fast, fast_lto
MODE ?= release

# Optional knobs
CSTD ?= -std=c11
WARN ?=
ARCH_FLAGS ?=
EXTRA_FLAGS ?=
PROFILE_FLAGS ?=

CFLAGS_COMMON = $(CSTD) $(WARN)

# Debugging / correctness
CFLAGS_debug = -g -O0 -fsanitize=address -fno-omit-frame-pointer
LDFLAGS_debug = -fsanitize=address

# Safe performance (no aggressive FP reordering)
CFLAGS_release = -O3 -g0 -fno-omit-frame-pointer
LDFLAGS_release =

# Maximum throughput (may change FP results; validate)
CFLAGS_fast = -O3 -ffast-math -funroll-loops -fno-math-errno -fno-trapping-math -fomit-frame-pointer
LDFLAGS_fast =

# As fast as possible plus link-time optimisation
CFLAGS_fast_lto = $(CFLAGS_fast) -flto
LDFLAGS_fast_lto = -flto

# Guard against typos in MODE
ifeq ($(strip $(CFLAGS_$(MODE))),)
$(error Unknown MODE '$(MODE)'. Use MODE=debug|release|fast|fast_lto)
endif

CFLAGS  = $(CFLAGS_COMMON) $(CFLAGS_$(MODE)) $(ARCH_FLAGS) $(EXTRA_FLAGS) $(PROFILE_FLAGS)
LDFLAGS = $(LDFLAGS_$(MODE)) $(PROFILE_FLAGS)

# ---------- targets ----------

all: MD_opt1 MD_opt2 MD_opt_archer2

# Opt1: branchless + rsqrt, preserves N3L
MD_opt1: MD_opt1.o $(OBJ_BASE)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ -lm

# Opt2: r²-based collision check, software prefetching
MD_opt2: MD_opt2.o $(OBJ_BASE)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ -lm

# Archer2 (AMD EPYC 7742 / Zen 2): FMA accumulation, larger blocks, AVX2 hints
# Build on Archer2 with:
#   module swap PrgEnv-cray PrgEnv-gnu
#   make MD_opt_archer2 MODE=fast ARCH_FLAGS="-march=znver2 -mtune=znver2"
MD_opt_archer2: MD_opt_archer2.o $(OBJ_BASE)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ -lm

clean:
	rm -f MD MD_opt1 MD_opt2 MD_opt_archer2 *.o

# Every object depends on the header and Makefile
%.o : %.c coord.h Makefile
	$(CC) $(CFLAGS) -c -o $@ $<
