#!/bin/bash
#SBATCH --job-name=mdperf_variants
#SBATCH --partition=standard
#SBATCH --qos=standard
#SBATCH --time=01:30:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --hint=nomultithread
#SBATCH --exclusive
#SBATCH --output=log_mdperf_variants_%j.txt
#SBATCH --error=log_mdperf_variants_%j.err

set -euo pipefail

COMPILER_ENV="${COMPILER_ENV:-PrgEnv-gnu}"
BUILD_CC="${BUILD_CC:-cc}"
export CC="${BUILD_CC}"

module swap PrgEnv-cray "${COMPILER_ENV}" || module load "${COMPILER_ENV}"

if ! command -v "${BUILD_CC}" >/dev/null 2>&1; then
  echo "Requested C compiler '${BUILD_CC}' is not available after loading ${COMPILER_ENV}." >&2
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
COMPILER_TAG="$(printf '%s' "${COMPILER_ENV}" | tr '[:upper:]' '[:lower:]' | sed 's/prgenv-//g')"
RESULTS_ROOT="${MP_ROOT}/results/variants"
RESULTS="${RESULTS_ROOT}/${COMPILER_TAG}"
METADATA="${RESULTS}/metadata"

MODE="${MODE:-fast}"
NSTEP="${NSTEP:-100}"
REPEATS="${REPEATS:-3}"
ARCH_FLAGS_DEFAULT="${ARCH_FLAGS_DEFAULT:-}"
EXTRA_FLAGS_DEFAULT="${EXTRA_FLAGS_DEFAULT:--D_DEFAULT_SOURCE}"
BASE_MODE="${BASE_MODE:-${MODE}}"
BASE_ARCH_FLAGS="${BASE_ARCH_FLAGS:-${ARCH_FLAGS_DEFAULT}}"
RUN_ARCHER2="${RUN_ARCHER2:-0}"

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
    echo "script=bench_variants.slurm"
    echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "hostname=$(hostname)"
    echo "PP_ROOT=${PP_ROOT}"
    echo "MP_ROOT=${MP_ROOT}"
    echo "BASE_WORKDIR=${BASE_WORKDIR}"
    echo "WORKDIR=${WORKDIR}"
    echo "TESTDIR=${TESTDIR}"
    echo "RESULTS=${RESULTS}"
    echo "COMPILER_ENV=${COMPILER_ENV}"
    echo "COMPILER_TAG=${COMPILER_TAG}"
    echo "BUILD_CC=${BUILD_CC}"
    echo "BASE_MODE=${BASE_MODE}"
    echo "BASE_ARCH_FLAGS=${BASE_ARCH_FLAGS}"
    echo "MODE=${MODE}"
    echo "NSTEP=${NSTEP}"
    echo "REPEATS=${REPEATS}"
    echo "ARCH_FLAGS_DEFAULT=${ARCH_FLAGS_DEFAULT}"
    echo "EXTRA_FLAGS_DEFAULT=${EXTRA_FLAGS_DEFAULT}"
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

  if [[ ! -e "${exe_path}" ]]; then
    echo "Expected executable ${exe_path} was not produced by the build." >&2
    ls -l "$(dirname "${exe_path}")" >&2 || true
    exit 1
  fi

  if [[ ! -x "${exe_path}" ]]; then
    echo "Expected executable ${exe_path} exists but is not executable." >&2
    ls -l "${exe_path}" >&2 || true
    exit 1
  fi
}

run_benchmark_executable () {
  local exe_path="$1"
  local run_log="$2"
  shift 2

  if "${exe_path}" "$@" > "${run_log}"; then
    return 0
  else
    local status=$?
    echo "Execution failed for ${exe_path} (exit ${status})." >&2

    if command -v file >/dev/null 2>&1; then
      file "${exe_path}" >&2 || true
    fi

    if command -v ldd >/dev/null 2>&1; then
      ldd "${exe_path}" >&2 || true
    fi

    return "${status}"
  fi
}

capture_metadata

echo "MDPerformance variant sweep"
echo "  PP_ROOT=${PP_ROOT}"
echo "  MP_ROOT=${MP_ROOT}"
echo "  COMPILER_ENV=${COMPILER_ENV}"
echo "  COMPILER_TAG=${COMPILER_TAG}"
echo "  BASE_WORKDIR=${BASE_WORKDIR}"
echo "  BUILD_CC=${BUILD_CC}"
echo "  BASE_MODE=${BASE_MODE}"
echo "  BASE_ARCH_FLAGS=${BASE_ARCH_FLAGS:-<none>}"
echo "  MODE=${MODE}"
echo "  NSTEP=${NSTEP}"
echo "  REPEATS=${REPEATS}"
echo "  ARCH_FLAGS_DEFAULT=${ARCH_FLAGS_DEFAULT:-<none>}"
echo "  RUN_ARCHER2=${RUN_ARCHER2}"
echo

