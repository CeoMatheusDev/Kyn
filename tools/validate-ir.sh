#!/usr/bin/env bash
# Validates the LLVM IR emitted by kync with a real LLVM tool.
#
# Motivation: the unit tests in `src/codegen/llvm.zig` only check the IR
# structure (terminated blocks, types, instructions). This script closes the
# gap by running the LLVM verifier over the IR of every fixture the compiler
# accepts today.
#
# Usage: tools/validate-ir.sh [path-to-kync] [--require-tool]
#
#   --require-tool  fails (code 1) when no LLVM tool exists, instead of
#                   warning and skipping. Used by CI so that a missing
#                   verifier never passes silently.
#
# Tools looked up, in this order:
#   1. llvm-as (llvm-as, llvm-as-NN or /usr/lib/llvm-NN/bin/llvm-as)
#   2. clang  (clang, clang-NN) using `-x ir -c`
# If none exists the script warns and exits with code 0 (skip), so it does not
# break environments without LLVM. CI installs the tool and runs the validation.

set -u

KYNC="./zig-out/bin/kync"
REQUIRE_TOOL=0
for arg in "$@"; do
    case "$arg" in
        --require-tool) REQUIRE_TOOL=1 ;;
        -*) echo "validate-ir: unknown option '$arg'" >&2; exit 2 ;;
        *) KYNC="$arg" ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -x "$KYNC" ]; then
    echo "validate-ir: kync not found/executable at '$KYNC'" >&2
    exit 1
fi

VALIDATOR=""
VALIDATOR_KIND=""

find_tool() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    return 1
}

# 1) llvm-as on PATH and with a version suffix.
for candidate in llvm-as llvm-as-21 llvm-as-20 llvm-as-19 llvm-as-18 llvm-as-17 llvm-as-16 llvm-as-15 llvm-as-14; do
    if found="$(find_tool "$candidate")"; then
        VALIDATOR="$found"
        VALIDATOR_KIND="llvm-as"
        break
    fi
done

# 2) llvm-as in /usr/lib/llvm-*/bin (Debian/Ubuntu install without PATH).
if [ -z "$VALIDATOR" ]; then
    for path in /usr/lib/llvm-*/bin/llvm-as /usr/local/opt/llvm/bin/llvm-as; do
        if [ -x "$path" ]; then
            VALIDATOR="$path"
            VALIDATOR_KIND="llvm-as"
            break
        fi
    done
fi

# 3) clang as an alternative.
if [ -z "$VALIDATOR" ]; then
    for candidate in clang clang-21 clang-20 clang-19 clang-18 clang-17 clang-16 clang-15 clang-14; do
        if found="$(find_tool "$candidate")"; then
            VALIDATOR="$found"
            VALIDATOR_KIND="clang"
            break
        fi
    done
fi

if [ -z "$VALIDATOR" ]; then
    if [ "$REQUIRE_TOOL" -eq 1 ]; then
        echo "validate-ir: ERROR — no LLVM tool found and --require-tool was passed" >&2
        echo "validate-ir: install 'llvm' or 'clang' to validate the IR" >&2
        exit 1
    fi
    echo "validate-ir: no llvm-as/clang found — IR validation skipped" >&2
    echo "validate-ir: install LLVM (e.g. 'apt-get install llvm' or 'apt-get install clang') to validate" >&2
    exit 0
fi

echo "validate-ir: using $VALIDATOR ($VALIDATOR_KIND)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

total=0
passed=0
failed=0

validate_one() {
    local src="$1"
    local name="$2"
    local ir="$WORK/$name.ll"
    local log="$WORK/$name.log"

    total=$((total + 1))

    if ! "$KYNC" emit --llvm "$src" -o "$ir" 2>"$log"; then
        failed=$((failed + 1))
        echo "  FAIL   $name: IR emission failed"
        sed 's/^/         /' "$log"
        return
    fi

    local ok=1
    case "$VALIDATOR_KIND" in
        llvm-as)
            "$VALIDATOR" "$ir" -o /dev/null 2>"$log" || ok=0
            ;;
        clang)
            "$VALIDATOR" -Wno-override-module -x ir -c "$ir" -o /dev/null 2>"$log" || ok=0
            ;;
    esac

    if [ "$ok" -eq 1 ]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        echo "  FAIL   $name: $VALIDATOR_KIND rejected the IR"
        sed 's/^/         /' "$log"
    fi
}

echo "validate-ir: behavioral fixtures (tests/e2e/positive)"
for src in "$ROOT"/tests/e2e/positive/*.kyn; do
    validate_one "$src" "$(basename "$src" .kyn)"
done

echo "validate-ir: integration fixtures (tests/integration/case_N.kyn)"
for src in "$ROOT"/tests/integration/case_*.kyn; do
    validate_one "$src" "$(basename "$src" .kyn)"
done

echo "validate-ir: imported modules (tests/e2e/modules/<case>/main.kyn)"
for src in "$ROOT"/tests/e2e/modules/*/main.kyn; do
    [ -e "$src" ] || continue
    validate_one "$src" "mod_$(basename "$(dirname "$src")")"
done

echo
echo "validate-ir: $passed/$total modules accepted by the LLVM verifier, $failed rejected"

[ "$failed" -eq 0 ] || exit 1
exit 0
