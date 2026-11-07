#!/usr/bin/env bash
# Valida o LLVM IR emitido pelo kync com uma ferramenta LLVM real.
#
# Motivação: os testes unitários de `src/codegen/llvm.zig` verificam apenas a
# estrutura do IR (blocos terminados, tipos, instruções). Este script fecha a
# lacuna rodando o verificador do LLVM sobre o IR de todas as fixtures que o
# compilador aceita hoje.
#
# Uso: tools/validate-ir.sh [caminho-do-kync]
#
# Ferramentas procuradas, nesta ordem:
#   1. llvm-as (llvm-as, llvm-as-NN ou /usr/lib/llvm-NN/bin/llvm-as)
#   2. clang  (clang, clang-NN) usando `-x ir -c`
# Se nenhuma existir, o script avisa e sai com código 0 (skip), para não
# quebrar ambientes sem LLVM. Em CI a ferramenta é instalada e a validação roda.

set -u

KYNC="${1:-./zig-out/bin/kync}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -x "$KYNC" ]; then
    echo "validate-ir: kync não encontrado/executável em '$KYNC'" >&2
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

# 1) llvm-as no PATH e com sufixo de versão.
for candidate in llvm-as llvm-as-21 llvm-as-20 llvm-as-19 llvm-as-18 llvm-as-17 llvm-as-16 llvm-as-15 llvm-as-14; do
    if found="$(find_tool "$candidate")"; then
        VALIDATOR="$found"
        VALIDATOR_KIND="llvm-as"
        break
    fi
done

# 2) llvm-as em /usr/lib/llvm-*/bin (instalação Debian/Ubuntu sem PATH).
if [ -z "$VALIDATOR" ]; then
    for path in /usr/lib/llvm-*/bin/llvm-as /usr/local/opt/llvm/bin/llvm-as; do
        if [ -x "$path" ]; then
            VALIDATOR="$path"
            VALIDATOR_KIND="llvm-as"
            break
        fi
    done
fi

# 3) clang como alternativa.
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
    echo "validate-ir: nenhum llvm-as/clang encontrado — validação de IR ignorada" >&2
    echo "validate-ir: instale LLVM (ex.: 'apt-get install llvm' ou 'apt-get install clang') para validar" >&2
    exit 0
fi

echo "validate-ir: usando $VALIDATOR ($VALIDATOR_KIND)"

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
        echo "  FALHA  $name: emissão de IR falhou"
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
        echo "  FALHA  $name: $VALIDATOR_KIND rejeitou o IR"
        sed 's/^/         /' "$log"
    fi
}

echo "validate-ir: fixtures comportamentais (tests/e2e/positive)"
for src in "$ROOT"/tests/e2e/positive/*.kyn; do
    validate_one "$src" "$(basename "$src" .kyn)"
done

echo "validate-ir: fixtures de integração (tests/integration/case_N.kyn)"
for src in "$ROOT"/tests/integration/case_*.kyn; do
    validate_one "$src" "$(basename "$src" .kyn)"
done

echo
echo "validate-ir: $passed/$total módulos aceitos pelo verificador LLVM, $failed rejeitados"

[ "$failed" -eq 0 ] || exit 1
exit 0
