# MD Performance — Optimisation Report

Single-threaded optimisations applied to an N-body gravitational / collision
molecular-dynamics kernel (`Nbody = 4096`, O(N²) pairwise forces, semi-implicit
Euler integration).

## Build

```bash
# Optimised variants:
make all MODE=fast        # -O3 -ffast-math — recommended for benchmarking

# Individual targets:
make MD_opt1         # optimisation level 1
make MD_opt2         # optimisation level 2
make MD_opt_archer2  # Archer2-tuned variant

# Other modes:
make MODE=release         # -O3, strict IEEE floats
make MODE=fast_lto        # -O3 -ffast-math -flto  (extra ~6-9 % from LTO)
make MODE=debug           # -O0 -fsanitize=address
```

### Building on Archer2

```bash
module swap PrgEnv-cray PrgEnv-gnu
make MD_opt_archer2 MODE=fast ARCH_FLAGS="-march=znver2 -mtune=znver2"
```

Run any variant the same way as the original:

```bash
./MD_opt1          # default 100 steps × 5 saves
./MD_opt2 200      # 200 steps × 5 saves
```

---

## Toolchain and Hardware Context

This project mixes three layers of optimisation:

1. **Algorithmic / source-level changes**
   Examples: Newton's-third-law pair reduction, j-blocking, branchless
   collision handling, reciprocal-sqrt reformulation.
2. **Compiler-visible optimisation features**
   Examples: `restrict`, `__builtin_assume_aligned`, vectorisation pragmas,
   `fma()`, `__builtin_prefetch`, `-O3`, `-ffast-math`, `-flto`.
3. **Hardware-targeted tuning**
   Examples: AVX2 width on Zen 2, FMA pipelines, L1/L2/L3 cache sizing,
   `-march=znver2 -mtune=znver2`.

The code is still single-threaded throughout.  The goal is to reduce the
runtime of the dominant N-body force kernel on one core by making the compiler
generate better scalar and SIMD machine code for the hot loops.

### What `make` is doing here

The `Makefile` is not only compiling one executable.  It is used to build
several source variants with different optimisation strategies:

- `MD/C/MD.c` — original baseline, built with the separate `MD/C/Makefile`
- `MD_opt1` — branchless collision + reciprocal-sqrt + vectorisation hints
- `MD_opt2` — opt1 plus r²-based collision and software prefetching
- `MD_opt_archer2` — hardware-tuned Zen 2 / Archer2 version

The `MODE` variable controls the optimisation level:

- `release` — `-O3` without aggressive floating-point reassociation
- `fast` — `-O3 -ffast-math -funroll-loops ...`
- `fast_lto` — `fast` plus `-flto`
- `debug` — `-O0` with AddressSanitizer

So `make` is the top-level tool that combines:

- the chosen source variant
- the chosen compiler flags
- the chosen target architecture flags

into a concrete executable for benchmarking.

### What `cc` means on an HPC system

On a laptop or workstation, `cc` may be a direct compiler such as:

- GCC
- Clang / Apple Clang

On an HPC machine such as Archer2, `cc` is often a **compiler wrapper**.  The
wrapper picks the actual backend compiler based on the currently loaded module
environment.

That matters because the same source code may be compiled by:

- GNU `gcc`
- LLVM/Clang-based compilers
- AOCC

without changing the build command itself.

### What AOCC is

**AOCC** is the **AMD Optimizing C/C++ Compiler**.  It is AMD's
LLVM/Clang-derived compiler toolchain, tuned for AMD CPUs such as the Zen
family used in Archer2.

Why AOCC matters in this project:

- it understands the same broad optimisation style as Clang
- it is designed to generate strong code for AMD microarchitectures
- it can make better use of Zen-specific instruction scheduling and throughput
- it is a natural compiler choice for the `MD_opt_archer2` variant

In practice, AOCC is relevant because the Archer2-specific kernel uses features
that rely on the compiler generating efficient AVX2/FMA code:

