#!/usr/bin/env bash
# =============================================================================
# run_ablation.sh  —  ECE 284 Project 2, Part 4 Task 3
#
# Grid search over TournamentBP predictor sizes (2x2x2 = 8 configs),
# sweeping all 5 benchmarks per config.
#
# Variables varied (defaults from BranchPredictor.py):
#   localPredictorSize  : default 2048  → ablations: 1024 (0.5x), 4096 (2x)
#   globalPredictorSize : default 8192  → ablations: 4096 (0.5x), 16384 (2x)
#   choicePredictorSize : default 8192  → ablations: 4096 (0.5x), 16384 (2x)
#
# Usage:
#   ./run_ablation.sh                          # all 5 benchmarks
#   ./run_ablation.sh 401.bzip2                # single benchmark
#   ./run_ablation.sh "401.bzip2 429.mcf"      # subset (quoted)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# ① PARAMETER SETTINGS
# ---------------------------------------------------------------------------
GEM5_DIR="${HOME}/gem5"
SPEC_DIR="${HOME}/Downloads/Project1_SPEC-master"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_BP_SCRIPT="${SCRIPT_DIR}/change_branch_predictor.sh"
RESULTS_DIR="${SCRIPT_DIR}/results"
CSV_FILE="${RESULTS_DIR}/result_ablation.csv"

BP_PY="${GEM5_DIR}/src/cpu/pred/BranchPredictor.py"

# Default values (from BranchPredictor.py image)
DEFAULT_LOCAL=2048
DEFAULT_GLOBAL=8192
DEFAULT_CHOICE=8192

# Ablation values: 0.5x and 2x of each default
LOCAL_SIZES=(1024 4096)
GLOBAL_SIZES=(4096 16384)
CHOICE_SIZES=(4096 16384)

# Benchmarks
declare -A BENCHMARKS
BENCHMARKS["401.bzip2"]="${SPEC_DIR}/401.bzip2/src/benchmark|${SPEC_DIR}/401.bzip2/data/input.program"
BENCHMARKS["429.mcf"]="${SPEC_DIR}/429.mcf/src/benchmark|${SPEC_DIR}/429.mcf/data/inp.in"
BENCHMARKS["456.hmmer"]="${SPEC_DIR}/456.hmmer/src/benchmark|${SPEC_DIR}/456.hmmer/data/bombesin.hmm.new"
BENCHMARKS["458.sjeng"]="${SPEC_DIR}/458.sjeng/src/benchmark|${SPEC_DIR}/458.sjeng/data/test.txt"
BENCHMARKS["470.lbm"]="${SPEC_DIR}/470.lbm/src/benchmark|20 reference.dat 0 1 ${SPEC_DIR}/470.lbm/data/100_100_130_cf_a.of"
DEFAULT_BM_ORDER=("401.bzip2" "429.mcf" "456.hmmer" "458.sjeng" "470.lbm")

# Simulation parameters (Project 2 requirements)
CPU_TYPE=DerivO3CPU
MAX_INST=500000000
L1D_SIZE=128kB;  L1I_SIZE=128kB;  L2_SIZE=1MB
L1D_ASSOC=2;     L1I_ASSOC=2;     L2_ASSOC=4
CACHE_LINE=64
L1_MISS_PENALTY=10
L2_MISS_PENALTY=80

