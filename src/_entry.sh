}

# ─── 入口判断 ─────────────────────────────────────────
if [ "${LEYILI_ALLOW_ANY_DISTRO:-0}" != "1" ]; then
  if ! require_debian_family; then
    exit 1
  fi
fi
register_sb_command || true

show_menu
