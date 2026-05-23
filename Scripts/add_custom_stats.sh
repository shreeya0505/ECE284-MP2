#!/usr/bin/env bash
# =============================================================================
# add_custom_stats.sh
#
# Automates Part 3 of ECE 284 Project 2:
#   1. Modify bpred_unit.hh  — declare BTBMissPct & BranchMispredPercent
#   2. Modify bpred_unit.cc  — register ADD_STAT entries + set precision
#   3. Recompile gem5 (with OOM-safe swap auto-creation)
#   4. Run HelloWorld with DerivO3CPU
#   5. Verify new metrics appear in m5out/stats.txt
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GEM5_DIR="${HOME}/gem5"
PRED_DIR="${GEM5_DIR}/src/cpu/pred"
HH_FILE="${PRED_DIR}/bpred_unit.hh"
CC_FILE="${PRED_DIR}/bpred_unit.cc"
GEM5_BIN="${GEM5_DIR}/build/X86/gem5.opt"
SE_CONFIG="${GEM5_DIR}/configs/deprecated/example/se.py"
HELLO_BIN="${GEM5_DIR}/tests/test-progs/hello/bin/x86/linux/hello"
STATS_TXT="${GEM5_DIR}/m5out/stats.txt"
SWAP_FILE="/swapfile"
SWAP_SIZE="8G"

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

echo -e "${BOLD}"
echo "============================================================"
echo "  gem5 Part 3 — Add Custom Branch Predictor Statistics"
echo "  BTBMissPct  &  BranchMispredPercent"
echo "============================================================"
echo -e "${RESET}"

# ---------------------------------------------------------------------------
# Step 0 — Pre-flight checks
# ---------------------------------------------------------------------------
step "Step 0 — Pre-flight checks"

[[ -d "${GEM5_DIR}" ]]  || { error "gem5 dir not found: ${GEM5_DIR}"; exit 1; }
[[ -f "${HH_FILE}" ]]   || { error "bpred_unit.hh not found: ${HH_FILE}"; exit 1; }
[[ -f "${CC_FILE}" ]]   || { error "bpred_unit.cc not found: ${CC_FILE}"; exit 1; }
success "Source files found."

# Guard: skip if already patched (idempotent re-run)
if grep -q "BTBMissPct" "${HH_FILE}"; then
    warn "bpred_unit.hh already contains BTBMissPct — skipping source edits."
    warn "If you want to re-apply, restore backups first."
    SKIP_EDIT=true
else
    SKIP_EDIT=false
fi

# Memory / swap check
TOTAL_MEM_GB=$(awk '/MemTotal/  {printf "%d", $2/1024/1024}' /proc/meminfo)
TOTAL_SWP_GB=$(awk '/SwapTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
TOTAL_AVAIL=$(( TOTAL_MEM_GB + TOTAL_SWP_GB ))
info "RAM: ${TOTAL_MEM_GB}GB  Swap: ${TOTAL_SWP_GB}GB  Total: ${TOTAL_AVAIL}GB"
SWAP_CREATED=false
if [[ ${TOTAL_AVAIL} -lt 6 ]]; then
    warn "Total memory < 6GB — auto-creating ${SWAP_SIZE} swap at ${SWAP_FILE}"
    if [[ ! -f "${SWAP_FILE}" ]]; then
        sudo fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}" 2>/dev/null \
            || sudo dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=8192 status=progress
        sudo chmod 600 "${SWAP_FILE}"
        sudo mkswap "${SWAP_FILE}"
    fi
    sudo swapon "${SWAP_FILE}" 2>/dev/null || true
    success "Swap activated. $(awk '/SwapTotal/{printf "%dGB", $2/1024/1024}' /proc/meminfo) available."
    SWAP_CREATED=true
fi

# Decide compile parallelism
AVAIL_MEM_GB=$(awk '/MemAvailable/{printf "%d", $2/1024/1024}' /proc/meminfo)
[[ ${AVAIL_MEM_GB} -lt 4 ]] && SCONS_JOBS=1 || SCONS_JOBS=$(nproc)
info "Compile threads: -j${SCONS_JOBS}"

