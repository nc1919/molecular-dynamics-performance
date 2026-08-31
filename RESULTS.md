# Recorded results

The detailed report records the following Apple Silicon timings for 4,096 bodies and 500 timesteps. These are historical observations; raw run directories were removed from the review tree.

| Build mode | Variant | Time (s) | Speedup vs fast baseline |
|---|---|---:|---:|
| fast | baseline | 11.74 | 1.00× |
| fast | opt1 | 7.80 | 1.51× |
| fast | opt2 | 8.17 | 1.44× |
| fast_lto | baseline | 10.91 | 1.08× |
| fast_lto | opt1 | 7.33 | 1.60× |
| fast_lto | opt2 | 7.40 | 1.59× |

The report attributes the largest gain to branchless collision handling and reciprocal-square-root reformulation enabling SIMD in the inner pair loop. The Archer2-specific variant was not benchmarked on Apple Silicon.

## Interpretation limits

The archived narrative does not preserve enough raw metadata here to independently verify replicate count, dispersion, compiler version, or machine identity. Before portfolio publication:

1. rerun at least three repetitions per case;
2. capture compiler/version, exact flags, CPU, and operating environment;
3. report arithmetic mean plus dispersion;
4. retain comparator, collision-count, and NaN/Inf checks; and
5. separate portable gains from Zen 2-specific claims.
