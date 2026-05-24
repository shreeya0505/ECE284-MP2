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
XLSX_FILE="${RESULTS_DIR}/result.xlsx"

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

        # ── ③ Skip check: does this row already exist in result.xlsx? ────────
        if [[ -f "${XLSX_FILE}" && -f "${STATS_FILE}" ]]; then
            ALREADY=$(python3 - "${XLSX_FILE}" "${BP}" "${BM}" <<'PYEOF'
import sys
try:
    import openpyxl
    wb = openpyxl.load_workbook(sys.argv[1])
    ws = wb.active
    bp, bm = sys.argv[2], sys.argv[3]
    for row in ws.iter_rows(min_row=2, values_only=True):
        if row[0] == bp and row[1] == bm:
            print("yes"); sys.exit(0)
    print("no")
except Exception:
    print("no")
PYEOF
)
            if [[ "${ALREADY}" == "yes" ]]; then
                warn "  Skipping ${BP} × ${BM} — already in result.xlsx."
                continue
            fi
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

        IL1_MISS=$(extract_stat "${STATS_FILE}" "system.cpu.icache.overall_misses::total")
        DL1_MISS=$(extract_stat "${STATS_FILE}" "system.cpu.dcache.overall_misses::total")
        L2_MISS=$(extract_stat  "${STATS_FILE}" "system.l2.overall_misses::total")
        TOTAL_INST=$(extract_stat "${STATS_FILE}" "simInsts")
        BTB_MISS_PCT=$(extract_stat "${STATS_FILE}" "BTBMissPct")
        BRANCH_MISPRED_PCT=$(extract_stat "${STATS_FILE}" "BranchMispredPercent")

        # Fallback stat names (gem5 versions differ slightly)
        [[ "${IL1_MISS}" == "0" ]] && \
            IL1_MISS=$(extract_stat "${STATS_FILE}" "system.cpu.icache.overall_miss_num::total")
        [[ "${DL1_MISS}" == "0" ]] && \
            DL1_MISS=$(extract_stat "${STATS_FILE}" "system.cpu.dcache.overall_miss_num::total")
        [[ "${L2_MISS}"  == "0" ]] && \
            L2_MISS=$(extract_stat  "${STATS_FILE}" "system.l2.overall_miss_num::total")

        # ── ⑦ Append to result.xlsx via Python ───────────────────────────────
        python3 - \
            "${XLSX_FILE}" "${BP}" "${BM}" \
            "${IL1_MISS}" "${DL1_MISS}" "${L2_MISS}" "${TOTAL_INST}" \
            "${BTB_MISS_PCT}" "${BRANCH_MISPRED_PCT}" \
            "${L1_MISS_PENALTY}" "${L2_MISS_PENALTY}" \
            <<'PYEOF'
import sys, os
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

xlsx        = sys.argv[1]
bp          = sys.argv[2]
bm          = sys.argv[3]
il1_miss    = sys.argv[4]
dl1_miss    = sys.argv[5]
l2_miss     = sys.argv[6]
total_inst  = sys.argv[7]
btb_miss    = sys.argv[8]
branch_mis  = sys.argv[9]
l1_pen      = sys.argv[10]
l2_pen      = sys.argv[11]

HEADERS = [
    "BranchPredictor", "Benchmark",
    "IL1_Misses", "DL1_Misses", "L2_Misses", "Total_Instructions",
    "BTBMissPct", "BranchMispredPercent",
    "CPI"
]

# CPI = 1 + [(IL1+DL1)*L1_pen + L2*L2_pen] / Total_Inst
# Written as Excel formula so the sheet stays dynamic
def cpi_formula(row):
    # Columns: C=IL1, D=DL1, E=L2, F=Total_Inst
    return (
        f"=1+((C{row}+D{row})*{l1_pen}+E{row}*{l2_pen})/F{row}"
    )

# ── Load or create workbook ───────────────────────────────────────────────
if os.path.exists(xlsx):
    wb = load_workbook(xlsx)
    ws = wb.active
    # Ensure headers present (in case file was created externally)
    if ws.max_row == 0 or ws.cell(1, 1).value != "BranchPredictor":
        ws.insert_rows(1)
        for col, h in enumerate(HEADERS, 1):
            ws.cell(1, col).value = h
else:
    wb = Workbook()
    ws = wb.active
    ws.title = "Results"

# ── Write headers if sheet is empty ──────────────────────────────────────
if ws.max_row < 1 or ws.cell(1, 1).value is None:
    for col, h in enumerate(HEADERS, 1):
        c = ws.cell(1, col, h)
        c.font      = Font(bold=True, color="FFFFFF", name="Arial", size=11)
        c.fill      = PatternFill("solid", start_color="2E4057")
        c.alignment = Alignment(horizontal="center", wrap_text=True)

# ── Append data row ───────────────────────────────────────────────────────
next_row = ws.max_row + 1

# Alternate row shading
fill_color = "EBF1F5" if next_row % 2 == 0 else "FFFFFF"
row_fill   = PatternFill("solid", start_color=fill_color)

thin = Side(border_style="thin", color="CCCCCC")
border = Border(left=thin, right=thin, top=thin, bottom=thin)

values = [
    bp, bm,
    int(float(il1_miss)), int(float(dl1_miss)), int(float(l2_miss)),
    int(float(total_inst)),
    float(btb_miss), float(branch_mis),
    cpi_formula(next_row)
]

for col, val in enumerate(values, 1):
    c = ws.cell(next_row, col, val)
    c.fill   = row_fill
    c.border = border
    c.font   = Font(name="Arial", size=10)
    if col in (3, 4, 5, 6):
        c.number_format = "#,##0"
    elif col in (7, 8):
        c.number_format = "0.000000"
    elif col == 9:
        c.number_format = "0.0000"
    c.alignment = Alignment(horizontal="center")

# ── Column widths ─────────────────────────────────────────────────────────
widths = [16, 14, 14, 14, 12, 20, 16, 22, 10]
for i, w in enumerate(widths, 1):
    ws.column_dimensions[get_column_letter(i)].width = w

wb.save(xlsx)
print(f"Appended: {bp} x {bm}  →  {xlsx}")
PYEOF

        success "  Saved to result.xlsx: ${BP} × ${BM}"
        echo ""
        info "  Stats summary:"
        echo "    IL1_Misses           = ${IL1_MISS}"
        echo "    DL1_Misses           = ${DL1_MISS}"
        echo "    L2_Misses            = ${L2_MISS}"
        echo "    Total_Instructions   = ${TOTAL_INST}"
        echo "    BTBMissPct           = ${BTB_MISS_PCT}"
        echo "    BranchMispredPercent = ${BRANCH_MISPRED_PCT}"

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
info "XLSX output       : ${XLSX_FILE}"
echo ""
if [[ -f "${XLSX_FILE}" ]]; then
    ROW_COUNT=$(python3 -c "
import openpyxl
wb = openpyxl.load_workbook('${XLSX_FILE}')
print(wb.active.max_row - 1)
" 2>/dev/null || echo "?")
    success "result.xlsx contains ${ROW_COUNT} result row(s)."
fi
success "All done."
