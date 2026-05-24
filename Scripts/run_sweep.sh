#!/usr/bin/env bash
# =============================================================================
# run_sweep.sh  —  ECE 284 Project 2, Part 4 & 5
#
# For each Branch Predictor x Benchmark combination:
#   1. Check current BP in BaseO3CPU.py; call change_branch_predictor.sh if needed
#   2. Run gem5 simulation with Project-2 parameters
#   3. Collect BTBMissPct, BranchMispredPercent, miss counts → CPI
#   4. Append results to ./results/result.xlsx  (skip if row already exists)
#
# Usage:
#   ./run_sweep.sh
#   ./run_sweep.sh LocalBP          # run only one BP
#   ./run_sweep.sh LocalBP 401.bzip2 # run one BP x one benchmark
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# ① PARAMETER SETTINGS  ← edit here
# ---------------------------------------------------------------------------
GEM5_DIR="${HOME}/gem5"
SPEC_DIR="${HOME}/Downloads/Project1_SPEC-master"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_BP_SCRIPT="${SCRIPT_DIR}/change_branch_predictor.sh"
RESULTS_DIR="${SCRIPT_DIR}/results"
CSV_FILE="${RESULTS_DIR}/result.csv"

# Branch predictors to sweep (Project 2 requires all three)
BRANCH_PREDICTORS=("LocalBP" "BiModeBP" "TournamentBP")

# Benchmarks: name → "binary|argument"
declare -A BENCHMARKS
BENCHMARKS["401.bzip2"]="${SPEC_DIR}/401.bzip2/src/benchmark|${SPEC_DIR}/401.bzip2/data/input.program"
BENCHMARKS["429.mcf"]="${SPEC_DIR}/429.mcf/src/benchmark|${SPEC_DIR}/429.mcf/data/inp.in"
BENCHMARKS["456.hmmer"]="${SPEC_DIR}/456.hmmer/src/benchmark|${SPEC_DIR}/456.hmmer/data/bombesin.hmm.new"
BENCHMARKS["458.sjeng"]="${SPEC_DIR}/458.sjeng/src/benchmark|${SPEC_DIR}/458.sjeng/data/test.txt"
BENCHMARKS["470.lbm"]="${SPEC_DIR}/470.lbm/src/benchmark|20 reference.dat 0 1 ${SPEC_DIR}/470.lbm/data/100_100_130_cf_a.of"

# Benchmark order (associative arrays have no guaranteed order in bash)
BENCHMARK_ORDER=("401.bzip2" "429.mcf" "456.hmmer" "458.sjeng" "470.lbm")

# gem5 simulation parameters  (Project 2 requirements)
CPU_TYPE=DerivO3CPU
MAX_INST=500000000       # 500 million instructions
L1D_SIZE=128kB
L1I_SIZE=128kB
L2_SIZE=1MB
L1D_ASSOC=2
L1I_ASSOC=2
L2_ASSOC=4               # Project 2 requirement (was 8 in Project 1)
CACHE_LINE=64

# CPI formula weights  (from project spec)
L1_MISS_PENALTY=10
L2_MISS_PENALTY=80