# ---------------------------------------------------------------------------
# Step 1 — Modify bpred_unit.hh
# ---------------------------------------------------------------------------
step "Step 1 — Patching bpred_unit.hh (declare new Formula members)"

if [[ "${SKIP_EDIT}" == "false" ]]; then
    BACKUP_HH="${HH_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "${HH_FILE}" "${BACKUP_HH}"
    info "Backup: ${BACKUP_HH}"

    # Verify the anchor exists
    if ! grep -q "BTBHitRatio" "${HH_FILE}"; then
        error "Cannot find 'BTBHitRatio' in ${HH_FILE}."
        error "The struct layout may differ — check manually."
        exit 1
    fi

    # Insert the two new declarations immediately after the BTBHitRatio declaration line.
    # We use Python for reliable multi-line insertion (no sed portability issues).
    python3 - "${HH_FILE}" <<'PYEOF'
import sys, re

path = sys.argv[1]
text = open(path).read()

# Match the full line that declares BTBHitRatio (captures leading whitespace)
pattern = re.compile(
    r'([ \t]*statistics::Formula\s+BTBHitRatio\s*;[ \t]*\n)'
)

insertion = (
    "\n"
    "        /** Stat for the percentage of BTB misses. */\n"
    "        statistics::Formula BTBMissPct;\n"
    "        /** Stat for the percentage of branch mispredictions. */\n"
    "        statistics::Formula BranchMispredPercent;\n"
)

new_text, n = pattern.subn(r'\1' + insertion, text)
if n == 0:
    print("ERROR: BTBHitRatio declaration line not found — check struct layout.")
    sys.exit(1)

open(path, 'w').write(new_text)
print(f"Inserted 2 Formula declarations after BTBHitRatio ({n} substitution).")
PYEOF

    success "bpred_unit.hh patched."
    echo ""
    echo "  Inserted block (context):"
    grep -A 5 "BTBHitRatio" "${HH_FILE}" | head -10 | sed 's/^/    /'
    echo ""
fi

# ---------------------------------------------------------------------------
# Step 2 — Modify bpred_unit.cc
# ---------------------------------------------------------------------------
step "Step 2 — Patching bpred_unit.cc (ADD_STAT entries + precision)"

if [[ "${SKIP_EDIT}" == "false" ]]; then
    BACKUP_CC="${CC_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "${CC_FILE}" "${BACKUP_CC}"
    info "Backup: ${BACKUP_CC}"

    # ── 2a: Insert ADD_STAT entries after the BTBHitRatio ADD_STAT ──────────
    #
    # The existing initializer list looks like (simplified):
    #
    #   ADD_STAT(BTBHitRatio, ..., BTBHits / BTBLookups),
    #   ...
    # We find the ADD_STAT(BTBHitRatio, ...) entry (which may span multiple
    # lines) and append our two new entries after it.
    #
    # Strategy: locate the closing ")," of the BTBHitRatio ADD_STAT and insert
    # after that line.

    python3 - "${CC_FILE}" <<'PYEOF'
import sys, re

path = sys.argv[1]
text = open(path).read()

# ── Guard: already patched? ──────────────────────────────────────────────
if 'BTBMissPct' in text:
    print("Already patched — skipping ADD_STAT insertion.")
    sys.exit(0)

# ── Find the ADD_STAT(BTBHitRatio ...) block ─────────────────────────────
# It starts with ADD_STAT(BTBHitRatio and ends with its closing "),"
# which may be on a later line.  We find the character-level span.
start = text.find('ADD_STAT(BTBHitRatio')
if start == -1:
    print("ERROR: ADD_STAT(BTBHitRatio not found in bpred_unit.cc")
    sys.exit(1)