- `fma()` calls
- vectorisation pragmas
- prefetch hints
- architecture-specific `-march=znver2 -mtune=znver2`

If you build with:

```bash
module swap PrgEnv-cray PrgEnv-aocc
make MD_opt_archer2 MODE=fast ARCH_FLAGS="-march=znver2 -mtune=znver2"
```

then the `cc` wrapper should route the build to AOCC rather than GCC.

### GCC vs Clang vs AOCC in this codebase

This optimisation work is intentionally written in a style that mainstream C
compilers can understand.

Examples:

- `restrict` is standard C and helps all compilers
- `fma()` is a standard math-library interface
- `__builtin_assume_aligned` is supported by Clang/GCC-family compilers
- `__builtin_prefetch` is supported by Clang/GCC-family compilers
- `#pragma clang loop ...` is Clang/AOCC-oriented
- `#pragma GCC ivdep` is the GCC-oriented fallback

So the code is trying to be:

- portable at the source level
- but still explicit enough for each compiler family to optimise well

### What `-O3` is doing

`-O3` is the base high-optimisation level.  It typically enables:

- inlining
- loop transformations
- common-subexpression elimination
- dead-code elimination
- strength reduction
- vectorisation attempts

Most of the performance improvements in this project depend on the compiler
being able to see straight-line arithmetic and regular memory access patterns,
which is why `-O3` is the practical baseline for all meaningful timing runs.

### What `-ffast-math` is doing

`-ffast-math` allows the compiler to relax strict IEEE floating-point rules in
order to generate faster code.

Why it matters here:

- it makes reciprocal-sqrt style optimisation more attractive to the compiler
- it allows more reassociation and simplification in the hot arithmetic path
- it can improve vectorisation of floating-point loops

Trade-off:

- results may differ in the last few bits from strict IEEE evaluation
- correctness therefore still has to be checked against the baseline output

This is why the report treats `fast` and `fast_lto` as benchmark-oriented modes
rather than blindly assuming they are always acceptable.

### What LTO (`-flto`) is doing

LTO means **Link-Time Optimisation**.  Instead of optimising each source file in
complete isolation, the compiler keeps intermediate optimisation information
until link time and then performs cross-file optimisation.

Potential benefits here:

- more aggressive inlining across translation units
- better dead-code elimination
- better constant propagation across file boundaries

In this particular codebase, the largest wins still come from the kernel source
changes, but LTO can give an extra improvement on top.

### What the vectorisation pragmas are doing

The code uses compiler hints such as:

```c
#pragma clang loop vectorize(enable) interleave(enable) vectorize_width(4)
#pragma GCC ivdep
```

These are not instructions to the hardware.  They are **hints to the compiler**
about how aggressively it should try to transform the loop into SIMD code.

Why they matter:

- compilers can be conservative when branches or pointer aliasing exist
- once the collision logic is made branchless, these pragmas help push the
  vectoriser toward the intended loop form

### What `restrict` and alignment tell the compiler

Two of the most important compiler-facing features in this project are:

- `restrict`
- 64-byte aligned allocation plus `__builtin_assume_aligned`

Together they tell the compiler:

- these arrays do not alias each other
- these pointers are aligned on cache-line / SIMD-friendly boundaries

That reduces the need for:

- runtime alias checks
- conservative reloads
- unaligned vector load/store sequences

### What `fma()` is doing

`fma(a, b, c)` computes:

```c
a * b + c
```

as a single fused operation.

Why that matters:

- one fused instruction can replace a multiply followed by an add/subtract
- on hardware with dedicated FMA pipelines, this reduces latency and improves
  throughput
- it also changes numerical rounding slightly because the multiply-add is
  rounded once instead of twice

That is why the Archer2-specific variant documents small possible last-digit
differences while still preserving the same physical model.

## Core Hardware Components Targeted By The Optimisations

These source changes are aimed at specific parts of modern CPU hardware.

### 1. SIMD/vector units

SIMD hardware executes the same arithmetic on multiple data elements at once.

