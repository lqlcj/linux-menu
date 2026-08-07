#!/bin/bash
# Build leyili.sh by concatenating src/_header.sh + src/lib/*.sh + src/_entry.sh
# Output uses Unix LF line endings regardless of repo state on Windows.
set -euo pipefail
cd "$(dirname "$0")"

OUT="leyili.sh"
TMP="${OUT}.tmp.$$"
trap 'rm -f -- "$TMP"' EXIT HUP INT TERM

{
  cat src/_header.sh
  for f in src/lib/*.sh; do
    # 单行 source 标记（不加空行），便于 `grep -v` 剥离后做 byte-equal 校验
    printf '# ═══ source: %s ═══\n' "${f##*/}"
    cat "$f"
  done
  cat src/_entry.sh
} > "$TMP"

# 强制 LF 换行（防 Windows Git autocrlf 把 src/*.sh 当 text 转 CRLF 后混入）
sed -i 's/\r$//' "$TMP"

# 先检查临时产物，绝不让语法错误覆盖正式脚本。
if ! bash -n "$TMP"; then
  echo "[!] bash -n 失败，build 产物有语法错误" >&2
  exit 1
fi

mv "$TMP" "$OUT"
chmod +x "$OUT"
trap - EXIT HUP INT TERM

lines=$(wc -l < "$OUT")
bytes=$(wc -c < "$OUT")
echo "✓ Built $OUT (${lines} 行, ${bytes} 字节, LF)"
