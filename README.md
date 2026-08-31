# Molecular-dynamics performance optimisation

An extended single-core optimisation study of a 4,096-body O(N²) molecular-dynamics kernel. It compares an original C baseline with portable hand optimisations and a Zen 2/Archer2-targeted variant.

> The repository name is misspelled (`Peformance`). Rename it before publication if links can be updated safely. This is the later hand-optimisation phase; `PerformanceProgramming` contains the earlier compiler-mode study.

## Layout

- `MD/C/` — original baseline and input fixture.
- `MDPerformance/C/` — `MD_opt1`, `MD_opt2`, and `MD_opt_archer2` source variants.
- `MDPerformance/Test/` — numerical output comparator.
- `MDPerformance/*.slurm` — repeatable compiler, variant, vectorisation, and Archer2 sweeps.
- `MDPerformance/C/README.md` — detailed optimisation rationale and archived report narrative.
- [RESULTS.md](RESULTS.md) — concise recorded results and caveats.

## Build

Requirements: a C11 compiler, `make`, and a POSIX-like environment.

```bash
make -C MD/C MODE=release
make -C MDPerformance/C MODE=fast
```

The second command builds the three optimised variants. Run a target from its directory so it can find `input.dat`:

```bash
(cd MDPerformance/C && ./MD_opt1 100)
```

`fast` and `fast_lto` relax floating-point semantics. Validate outputs against a release baseline with `MDPerformance/Test/diff-output`.

## HPC experiments

The Slurm files no longer contain a personal account. Their partitions, QoS, modules, compiler wrappers, and Zen 2 flags remain site-specific and must be reviewed before submission. Generated results and scheduler logs are ignored.

## Publication notes

Raw outputs, binaries, object files, profiler metadata, assessment PDFs, and personal-path-bearing logs were removed from the review tree. The full Git history still needs a separate privacy/size decision before visibility changes.

This began as coursework. Confirm module policy and collaborator permissions. No project-wide licence has been selected, so review does not grant reuse rights.
