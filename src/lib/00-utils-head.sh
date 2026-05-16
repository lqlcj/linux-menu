detect_distro(){
  if [ ! -r /etc/os-release ]; then
    printf '%s' "unknown"
    return
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '%s' "${ID:-unknown}"
}

is_debian_family(){
  local id id_like
  if [ ! -r /etc/os-release ]; then
    return 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  id="${ID:-}"
  id_like="${ID_LIKE:-}"
  case "$id" in
    debian|ubuntu|raspbian|linuxmint|devuan|kali|pop|elementary|zorin)
      return 0
      ;;
  esac
  case "$id_like" in
    *debian*|*ubuntu*)
      return 0
      ;;
  esac
  return 1
}

require_debian_family(){
  if is_debian_family; then
    return 0
  fi

  echo ""
  echo -e "  ${R}此脚本仅支持 Debian / Ubuntu 系发行版${N}"
  echo -e "  当前系统: ${C}$(detect_distro)${N}"
  echo -e "  如需强制运行可设置环境变量 ${B}LEYILI_ALLOW_ANY_DISTRO=1${N}"
  return 1
}

cleanup_old_backups(){
  local pattern="$1"
  local keep="${2:-5}"
  local dir base victim
  local -a victims=()

  if [ -z "$pattern" ]; then
    return 0
  fi

  case "$keep" in
    ''|*[!0-9]*) return 0 ;;
  esac

  # 用 find + null 分隔取代 ls 通配，正确处理含空格 / 特殊字符的路径
  dir=$(dirname -- "$pattern")
  base=$(basename -- "$pattern")
  [ -d "$dir" ] || return 0

  # 按 mtime 倒序收集，跳过最新 $keep 份后删除其余
  while IFS= read -r -d '' victim; do
    victims+=("${victim#*$'\t'}")
  done < <(find "$dir" -maxdepth 1 -type f -name "$base" -printf '%T@\t%p\0' 2>/dev/null \
           | LC_ALL=C sort -zrn 2>/dev/null)

  if [ "${#victims[@]}" -le "$keep" ]; then
    return 0
  fi

  local i
  for ((i = keep; i < ${#victims[@]}; i++)); do
    [ -n "${victims[i]}" ] && rm -f -- "${victims[i]}"
  done
}