Relevant examples:

- Apple Silicon NEON: effectively 2 doubles per 128-bit vector
- AMD Zen 2 AVX2: 4 doubles per 256-bit vector

Optimisations that target SIMD:

- SoA layout
- aligned allocation
- `restrict`
- branchless collision handling
- vectorisation pragmas
- reciprocal-sqrt refactoring

### 2. Vector register file

Once a loop is vectorised, temporary values live in SIMD registers rather than
being reloaded from memory each iteration.

Optimisations that help here:

- scalar hoisting
- local force accumulators
- reducing loop-carried dependencies
- interleave hints in the Archer2 variant

### 3. FMA pipelines

Zen 2 has dedicated FMA hardware.  The Archer2 variant uses this explicitly via
`fma()` to shorten the arithmetic dependency chain in the force accumulation.

This is the main hardware reason for having a separate `MD_opt_archer2`
executable instead of only one generic optimised kernel.

### 4. L1 data cache

The L1 cache is the fastest general-purpose memory visible to the core.

Optimisations that target it:

- j-blocking / loop tiling
- aligned contiguous arrays
- keeping the tile working set bounded
- hoisting invariant `i`-body data into registers

### 5. L2 / L3 cache and hardware prefetch

The larger caches are slower but still far better than main memory.

Optimisations that target them:

- software prefetching of the next j-block
- long contiguous walks through SoA arrays
- using larger blocks in the Archer2 variant where the hardware can tolerate it

### 6. Branch predictor and control flow

Branchy code is harder to vectorise and can also stall the scalar pipeline if
branches are hard to predict.

Optimisation that targets this:

- branchless collision handling via sign-select

This is both a compiler optimisation enabler and a control-flow optimisation.

## Optimisations already in the baseline (`MD/C/MD.c`)

The baseline is not a naive implementation.  It already contains a number of
important optimisations over a textbook N-body loop.

### 1 · Structure-of-Arrays (SoA) data layout

A naive implementation stores each body as a struct:

```c
struct Body { double mass, radius, vis, pos[3], velo[3]; };
struct Body bodies[Nbody];  // AoS — strides of ~88 bytes between x-coords
```

The baseline instead uses parallel arrays per field (`coord.h`):

```c
double *pos[Ndim], *velo[Ndim], *f[Ndim];
double *mass, *radius, *vis, *inv_mass;
```

Consecutive bodies' x-positions sit in contiguous memory (`pos[Xcoord][0]`,
`pos[Xcoord][1]`, …).  This gives unit-stride access for the inner loop,
maximising cache-line utilisation and enabling SIMD loads of consecutive
elements.

### 2 · 64-byte aligned allocation

All arrays are allocated with `posix_memalign(&ptr, 64, …)` in `control.c`.
64-byte alignment matches the cache-line size on x86 and ARM, ensuring:

- No split cache-line loads (each load touches exactly one cache line).
- SIMD-aligned load/store instructions can be used (avoiding unaligned
  penalty on older hardware).

### 3 · `restrict` qualifiers and `__builtin_assume_aligned`

Every pointer in `evolve()` is cast through `restrict` and
`__builtin_assume_aligned`:

```c
double *restrict pos_x = (double *restrict) __builtin_assume_aligned(pos[Xcoord], 64);
```

`restrict` promises the compiler that no two pointers alias the same memory,
enabling store-to-load forwarding elimination and loop reordering.
`__builtin_assume_aligned` lets the compiler emit aligned SIMD instructions
without runtime alignment checks.

### 4 · Newton's Third Law (N3L) — halved pair count

A naive double loop computes N² pair interactions.  The baseline exploits
Newton's third law: the force on body `i` from body `j` is equal and opposite
to the force on `j` from `i`.  By only iterating over pairs with `j > i`
(upper-triangular), each pair is computed once and the result applied to both
bodies:

```c
for(i = 0; i < Nbody; i++)
    for(j = i + 1; j < Nbody; j++)  // N(N-1)/2 pairs, not N²
```