# Walk forward to find the matching closing "),"
depth = 0
i = start
in_stat = False
end = -1
while i < len(text):
    ch = text[i]
    if ch == '(':
        depth += 1
        in_stat = True
    elif ch == ')':
        depth -= 1
        if in_stat and depth == 0:
            # closing ')' of ADD_STAT found; look for the trailing comma
            j = i + 1
            while j < len(text) and text[j] in (' ', '\t'):
                j += 1
            if j < len(text) and text[j] == ',':
                end = j  # points at the comma
            else:
                end = i  # no trailing comma (last entry) — insert after ')'
            break
    i += 1

if end == -1:
    print("ERROR: could not locate end of ADD_STAT(BTBHitRatio ...) block")
    sys.exit(1)

# Find the end of that line (after the comma/paren)
line_end = text.find('\n', end)
if line_end == -1:
    line_end = len(text)

insertion = (
    "\n"
    "    ADD_STAT(BTBMissPct, statistics::units::Ratio::get(),\n"
    '             "BTB Miss Percentage",\n'
    "             (1 - (BTBHits / BTBLookups)) * 100),\n"
    "    ADD_STAT(BranchMispredPercent, statistics::units::Ratio::get(),\n"
    '             "Percent of Branch Mispredict",\n'
    "             (condIncorrect / lookups) * 100)"
)

# Check whether the BTBHitRatio entry has a trailing comma (i.e. more entries follow).
# If it does, our new block must also end with a comma before those entries.
# We search for what comes after our insertion point.
after_block = text[line_end+1:line_end+200].lstrip()
if after_block.startswith('{'):
    # The next thing is the precision block — we are the last entry, no trailing comma
    insertion += "\n"
else:
    insertion += ",\n"

new_text = text[:line_end+1] + insertion + text[line_end+1:]
open(path, 'w').write(new_text)
print("ADD_STAT entries inserted after BTBHitRatio.")
PYEOF

    # ── 2b: Add precision calls inside the { } block ────────────────────────
    python3 - "${CC_FILE}" <<'PYEOF'
import sys, re

path = sys.argv[1]
text = open(path).read()

if 'BTBMissPct.precision' in text:
    print("Precision calls already present — skipping.")
    sys.exit(0)

# Find the precision block: look for "BTBHitRatio.precision"
anchor = 'BTBHitRatio.precision'
pos = text.find(anchor)
if pos == -1:
    print("ERROR: 'BTBHitRatio.precision' not found — cannot insert precision calls.")
    sys.exit(1)

# Find the end of that statement (the semicolon + newline)
semi = text.find(';', pos)
if semi == -1:
    print("ERROR: semicolon after BTBHitRatio.precision not found.")
    sys.exit(1)
line_end = text.find('\n', semi)
if line_end == -1:
    line_end = len(text)

# Detect indentation from the anchor line
line_start = text.rfind('\n', 0, pos) + 1
indent = ''
for ch in text[line_start:]:
    if ch in (' ', '\t'):
        indent += ch
    else:
        break

insertion = (
    f"\n{indent}BTBMissPct.precision(6);"
    f"\n{indent}BranchMispredPercent.precision(6);"
)

new_text = text[:line_end] + insertion + text[line_end:]
open(path, 'w').write(new_text)
print("Precision calls inserted after BTBHitRatio.precision(6).")
PYEOF

    success "bpred_unit.cc patched."
    echo ""
    echo "  ADD_STAT context:"
    grep -A 3 "BTBMissPct" "${CC_FILE}" | head -15 | sed 's/^/    /'
    echo ""
    echo "  Precision block context:"
    grep -A 4 "BTBHitRatio.precision" "${CC_FILE}" | sed 's/^/    /'
    echo ""
fi

# ---------------------------------------------------------------------------
# Step 3 — Recompile gem5
# ---------------------------------------------------------------------------
step "Step 3 — Recompiling gem5 (X86 opt, -j${SCONS_JOBS})"
info "This may take 1–2 hours on low-memory machines with -j1."
echo ""

