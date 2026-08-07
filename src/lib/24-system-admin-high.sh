create_regular_user(){
  local username=""
  local home_dir=""
  local copy_choice=""

  if ! require_root; then
    return 1
  fi

  echo ""
  username=$(prompt_for_linux_username "  请输入要创建的普通用户名: ")
  if [ -z "$username" ]; then
    echo -e "${R}用户名读取失败${N}"
    pause_screen
    return 1
  fi

  if id "$username" >/dev/null 2>&1; then
    echo -e "${Y}用户 ${C}$username${N}${Y} 已存在，跳过创建${N}"
    pause_screen
    return 0
  fi

  echo -e "${Y}==> 开始创建用户 ${C}$username${N}${Y}，接下来会进入 adduser 交互流程...${N}"
  if ! adduser "$username"; then
    echo ""
    echo -e "${R}用户创建失败，请检查上方输出${N}"
    pause_screen
    return 1
  fi

  # 如果 root 有 authorized_keys，询问是否拷贝给新用户（密钥登录场景双保险）
  if [ -s /root/.ssh/authorized_keys ]; then
    home_dir=$(getent passwd "$username" | cut -d: -f6)
    if [ -n "$home_dir" ] && [ -d "$home_dir" ]; then
      echo ""
      echo -e "  ${Y}检测到 /root/.ssh/authorized_keys 存在${N}"
      read -p "  是否将 root 的 SSH 公钥复制给 ${username}？(Y/n): " copy_choice
      if [ "$copy_choice" != "n" ] && [ "$copy_choice" != "N" ]; then
        mkdir -p "$home_dir/.ssh"
        if cp /root/.ssh/authorized_keys "$home_dir/.ssh/authorized_keys"; then
          chmod 700 "$home_dir/.ssh"
          chmod 600 "$home_dir/.ssh/authorized_keys"
          chown -R "$username:$username" "$home_dir/.ssh"
          echo -e "  ${G}已复制公钥到 ${C}${home_dir}/.ssh/authorized_keys${N}"
        else
          echo -e "  ${R}公钥复制失败，请稍后手动处理${N}"
        fi
      else
        echo -e "  ${D}已跳过公钥复制${N}"
      fi
    fi
  fi

  echo ""
  echo -e "${G}用户 ${C}$username${N}${G} 创建完成${N}"
  pause_screen
}

add_user_to_sudo_group(){
  local username=""

  if ! require_root; then
    return 1
  fi

  echo ""
  username=$(prompt_for_linux_username "  请输入要加入 sudo 组的用户名: ")
  if [ -z "$username" ]; then
    echo -e "${R}用户名读取失败${N}"
    pause_screen
    return 1
  fi

  if ! id "$username" >/dev/null 2>&1; then
    echo -e "${R}用户 ${C}$username${N}${R} 不存在${N}"
    pause_screen
    return 1
  fi

  if ! getent group sudo >/dev/null 2>&1; then
    echo -e "${R}系统中不存在 sudo 组${N}"
    pause_screen
    return 1
  fi

  if id -nG "$username" | tr ' ' '\n' | grep -Fxq sudo; then
    echo -e "${Y}用户 ${C}$username${N}${Y} 已经在 sudo 组中${N}"
    pause_screen
    return 0
  fi

  if ! usermod -aG sudo "$username"; then
    echo -e "${R}加入 sudo 组失败，请检查上方输出${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${G}已将 ${C}$username${N}${G} 加入 sudo 组${N}"
  echo -e "  ${Y}提示：${N} 新的组权限通常需要重新登录后才会完全生效"
  pause_screen
}

test_user_login(){
  local username=""

  if ! require_root; then
    return 1
  fi

  echo ""
  username=$(prompt_for_linux_username "  请输入要测试登录的用户名: ")
  if [ -z "$username" ]; then
    echo -e "${R}用户名读取失败${N}"
    pause_screen
    return 1
  fi

  if ! id "$username" >/dev/null 2>&1; then
    echo -e "${R}用户 ${C}$username${N}${R} 不存在${N}"
    pause_screen
    return 1
  fi

  echo -e "${Y}==> 即将切换到 ${C}$username${N}${Y} 的登录环境${N}"
  echo -e "  输入 ${B}exit${N} 返回当前菜单"
  echo ""

  if su - "$username"; then
    echo ""
    echo -e "${G}已返回当前菜单，用户切换流程正常${N}"
  else
    echo ""
    echo -e "${R}su - $username 执行失败，请检查密码、shell 或 PAM 配置${N}"
  fi

  pause_screen
}

