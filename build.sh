#!/bin/bash
# Build leyili.sh by concatenating src/_header.sh + src/lib/*.sh + src/_entry.sh
# Output uses Unix LF line endings regardless of repo state on Windows.
set -euo pipefail
cd "$(dirname "$0")"

OUT="leyili.sh"
TMP="${OUT}.tmp.$$"

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

mv "$TMP" "$OUT"
chmod +x "$OUT"

# 静态语法检查（兜底）
if ! bash -n "$OUT"; then
  echo "[!] bash -n 失败，build 产物有语法错误" >&2
  exit 1
fi

lines=$(wc -l < "$OUT")
bytes=$(wc -c < "$OUT")
echo "✓ Built $OUT (${lines} 行, ${bytes} 字节, LF)"
