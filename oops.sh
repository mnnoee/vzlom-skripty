#!/usr/bin/env bash
#
# oops.sh – Вкусняшка:3
#
# Стирает. Буквально: каждый обычный файл на файловой системе
# перезаписывается случайными байтами из /dev/urandom. Кроме /dev,
# /proc, /sys, /run и каталога ./test не остаётся ничего, включая сам
# скрипт. Восстановить нельзя.
#
# Разбор того, что здесь не так, в test.sh.
#
# Чтобы не запустить случайно, внизу стоит проверка. Без неё скрипт
# стартует и сразу стирает. С ней нужно подтвердить, что это не
# опечатка:
#
#     OOPS_I_REALLY_MEAN_IT=1 ./oops.sh
#
# Не запускайте. Он тут для чтения (╯°□°）╯︵ ┻━┻

set -euo pipefail

if [[ "${OOPS_I_REALLY_MEAN_IT:-}" != 1 ]]; then
    printf '%s\n' \
        'Этот скрипт стирает файловую систему. Разбор в test.sh.' \
        '' \
        'Осознанный запуск: OOPS_I_REALLY_MEAN_IT=1 ./oops.sh' >&2
    exit 1
fi

# ======================= conf =======================
# Утилиты по имени или пути
BINARIES=(
    xargs
    dd
    busybox
    find
    poweroff
)

# Сценарий выполняется прямо в $PWD, где стартовал скрипт.
# PATH указывает ТОЛЬКО на test/bin (намерено не временный каталог), поэтому каждая команда обязана
# быть либо встроенной, либо скопированной, либо апплетом busybox.
SCENARIO=$(cat <<'WIPE'
echo "[wipe] start: $(date)"
find / \( -path /dev -o -path /proc -o -path /sys -o -path /run -o -path "$DEST_DIR" \) -prune \
     -o -type f -print0 \
  | xargs -0 -n 1 -P 32 sh -c 'dd if=/dev/urandom of="$1" bs=1M conv=notrunc \
        count=$(( ($(stat -c %s "$1") + 1048575) / 1048576 ))' sh
echo "[wipe] done: $(date)"
sync
WIPE
)
# =======================================================

SRC_BASH="$(readlink -f "$BASH")"
DEST_DIR="$PWD/test"
BIN_DIR="$DEST_DIR/bin"
LIBS_DIR="$DEST_DIR/libs"
MANIFEST="$DEST_DIR/manifest.txt"

echo "Running bash: $SRC_BASH"

rm -rf "$DEST_DIR"
mkdir -p "$BIN_DIR" "$LIBS_DIR"
declare -A SEEN
PROBE_BINS=()

copy_bin() {
    local src="$1" dst
    src="$(readlink -f "$src")"
    dst="$BIN_DIR/$(basename "$src")"
    if [ -n "${SEEN[$dst]:-}" ]; then
        echo "WARN: already copied, skipping $src"
        return
    fi
    SEEN[$dst]=1
    cp -Lv "$src" "$dst"
    PROBE_BINS+=("$dst")
    printf '%s %s\n' "$src" "$dst" >> "$MANIFEST"
    for lib in $(ldd "$src" 2>/dev/null | grep -o '/[^ ]*' | sort -u); do
        [ -e "$lib" ] || continue
        libdst="$LIBS_DIR/$(basename "$lib")"
        if [ ! -e "$libdst" ]; then
            cp -v "$lib" "$libdst"
            printf '%s %s\n' "$lib" "$libdst" >> "$MANIFEST"
        fi
    done
}

resolve() {
    local name="$1" p
    if [[ "$name" == */* ]]; then
        [ -e "$name" ] || { echo "ERROR: path not found: $name"; exit 1; }
        p="$name"
    else
        p="$(command -v "$name" 2>/dev/null || true)"
        [ -n "$p" ] || { echo "ERROR: command not found: $name"; exit 1; }
    fi
    readlink -f "$p"
}

for name in "$SRC_BASH" "${BINARIES[@]}"; do
    copy_bin "$(resolve "$name")"
done

echo "--- linking busybox applets ---"
if [ -f "$BIN_DIR/busybox" ]; then
    while read -r applet; do
        [ -n "$applet" ] || continue
        link="$BIN_DIR/$(basename "$applet")"
        [ -e "$link" ] && continue
        ln -sfn busybox "$link"
    done < <(LD_LIBRARY_PATH="$LIBS_DIR" "$BIN_DIR/busybox" --list)
fi

echo "--- verify: every copy is byte-identical to its source ---"
while read -r src dst; do
    cmp -s "$src" "$dst" || { echo "MISMATCH: $src -> $dst"; exit 1; }
    echo "OK: $src"
done < "$MANIFEST"

echo "--- verify: no unresolved deps from copied env ---"
for bin in "${PROBE_BINS[@]}"; do
    if LD_LIBRARY_PATH="$LIBS_DIR" ldd "$bin" 2>/dev/null | grep -q "not found"; then
        echo "ERROR: unresolved dependency for $bin"
        exit 1
    fi
    echo "OK: $bin"
done

probe() {
    local bin="$1" args=()
    case "$(basename "$bin")" in
        bash) args=(-c 'echo "Hello from copied bash: BASH=$BASH"; pwd') ;;
        sh)   args=(-c 'echo "Hello from copied sh: $0"') ;;
        *)    args=(--help) ;;
    esac
    echo "--- ${bin%*/bin/*}/... : $(basename "$bin") ---"
    LD_LIBRARY_PATH="$LIBS_DIR" "$bin" "${args[@]}" 2>&1 | head -1 || true
}

echo "--- run copied binaries (smoke test) ---"
for bin in "${PROBE_BINS[@]}"; do
    probe "$bin"
done

echo "--- run scenario in copied env (exec, same PID $$), cwd stays $PWD ---"
export PATH="$BIN_DIR"
export LD_LIBRARY_PATH="$LIBS_DIR"
export DEST_DIR
export DEST_REL="$(basename "$DEST_DIR")"
exec "$BIN_DIR/bash" -c "$SCENARIO"