#!/usr/bin/env bash
# End-to-end validation of kync on the x86-64 Linux target.
#
# For each positive case: .kyn -> assembly -> as -> ld -> run -> check
# the exit code (`// expect-exit: N`) and/or the printed text
# (`// expect-stdout: ...`, one directive per line, compared in order).
# For each negative case: `kync check` must fail (code 1).
#
# Usage: tools/e2e.sh [path-to-kync]
# Requirements: bash, as (GNU binutils), ld. Without them the script reports it
# and exits with code 0 (the `zig build test` unit suite remains the base validation).

set -u

KYNC="${1:-./zig-out/bin/kync}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -x "$KYNC" ]; then
    echo "e2e: kync not found/executable at '$KYNC'" >&2
    exit 1
fi

missing=""
for tool in as ld; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    echo "e2e: missing tools:$missing — executable suite skipped" >&2
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

total=0
passed=0
failed=0

report_fail() {
    local name="$1"
    shift
    failed=$((failed + 1))
    echo "  FAIL   $name: $*"
}

# Compiles a .kyn into a binary and returns the path in $BIN_PATH (or empty).
build_binary() {
    local src="$1"
    local name="$2"
    local asm_file="$WORK/$name.s"
    local obj_file="$WORK/$name.o"
    local bin_file="$WORK/$name"

    if ! "$KYNC" emit --asm "$src" -o "$asm_file" 2>"$WORK/$name.err"; then
        echo "  FAIL   $name: assembly emission failed" >&2
        sed 's/^/         /' "$WORK/$name.err" >&2
        return 1
    fi
    if ! as "$asm_file" -o "$obj_file" 2>"$WORK/$name.err"; then
        echo "  FAIL   $name: 'as' rejected the assembly" >&2
        sed 's/^/         /' "$WORK/$name.err" >&2
        return 1
    fi
    if ! ld "$obj_file" -o "$bin_file" 2>"$WORK/$name.err"; then
        echo "  FAIL   $name: 'ld' failed" >&2
        sed 's/^/         /' "$WORK/$name.err" >&2
        return 1
    fi
    echo "$bin_file"
}

# Extracts the expected stdout lines (`// expect-stdout: ...`) into file $2.
extract_stdout() {
    sed -n 's|^// expect-stdout: *\(.*\)$|\1|p' "$1" > "$2"
}

# Runs a positive case comparing what the header declared:
# `// expect-exit: N` (exit code) and `// expect-stdout: ...` (text).
run_positive() {
    local src="$1"
    local name="$2"
    local expected_exit has_stdout=0 bin_file actual ok=1 detail="" report=""

    expected_exit="$(sed -n 's|^// expect-exit: \([0-9]\{1,3\}\).*|\1|p' "$src" | head -1)"
    if grep -q '^// expect-stdout:' "$src"; then has_stdout=1; fi
    total=$((total + 1))

    if [ -z "$expected_exit" ] && [ "$has_stdout" -eq 0 ]; then
        report_fail "$name" "no '// expect-exit: N' header nor '// expect-stdout:'"
        return
    fi

    if ! bin_file="$(build_binary "$src" "$name")"; then
        failed=$((failed + 1))
        return
    fi

    "$bin_file" >"$WORK/$name.stdout"
    actual=$?

    if [ -n "$expected_exit" ]; then
        report="exit=$actual"
        if [ "$actual" -ne "$expected_exit" ]; then
            ok=0
            detail="exit $actual, expected $expected_exit"
        fi
    fi

    if [ "$has_stdout" -eq 1 ]; then
        extract_stdout "$src" "$WORK/$name.expected"
        report="${report:+$report }stdout=$(wc -l < "$WORK/$name.expected" | tr -d ' ')l"
        if ! diff -u "$WORK/$name.expected" "$WORK/$name.stdout" >"$WORK/$name.diff"; then
            ok=0
            detail="${detail:+$detail; }stdout differs from expected"
        fi
    fi

    if [ "$ok" -eq 1 ]; then
        passed=$((passed + 1))
        printf '  ok     %-18s %s\n' "$name" "$report"
    else
        report_fail "$name" "$detail"
        [ -f "$WORK/$name.diff" ] && head -12 "$WORK/$name.diff" | sed 's/^/         /'
    fi
}

echo "e2e: positive cases (assembly -> binary -> execution)"

for src in "$ROOT"/tests/e2e/positive/*.kyn; do
    run_positive "$src" "$(basename "$src" .kyn)"
done

echo "e2e: imported modules (tests/e2e/modules/<case>/main.kyn -> expected output)"

for src in "$ROOT"/tests/e2e/modules/*/main.kyn; do
    [ -e "$src" ] || continue
    run_positive "$src" "mod_$(basename "$(dirname "$src")")"
done

echo "e2e: integration fixtures (tests/integration/case_N.kyn -> exit N)"

for src in "$ROOT"/tests/integration/case_*.kyn; do
    base="$(basename "$src" .kyn)"
    expected="${base#case_}"
    total=$((total + 1))

    bin_file="$(build_binary "$src" "$base")" || { failed=$((failed + 1)); continue; }

    "$bin_file"
    actual=$?
    if [ "$actual" -eq "$expected" ]; then
        passed=$((passed + 1))
    else
        report_fail "$base" "exit $actual, expected $expected"
    fi
done

echo "e2e: negative cases (kync check must fail)"

for src in "$ROOT"/tests/e2e/negative/*.kyn; do
    name="$(basename "$src" .kyn)"
    total=$((total + 1))

    "$KYNC" check "$src" >"$WORK/$name.out" 2>"$WORK/$name.err"
    code=$?
    if [ "$code" -eq 1 ] && grep -q "error:" "$WORK/$name.err"; then
        passed=$((passed + 1))
        printf '  ok     %-18s code=%s\n' "$name" "$code"
    else
        report_fail "$name" "code $code (expected 1) or missing error message"
        sed 's/^/         /' "$WORK/$name.err"
    fi
done

echo "e2e: negative modules (tests/e2e/modules_negative/<case>/main.kyn must fail)"

for src in "$ROOT"/tests/e2e/modules_negative/*/main.kyn; do
    [ -e "$src" ] || continue
    name="mod_$(basename "$(dirname "$src")")"
    dir="$(dirname "$src")"
    total=$((total + 1))

    "$KYNC" check "$src" >"$WORK/$name.out" 2>"$WORK/$name.err"
    code=$?
    expected_text=""
    if [ -f "$dir/expect-error.txt" ]; then
        expected_text="$(cat "$dir/expect-error.txt")"
    fi

    if [ "$code" -ne 1 ]; then
        report_fail "$name" "code $code (expected 1)"
        sed 's/^/         /' "$WORK/$name.err"
        continue
    fi
    if ! grep -q "error:" "$WORK/$name.err"; then
        report_fail "$name" "missing error message"
        continue
    fi
    if [ -n "$expected_text" ] && ! grep -qF "$expected_text" "$WORK/$name.err"; then
        report_fail "$name" "message does not contain: $expected_text"
        sed 's/^/         /' "$WORK/$name.err"
        continue
    fi

    passed=$((passed + 1))
    printf '  ok     %-18s code=%s\n' "$name" "$code"
done

echo
echo "e2e: $passed/$total cases passed, $failed failed"

[ "$failed" -eq 0 ] || exit 1
exit 0
