#!/bin/bash
#SBATCH --job-name=mdperf_modes
#SBATCH --partition=standard
#SBATCH --qos=standard
#SBATCH --time=01:30:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --hint=nomultithread
#SBATCH --exclusive
#SBATCH --output=log_mdperf_modes_%j.txt
#SBATCH --error=log_mdperf_modes_%j.err

set -euo pipefail

module load PrgEnv-gnu

SUBMIT_DIR="${SLURM_SUBMIT_DIR:-$PWD}"
if [[ -d "${SUBMIT_DIR}/MDPerformance/C" && -d "${SUBMIT_DIR}/MD/C" ]]; then
  PP_ROOT="${SUBMIT_DIR}"
  MP_ROOT="${SUBMIT_DIR}/MDPerformance"
elif [[ -d "${SUBMIT_DIR}/C" && -d "${SUBMIT_DIR}/Test" && -d "$(dirname "${SUBMIT_DIR}")/MD/C" ]]; then
  MP_ROOT="${SUBMIT_DIR}"
  PP_ROOT="$(dirname "${SUBMIT_DIR}")"
else
  echo "Could not locate MDPerformance and MD directories from ${SUBMIT_DIR}" >&2
  exit 1
fi

BASE_WORKDIR="${PP_ROOT}/MD/C"
WORKDIR="${MP_ROOT}/C"
TESTDIR="${MP_ROOT}/Test"
RESULTS="${MP_ROOT}/results/modes"
METADATA="${RESULTS}/metadata"

TARGET="${TARGET:-MD_opt1}"
NSTEP="${NSTEP:-100}"
REPEATS="${REPEATS:-3}"
ARCH_FLAGS_FAST_LTO="${ARCH_FLAGS_FAST_LTO:--march=native}"
EXTRA_FLAGS_DEFAULT="${EXTRA_FLAGS_DEFAULT:--D_DEFAULT_SOURCE}"
BASE_MODE="${BASE_MODE:-release}"
BASE_ARCH_FLAGS="${BASE_ARCH_FLAGS:-}"

mkdir -p "${RESULTS}"

capture_metadata () {
  mkdir -p "${METADATA}"

  {
    echo "script=bench_modes.slurm"
    echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "hostname=$(hostname)"
    echo "PP_ROOT=${PP_ROOT}"
    echo "MP_ROOT=${MP_ROOT}"
    echo "BASE_WORKDIR=${BASE_WORKDIR}"
    echo "WORKDIR=${WORKDIR}"
    echo "TESTDIR=${TESTDIR}"
    echo "RESULTS=${RESULTS}"
    echo "TARGET=${TARGET}"
    echo "BASE_MODE=${BASE_MODE}"
    echo "BASE_ARCH_FLAGS=${BASE_ARCH_FLAGS}"
    echo "NSTEP=${NSTEP}"
    echo "REPEATS=${REPEATS}"
    echo "ARCH_FLAGS_FAST_LTO=${ARCH_FLAGS_FAST_LTO}"
    echo "EXTRA_FLAGS_DEFAULT=${EXTRA_FLAGS_DEFAULT}"
  } > "${METADATA}/run_config.txt"

  (uname -a || true) > "${METADATA}/uname.txt"
  (lscpu || true) > "${METADATA}/lscpu.txt"
  (module list 2>&1 || true) > "${METADATA}/module_list.txt"
  (which cc || true) > "${METADATA}/cc_path.txt"
  (cc --version || true) > "${METADATA}/cc_version.txt"
  (gcc --version || true) > "${METADATA}/gcc_version.txt"
  (clang --version || true) > "${METADATA}/clang_version.txt"
}

check_output_sanity () {
  local output_file="$1"
  local report_file="$2"

  if grep -Eiq '(^|[^[:alpha:]])(nan|inf)([^[:alpha:]]|$)' "${output_file}"; then
    echo "NaN/Inf tokens detected in ${output_file}" > "${report_file}"
  else
    echo "No NaN/Inf tokens detected in ${output_file}" > "${report_file}"
  fi
}