# ---------------------------------------------------------------------------
# ② CLI: optional benchmark filter
# ---------------------------------------------------------------------------
if [[ $# -ge 1 ]]; then
    read -ra BM_ORDER <<< "$1"
else
    BM_ORDER=("${DEFAULT_BM_ORDER[@]}")
fi

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
# Helpers
# ---------------------------------------------------------------------------
current_bp() {
    python3 - "${GEM5_DIR}/src/cpu/o3/BaseO3CPU.py" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'Param\.BranchPredictor\(\s*([A-Za-z0-9_]+)', text)
print(m.group(1) if m else "Unknown")
PYEOF
}

extract_stat() {
    local f="$1" key="$2"
    grep -m1 "${key}" "${f}" | awk '{print $2}' | tr -d '\r' || echo "0"
}

# Modify a Param.Unsigned line in BranchPredictor.py and print the result
set_bp_param() {
    local param="$1" value="$2"
    # Match:  paramName = Param.Unsigned(digits, "...")
    python3 - "${BP_PY}" "${param}" "${value}" <<'PYEOF'
import re, sys
path, param, value = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
pattern = re.compile(
    r'(' + re.escape(param) + r'\s*=\s*Param\.Unsigned\()(\d+)(,)',
)
new_text, n = pattern.subn(lambda m: m.group(1) + value + m.group(3), text)
if n == 0:
    print(f"ERROR: param '{param}' not found in {path}", flush=True)
    sys.exit(1)
open(path, 'w').write(new_text)
# Print the modified line for double-check
for line in new_text.splitlines():
    if param in line and 'Param.Unsigned' in line:
        print(f"  [MODIFIED] {line.strip()}", flush=True)
        break
PYEOF
}

# Restore all three params to their defaults
restore_defaults() {
    info "Restoring BranchPredictor.py to defaults..."
    set_bp_param "localPredictorSize"  "${DEFAULT_LOCAL}"
    set_bp_param "globalPredictorSize" "${DEFAULT_GLOBAL}"
    set_bp_param "choicePredictorSize" "${DEFAULT_CHOICE}"
    success "Defaults restored: local=${DEFAULT_LOCAL} global=${DEFAULT_GLOBAL} choice=${DEFAULT_CHOICE}"
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
step "Pre-flight checks"

[[ -d "${GEM5_DIR}" ]]         || { error "gem5 not found: ${GEM5_DIR}";            exit 1; }
[[ -f "${BP_PY}" ]]            || { error "BranchPredictor.py not found: ${BP_PY}"; exit 1; }
[[ -f "${CHANGE_BP_SCRIPT}" ]] || { error "change_branch_predictor.sh not found";   exit 1; }
[[ -x "${CHANGE_BP_SCRIPT}" ]] || chmod +x "${CHANGE_BP_SCRIPT}"
[[ -f "${GEM5_DIR}/build/X86/gem5.opt" ]] || { error "gem5.opt not found — compile first."; exit 1; }

for bm in "${BM_ORDER[@]}"; do
    [[ -n "${BENCHMARKS[$bm]+x}" ]] || { error "Unknown benchmark: ${bm}"; exit 1; }
    bin="${BENCHMARKS[$bm]%%|*}"
    [[ -f "${bin}" ]] || { error "Binary not found: ${bin}"; exit 1; }
done
success "All checks passed."

# Ensure TournamentBP is active
ACTIVE_BP=$(current_bp)
if [[ "${ACTIVE_BP}" != "TournamentBP" ]]; then
    warn "Active BP is '${ACTIVE_BP}' — switching to TournamentBP..."
    bash "${CHANGE_BP_SCRIPT}" TournamentBP
    ACTIVE_BP=$(current_bp)
    [[ "${ACTIVE_BP}" == "TournamentBP" ]] || { error "Failed to switch to TournamentBP."; exit 1; }
    success "Switched to TournamentBP."
else
    success "TournamentBP already active."
fi

# Create results dir and CSV header
mkdir -p "${RESULTS_DIR}"
if [[ ! -f "${CSV_FILE}" ]]; then
    echo "localPredictorSize,globalPredictorSize,choicePredictorSize,Benchmark,IL1_Misses,DL1_Misses,L2_Misses,Total_Instructions,BTBMissPct,BranchMispredPercent,CPI,gem5_report_CPI" \
        > "${CSV_FILE}"
    info "Created result_ablation.csv"
fi

# Print sweep plan
echo ""
echo -e "${BOLD}Grid search plan (2×2×2 = 8 configs × ${#BM_ORDER[@]} benchmarks = $((8*${#BM_ORDER[@]})) runs):${RESET}"
echo "  localPredictorSize  : ${LOCAL_SIZES[*]}  (default ${DEFAULT_LOCAL})"
echo "  globalPredictorSize : ${GLOBAL_SIZES[*]}  (default ${DEFAULT_GLOBAL})"
echo "  choicePredictorSize : ${CHOICE_SIZES[*]}  (default ${DEFAULT_CHOICE})"
echo "  Benchmarks          : ${BM_ORDER[*]}"
echo ""

# ---------------------------------------------------------------------------
# ③ Grid search
# ---------------------------------------------------------------------------
CONFIG_NUM=0

for LOCAL in "${LOCAL_SIZES[@]}"; do
for GLOBAL in "${GLOBAL_SIZES[@]}"; do
for CHOICE in "${CHOICE_SIZES[@]}"; do

    (( CONFIG_NUM++ )) || true
    CONFIG_TAG="local${LOCAL}_global${GLOBAL}_choice${CHOICE}"

    step "Config ${CONFIG_NUM}/8: ${CONFIG_TAG}"

    # ── Modify BranchPredictor.py ──────────────────────────────────────────
    info "Updating BranchPredictor.py..."
    BACKUP_PY="${BP_PY}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "${BP_PY}" "${BACKUP_PY}"

    set_bp_param "localPredictorSize"  "${LOCAL}"
    set_bp_param "globalPredictorSize" "${GLOBAL}"
    set_bp_param "choicePredictorSize" "${CHOICE}"

    # ── Recompile ─────────────────────────────────────────────────────────
    info "Recompiling gem5..."
    AVAIL_MEM=$(awk '/MemAvailable/{printf "%d", $2/1024/1024}' /proc/meminfo)
    [[ ${AVAIL_MEM} -lt 4 ]] && JOBS=1 || JOBS=$(nproc)

    cd "${GEM5_DIR}"
    BUILD_LOG="/tmp/gem5_build_${CONFIG_TAG}.log"
    if ! scons build/X86/gem5.opt -j"${JOBS}" 2>&1 | tee "${BUILD_LOG}"; then
        error "Build FAILED for config ${CONFIG_TAG}. Restoring backup..."
        cp "${BACKUP_PY}" "${BP_PY}"
        continue
    fi
    success "Build succeeded for ${CONFIG_TAG}."

    # ── Per-benchmark simulation ───────────────────────────────────────────
    for BM in "${BM_ORDER[@]}"; do

        echo ""
        info "  Running: ${CONFIG_TAG} × ${BM}"

        # Skip check
        if grep -q "^${LOCAL},${GLOBAL},${CHOICE},${BM}," "${CSV_FILE}"; then
            warn "  Skipping — already in result_ablation.csv."
            continue
        fi

        BM_OUT_DIR="${RESULTS_DIR}/ablation/${CONFIG_TAG}/${BM}/m5out"
        STATS_FILE="${BM_OUT_DIR}/stats.txt"
        SIM_LOG="${RESULTS_DIR}/ablation/${CONFIG_TAG}/${BM}/sim.log"
        mkdir -p "${BM_OUT_DIR}"

        BIN="${BENCHMARKS[$BM]%%|*}"
        ARG="${BENCHMARKS[$BM]##*|}"

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

        if [[ ${SIM_RC} -ne 0 ]] || [[ ! -f "${STATS_FILE}" ]]; then
            error "  Simulation FAILED: ${CONFIG_TAG} × ${BM}. See ${SIM_LOG}"
            continue
        fi
        success "  Simulation complete."

        # ── Extract stats ─────────────────────────────────────────────────
        IL1_MISS=$(extract_stat "${STATS_FILE}" "system.cpu.icache.overallMisses::total")
        DL1_MISS=$(extract_stat "${STATS_FILE}" "system.cpu.dcache.overallMisses::total")
        L2_MISS=$( extract_stat "${STATS_FILE}" "system.l2.overallMisses::total")
        TOTAL_INST=$(extract_stat "${STATS_FILE}" "sim_insts")
        BTB_MISS_PCT=$(extract_stat "${STATS_FILE}" "BTBMissPct")
        BRANCH_MISPRED_PCT=$(extract_stat "${STATS_FILE}" "BranchMispredPercent")
        GEM5_CPI=$(extract_stat "${STATS_FILE}" "system.cpu.cpi")

        # Fallbacks
        [[ "${IL1_MISS}"   == "0" ]] && IL1_MISS=$(extract_stat "${STATS_FILE}" "system.cpu.icache.overall_misses::total")
        [[ "${DL1_MISS}"   == "0" ]] && DL1_MISS=$(extract_stat "${STATS_FILE}" "system.cpu.dcache.overall_misses::total")
        [[ "${L2_MISS}"    == "0" ]] && L2_MISS=$(extract_stat  "${STATS_FILE}" "system.l2.overall_misses::total")
        [[ "${TOTAL_INST}" == "0" ]] && TOTAL_INST=$(extract_stat "${STATS_FILE}" "simInsts")
        [[ "${GEM5_CPI}"   == "0" ]] && GEM5_CPI=$(extract_stat "${STATS_FILE}" "system.cpu.cpi_total")

        # ── Compute CPI ───────────────────────────────────────────────────
        CPI=$(awk "BEGIN {
            il1=${IL1_MISS}; dl1=${DL1_MISS}; l2=${L2_MISS}; inst=${TOTAL_INST}
            if (inst > 0)
                printf \"%.6f\", 1 + ((il1+dl1)*${L1_MISS_PENALTY} + l2*${L2_MISS_PENALTY}) / inst
            else
                print \"N/A\"
        }")

        # ── Append to CSV ─────────────────────────────────────────────────
        echo "${LOCAL},${GLOBAL},${CHOICE},${BM},${IL1_MISS},${DL1_MISS},${L2_MISS},${TOTAL_INST},${BTB_MISS_PCT},${BRANCH_MISPRED_PCT},${CPI},${GEM5_CPI}" \
            >> "${CSV_FILE}"

        success "  Saved → result_ablation.csv"
        echo "    localPredictorSize   = ${LOCAL}"
        echo "    globalPredictorSize  = ${GLOBAL}"
        echo "    choicePredictorSize  = ${CHOICE}"
        echo "    IL1_Misses           = ${IL1_MISS}"
        echo "    DL1_Misses           = ${DL1_MISS}"
        echo "    L2_Misses            = ${L2_MISS}"
        echo "    Total_Instructions   = ${TOTAL_INST}"
        echo "    BTBMissPct           = ${BTB_MISS_PCT}"
        echo "    BranchMispredPercent = ${BRANCH_MISPRED_PCT}"
        echo "    CPI (formula)        = ${CPI}"
        echo "    CPI (gem5 report)    = ${GEM5_CPI}"

    done  # benchmark loop

done  # choice loop
done  # global loop
done  # local loop

# ---------------------------------------------------------------------------
# Restore defaults when all done
# ---------------------------------------------------------------------------
step "Restoring BranchPredictor.py to original defaults"
restore_defaults

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}============================================================"
echo "  Ablation Sweep Complete"
echo "============================================================${RESET}"
echo ""
info "Results : ${CSV_FILE}"
if [[ -f "${CSV_FILE}" ]]; then
    ROW_COUNT=$(( $(wc -l < "${CSV_FILE}") - 1 ))
    success "result_ablation.csv contains ${ROW_COUNT} row(s)."
    echo ""
    column -t -s',' "${CSV_FILE}" | sed 's/^/  /'
fi
echo ""
success "All done."
