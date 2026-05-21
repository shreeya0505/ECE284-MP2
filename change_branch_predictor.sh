#!/usr/bin/env bash
# =============================================================================
# change_branch_predictor.sh
#
# Automates:
#   1. Editing the branch predictor in BaseO3CPU.py
#   2. Recompiling gem5 with scons
#   3. Running the HelloWorld test with the O3 CPU model
#   4. Verifying the chosen predictor via grep on config.ini
#
# Usage:
#   ./change_branch_predictor.sh [PREDICTOR]
#
# Arguments:
#   PREDICTOR  (optional) Branch predictor class name to use.
#              Defaults to BiModeBP.
#              Other valid options: LocalBP, TournamentBP, LTAGE, TAGE,
#                                   MultiperspectivePerceptron8KB, etc.
#
# Examples:
#   ./change_branch_predictor.sh              # uses BiModeBP (default)
#   ./change_branch_predictor.sh LocalBP
#   ./change_branch_predictor.sh LTAGE
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these paths if your gem5 installation differs
# ---------------------------------------------------------------------------
GEM5_DIR="${HOME}/gem5"
O3_DIR="${GEM5_DIR}/src/cpu/o3"
TARGET_FILE="${O3_DIR}/BaseO3CPU.py"
GEM5_BIN="${GEM5_DIR}/build/X86/gem5.opt"
SE_CONFIG="${GEM5_DIR}/configs/deprecated/example/se.py"
HELLO_BIN="${GEM5_DIR}/tests/test-progs/hello/bin/x86/linux/hello"
CONFIG_INI="${GEM5_DIR}/m5out/config.ini"
SCONS_JOBS=$(nproc)          # use all available CPU cores for compilation

# ---------------------------------------------------------------------------
# Colours for readable output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}==> $*${RESET}"; }

# ---------------------------------------------------------------------------
# Parse argument
# ---------------------------------------------------------------------------
NEW_PREDICTOR="${1:-BiModeBP}"

echo -e "${BOLD}"
echo "============================================================"
echo "  gem5 Branch Predictor Automation Script"
echo "  Target predictor : ${NEW_PREDICTOR}"
echo "  gem5 root        : ${GEM5_DIR}"
echo "============================================================"
echo -e "${RESET}"

# ---------------------------------------------------------------------------
# Step 0 — Sanity checks
# ---------------------------------------------------------------------------
step "Step 0 — Pre-flight checks"

if [[ ! -d "${GEM5_DIR}" ]]; then
    error "gem5 directory not found: ${GEM5_DIR}"
    error "Set GEM5_DIR at the top of this script to your gem5 installation."
    exit 1
fi
success "gem5 directory found."

if [[ ! -f "${TARGET_FILE}" ]]; then
    error "BaseO3CPU.py not found: ${TARGET_FILE}"
    exit 1
fi
success "BaseO3CPU.py found."

if ! grep -q "branchPred" "${TARGET_FILE}"; then
    error "Could not find a 'branchPred' line in ${TARGET_FILE}."
    error "The file layout may have changed — inspect it manually."
    exit 1
fi
success "branchPred parameter located in BaseO3CPU.py."

# Detect the current predictor name for the summary.
# The branchPred block is multi-line, e.g.:
#
#   branchPred = Param.BranchPredictor(
#       TournamentBP(numThreads = Parent.numThreads),
#       "Branch Predictor"
#   )
#
# We read the whole file as one string and pull the first word token that
# appears after "Param.BranchPredictor(" (skipping any whitespace/newlines).
CURRENT_PREDICTOR=$(python3 - "${TARGET_FILE}" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'Param\.BranchPredictor\(\s*([A-Za-z0-9_]+)', text)
print(m.group(1) if m else "Unknown")
PYEOF
)
info "Current predictor : ${CURRENT_PREDICTOR}"

# ---------------------------------------------------------------------------
# Step 1 — Edit BaseO3CPU.py
# ---------------------------------------------------------------------------
step "Step 1 — Updating branch predictor in BaseO3CPU.py"

# Create a timestamped backup
BACKUP_FILE="${TARGET_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp "${TARGET_FILE}" "${BACKUP_FILE}"
info "Backup saved to: ${BACKUP_FILE}"

# ── Multi-line replacement via Python ───────────────────────────────────────
#
# The branchPred block can take two forms depending on the predictor:
#
#   FORM A — predictor that accepts numThreads (e.g. TournamentBP):
#       branchPred = Param.BranchPredictor(
#           TournamentBP(numThreads = Parent.numThreads),
#           "Branch Predictor"
#       )
#
#   FORM B — predictor with no constructor args (e.g. BiModeBP, LocalBP):
#       branchPred = Param.BranchPredictor(
#           BiModeBP(),
#           "Branch Predictor"
#       )
#
# The regex below matches the entire inner constructor call — class name plus
# optional parenthesised arguments — and replaces it wholesale so there is
# never a stray comma or mismatched parenthesis.
#
# Predictor classes that accept numThreads:
NEEDS_THREADS="TournamentBP LTAGE TAGE MultiperspectivePerceptron8KB MultiperspectivePerceptron64KB"

python3 - "${TARGET_FILE}" "${NEW_PREDICTOR}" "${NEEDS_THREADS}" <<'PYEOF'
import re, sys

target_file  = sys.argv[1]
new_pred     = sys.argv[2]
needs_threads_list = sys.argv[3].split()

text = open(target_file).read()