capture_metadata

echo "MDPerformance mode sweep"
echo "  BASE_WORKDIR=${BASE_WORKDIR}"
echo "  BASE_MODE=${BASE_MODE}"
echo "  BASE_ARCH_FLAGS=${BASE_ARCH_FLAGS:-<none>}"
echo "  TARGET=${TARGET}"
echo "  NSTEP=${NSTEP}"
echo "  REPEATS=${REPEATS}"
echo "  ARCH_FLAGS_FAST_LTO=${ARCH_FLAGS_FAST_LTO}"
echo

make -C "${TESTDIR}" clean
make -C "${TESTDIR}"

run_baseline_case () {
  local tag="$1"

  echo "== Case: ${tag} (original MD baseline, ${BASE_MODE}) =="
  make -C "${BASE_WORKDIR}" clean
  make -C "${BASE_WORKDIR}" MODE="${BASE_MODE}" ARCH_FLAGS="${BASE_ARCH_FLAGS}" EXTRA_FLAGS="${EXTRA_FLAGS_DEFAULT}"

  for rep in $(seq 1 "${REPEATS}"); do
    local rep_dir="${RESULTS}/${tag}/rep${rep}"
    mkdir -p "${rep_dir}"
    pushd "${BASE_WORKDIR}" >/dev/null
    rm -f output.dat*
    ./MD "${NSTEP}" > "${rep_dir}/run.log"
    mv output.dat* "${rep_dir}/"
    popd >/dev/null
    check_output_sanity "${rep_dir}/output.dat$(printf "%03d" $((NSTEP*5)))" "${rep_dir}/sanity.txt"
  done
}

run_perf_case () {
  local tag="$1"
  local mode="$2"
  local arch_flags="$3"

  echo "== Case: ${tag} (${TARGET}, ${mode}) =="
  make -C "${WORKDIR}" clean
  make -C "${WORKDIR}" "${TARGET}" MODE="${mode}" ARCH_FLAGS="${arch_flags}" EXTRA_FLAGS="${EXTRA_FLAGS_DEFAULT}"

  for rep in $(seq 1 "${REPEATS}"); do
    local rep_dir="${RESULTS}/${tag}/rep${rep}"
    mkdir -p "${rep_dir}"
    pushd "${WORKDIR}" >/dev/null
    rm -f output.dat*
    "./${TARGET}" "${NSTEP}" > "${rep_dir}/run.log"
    mv output.dat* "${rep_dir}/"
    popd >/dev/null
    check_output_sanity "${rep_dir}/output.dat$(printf "%03d" $((NSTEP*5)))" "${rep_dir}/sanity.txt"
  done
}

baseline_tag="md_release"
run_baseline_case "${baseline_tag}"
run_perf_case "target_release" "release" ""
run_perf_case "target_fast" "fast" ""
run_perf_case "target_fast_lto" "fast_lto" ""
run_perf_case "target_fast_lto_arch" "fast_lto" "${ARCH_FLAGS_FAST_LTO}"

baseline_file="${RESULTS}/${baseline_tag}/rep1/output.dat$(printf "%03d" $((NSTEP*5)))"

echo
echo "== Correctness vs original MD baseline (${baseline_file}) =="
for tag in target_release target_fast target_fast_lto target_fast_lto_arch; do
  current="${RESULTS}/${tag}/rep1/output.dat$(printf "%03d" $((NSTEP*5)))"
  echo "-- ${tag}"
  "${TESTDIR}/diff-output" "${baseline_file}" "${current}" || true
done

echo
echo "== Timing summary (first replicate) =="
for tag in md_release target_release target_fast target_fast_lto target_fast_lto_arch; do
  printf -- "-- %s: " "${tag}"
  awk '/timesteps took/ {last=$0} END {print last}' "${RESULTS}/${tag}/rep1/run.log"
done