make -C "${TESTDIR}" clean
make -C "${TESTDIR}"

run_baseline_case () {
  local tag="$1"
  local exe_path="${BASE_WORKDIR}/MD"

  echo "== Case: ${tag} (original MD baseline) =="
  make -C "${BASE_WORKDIR}" clean
  make -B -C "${BASE_WORKDIR}" CC="${BUILD_CC}" MD MODE="${BASE_MODE}" ARCH_FLAGS="${BASE_ARCH_FLAGS}" EXTRA_FLAGS="${EXTRA_FLAGS_DEFAULT}"
  expect_executable "${exe_path}"

  for rep in $(seq 1 "${REPEATS}"); do
    local rep_dir="${RESULTS}/${tag}/rep${rep}"
    mkdir -p "${rep_dir}"
    pushd "${BASE_WORKDIR}" >/dev/null
    rm -f output.dat*
    run_benchmark_executable "${exe_path}" "${rep_dir}/run.log" "${NSTEP}"
    mv output.dat* "${rep_dir}/"
    popd >/dev/null
    check_output_sanity "${rep_dir}/output.dat$(printf "%03d" $((NSTEP*5)))" "${rep_dir}/sanity.txt"
  done
}

run_perf_case () {
  local tag="$1"
  local target="$2"
  local arch_flags="$3"
  local exe_path="${WORKDIR}/${target}"

  echo "== Case: ${tag} (${target}) =="
  make -C "${WORKDIR}" clean
  make -B -C "${WORKDIR}" CC="${BUILD_CC}" "${target}" MODE="${MODE}" ARCH_FLAGS="${arch_flags}" EXTRA_FLAGS="${EXTRA_FLAGS_DEFAULT}"
  expect_executable "${exe_path}"

  for rep in $(seq 1 "${REPEATS}"); do
    local rep_dir="${RESULTS}/${tag}/rep${rep}"
    mkdir -p "${rep_dir}"
    pushd "${WORKDIR}" >/dev/null
    rm -f output.dat*
    run_benchmark_executable "${exe_path}" "${rep_dir}/run.log" "${NSTEP}"
    mv output.dat* "${rep_dir}/"
    popd >/dev/null
    check_output_sanity "${rep_dir}/output.dat$(printf "%03d" $((NSTEP*5)))" "${rep_dir}/sanity.txt"
  done
}

baseline_tag="baseline"
run_baseline_case "${baseline_tag}"
run_perf_case "opt1" "MD_opt1" "${ARCH_FLAGS_DEFAULT}"
run_perf_case "opt2" "MD_opt2" "${ARCH_FLAGS_DEFAULT}"

if [[ "${RUN_ARCHER2}" == "1" ]]; then
  run_perf_case "archer2" "MD_opt_archer2" "${ARCH_FLAGS_DEFAULT}"
fi

baseline_file="${RESULTS}/${baseline_tag}/rep1/output.dat$(printf "%03d" $((NSTEP*5)))"

echo
echo "== Correctness vs baseline (${baseline_file}) =="
for tag in opt1 opt2; do
  current="${RESULTS}/${tag}/rep1/output.dat$(printf "%03d" $((NSTEP*5)))"
  echo "-- ${tag}"
  "${TESTDIR}/diff-output" "${baseline_file}" "${current}" || true
done

if [[ "${RUN_ARCHER2}" == "1" ]]; then
  current="${RESULTS}/archer2/rep1/output.dat$(printf "%03d" $((NSTEP*5)))"
  echo "-- archer2"
  "${TESTDIR}/diff-output" "${baseline_file}" "${current}" || true
fi

echo
echo "== Timing summary (first replicate) =="
for tag in baseline opt1 opt2; do
  printf -- "-- %s: " "${tag}"
  awk '/timesteps took/ {last=$0} END {print last}' "${RESULTS}/${tag}/rep1/run.log"
done

if [[ "${RUN_ARCHER2}" == "1" ]]; then
  printf -- "-- %s: " "archer2"
  awk '/timesteps took/ {last=$0} END {print last}' "${RESULTS}/archer2/rep1/run.log"
fi