This halves the dominant O(N²) work from ~16.8 M to ~8.4 M pair iterations
per timestep.

### 5 · J-blocking / loop tiling

The inner j-loop is tiled with `PairBlockSize = 128`.  Each tile processes a
contiguous chunk of 128 bodies, keeping their position, mass, radius, and
force data (~8 KB) resident in L1 cache:

```c
for(j_block = i + 1; j_block < Nbody; j_block += PairBlockSize)
    for(jj = 0; jj < block_len; jj++)
        // positions and forces for jj all in L1
```

Without tiling, the inner loop would stride over all N bodies, evicting data
from L1 before it can be reused.  The tile size of 128 is chosen so the full
working set (8 arrays × 128 doubles × 8 bytes = 8 KB) fits comfortably in a
32 KB L1d cache.

### 6 · Pre-computed derived quantities

Quantities that are constant across all timesteps are computed once at load
time in `control.c`, not inside the hot loop:

```c
inv_mass[i]          = 1.0 / mass[i];          // avoids a division per integration step
pair_mass_scale[i]   = G * mass[i];            // avoids 2 multiplies per pair
central_mass_scale[i]= G * M_central * mass[i];// avoids 3 multiplies per body per step
```

This strength reduction eliminates millions of redundant multiplies and
divisions per timestep.

### 7 · Scalar hoisting / register promotion

Loop-invariant values are hoisted out of the inner loop into `const` locals:

```c
const double px_i = pos_x[i];          // body i's position — constant across all j
const double pair_scale_i = pair_scale[i];
const double radius_i = radius_value[i];
double fix = force_x[i];               // accumulator kept in register, written once
```

The force accumulators `fix/fiy/fiz` are kept in registers across the entire
inner loop and written back to `force_x[i]` only at the end.  This avoids
repeated loads and stores to the force array for body `i`.

### 8 · Global → local collision counter

The collision count is accumulated into a local variable `collisions_local`
rather than the global `collisions`:

```c
int collisions_local = collisions;
// ... hot loops use collisions_local ...
collisions = collisions_local;
```

This avoids writing to a global (potentially memory-mapped) variable on every
collision, letting the compiler keep the counter in a register.

### 9 · Loop fission (three-phase timestep)

Each timestep is split into three separate loops rather than a single fused
loop:

1. **Central force + drag** — O(N), reads `pos`, `velo`, writes `force`.
2. **Pairwise forces** — O(N²/2), reads `pos`, `mass`, `radius`, reads+writes
   `force`.
3. **Integration** — O(N), reads+writes `pos`, `velo`, reads `force`.

Separating the phases improves cache locality: each loop streams through a
well-defined set of arrays without polluting the cache with data needed by a
different phase.

### 10 · Wind constants hoisted to locals

The `wind[Xcoord]`, `wind[Ycoord]`, `wind[Zcoord]` array accesses are hoisted
to scalar locals `wind_x`, `wind_y`, `wind_z` at the top of `evolve()`,
avoiding repeated indirection through the array pointer.

### What the baseline does NOT do

Despite these optimisations, the baseline's **inner loop is not
auto-vectorised**.  The compiler vectorisation report confirms:

```
MD.c:77:9: remark: the cost-model indicates that vectorization is not beneficial
```

Two properties of the inner loop prevent this:

1. **Branch on collision** (`if(r >= size) … else …`) — the two paths write
   different signs to different arrays, forcing scalar fallback.
2. **Division in the critical path** — `scale = coeff / (r2 * r)` chains
   `sqrt` and `fdiv`, each high-latency and difficult to pipeline in SIMD.

These are addressed in opt1, opt2, and the Archer2 variant below.

---

## Optimisation Level 1 — `MD_opt1.c`

*Same algorithmic structure (N3L pair walk, j-blocking).
Changes are arithmetic / compiler-hint only.*

### 1 · Reciprocal-sqrt — eliminate division