cd "${GEM5_DIR}"
if ! scons build/X86/gem5.opt -j"${SCONS_JOBS}" 2>&1 | tee /tmp/gem5_build_part3.log; then
    error "scons build FAILED. See /tmp/gem5_build_part3.log"
    info  "Restoring source backups..."
    [[ -f "${BACKUP_HH:-}" ]] && cp "${BACKUP_HH}" "${HH_FILE}" && info "Restored ${HH_FILE}"
    [[ -f "${BACKUP_CC:-}" ]] && cp "${BACKUP_CC}" "${CC_FILE}" && info "Restored ${CC_FILE}"
    exit 1
fi
success "gem5 compiled successfully."

# ---------------------------------------------------------------------------
# Step 4 — Run HelloWorld
# ---------------------------------------------------------------------------
step "Step 4 — Running HelloWorld (DerivO3CPU + caches)"

[[ -f "${HELLO_BIN}" ]] || { error "HelloWorld binary not found: ${HELLO_BIN}"; exit 1; }
[[ -f "${SE_CONFIG}"  ]] || { error "se.py not found: ${SE_CONFIG}"; exit 1; }

echo ""
"${GEM5_BIN}" \
    "${SE_CONFIG}" \
    -c "${HELLO_BIN}" \
    --cpu-type=DerivO3CPU \
    --caches \
    2>&1 | tee /tmp/gem5_hello_part3.log

SIM_RC=${PIPESTATUS[0]}
if [[ ${SIM_RC} -ne 0 ]]; then
    error "gem5 simulation exited with code ${SIM_RC}. See /tmp/gem5_hello_part3.log"
    exit 1
fi
success "HelloWorld simulation completed."

# ---------------------------------------------------------------------------
# Step 5 — Verify new metrics in stats.txt
# ---------------------------------------------------------------------------
step "Step 5 — Verifying new metrics in stats.txt"

[[ -f "${STATS_TXT}" ]] || { error "stats.txt not found: ${STATS_TXT}"; exit 1; }

echo ""
echo "  grep \"Percent\\|Pct\" output:"
echo "  ─────────────────────────────────────────"
grep "Percent\|Pct" "${STATS_TXT}" | sed 's/^/  /' || true
echo ""

FOUND_BTB=$(grep -c "BTBMissPct"          "${STATS_TXT}" || true)
FOUND_MIS=$(grep -c "BranchMispredPercent" "${STATS_TXT}" || true)

if [[ ${FOUND_BTB} -gt 0 && ${FOUND_MIS} -gt 0 ]]; then
    success "Both BTBMissPct and BranchMispredPercent found in stats.txt ✓"
elif [[ ${FOUND_BTB} -gt 0 ]]; then
    warn "BTBMissPct found but BranchMispredPercent is missing."
elif [[ ${FOUND_MIS} -gt 0 ]]; then
    warn "BranchMispredPercent found but BTBMissPct is missing."
else
    error "Neither metric found in stats.txt."
    error "Check /tmp/gem5_build_part3.log and /tmp/gem5_hello_part3.log for clues."
    exit 1
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}============================================================"
echo "  Summary"
echo "============================================================${RESET}"
echo ""
echo -e "  bpred_unit.hh backup : ${BACKUP_HH:-'(skipped — already patched)'}"
echo -e "  bpred_unit.cc backup : ${BACKUP_CC:-'(skipped — already patched)'}"
echo -e "  Build log            : /tmp/gem5_build_part3.log"
echo -e "  Simulation log       : /tmp/gem5_hello_part3.log"
echo -e "  stats.txt            : ${STATS_TXT}"
echo ""
success "Part 3 complete."

if [[ "${SWAP_CREATED}" == "true" ]]; then
    echo ""
    warn "Temporary swap file is still active: ${SWAP_FILE}"
    warn "Run the following to free disk space when no longer needed:"
    warn "  sudo swapoff ${SWAP_FILE} && sudo rm ${SWAP_FILE}"
fi
