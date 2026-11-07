#!/usr/bin/env bash
# Validação de ponta a ponta do kync no alvo x86-64 Linux.
#
# Para cada caso positivo: .kyn -> assembly -> as -> ld -> executar -> conferir
# o código de saída. Para cada caso negativo: `kync check` deve falhar (código 1).
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

echo "e2e: casos positivos (assembly -> binário -> execução)"

for src in "$ROOT"/tests/e2e/positive/*.kyn; do
    name="$(basename "$src" .kyn)"
    expected="$(sed -n 's/^\/\/ expect-exit: \([0-9]\{1,3\}\).*/\1/p' "$src" | head -1)"
    total=$((total + 1))

    if [ -z "$expected" ]; then
        report_fail "$name" "sem cabeçalho '// expect-exit: N'"
        continue
    fi

    bin_file="$(build_binary "$src" "$name")" || { failed=$((failed + 1)); continue; }

    "$bin_file"
    actual=$?
    if [ "$actual" -eq "$expected" ]; then
        passed=$((passed + 1))
        printf '  ok     %-18s saída=%s\n' "$name" "$actual"
    else
        report_fail "$name" "saída $actual, esperado $expected"
    fi
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

echo
echo "e2e: $passed/$total casos passaram, $failed falharam"

[ "$failed" -eq 0 ] || exit 1
exit 0
