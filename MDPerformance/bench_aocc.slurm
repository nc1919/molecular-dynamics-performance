#!/bin/bash
#SBATCH --job-name=mdperf_aocc
#SBATCH --partition=standard
#SBATCH --qos=standard
#SBATCH --time=01:30:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --hint=nomultithread
#SBATCH --exclusive
#SBATCH --output=log_mdperf_aocc_%j.txt
#SBATCH --error=log_mdperf_aocc_%j.err

set -euo pipefail

module swap PrgEnv-cray PrgEnv-aocc || module load PrgEnv-aocc

BUILD_CC="${BUILD_CC:-cc}"
export CC="${BUILD_CC}"

if ! command -v "${BUILD_CC}" >/dev/null 2>&1; then
  echo "Requested C compiler '${BUILD_CC}' is not available after loading AOCC modules." >&2
  module list 2>&1 || true
  exit 1
fi

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
RESULTS="${MP_ROOT}/results/aocc"
METADATA="${RESULTS}/metadata"

MODE="${MODE:-fast}"
BASE_MODE="${BASE_MODE:-release}"
NSTEP="${NSTEP:-100}"
REPEATS="${REPEATS:-3}"
ARCH_FLAGS="${ARCH_FLAGS:--march=znver2 -mtune=znver2}"
EXTRA_FLAGS_DEFAULT="${EXTRA_FLAGS_DEFAULT:--D_DEFAULT_SOURCE}"
RUN_OPT1="${RUN_OPT1:-1}"
RUN_OPT2="${RUN_OPT2:-1}"
RUN_ARCHER2="${RUN_ARCHER2:-1}"

mkdir -p "${RESULTS}"

write_version_file () {
  local tool_name="$1"
  local output_file="$2"

  if command -v "${tool_name}" >/dev/null 2>&1; then
    "${tool_name}" --version > "${output_file}" 2>&1 || true
  else
    echo "${tool_name} not found" > "${output_file}"
  fi
}