configure_ssh_port(){
  local ssh_port=""
  local confirm=""
  local server_ip=""
  local suggested_ssh_port=""
  local current_ssh_port=""

  if ! require_root; then
    return 1
  fi

  echo ""
  current_ssh_port=$(get_current_ssh_port)
  suggested_ssh_port=$(generate_random_high_port "$current_ssh_port")

  while true; do
    read -p "  新 SSH 端口 (${suggested_ssh_port}): " ssh_port
    ssh_port="${ssh_port:-$suggested_ssh_port}"
    if ! validate_port "$ssh_port"; then
      echo -e "${R}端口必须是 1-65535 的数字${N}"
      continue
    fi
    if [ "$ssh_port" = "$current_ssh_port" ]; then
      echo -e "${Y}新端口与当前 SSH 端口相同，无需修改${N}"
      sleep 1
      return 0
    fi
    if check_port_in_use "$ssh_port"; then
      echo -e "${R}端口 ${ssh_port} 已被占用，请换一个${N}"
      continue
    fi
    break
  done

  echo -e "${Y}警告：${N} 修改后请确认安全组（云平台）已放行新端口。"
  read -p "  确认将 SSH 端口修改为 ${ssh_port} 并重启 SSH 服务？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  echo ""
  if ! node_apply_firewall_for_mode "$ssh_port" tcp dualstack; then
    echo -e "${R}新 SSH 端口防火墙放行失败，已中止修改${N}"
    pause_screen
    return 1
  fi

  if apply_sshd_setting "Port" "$ssh_port" "SSH 端口已更新并重启服务"; then
    cleanup_old_backups "${SSHD_CONFIG_PATH}.bak.*" 5

    server_ip=$(detect_primary_ipv4)
    server_ip="${server_ip:-你的IP}"
    echo -e "  新登录方式: ${C}ssh 用户名@${server_ip} -p ${ssh_port}${N}"
    echo -e "  配置文件: ${C}$SSHD_CONFIG_PATH${N}"
    echo ""
    echo -e "  ${B}${R}【强烈建议】${N}${B}保留当前 SSH 窗口！${N}"
    echo -e "  ${B}先开新终端用普通用户 + 新端口验证可登录，再关闭当前窗口。${N}"
    pause_screen
  fi
}

disable_root_ssh_login(){
  local confirm=""
  local sudo_users=""
  local user=""
  local home_dir=""
  local has_key=0
  local has_passwd=0
  local can_login_user=""
  local pwd_auth_effective="" pubkey_auth_effective=""

  if ! require_root; then
    return 1
  fi

  echo ""
  echo -e "${Y}警告：${N} 请先确认普通用户已经可以正常登录并执行 sudo。"
  read -p "  确认禁止 root 通过 SSH 登录？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  # 必须至少有 1 个非 root 的 sudo 用户按当前认证策略可 SSH 登录。
  sudo_users=$(getent group sudo 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -v '^root$' | grep -v '^$')
  if [ -z "$sudo_users" ]; then
    echo ""
    echo -e "${R}没有发现非 root 的 sudo 组成员，禁用 root 登录会导致服务器变砖${N}"
    echo -e "${Y}请先在管理员设置中执行 1)创建普通用户 + 2)加入 sudo 组${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "  ${B}检查可登录的非 root sudo 用户...${N}"
  while IFS= read -r user; do
    [ -z "$user" ] && continue
    has_key=0
    has_passwd=0
    pwd_auth_effective=$(get_effective_sshd_value PasswordAuthentication "$user")
    pubkey_auth_effective=$(get_effective_sshd_value PubkeyAuthentication "$user")
    home_dir=$(getent passwd "$user" | cut -d: -f6)
    if [ "$pubkey_auth_effective" != "no" ] \
       && [ -n "$home_dir" ] && [ -s "$home_dir/.ssh/authorized_keys" ]; then
      has_key=1
    fi
    if [ "$pwd_auth_effective" = "yes" ] \
       && passwd -S "$user" 2>/dev/null | awk '{exit !($2 == "P")}'; then
      has_passwd=1
    fi
    if [ "$has_key" = "1" ] || [ "$has_passwd" = "1" ]; then
      can_login_user="$user"
      local marks=""
      [ "$has_passwd" = "1" ] && marks="${marks}密码 "
      [ "$has_key" = "1" ] && marks="${marks}公钥 "
      echo -e "    ${G}✓${N}  ${C}${user}${N}  ${D}(${marks% })${N}"
    else
      echo -e "    ${R}✗${N}  ${C}${user}${N}  ${D}(未设密码且无 authorized_keys)${N}"
    fi
  done <<EOF
$sudo_users
EOF

  if [ -z "$can_login_user" ]; then
    echo ""
    echo -e "${R}没有任何非 root sudo 用户能 SSH 登录，已中止${N}"
    echo -e "${Y}修复建议：${N}"
    echo -e "  - 给某个 sudo 用户设密码：${C}passwd <用户名>${N}"
    echo -e "  - 或将公钥放到 ${C}~<用户名>/.ssh/authorized_keys${N}"
    pause_screen
    return 1
  fi
  echo -e "  ${G}通过：至少 ${C}${can_login_user}${G} 可登录${N}"

  if apply_sshd_setting "PermitRootLogin" "no" "root SSH 登录已禁用"; then
    cleanup_old_backups "${SSHD_CONFIG_PATH}.bak.*" 5
    echo -e "  当前设置: ${C}PermitRootLogin no${N}"
    echo -e "  配置文件: ${C}$SSHD_CONFIG_PATH${N}"
    echo ""
    echo -e "  ${B}${R}【强烈建议】${N}${B}保留当前 SSH 窗口！${N}"
    echo -e "  ${B}先开新终端用普通用户登录，并验证 ${C}sudo -i${N}${B} 可用，再关闭当前窗口。${N}"
    pause_screen
  fi
}

