#!/usr/bin/env bash
#
# tan.sh – тот же каркас, но задача, которую не жалко
#
# Оригинал (разобран в test.sh) делал ровно то же: собирал изолированное
# окружение в ./test, рассылал симлинки на апплеты busybox, проверял
# копии и запускал сценарий через exec. Отличаются содержание сценария
# и количество копируемого мусора.
#
#   ./tan.sh        # tan(30°) = 0.58
#   ./tan.sh 45     # tan(45°) = 1.00
#   ./tan.sh 30 4   # tan(30°) = 0.5774
#
# Побочный эффект – ./test примерно на 3 МБ. Удаляется в любой момент:
# rm -rf ./test

set -euo pipefail

# --- что копируем ------------------------------------------------------
# В оригинале список был такой: xargs, dd, busybox, find, poweroff.
# Для подсчёта тангенса хватает bash и busybox, из апплетов которого
# нужен один awk. Остальное копировалось, проверялось и не
# использовалось – вместе с systemctl и его libsystemd на 6.5 МБ.

readonly BINARIES=( busybox )

# Апплеты, которые имеет смысл запустить в смоук-тесте. У всех
# апплетов общего безопасного вызова нет – у mount и reboot его не
# бывает по определению, поэтому список закрытый.
readonly BUSYBOX_APPLETS='awk printf pwd'

readonly ANGLE="${1:-30}"
readonly PRECISION="${2:-2}"

# --- проверяем вход до того, как что-либо создано на диске ---------------

[[ "$ANGLE" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || {
    printf 'Угол должен быть числом. Получено: %s\n' "$ANGLE" >&2; exit 2; }

[[ "$PRECISION" =~ ^[0-9]+$ ]] && (( PRECISION >= 1 && PRECISION <= 15 )) || {
    printf 'Точность – целое число от 1 до 15. Получено: %s\n' "$PRECISION" >&2; exit 2; }

# При 90 + 180k касательной нет. Ловим заранее, а не делением на ноль.
if awk -v d="$ANGLE" 'BEGIN { r = d % 180; if (r < 0) r += 180
                             exit (r > 89.999999 && r < 90.000001) ? 0 : 1 }'; then
    printf 'tan(%s°) не определён – cos угла равен нулю\n' "$ANGLE" >&2
    exit 2
fi

# --- сценарий ----------------------------------------------------------
# Выполняется прямо в $PWD, откуда запущен скрипт, и видит только
# ./test/bin в PATH. Так что всё, что вызывается – либо встроенная
# команда bash, либо апплет busybox. Ничего из системы случайно не
# подтянется.
#
# Считаем через sin/cos, а не через tan: в некоторых сборках awk
# функции tan() просто нет, а sin и cos есть везде.

readonly SCENARIO=$(cat <<'SCENARIO_EOF'
set -euo pipefail

# В ru_* десятичный разделитель – запятая, и напечаталось бы 0,58.
export LC_ALL=C

angle="${1:?угол не передан}"
precision="${2:-2}"

value="$(awk -v deg="$angle" '
    BEGIN {
        pi  = atan2(0, -1)
        rad = deg * pi / 180
        printf "%.12f", sin(rad) / cos(rad)
    }
')"

printf "tan(%s°) = %.*f\n" "$angle" "$precision" "$value"
SCENARIO_EOF
)

# --- собираем окружение -------------------------------------------------

readonly SRC_BASH="$(readlink -f "$BASH")"
readonly DEST_DIR="${TAN_ENV_DIR:-$PWD/test}"
readonly BIN_DIR="$DEST_DIR/bin"
readonly LIBS_DIR="$DEST_DIR/libs"
readonly MANIFEST="$DEST_DIR/manifest.txt"

printf 'Окружение: %s\n' "$DEST_DIR"

# В оригинале здесь стоял голый `rm -rf "$DEST_DIR"`, где DEST_DIR="$PWD/test"
# – то есть скрипт сносил каталог с именем test, не глядя, что внутри.
# Теперь перед удалением проверяем, что цель не система и не $HOME
# и что она действительно лежит внутри текущего каталога.

prepare_dest_dir() {
    local target; target="$(readlink -f "$DEST_DIR" 2>/dev/null || printf '%s' "$DEST_DIR")"

    case "$target" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|"$HOME"|/srv|/sys|/tmp|/usr|/var)
            printf 'Не трогаю системный каталог: %s\n' "$target" >&2
            exit 1 ;;
    esac

    if [[ "$PWD" != "$target" && "$target" != "$PWD/"* ]]; then
        printf '%s лежит вне %s – не трогаю\n' "$target" "$PWD" >&2
        exit 1
    fi

    rm -rf -- "$target"
    mkdir -p -- "$BIN_DIR" "$LIBS_DIR"
    : > "$MANIFEST"
}