# ---------------------------------------------------------------------------
# ② Optional CLI overrides:  ./run_sweep.sh [BP] [benchmark]
# ---------------------------------------------------------------------------
if [[ $# -ge 1 ]]; then BRANCH_PREDICTORS=("$1"); fi
if [[ $# -ge 2 ]]; then BENCHMARK_ORDER=("$2"); fi

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}==> $*${RESET}"; }

# ---------------------------------------------------------------------------
# Helper: get current BP from BaseO3CPU.py
# ---------------------------------------------------------------------------
current_bp() {
    python3 - "${GEM5_DIR}/src/cpu/o3/BaseO3CPU.py" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'Param\.BranchPredictor\(\s*([A-Za-z0-9_]+)', text)
print(m.group(1) if m else "Unknown")
PYEOF
}

# ---------------------------------------------------------------------------
# Helper: extract a single numeric stat from stats.txt
#   usage: extract_stat <stats_file> <stat_name>
# ---------------------------------------------------------------------------
extract_stat() {
    local stats_file="$1"
    local stat_name="$2"
    # gem5 stat lines: "system.cpu.branchPred.BTBMissPct   12.345  # description"
    grep -m1 "${stat_name}" "${stats_file}" \
        | awk '{print $2}' \
        | tr -d '\r' \
        || echo "0"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
step "Pre-flight checks"

[[ -d "${GEM5_DIR}" ]]         || { error "gem5 not found: ${GEM5_DIR}";           exit 1; }
[[ -f "${CHANGE_BP_SCRIPT}" ]] || { error "change_branch_predictor.sh not found: ${CHANGE_BP_SCRIPT}"; exit 1; }
[[ -x "${CHANGE_BP_SCRIPT}" ]] || chmod +x "${CHANGE_BP_SCRIPT}"
[[ -f "${GEM5_DIR}/build/X86/gem5.opt" ]] || { error "gem5.opt not found — compile first."; exit 1; }

# Verify all benchmark binaries exist
for bm in "${BENCHMARK_ORDER[@]}"; do
    bin="${BENCHMARKS[$bm]%%|*}"
    [[ -f "${bin}" ]] || { error "Benchmark binary not found: ${bin}"; exit 1; }
done

mkdir -p "${RESULTS_DIR}"
success "All pre-flight checks passed."

# Summarise sweep plan
echo ""
info "Branch predictors : ${BRANCH_PREDICTORS[*]}"
info "Benchmarks        : ${BENCHMARK_ORDER[*]}"
info "Results directory : ${RESULTS_DIR}"
info "XLSX output       : ${XLSX_FILE}"
echo ""
info "Simulation config : CPU=${CPU_TYPE}  MAX_INST=${MAX_INST}"
info "Cache config      : L1D=${L1D_SIZE}/${L1D_ASSOC}w  L1I=${L1I_SIZE}/${L1I_ASSOC}w  L2=${L2_SIZE}/${L2_ASSOC}w  CL=${CACHE_LINE}B"
echo ""

# ---------------------------------------------------------------------------
# Main sweep
# ---------------------------------------------------------------------------
for BP in "${BRANCH_PREDICTORS[@]}"; do

    step "Branch Predictor: ${BP}"

    # ── ① Check & switch predictor ──────────────────────────────────────────
    ACTIVE_BP=$(current_bp)
    if [[ "${ACTIVE_BP}" != "${BP}" ]]; then
        warn "Active predictor is '${ACTIVE_BP}', need '${BP}'. Running change_branch_predictor.sh ..."
        bash "${CHANGE_BP_SCRIPT}" "${BP}"
        # Verify switch succeeded
        ACTIVE_BP=$(current_bp)
        if [[ "${ACTIVE_BP}" != "${BP}" ]]; then
            error "Predictor switch failed — BaseO3CPU.py still shows '${ACTIVE_BP}'. Aborting."
            exit 1
        fi
        success "Predictor switched to ${BP}."
    else
        success "Predictor already set to ${BP} — no recompile needed."
    fi

    BP_RESULT_DIR="${RESULTS_DIR}/${BP}"
    mkdir -p "${BP_RESULT_DIR}"

    # ── ② Per-benchmark simulation ──────────────────────────────────────────
    for BM in "${BENCHMARK_ORDER[@]}"; do

        echo ""
        info "  Running: ${BP} × ${BM}"

        BM_OUT_DIR="${BP_RESULT_DIR}/${BM}/m5out"
        STATS_FILE="${BM_OUT_DIR}/stats.txt"

        # ── ③ Skip check: does this row already exist in result.csv? ────────
        if [[ -f "${CSV_FILE}" ]] && grep -q "^${BP},${BM}," "${CSV_FILE}"; then
            warn "  Skipping ${BP} × ${BM} — already in result.csv."
            continue
        fi

        # ── ④ Run simulation ─────────────────────────────────────────────────
        mkdir -p "${BM_OUT_DIR}"
        BIN="${BENCHMARKS[$BM]%%|*}"
        ARG="${BENCHMARKS[$BM]##*|}"

        info "  Output dir: ${BM_OUT_DIR}"
        SIM_LOG="${BP_RESULT_DIR}/${BM}/sim.log"

        set +e
        time "${GEM5_DIR}/build/X86/gem5.opt" \
            -d "${BM_OUT_DIR}" \
            "${GEM5_DIR}/configs/deprecated/example/se.py" \
            -c "${BIN}" \
            -o "${ARG}" \
            -I "${MAX_INST}" \
            --cpu-type="${CPU_TYPE}" \
            --caches \
            --l2cache \
            --l1d_size="${L1D_SIZE}" \
            --l1i_size="${L1I_SIZE}" \
            --l2_size="${L2_SIZE}" \
            --l1d_assoc="${L1D_ASSOC}" \
            --l1i_assoc="${L1I_ASSOC}" \
            --l2_assoc="${L2_ASSOC}" \
            --cacheline_size="${CACHE_LINE}" \
            2>&1 | tee "${SIM_LOG}"
        SIM_RC=${PIPESTATUS[0]}
        set -e

        if [[ ${SIM_RC} -ne 0 ]]; then
            error "  Simulation FAILED for ${BP} × ${BM} (exit ${SIM_RC}). See ${SIM_LOG}"
            warn  "  Skipping result collection for this run."
            continue
        fi

        if [[ ! -f "${STATS_FILE}" ]]; then
            error "  stats.txt not found after simulation: ${STATS_FILE}"
            continue
        fi

        success "  Simulation complete: ${BP} × ${BM}"

        # ── ⑤ Verify BP in config.ini ────────────────────────────────────────
        CONFIG_INI="${BM_OUT_DIR}/config.ini"
        if [[ -f "${CONFIG_INI}" ]]; then
            if grep -q "${BP}" "${CONFIG_INI}"; then
                success "  Confirmed '${BP}' in config.ini ✓"
            else
                warn "  '${BP}' not found in config.ini — verify manually."
                grep -A 2 "branchPred" "${CONFIG_INI}" | sed 's/^/      /' || true
            fi
        fi

        # ── ⑥ Collect stats ──────────────────────────────────────────────────
        info "  Collecting stats from ${STATS_FILE} ..."

        IL1_MISS=$(extract_stat "${STATS_FILE}" "system.cpu.icache.overallMisses::total")
        DL1_MISS=$(extract_stat "${STATS_FILE}" "system.cpu.dcache.overallMisses::total")
        L2_MISS=$(extract_stat  "${STATS_FILE}" "system.l2.overallMisses::total")
        TOTAL_INST=$(extract_stat "${STATS_FILE}" "sim_insts")
        BTB_MISS_PCT=$(extract_stat "${STATS_FILE}" "BTBMissPct")
        BRANCH_MISPRED_PCT=$(extract_stat "${STATS_FILE}" "BranchMispredPercent")

        # Fallback stat names (try alternate conventions if primary returned 0)
        [[ "${IL1_MISS}"   == "0" ]] && \
            IL1_MISS=$(extract_stat "${STATS_FILE}" "system.cpu.icache.overall_misses::total")
        [[ "${DL1_MISS}"   == "0" ]] && \
            DL1_MISS=$(extract_stat "${STATS_FILE}" "system.cpu.dcache.overall_misses::total")
        [[ "${L2_MISS}"    == "0" ]] && \
            L2_MISS=$(extract_stat  "${STATS_FILE}" "system.l2.overall_misses::total")
        [[ "${TOTAL_INST}" == "0" ]] && \
            TOTAL_INST=$(extract_stat "${STATS_FILE}" "simInsts")

        # ── ⑦ Compute CPI and append to result.csv ───────────────────────────
        # CPI = 1 + [(IL1_miss + DL1_miss)*10 + L2_miss*80] / Total_Inst
        CPI=$(awk "BEGIN {
            il1=${IL1_MISS}; dl1=${DL1_MISS}; l2=${L2_MISS}; inst=${TOTAL_INST}
            if (inst > 0)
                printf \"%.6f\", 1 + ((il1+dl1)*${L1_MISS_PENALTY} + l2*${L2_MISS_PENALTY}) / inst
            else
                print \"N/A\"
        }")

        # Write CSV header if file does not exist yet
        if [[ ! -f "${CSV_FILE}" ]]; then
            echo "BranchPredictor,Benchmark,IL1_Misses,DL1_Misses,L2_Misses,Total_Instructions,BTBMissPct,BranchMispredPercent,CPI" \
                > "${CSV_FILE}"
        fi

        # Append result row
        echo "${BP},${BM},${IL1_MISS},${DL1_MISS},${L2_MISS},${TOTAL_INST},${BTB_MISS_PCT},${BRANCH_MISPRED_PCT},${CPI}" \
            >> "${CSV_FILE}"

        success "  Saved to result.csv: ${BP} × ${BM}"
        echo ""
        info "  Stats summary:"
        echo "    IL1_Misses           = ${IL1_MISS}"
        echo "    DL1_Misses           = ${DL1_MISS}"
        echo "    L2_Misses            = ${L2_MISS}"
        echo "    Total_Instructions   = ${TOTAL_INST}"
        echo "    BTBMissPct           = ${BTB_MISS_PCT}"
        echo "    BranchMispredPercent = ${BRANCH_MISPRED_PCT}"
        echo "    CPI                  = ${CPI}"

    done  # benchmark loop

done  # branch predictor loop

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}============================================================"
echo "  Sweep Complete"
echo "============================================================${RESET}"
echo ""
info "Results directory : ${RESULTS_DIR}"
info "CSV output        : ${CSV_FILE}"
echo ""
if [[ -f "${CSV_FILE}" ]]; then
    ROW_COUNT=$(( $(wc -l < "${CSV_FILE}") - 1 ))
    success "result.csv contains ${ROW_COUNT} result row(s)."
    echo ""
    column -t -s',' "${CSV_FILE}" | sed 's/^/  /'
fi
echo ""
success "All done."