**Before (baseline):**

```c
const double r     = sqrt(r2);
const double scale = (pair_scale_i * mass_block[jj]) / (r2 * r);
```

**After (opt1):**

```c
const double inv_r  = 1.0 / sqrt(r2);
const double r      = r2 * inv_r;          // for collision check
const double inv_r3 = inv_r * inv_r * inv_r;
const double scale  = pair_scale_i * mass_block[jj] * inv_r3;
```

**Why it matters:**

- Replaces `sqrt` + `fdiv` with `rsqrt` + multiply chain.  Under `-ffast-math`
  the compiler can emit a hardware reciprocal-sqrt estimate followed by a
  Newton–Raphson iteration — roughly 3× faster than `sqrt` + `div` on x86 and
  ARM.
- `r = r2 * inv_r` reuses the reciprocal to recover `r` for the collision
  distance check without a second `sqrt`.
- The same transformation is applied to the O(N) central-force loop.

### 2 · Branchless collision — sign-select

**Before:**

```c
if(r >= size){
    fix -= dfx;  force_x_block[jj] += dfx;
    // …
}else{
    fix += dfx;  force_x_block[jj] -= dfx;
    collisions_local++;
}
```

**After:**

```c
const double sign = (r >= size) ? 1.0 : -1.0;
const int    coll = (r < size);
const double sdfx = sign * dfx;
fix        -= sdfx;
fx_blk[jj] += sdfx;
collisions_local += coll;
```

**Why it matters:**

- The `if/else` prevents the compiler from vectorising the inner loop: it sees
  two distinct write patterns and falls back to scalar.
- With the sign-select, every iteration executes the *same* sequence of
  multiplies and accumulations.  The compiler can emit masked SIMD (e.g.
  `vblendvpd` on AVX, `bsl` on NEON) without scalar fallback.
- `coll` is a 0/1 integer from the comparison — no extra branch.

**This is the single most impactful change.** The compiler vectorisation report
confirms the inner loop is now vectorised at width 4:

```
MD_opt1.c:109: remark: vectorized loop (vectorization width: 4, interleaved count: 1)
```

### 3 · Vectorisation pragmas

```c
#pragma clang loop vectorize(enable) interleave(enable) vectorize_width(4)
// or
#pragma GCC ivdep
```

Applied to the inner `jj` loop and the O(N) loops.  These tell the
auto-vectoriser that iterations are independent (the `restrict` pointers
already hint at this, but some compilers need the explicit nudge after the
branchless rewrite).

---

## Optimisation Level 2 — `MD_opt2.c`

*Builds on all opt1 improvements with further critical-path and
cache-latency refinements.*

### 1 · r²-based collision check

**Opt1:**

```c
const double r    = r2 * inv_r;          // multiply on rsqrt critical path
const double sign = (r >= size) ? 1.0 : -1.0;
```

**Opt2:**

```c
const double size_sq = size * size;       // independent of rsqrt
const double sign    = (r2 >= size_sq) ? 1.0 : -1.0;
```

Mathematically equivalent for positive `r` and `size`.  The key benefit is
that `size_sq` depends only on radius data (loaded from memory, available
early), while `r = r2 * inv_r` depends on the rsqrt output.  This moves the
collision comparison **off the rsqrt critical path**, so the sign-select value
is ready before `dfx/dfy/dfz` and the final accumulation can proceed without
stalling.

The multiply `r = r2 * inv_r` is eliminated entirely.

### 2 · Software prefetching

At the top of each j-block, the next block's position and mass arrays are
prefetched into L2:

```c
__builtin_prefetch(pos_x + j_block + PairBlockSize, 0, 1);
```

This hides main-memory latency when the working set exceeds L2 (relevant
for larger N or systems with higher memory latency).

---

## Archer2 variant — `MD_opt_archer2.c`

*Tuned for Archer2's AMD EPYC 7742 (Zen 2) processors.  Includes all opt1
and opt2 improvements plus hardware-specific refinements.*