# Match the existing inner constructor: SomeName(...) or SomeName()
# sitting between "Param.BranchPredictor(" and the following comma+description.
pattern = re.compile(
    r'(Param\.BranchPredictor\(\s*)'   # group 1 — opening, keep as-is
    r'[A-Za-z0-9_]+'                   # old class name  — discard
    r'\([^)]*\)'                       # old args in ()  — discard
    r'(\s*,\s*"Branch Predictor")',     # group 2 — description, keep as-is
    re.DOTALL
)

if new_pred in needs_threads_list:
    inner = f'{new_pred}(numThreads = Parent.numThreads)'
else:
    inner = f'{new_pred}()'

def replacer(m):
    return m.group(1) + inner + m.group(2)

new_text, n = pattern.subn(replacer, text)

if n == 0:
    print("NOMATCH", flush=True)
    sys.exit(1)

open(target_file, 'w').write(new_text)
print("OK", flush=True)
PYEOF

PY_RESULT=$?
if [[ ${PY_RESULT} -ne 0 ]]; then
    error "Python replacement script failed — the branchPred block format is unexpected."
    error "Check ${TARGET_FILE} manually around the 'branchPred' definition."
    info  "Restoring backup..."
    cp "${BACKUP_FILE}" "${TARGET_FILE}"
    exit 1
fi

# ── Verify the change was applied ───────────────────────────────────────────
APPLIED_PREDICTOR=$(python3 - "${TARGET_FILE}" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'Param\.BranchPredictor\(\s*([A-Za-z0-9_]+)', text)
print(m.group(1) if m else "")
PYEOF
)

if [[ "${APPLIED_PREDICTOR}" != "${NEW_PREDICTOR}" ]]; then
    error "Verification failed: expected '${NEW_PREDICTOR}', found '${APPLIED_PREDICTOR}'."
    info  "Restoring backup..."
    cp "${BACKUP_FILE}" "${TARGET_FILE}"
    exit 1
fi

success "BaseO3CPU.py updated: ${CURRENT_PREDICTOR} → ${NEW_PREDICTOR}"

# Show the updated block for confirmation
echo ""
echo "  Updated branchPred block:"
grep -A 3 "branchPred" "${TARGET_FILE}" | sed 's/^/    /'
echo ""

# ---------------------------------------------------------------------------
# Step 2 — Recompile gem5
# ---------------------------------------------------------------------------
step "Step 2 — Recompiling gem5 (X86, opt, -j${SCONS_JOBS})"
info "This may take several minutes on first build or after major changes."
echo ""

cd "${GEM5_DIR}"

# Run scons; tee output so the user sees progress and we can check for errors
if ! scons build/X86/gem5.opt -j"${SCONS_JOBS}" 2>&1 | tee /tmp/gem5_build.log; then
    error "scons build FAILED. See /tmp/gem5_build.log for details."
    info  "Restoring backup to leave the source tree in a known state..."
    cp "${BACKUP_FILE}" "${TARGET_FILE}"
    exit 1
fi

success "gem5 compiled successfully."

# ---------------------------------------------------------------------------
# Step 3 — Run HelloWorld with O3 CPU + caches
# ---------------------------------------------------------------------------
step "Step 3 — Running HelloWorld test (DerivO3CPU + caches)"

if [[ ! -f "${HELLO_BIN}" ]]; then
    error "HelloWorld binary not found: ${HELLO_BIN}"
    error "Build it with: cd ${GEM5_DIR} && make -C tests/test-progs/hello"
    exit 1
fi

if [[ ! -f "${SE_CONFIG}" ]]; then
    error "SE config script not found: ${SE_CONFIG}"
    exit 1
fi

echo ""
"${GEM5_BIN}" \
    "${SE_CONFIG}" \
    -c "${HELLO_BIN}" \
    --cpu-type=DerivO3CPU \
    --caches \
    2>&1 | tee /tmp/gem5_hello.log

SIM_EXIT=${PIPESTATUS[0]}
if [[ ${SIM_EXIT} -ne 0 ]]; then
    error "gem5 simulation exited with code ${SIM_EXIT}."
    error "See /tmp/gem5_hello.log for details."
    exit 1
fi

success "HelloWorld simulation completed."

# ---------------------------------------------------------------------------
# Step 4 — Verify predictor in config.ini
# ---------------------------------------------------------------------------
step "Step 4 — Verifying predictor in ${CONFIG_INI}"

if [[ ! -f "${CONFIG_INI}" ]]; then
    error "config.ini not found at: ${CONFIG_INI}"
    error "The simulation may not have written output to the expected location."
    exit 1
fi

echo ""
echo "  grep output (branchPred section):"
echo "  ----------------------------------"
grep -A 2 "branchPred" "${CONFIG_INI}" | sed 's/^/  /'
echo ""

# Check that our chosen predictor is actually listed
if grep -q "${NEW_PREDICTOR}" "${CONFIG_INI}"; then
    success "Confirmed: '${NEW_PREDICTOR}' is listed in config.ini ✓"
else
    warn "The string '${NEW_PREDICTOR}' was NOT found in config.ini."
    warn "gem5 sometimes stores the fully-qualified Python path."
    warn "Check the grep output above to confirm the predictor manually."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}============================================================"
echo "  Summary"
echo "============================================================${RESET}"
echo ""
echo -e "  Previous predictor : ${YELLOW}${CURRENT_PREDICTOR}${RESET}"
echo -e "  New predictor      : ${GREEN}${NEW_PREDICTOR}${RESET}"
echo -e "  Backup             : ${BACKUP_FILE}"
echo -e "  Build log          : /tmp/gem5_build.log"
echo -e "  Simulation log     : /tmp/gem5_hello.log"
echo -e "  config.ini         : ${CONFIG_INI}"
echo ""
success "All steps completed successfully."
