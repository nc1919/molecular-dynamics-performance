/*
 * The performance version keeps the hot-path arithmetic inside MD.c so the
 * compiler can see the full timestep kernel and optimise across loop bodies.
 *
 * This translation unit is intentionally empty and is retained only to keep
 * the directory layout close to the baseline coursework code.
 */