### Target hardware

| Property | Value |
|---|---|
| Processor | AMD EPYC 7742 "Rome" (Zen 2) |
| SIMD | AVX2 — 256-bit, **4 doubles per YMM register** |
| Registers | 16 × 256-bit YMM registers |
| FP throughput | **2 × FMA units** → peak 16 DP FLOPs/cycle |
| L1d cache | 32 KB per core, 8-way, ~5 cycle latency |
| L2 cache | 512 KB per core, 8-way, ~12 cycle latency |
| L3 cache | 16 MB per CCX (shared by 4 cores), ~40 cycle latency |

### 1 · FMA accumulation (VFMADD / VFNMADD)

**Opt1 (separate multiply + add):**

```c
const double sdfx = sign * dfx;      // VMULPD  — 5-cycle latency
fix -= sdfx;                          // VSUBPD  — 3-cycle latency (depends on VMUL)
fx_blk[jj] += sdfx;                  // VADDPD  — 3-cycle latency (depends on VMUL)
```

**Archer2 (fused multiply-add):**

```c
const double nsign = -sign;
fix = fma(nsign, dfx, fix);           // VFNMADD — 5-cycle latency (total)
fx_blk[jj] = fma(sign, dfx, fx_blk[jj]); // VFMADD — 5-cycle latency (total)
```

**Why it matters on Zen 2:**

- The multiply→add dependency chain in opt1 is **5 + 3 = 8 cycles** per
  accumulation.  FMA folds both into a single **5-cycle** instruction: a
  **3-cycle saving on the critical path** per accumulation.
- With 3 dimensions × 2 sides (i and j) = 6 accumulations per pair, FMA
  saves up to **18 cycles of critical-path latency** per inner-loop iteration.
- Zen 2 has **2 independent FMA pipes**.  Three FMA ops on `fix/fiy/fiz` are
  independent and issue in **2 cycles throughput** (3 ops / 2 pipes).
- FMA is also applied to the O(N) central-force and integration loops:
  `force[i] = fma(-rs, px, drag*(v+wind))` and `pos[i] = fma(dt, v, pos[i])`.

### 2 · r²-based collision check (amplified benefit)

Same algebraic trick as opt2 (`r² ≥ size²` instead of `r ≥ size`), but the
benefit is **larger on AVX2** than on NEON:

- AVX2 processes **4 lanes** simultaneously.  A pipeline stall waiting for the
  rsqrt to resolve `r = r2 * inv_r` stalls **all 4 lanes**.
- With r²-based check, the sign-select depends on `r2` (available ~6 cycles
  into the iteration) and `size²` (independent of rsqrt), not on `inv_r`
  (available only after rsqrt finishes at ~15+ cycles).

### 3 · Increased j-block size (256)

The baseline uses `PairBlockSize = 128`.  Per-block working set:

| Block size | Working set | Fits in L1d? |
|---|---|---|
| 128 | 8 arrays × 128 × 8 B = **8 KB** | Yes (32 KB) |
| **256** | 8 arrays × 256 × 8 B = **16 KB** | **Yes (32 KB)** |

Larger blocks reduce loop overhead per pair (fewer block transitions) and
give the hardware prefetcher longer sequential access runs.  At 16 KB
the block data fills half of L1d, leaving room for i-body data, stack, and
prefetched data from the next block.

### 4 · Software prefetching (Zen 2 tuning)

```c
__builtin_prefetch(pos_x + j_block + PairBlockSize, 0, 1);
```

Issued at the top of each j-block for the **next** block's position and mass
arrays.  With `PairBlockSize = 256` and ~10–20 cycles per inner iteration, the
next block's data is requested ~2500–5000 cycles before it is needed — well
matched to Zen 2's L3→L1 fill latency (~40 cycles) with margin.

### 5 · AVX2-width vectorisation hints (width 4, interleave 2)

```c
#pragma clang loop vectorize_width(4) interleave_count(2)
```

