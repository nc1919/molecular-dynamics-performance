SRC=MD.c control.c util.c
OBJ=$(SRC:.c=.o)

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

CFLAGS = $(CFLAGS_COMMON) $(CFLAGS_$(MODE)) $(ARCH_FLAGS) $(EXTRA_FLAGS)
LDFLAGS = $(LDFLAGS_$(MODE))

all: MD

MD: $(OBJ)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJ) -lm

output.dat: MD input.dat
	./MD

clean:
	rm -f MD $(OBJ)

$(OBJ) : coord.h Makefile

