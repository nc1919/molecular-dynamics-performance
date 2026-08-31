#!/bin/bash
#SBATCH --job-name=mdperf_vectorize
#SBATCH --partition=standard
#SBATCH --qos=standard
#SBATCH --time=00:30:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --hint=nomultithread
#SBATCH --exclusive
#SBATCH --output=log_mdperf_vectorize_%j.txt
#SBATCH --error=log_mdperf_vectorize_%j.err

set -euo pipefail

COMPILER_ENV="${COMPILER_ENV:-PrgEnv-gnu}"
BUILD_CC="${BUILD_CC:-cc}"
MODE="${MODE:-fast}"
BASE_MODE="${BASE_MODE:-${MODE}}"
ARCH_FLAGS="${ARCH_FLAGS:-}"
EXTRA_FLAGS_DEFAULT="${EXTRA_FLAGS_DEFAULT:--D_DEFAULT_SOURCE}"
RUN_OPT1="${RUN_OPT1:-1}"
RUN_OPT2="${RUN_OPT2:-1}"
RUN_ARCHER2="${RUN_ARCHER2:-1}"
PROFILE_FLAGS="${PROFILE_FLAGS:-}"

module swap PrgEnv-cray "${COMPILER_ENV}" || module load "${COMPILER_ENV}"

export CC="${BUILD_CC}"

if ! command -v "${BUILD_CC}" >/dev/null 2>&1; then
  echo "Requested C compiler '${BUILD_CC}' is not available after loading ${COMPILER_ENV}." >&2
  module list 2>&1 || true
  exit 1
fi

if [[ -z "${PROFILE_FLAGS}" ]]; then
  case "${COMPILER_ENV}" in
    *gnu*)
      PROFILE_FLAGS="-fopt-info-vec-optimized -fopt-info-vec-missed"
      ;;
    *aocc*|*llvm*|*clang*)
      PROFILE_FLAGS="-Rpass=loop-vectorize -Rpass-missed=loop-vectorize"
      ;;
    *)
      PROFILE_FLAGS="-fopt-info-vec-optimized -fopt-info-vec-missed"
      ;;
  esac
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
COMPILER_TAG="$(printf '%s' "${COMPILER_ENV}" | tr '[:upper:]' '[:lower:]' | sed 's/prgenv-//g')"
RESULTS_ROOT="${MP_ROOT}/results/vectorization"
RESULTS="${RESULTS_ROOT}/${COMPILER_TAG}"
METADATA="${RESULTS}/metadata"

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
    echo "script=bench_vectorization.slurm"
    echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "hostname=$(hostname)"
    echo "PP_ROOT=${PP_ROOT}"
    echo "MP_ROOT=${MP_ROOT}"
    echo "BASE_WORKDIR=${BASE_WORKDIR}"
    echo "WORKDIR=${WORKDIR}"
    echo "RESULTS=${RESULTS}"
    echo "COMPILER_ENV=${COMPILER_ENV}"
    echo "COMPILER_TAG=${COMPILER_TAG}"
    echo "BUILD_CC=${BUILD_CC}"
    echo "BASE_MODE=${BASE_MODE}"
    echo "MODE=${MODE}"
    echo "ARCH_FLAGS=${ARCH_FLAGS}"
    echo "EXTRA_FLAGS_DEFAULT=${EXTRA_FLAGS_DEFAULT}"
    echo "PROFILE_FLAGS=${PROFILE_FLAGS}"
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

summarise_vector_report () {
  local log_file="$1"
  local summary_file="$2"

  if command -v rg >/dev/null 2>&1; then
    if ! rg -n -i 'vectoriz|remark|missed|optimized: loop|cost-model' "${log_file}" > "${summary_file}"; then
      echo "No vectorisation remarks found in ${log_file}" > "${summary_file}"
    fi
  else
    if ! grep -Ein 'vectoriz|remark|missed|optimized: loop|cost-model' "${log_file}" > "${summary_file}"; then
      echo "No vectorisation remarks found in ${log_file}" > "${summary_file}"
    fi
  fi
}

compile_original_md () {
  local case_dir="${RESULTS}/original_md"
  mkdir -p "${case_dir}"

  echo "== Compiling original MD baseline =="
  {
    echo "== clean =="
    make -C "${BASE_WORKDIR}" clean
    echo
    echo "== build objects =="
    make -B -C "${BASE_WORKDIR}" CC="${BUILD_CC}" MD.o control.o util.o \
      MODE="${BASE_MODE}" ARCH_FLAGS="${ARCH_FLAGS}" \
      EXTRA_FLAGS="${EXTRA_FLAGS_DEFAULT} ${PROFILE_FLAGS}"
  } > "${case_dir}/build.log" 2>&1

  summarise_vector_report "${case_dir}/build.log" "${case_dir}/vector_report.txt"
}

compile_perf_target () {
  local target="$1"
  local object_name="$2"
  local case_dir="${RESULTS}/${target}"
  mkdir -p "${case_dir}"

  echo "== Compiling ${target} =="
  {
    echo "== clean =="
    make -C "${WORKDIR}" clean
    echo
    echo "== build objects =="
    make -B -C "${WORKDIR}" CC="${BUILD_CC}" "${object_name}" control.o util.o \
      MODE="${MODE}" ARCH_FLAGS="${ARCH_FLAGS}" \
      EXTRA_FLAGS="${EXTRA_FLAGS_DEFAULT}" PROFILE_FLAGS="${PROFILE_FLAGS}"
  } > "${case_dir}/build.log" 2>&1

  summarise_vector_report "${case_dir}/build.log" "${case_dir}/vector_report.txt"
}

write_combined_summary () {
  local combined_file="${RESULTS}/combined_vector_report.txt"

  {
    echo "Vectorisation report summary"
    echo "compiler_env=${COMPILER_ENV}"
    echo "mode=${MODE}"
    echo "base_mode=${BASE_MODE}"
    echo "arch_flags=${ARCH_FLAGS:-<none>}"
    echo "profile_flags=${PROFILE_FLAGS}"
    echo

    for case_name in original_md MD_opt1 MD_opt2 MD_opt_archer2; do
      if [[ -f "${RESULTS}/${case_name}/vector_report.txt" ]]; then
        echo "== ${case_name} =="
        cat "${RESULTS}/${case_name}/vector_report.txt"
        echo
      fi
    done
  } > "${combined_file}"
}

capture_metadata

echo "MDPerformance vectorisation-report sweep"
echo "  COMPILER_ENV=${COMPILER_ENV}"
echo "  BUILD_CC=${BUILD_CC}"
echo "  BASE_MODE=${BASE_MODE}"
echo "  MODE=${MODE}"
echo "  ARCH_FLAGS=${ARCH_FLAGS:-<none>}"
echo "  PROFILE_FLAGS=${PROFILE_FLAGS}"
echo "  RUN_OPT1=${RUN_OPT1}"
echo "  RUN_OPT2=${RUN_OPT2}"
echo "  RUN_ARCHER2=${RUN_ARCHER2}"
echo

compile_original_md

if [[ "${RUN_OPT1}" == "1" ]]; then
  compile_perf_target "MD_opt1" "MD_opt1.o"
fi

if [[ "${RUN_OPT2}" == "1" ]]; then
  compile_perf_target "MD_opt2" "MD_opt2.o"
fi

if [[ "${RUN_ARCHER2}" == "1" ]]; then
  compile_perf_target "MD_opt_archer2" "MD_opt_archer2.o"
fi

write_combined_summary

echo
echo "== Combined vectorisation report =="
cat "${RESULTS}/combined_vector_report.txt"