capture_metadata () {
  mkdir -p "${METADATA}"

  {
    echo "script=bench_aocc.slurm"
    echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "hostname=$(hostname)"
    echo "PP_ROOT=${PP_ROOT}"
    echo "MP_ROOT=${MP_ROOT}"
    echo "BASE_WORKDIR=${BASE_WORKDIR}"
    echo "WORKDIR=${WORKDIR}"
    echo "TESTDIR=${TESTDIR}"
    echo "RESULTS=${RESULTS}"
    echo "BUILD_CC=${BUILD_CC}"
    echo "BASE_MODE=${BASE_MODE}"
    echo "MODE=${MODE}"
    echo "NSTEP=${NSTEP}"
    echo "REPEATS=${REPEATS}"
    echo "ARCH_FLAGS=${ARCH_FLAGS}"
    echo "EXTRA_FLAGS_DEFAULT=${EXTRA_FLAGS_DEFAULT}"
    echo "RUN_OPT1=${RUN_OPT1}"
    echo "RUN_OPT2=${RUN_OPT2}"
    echo "RUN_ARCHER2=${RUN_ARCHER2}"
  } > "${METADATA}/run_config.txt"

  (uname -a || true) > "${METADATA}/uname.txt"
  (lscpu || true) > "${METADATA}/lscpu.txt"
  (module list 2>&1 || true) > "${METADATA}/module_list.txt"
  (which cc || true) > "${METADATA}/cc_path.txt"
  (cc --version || true) > "${METADATA}/cc_version.txt"
  write_version_file gcc "${METADATA}/gcc_version.txt"
  write_version_file clang "${METADATA}/clang_version.txt"
  write_version_file amdclang "${METADATA}/amdclang_version.txt"
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

expect_executable () {
  local exe_path="$1"

  if [[ ! -x "${exe_path}" ]]; then
    echo "Expected executable ${exe_path} was not produced by the build." >&2
    ls -l "$(dirname "${exe_path}")" >&2 || true
    exit 1
  fi
}

run_baseline_case () {
  local tag="$1"
  local run_dir="${RESULTS}/${tag}"

  echo "== Building original MD baseline with AOCC =="
  make -C "${BASE_WORKDIR}" clean
  make -B -C "${BASE_WORKDIR}" CC="${BUILD_CC}" MD MODE="${BASE_MODE}" ARCH_FLAGS="${ARCH_FLAGS}" EXTRA_FLAGS="${EXTRA_FLAGS_DEFAULT}"
  expect_executable "${BASE_WORKDIR}/MD"

  echo "== Running baseline (for correctness reference) =="
  mkdir -p "${run_dir}"
  pushd "${BASE_WORKDIR}" >/dev/null
  rm -f output.dat*
  ./MD "${NSTEP}" > "${run_dir}/run.log"
  mv output.dat* "${run_dir}/"
  popd >/dev/null

  check_output_sanity "${run_dir}/output.dat$(printf "%03d" $((NSTEP*5)))" "${run_dir}/sanity.txt"
}

run_perf_case () {
  local target="$1"
  local run_root="${RESULTS}/${target}"

  echo "== Building ${target} with AOCC =="
  make -C "${WORKDIR}" clean
  make -B -C "${WORKDIR}" CC="${BUILD_CC}" "${target}" MODE="${MODE}" ARCH_FLAGS="${ARCH_FLAGS}" EXTRA_FLAGS="${EXTRA_FLAGS_DEFAULT}"
  expect_executable "${WORKDIR}/${target}"

  echo "== Running ${target} repeats =="
  for rep in $(seq 1 "${REPEATS}"); do
    local rep_dir="${run_root}/rep${rep}"
    mkdir -p "${rep_dir}"
    pushd "${WORKDIR}" >/dev/null
    rm -f output.dat*
    "./${target}" "${NSTEP}" > "${rep_dir}/run.log"
    mv output.dat* "${rep_dir}/"
    popd >/dev/null
    check_output_sanity "${rep_dir}/output.dat$(printf "%03d" $((NSTEP*5)))" "${rep_dir}/sanity.txt"
  done
}

capture_metadata

echo "MDPerformance AOCC sweep"
echo "  PP_ROOT=${PP_ROOT}"
echo "  MP_ROOT=${MP_ROOT}"
echo "  BUILD_CC=${BUILD_CC}"
echo "  BASE_MODE=${BASE_MODE}"
echo "  MODE=${MODE}"
echo "  NSTEP=${NSTEP}"
echo "  REPEATS=${REPEATS}"
echo "  ARCH_FLAGS=${ARCH_FLAGS}"
echo "  RUN_OPT1=${RUN_OPT1}"
echo "  RUN_OPT2=${RUN_OPT2}"
echo "  RUN_ARCHER2=${RUN_ARCHER2}"
echo

echo "== Building correctness comparator =="
make -C "${TESTDIR}" clean
make -C "${TESTDIR}"

baseline_tag="baseline"
run_baseline_case "${baseline_tag}"

enabled_targets=()

if [[ "${RUN_OPT1}" == "1" ]]; then
  enabled_targets+=("MD_opt1")
  run_perf_case "MD_opt1"
fi

if [[ "${RUN_OPT2}" == "1" ]]; then
  enabled_targets+=("MD_opt2")
  run_perf_case "MD_opt2"
fi

if [[ "${RUN_ARCHER2}" == "1" ]]; then
  enabled_targets+=("MD_opt_archer2")
  run_perf_case "MD_opt_archer2"
fi

baseline_file="${RESULTS}/${baseline_tag}/output.dat$(printf "%03d" $((NSTEP*5)))"

echo
echo "== Correctness vs original MD baseline (${baseline_file}) =="
for target in "${enabled_targets[@]}"; do
  current_file="${RESULTS}/${target}/rep1/output.dat$(printf "%03d" $((NSTEP*5)))"
  echo "-- ${target}"
  "${TESTDIR}/diff-output" "${baseline_file}" "${current_file}" || true
done

echo
echo "== Timing summary =="
printf -- "-- baseline: "
awk '/timesteps took/ {last=$0} END {print last}' "${RESULTS}/${baseline_tag}/run.log"
for target in "${enabled_targets[@]}"; do
  for rep in $(seq 1 "${REPEATS}"); do
    printf -- "-- %s rep%s: " "${target}" "${rep}"
    awk '/timesteps took/ {last=$0} END {print last}' "${RESULTS}/${target}/rep${rep}/run.log"
  done
done