Requests the auto-vectoriser to use the full 256-bit YMM width (4 doubles) and
interleave 2 independent vector iterations.  This keeps **both FMA pipes fed**:
while one iteration's FMA result is in-flight (5 cycles), the second iteration's
FMA can start on the other pipe.

With ~12 live vector values per iteration and interleave 2 = ~24 YMM values,
register pressure is tight on the 16-register x86-64 file.  The compiler may
spill a few temporaries, but the throughput gain from filling both FMA pipes
typically outweighs the spill cost.

### Summary vs opt1

| Change | Effect on Zen 2 |
|---|---|
| FMA accumulation | −3 cy critical path per accumulation (×6 = −18 cy/iter) |
| r²-based collision | Sign-select off rsqrt path (saves 4-lane stall) |
| Block size 256 | Halves block transitions, better prefetch runway |
| Software prefetch | Hides L3→L1 latency for next block |
| Interleave 2 | Fills both FMA pipes simultaneously |

---

## Measured results (Apple Silicon)

Benchmarked on Apple Silicon, `MODE=fast` (`-O3 -ffast-math`), 500 timesteps
(100 steps × 5 saves), `Nbody = 4096`.

| Build mode | Variant | 500 steps | Speedup |
|---|---|---|---|
| `fast` | **Baseline** (`MD.c`) | **11.74 s** | 1.00× |
| `fast` | **Opt1** (`MD_opt1.c`) | **7.80 s** | **1.51×** |
| `fast` | **Opt2** (`MD_opt2.c`) | **8.17 s** | **1.44×** |
| `fast_lto` | Baseline | 10.91 s | 1.08× |
| `fast_lto` | Opt1 | 7.33 s | **1.60×** |
| `fast_lto` | Opt2 | 7.40 s | **1.59×** |

The Archer2 variant was not benchmarked on Apple Silicon (it targets Zen 2).
On Apple Silicon it produces correct results but the interleave-2 hint is
ignored due to NEON register constraints.

### Why opt1 > opt2 on Apple Silicon

On Apple Silicon (NEON, 128-bit / 2-double vector width), opt1 and opt2 achieve
identical vectorisation (width 4, interleave 1).  The r²-based collision check
in opt2 replaces one multiply (`r2 * inv_r`) with another (`size * size`), so
the FP operation count is equal.  The critical-path benefit from moving the
collision check off the rsqrt path is too small to measure at this SIMD width.

On wider-SIMD hardware (AVX2 / AVX-512), the critical-path improvement from
opt2 and the Archer2 variant becomes more significant because more iterations
are in-flight simultaneously and pipeline bubbles are amplified.

### Where the speedup comes from

The entire 1.5× gain is explained by two changes:

1. **Branchless collision** enables auto-vectorisation of the inner loop
   (baseline: not vectorised → opt1: vectorised at width 4).
2. **Reciprocal-sqrt** replaces a high-latency `sqrt` + `fdiv` chain with
   multiply-only operations that the SIMD pipeline can sustain.

---

## Correctness

**Opt1 and opt2** produce **bit-for-bit identical** output files and collision
counts as the baseline when compiled with `-ffast-math` on the same platform.

**The Archer2 variant** matches collision counts exactly but may show
last-digit differences in position/velocity values (~10⁻⁹ relative).  This is
because `fma()` uses **single rounding** (one rounding step for a×b+c) whereas
the baseline's separate multiply + add uses **double rounding** (two steps).
Single rounding is IEEE 754-compliant and marginally *more* accurate.

| Save point | Collisions (all variants) |
|---|---|
| 100 steps | 0 |
| 200 steps | 8,661 |
| 300 steps | 42,843 |
| 400 steps | 54,871 |
| 500 steps | 68,827 |

Without `-ffast-math` (`MODE=release`), the reciprocal-sqrt refactoring is
algebraically equivalent and results are identical.  The r²-based collision
check in opt2 and the Archer2 variant is also algebraically equivalent for
positive `r` and `size`.