prepare_dest_dir

declare -A SEEN
PROBE_BINS=()

copy_bin() {
    local src="$1" dst lib libdst
    src="$(readlink -f "$src")"
    dst="$BIN_DIR/$(basename "$src")"

    if [ -n "${SEEN[$dst]:-}" ]; then
        printf 'Уже скопирован, пропускаю: %s\n' "$src"
        return
    fi
    SEEN[$dst]=1

    cp -Lv "$src" "$dst"
    PROBE_BINS+=("$dst")
    printf '%s %s\n' "$src" "$dst" >> "$MANIFEST"

    # Рядом с бинарём тащим его библиотеки – иначе в изолированном
    # окружении он просто не запустится.
    for lib in $(ldd "$src" 2>/dev/null | grep -o '/[^ ]*' | sort -u); do
        [ -e "$lib" ] || continue
        libdst="$LIBS_DIR/$(basename "$lib")"
        [ -e "$libdst" ] && continue
        cp -v "$lib" "$libdst"
        printf '%s %s\n' "$lib" "$libdst" >> "$MANIFEST"
    done
}

resolve() {
    local name="$1" p
    if [[ "$name" == */* ]]; then
        [ -e "$name" ] || { printf 'Нет такого пути: %s\n' "$name" >&2; exit 1; }
        p="$name"
    else
        p="$(command -v "$name" 2>/dev/null || true)"
        [ -n "$p" ] || { printf 'Команда не найдена: %s\n' "$name" >&2; exit 1; }
    fi
    readlink -f "$p"
}

for name in "$SRC_BASH" "${BINARIES[@]}"; do
    copy_bin "$(resolve "$name")"
done

printf -- '--- симлинки на апплеты busybox ---\n'
if [ -f "$BIN_DIR/busybox" ]; then
    while read -r applet; do
        [ -n "$applet" ] || continue
        link="$BIN_DIR/$applet"
        [ -e "$link" ] && continue
        ln -sfn busybox "$link"
    done < <(LD_LIBRARY_PATH="$LIBS_DIR" "$BIN_DIR/busybox" --list)
fi

# --- проверки ----------------------------------------------------------
# Их в оригинале зря недооценили: копии действительно могут разъехаться.

printf -- '--- копии совпадают с оригиналами побайтово ---\n'
while read -r src dst; do
    cmp -s "$src" "$dst" || { printf 'НЕ СОВПАЛО: %s -> %s\n' "$src" "$dst" >&2; exit 1; }
    printf 'ок: %s\n' "$src"
done < "$MANIFEST"

printf -- '--- зависимости берутся из test/libs ---\n'
for bin in "${PROBE_BINS[@]}"; do
    if LD_LIBRARY_PATH="$LIBS_DIR" ldd "$bin" 2>/dev/null | grep -q 'not found'; then
        printf 'Неразрешённая зависимость: %s\n' "$bin" >&2
        exit 1
    fi
    printf 'ок: %s\n' "$bin"
done

# --- смоук-тест -------------------------------------------------------

probe() {
    local bin="$1" args=()
    case "$(basename "$bin")" in
        bash)   args=(-c 'printf "bash из test/bin: %s\n" "$BASH"') ;;
        sh)     args=(-c 'printf "sh из test/bin: %s\n" "$0"') ;;
        awk)    args=('BEGIN { printf "awk из test/bin: sin(1) = %.4f\n", sin(1) }') ;;
        printf) args=('printf из test/bin: %d + %d = %d\n' 2 2 4) ;;
        pwd)    args=(-P) ;;
        busybox) args=(--help) ;;
        *)      return ;;
    esac
    printf -- '--- %s ---\n' "$(basename "$bin")"
    LD_LIBRARY_PATH="$LIBS_DIR" "$bin" "${args[@]}" 2>&1 | head -1 || true
}

for applet in $BUSYBOX_APPLETS; do
    [ -e "$BIN_DIR/$applet" ] && probe "$BIN_DIR/$applet"
done

for bin in "${PROBE_BINS[@]}"; do
    probe "$bin"
done

# --- запуск ------------------------------------------------------------

printf -- '--- сценарий в изолированном окружении (exec, тот же PID) ---\n'
export PATH="$BIN_DIR"
export LD_LIBRARY_PATH="$LIBS_DIR"
exec "$BIN_DIR/bash" -c "$SCENARIO" -- "$ANGLE" "$PRECISION"