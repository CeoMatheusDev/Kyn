#!/usr/bin/env bash
# Validação de ponta a ponta do kync no alvo x86-64 Linux.
#
# Para cada caso positivo: .kyn -> assembly -> as -> ld -> executar -> conferir
# o código de saída (`// expect-exit: N`) e/ou o texto impresso
# (`// expect-stdout: ...`, uma diretiva por linha, comparadas na ordem).
# Para cada caso negativo: `kync check` deve falhar (código 1).
#
# Uso: tools/e2e.sh [caminho-do-kync]
# Requisitos: bash, as (GNU binutils), ld. Sem isso, o script informa e sai com
# código 0 (a suíte unitária `zig build test` continua sendo a validação base).

set -u

KYNC="${1:-./zig-out/bin/kync}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -x "$KYNC" ]; then
    echo "e2e: kync não encontrado/executável em '$KYNC'" >&2
    exit 1
fi

missing=""
for tool in as ld; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    echo "e2e: ferramentas ausentes:$missing — suíte executável ignorada" >&2
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
    echo "  FALHA  $name: $*"
}

# Compila um .kyn para binário e devolve o caminho em $BIN_PATH (ou vazio).
build_binary() {
    local src="$1"
    local name="$2"
    local asm_file="$WORK/$name.s"
    local obj_file="$WORK/$name.o"
    local bin_file="$WORK/$name"

    if ! "$KYNC" emit --asm "$src" -o "$asm_file" 2>"$WORK/$name.err"; then
        echo "  FALHA  $name: emissão de assembly falhou" >&2
        sed 's/^/         /' "$WORK/$name.err" >&2
        return 1
    fi
    if ! as "$asm_file" -o "$obj_file" 2>"$WORK/$name.err"; then
        echo "  FALHA  $name: 'as' rejeitou o assembly" >&2
        sed 's/^/         /' "$WORK/$name.err" >&2
        return 1
    fi
    if ! ld "$obj_file" -o "$bin_file" 2>"$WORK/$name.err"; then
        echo "  FALHA  $name: 'ld' falhou" >&2
        sed 's/^/         /' "$WORK/$name.err" >&2
        return 1
    fi
    echo "$bin_file"
}

# Extrai as linhas de stdout esperadas (`// expect-stdout: ...`) para o arquivo $2.
extract_stdout() {
    sed -n 's|^// expect-stdout: *\(.*\)$|\1|p' "$1" > "$2"
}

# Executa um caso positivo comparando o que foi declarado no cabeçalho:
# `// expect-exit: N` (código de saída) e `// expect-stdout: ...` (texto).
run_positive() {
    local src="$1"
    local name="$2"
    local expected_exit has_stdout=0 bin_file actual ok=1 detail="" report=""

    expected_exit="$(sed -n 's|^// expect-exit: \([0-9]\{1,3\}\).*|\1|p' "$src" | head -1)"
    if grep -q '^// expect-stdout:' "$src"; then has_stdout=1; fi
    total=$((total + 1))

    if [ -z "$expected_exit" ] && [ "$has_stdout" -eq 0 ]; then
        report_fail "$name" "sem cabeçalho '// expect-exit: N' nem '// expect-stdout:'"
        return
    fi

    if ! bin_file="$(build_binary "$src" "$name")"; then
        failed=$((failed + 1))
        return
    fi

    "$bin_file" >"$WORK/$name.stdout"
    actual=$?

    if [ -n "$expected_exit" ]; then
        report="saída=$actual"
        if [ "$actual" -ne "$expected_exit" ]; then
            ok=0
            detail="saída $actual, esperado $expected_exit"
        fi
    fi

    if [ "$has_stdout" -eq 1 ]; then
        extract_stdout "$src" "$WORK/$name.expected"
        report="${report:+$report }stdout=$(wc -l < "$WORK/$name.expected" | tr -d ' ')l"
        if ! diff -u "$WORK/$name.expected" "$WORK/$name.stdout" >"$WORK/$name.diff"; then
            ok=0
            detail="${detail:+$detail; }stdout diferente do esperado"
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

echo "e2e: casos positivos (assembly -> binário -> execução)"

for src in "$ROOT"/tests/e2e/positive/*.kyn; do
    run_positive "$src" "$(basename "$src" .kyn)"
done

echo "e2e: módulos importados (tests/e2e/modules/<caso>/main.kyn -> saída esperada)"

for src in "$ROOT"/tests/e2e/modules/*/main.kyn; do
    [ -e "$src" ] || continue
    run_positive "$src" "mod_$(basename "$(dirname "$src")")"
done

echo "e2e: fixtures de integração (tests/integration/case_N.kyn -> saída N)"

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
        report_fail "$base" "saída $actual, esperado $expected"
    fi
done

echo "e2e: casos negativos (kync check deve falhar)"

for src in "$ROOT"/tests/e2e/negative/*.kyn; do
    name="$(basename "$src" .kyn)"
    total=$((total + 1))

    "$KYNC" check "$src" >"$WORK/$name.out" 2>"$WORK/$name.err"
    code=$?
    if [ "$code" -eq 1 ] && grep -q "erro:" "$WORK/$name.err"; then
        passed=$((passed + 1))
        printf '  ok     %-18s código=%s\n' "$name" "$code"
    else
        report_fail "$name" "código $code (esperado 1) ou mensagem de erro ausente"
        sed 's/^/         /' "$WORK/$name.err"
    fi
done

echo "e2e: módulos negativos (tests/e2e/modules_negative/<caso>/main.kyn deve falhar)"

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
        report_fail "$name" "código $code (esperado 1)"
        sed 's/^/         /' "$WORK/$name.err"
        continue
    fi
    if ! grep -q "erro:" "$WORK/$name.err"; then
        report_fail "$name" "mensagem de erro ausente"
        continue
    fi
    if [ -n "$expected_text" ] && ! grep -qF "$expected_text" "$WORK/$name.err"; then
        report_fail "$name" "mensagem não contém: $expected_text"
        sed 's/^/         /' "$WORK/$name.err"
        continue
    fi

    passed=$((passed + 1))
    printf '  ok     %-18s código=%s\n' "$name" "$code"
done

echo
echo "e2e: $passed/$total casos passaram, $failed falharam"

[ "$failed" -eq 0 ] || exit 1
exit 0