enable_root_ssh_login(){
  local confirm=""

  if ! require_root; then
    return 1
  fi

  echo ""
  echo -e "${Y}警告：${N} 恢复 root 登录后建议继续使用密钥登录，避免暴力破解。"
  read -p "  确认恢复 root 通过 SSH 登录？(y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "  已取消"
    sleep 1
    return 0
  fi

  if apply_sshd_setting "PermitRootLogin" "yes" "root SSH 登录已恢复"; then
    cleanup_old_backups "${SSHD_CONFIG_PATH}.bak.*" 5
    echo -e "  当前设置: ${C}PermitRootLogin yes${N}"
    echo -e "  配置文件: ${C}$SSHD_CONFIG_PATH${N}"
    pause_screen
  fi
}

configure_passwordless_sudo(){
  local username=""
  local dropin_path=""
  local tmp_file=""

  if ! require_root; then
    return 1
  fi

  echo ""
  username=$(prompt_for_linux_username "  请输入要配置 sudo 免密的用户名: ")
  if [ -z "$username" ]; then
    echo -e "${R}用户名读取失败${N}"
    pause_screen
    return 1
  fi

  if ! id "$username" >/dev/null 2>&1; then
    echo -e "${R}用户 ${C}$username${N}${R} 不存在${N}"
    pause_screen
    return 1
  fi

  if ! command -v visudo >/dev/null 2>&1; then
    echo -e "${R}未找到 visudo，无法安全校验 sudoers 规则${N}"
    pause_screen
    return 1
  fi

  if ! grep -Eq '^[[:space:]]*[@#]includedir[[:space:]]+/etc/sudoers\.d([[:space:]]|$)' /etc/sudoers; then
    echo -e "${R}当前 /etc/sudoers 未启用 @includedir/#includedir /etc/sudoers.d，无法安全写入免密规则${N}"
    pause_screen
    return 1
  fi

  mkdir -p "$SUDOERS_DROPIN_DIR"
  dropin_path="${SUDOERS_DROPIN_DIR}/${username}-nopasswd"
  tmp_file=$(mktemp)

  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$username" > "$tmp_file"
  chmod 440 "$tmp_file"

  if ! visudo -cf "$tmp_file" >/dev/null 2>&1; then
    rm -f "$tmp_file"
    echo -e "${R}sudoers 规则语法校验失败${N}"
    pause_screen
    return 1
  fi

  if ! cp "$tmp_file" "$dropin_path"; then
    rm -f "$tmp_file"
    echo -e "${R}sudo 免密规则写入失败${N}"
    pause_screen
    return 1
  fi
  chmod 440 "$dropin_path"
  rm -f "$tmp_file"

  if ! visudo -cf /etc/sudoers >/dev/null 2>&1; then
    rm -f "$dropin_path"
    echo -e "${R}sudoers 总配置校验失败，已回滚${N}"
    pause_screen
    return 1
  fi

  echo ""
  echo -e "${G}已为 ${C}$username${N}${G} 配置 sudo 免密${N}"
  echo -e "  规则文件: ${C}$dropin_path${N}"
  echo -e "  现在可直接使用 ${C}sudo -i${N}"
  pause_screen
}

remove_passwordless_sudo(){
  local username=""
  local dropin_path=""

  if ! require_root; then
    return 1
  fi

  echo ""
  username=$(prompt_for_linux_username "  请输入要移除 sudo 免密的用户名: ")
  if [ -z "$username" ]; then
    echo -e "${R}用户名读取失败${N}"
    pause_screen
    return 1
  fi

  dropin_path="${SUDOERS_DROPIN_DIR}/${username}-nopasswd"
  if [ ! -f "$dropin_path" ]; then
    echo -e "${Y}未找到 ${C}$dropin_path${N}${Y}，无需移除${N}"
    pause_screen
    return 0
  fi

  if ! rm -f "$dropin_path"; then
    echo -e "${R}移除失败${N}"
    pause_screen
    return 1
  fi

  if command -v visudo >/dev/null 2>&1 && ! visudo -cf /etc/sudoers >/dev/null 2>&1; then
    echo -e "${Y}移除后 /etc/sudoers 校验有告警，请人工检查${N}"
  fi

  echo ""
  echo -e "${G}已移除 ${C}$username${N}${G} 的 sudo 免密规则${N}"
  pause_screen
}
