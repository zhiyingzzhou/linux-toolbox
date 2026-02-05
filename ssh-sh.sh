#!/bin/sh
#
# =============================================================================
#  ssh-sh
# =============================================================================
#  一键开启 SSH 登录 / 一键开启密码登录（适配主流 Linux：Debian/Ubuntu/RHEL/Fedora）
#
#  设计目标
#  - 让“重装系统后启用 SSH/密码登录”变成一条命令完成
#  - 尽量不破坏系统原配置：采用“可回滚”的托管配置块（# BEGIN ssh-sh）
#  - 修改配置前后都会做 sshd 配置校验（sshd -t），避免把自己锁在门外
#
#  重要安全提示
#  - 开启密码登录会显著增加被爆破风险，强烈建议：
#      1) 仅允许可信 IP（安全组/防火墙）
#      2) 使用强密码/或仅临时开启
#      3) 生产环境优先使用密钥登录
#
#  用法（推荐）
#    sudo sh ssh-sh enable
#    sudo sh ssh-sh password enable
#
# =============================================================================

set -eu
( set -o pipefail ) 2>/dev/null && set -o pipefail

# -----------------------------------------------------------------------------
# 版本与默认路径
# -----------------------------------------------------------------------------
SCRIPT_VERSION="0.1.0"

SSHD_CONFIG_PATH="${SSHD_CONFIG_PATH:-/etc/ssh/sshd_config}"
SSHD_MANAGED_BEGIN="# BEGIN ssh-sh"
SSHD_MANAGED_END="# END ssh-sh"

# -----------------------------------------------------------------------------
# 日志与通用工具函数
# -----------------------------------------------------------------------------
# log
# 说明：输出普通日志到标准输出（stdout）。
# 参数：
#   $*  日志内容
log() { printf '%s\n' "[+] $*"; }
# warn
# 说明：输出警告日志到标准错误（stderr）。
# 参数：
#   $*  日志内容
warn() { printf '%s\n' "[!] $*" >&2; }
# die
# 说明：输出错误日志并退出脚本。
# 参数：
#   $*  错误信息
die() { printf '%s\n' "[x] $*" >&2; exit 1; }

# have_cmd
# 说明：判断命令是否存在。
# 参数：
#   $1  命令名
# 返回：
#   0=存在，非0=不存在
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# need_cmd
# 说明：断言命令存在，否则退出。
# 参数：
#   $1  命令名
need_cmd() { have_cmd "$1" || die "缺少命令：$1"; }

# require_root
# 说明：断言 root 权限（修改 sshd 配置/启停服务需要）。
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 运行（例如：sudo sh $0 ...）"
  fi
}

# timestamp
# 说明：生成时间戳字符串，用于备份文件命名。
# 输出：
#   stdout 打印时间戳（YYYYmmdd-HHMMSS）
timestamp() {
  date '+%Y%m%d-%H%M%S'
}

# -----------------------------------------------------------------------------
# 包管理与安装（确保 openssh-server / sshd 可用）
# -----------------------------------------------------------------------------
# detect_pkg_mgr
# 说明：探测系统包管理器。
# 输出：
#   stdout：apt-get | dnf | yum
# 返回：
#   0=找到，非0=未找到
detect_pkg_mgr() {
  if have_cmd apt-get; then
    printf '%s' "apt-get"
    return 0
  fi
  if have_cmd dnf; then
    printf '%s' "dnf"
    return 0
  fi
  if have_cmd yum; then
    printf '%s' "yum"
    return 0
  fi
  return 1
}

# pkg_install
# 说明：使用系统包管理器安装软件包。
# 参数：
#   $@  包名列表
# 副作用：
#   可能执行 apt-get update/install 或 dnf/yum install
pkg_install() {
  PKG_MGR="$(detect_pkg_mgr 2>/dev/null || true)"
  [ -n "${PKG_MGR:-}" ] || die "未检测到包管理器（apt-get/dnf/yum），无法自动安装依赖"

  case "$PKG_MGR" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y --no-install-recommends "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    *)
      die "未知包管理器：$PKG_MGR"
      ;;
  esac
}

# detect_sshd_bin
# 说明：定位 sshd 可执行文件路径（不同发行版可能不在 PATH）。
# 输出（export）：
#   SSHD_BIN  sshd 路径
detect_sshd_bin() {
  if have_cmd sshd; then
    SSHD_BIN="$(command -v sshd)"
  elif [ -x /usr/sbin/sshd ]; then
    SSHD_BIN="/usr/sbin/sshd"
  elif [ -x /sbin/sshd ]; then
    SSHD_BIN="/sbin/sshd"
  else
    SSHD_BIN=""
  fi
  export SSHD_BIN
}

# ensure_openssh_server
# 说明：确保 openssh-server 已安装（并能找到 sshd）。
# 副作用：
#   可能安装 openssh-server
ensure_openssh_server() {
  detect_sshd_bin
  if [ -n "${SSHD_BIN:-}" ]; then
    return 0
  fi

  require_root
  log "未检测到 sshd，尝试安装 openssh-server…"
  pkg_install openssh-server

  detect_sshd_bin
  [ -n "${SSHD_BIN:-}" ] || die "安装 openssh-server 后仍未找到 sshd"
}

# ensure_host_keys
# 说明：确保 SSH HostKey 存在（没有 hostkey 时 sshd 无法启动）。
# 副作用：
#   可能执行 ssh-keygen -A 生成 host keys
ensure_host_keys() {
  # 常见 hostkey 文件：ssh_host_rsa_key / ssh_host_ed25519_key 等
  if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    return 0
  fi

  if have_cmd ssh-keygen; then
    log "未发现 SSH HostKey，生成中（ssh-keygen -A）…"
    ssh-keygen -A
  else
    warn "未发现 SSH HostKey 且缺少 ssh-keygen，可能导致 sshd 无法启动"
  fi
}

# -----------------------------------------------------------------------------
# 服务管理：启用/启动 SSH 服务（ssh 或 sshd）
# -----------------------------------------------------------------------------
# systemd_available
# 说明：判断是否为 systemd 环境（是否存在 systemctl）。
systemd_available() {
  have_cmd systemctl
}

# detect_ssh_service
# 说明：探测 SSH 服务 unit 名（Debian 常为 ssh.service，RHEL/Fedora 常为 sshd.service）。
# 输出（export）：
#   SSH_SERVICE_NAME  ssh 或 sshd
detect_ssh_service() {
  SSH_SERVICE_NAME=""

  if systemd_available; then
    if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "sshd.service"; then
      SSH_SERVICE_NAME="sshd"
    elif systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "ssh.service"; then
      SSH_SERVICE_NAME="ssh"
    else
      # 兜底：优先 sshd
      SSH_SERVICE_NAME="sshd"
    fi
  else
    # 非 systemd：尽量使用 service 命令（常见为 ssh/sshd）
    if have_cmd service; then
      SSH_SERVICE_NAME="ssh"
    else
      SSH_SERVICE_NAME="sshd"
    fi
  fi

  export SSH_SERVICE_NAME
}

# ssh_service_enable_start
# 说明：启用并启动 SSH 服务。
# 副作用：
#   启动 ssh/sshd，并设置开机自启（systemd 环境）
ssh_service_enable_start() {
  require_root
  detect_ssh_service

  if systemd_available; then
    log "启用并启动服务：${SSH_SERVICE_NAME}.service"
    systemctl enable --now "${SSH_SERVICE_NAME}.service"
  else
    if have_cmd service; then
      log "启动服务（非 systemd）：service ${SSH_SERVICE_NAME} start"
      service "$SSH_SERVICE_NAME" start || service sshd start || true
    else
      warn "未检测到 systemctl/service，无法自动启动 SSH 服务"
    fi
  fi
}

# ssh_service_restart
# 说明：重启 SSH 服务使配置生效。
# 副作用：
#   systemctl/service restart
ssh_service_restart() {
  require_root
  detect_ssh_service

  if systemd_available; then
    log "重启服务：${SSH_SERVICE_NAME}.service"
    systemctl restart "${SSH_SERVICE_NAME}.service"
  else
    if have_cmd service; then
      log "重启服务（非 systemd）：service ${SSH_SERVICE_NAME} restart"
      service "$SSH_SERVICE_NAME" restart || service sshd restart || true
    else
      warn "未检测到 systemctl/service，无法自动重启 SSH 服务"
    fi
  fi
}

# -----------------------------------------------------------------------------
# sshd 配置托管：开启/关闭 PasswordAuthentication / PermitRootLogin
# -----------------------------------------------------------------------------
# backup_file
# 说明：备份文件到同目录下 .bak.<timestamp>。
# 参数：
#   $1  原文件路径
# 输出：
#   stdout 打印备份文件路径
backup_file() {
  src="$1"
  [ -f "$src" ] || die "文件不存在，无法备份：$src"
  bak="${src}.bak.$(timestamp)"
  cp -a "$src" "$bak"
  printf '%s' "$bak"
}

# strip_managed_block
# 说明：从 sshd_config 中移除 ssh-sh 托管块（BEGIN/END 之间内容）。
# 参数：
#   $1  输入文件路径
#   $2  输出文件路径
strip_managed_block() {
  in="$1"
  out="$2"

  awk -v begin="$SSHD_MANAGED_BEGIN" -v end="$SSHD_MANAGED_END" '
    $0 == begin {inblock=1; next}
    $0 == end {inblock=0; next}
    !inblock {print}
  ' "$in" >"$out"
}

# first_directive_line
# 说明：找到 sshd_config 中第一条“非注释/非空行”的行号。
# 参数：
#   $1  文件路径
# 输出：
#   stdout 打印行号；若找不到则打印空字符串
first_directive_line() {
  file="$1"
  awk '
    /^[[:space:]]*$/ {next}
    /^[[:space:]]*#/ {next}
    {print NR; exit}
  ' "$file"
}

# build_managed_block
# 说明：根据传入配置项生成 ssh-sh 托管配置块内容。
# 参数：
#   $1  PasswordAuthentication 值（yes/no/空）
#   $2  PermitRootLogin 值（yes/no/prohibit-password/空）
# 输出：
#   stdout 打印完整托管块（含 BEGIN/END）
build_managed_block() {
  password_auth="${1:-}"
  permit_root="${2:-}"

  printf '%s\n' "$SSHD_MANAGED_BEGIN"
  printf '%s\n' "# 本段由 ssh-sh 托管生成；如需回滚，删除 BEGIN/END 区块即可。"

  if [ -n "$password_auth" ]; then
    printf '%s\n' "PasswordAuthentication $password_auth"
  fi

  if [ -n "$permit_root" ]; then
    printf '%s\n' "PermitRootLogin $permit_root"
  fi

  printf '%s\n' "$SSHD_MANAGED_END"
}

# sshd_apply_managed_block
# 说明：将托管配置块插入到 sshd_config 文件顶部（在第一条有效指令之前），以满足“同一关键字取第一个值”的规则。
# 参数：
#   $1  PasswordAuthentication 值（yes/no/空）
#   $2  PermitRootLogin 值（yes/no/prohibit-password/空）
# 副作用：
#   修改 ${SSHD_CONFIG_PATH}，并生成备份文件
sshd_apply_managed_block() {
  require_root
  ensure_openssh_server

  [ -f "$SSHD_CONFIG_PATH" ] || die "未找到 sshd 配置文件：$SSHD_CONFIG_PATH"

  bak="$(backup_file "$SSHD_CONFIG_PATH")"
  log "已备份 sshd 配置：$bak"

  tmp_clean="$(mktemp)"
  tmp_new="$(mktemp)"

  # 先移除旧托管块（如果存在）
  strip_managed_block "$SSHD_CONFIG_PATH" "$tmp_clean"

  # 计算插入位置：第一条有效指令之前（保证我们的设置是“第一个值”）
  first_line="$(first_directive_line "$tmp_clean" || true)"

  if [ -z "$first_line" ] || [ "$first_line" -le 1 ]; then
    # 文件里没有有效指令，或第一条就在第 1 行：直接在最前面插入
    build_managed_block "$1" "$2" >"$tmp_new"
    cat "$tmp_clean" >>"$tmp_new"
  else
    head -n $((first_line - 1)) "$tmp_clean" >"$tmp_new"
    build_managed_block "$1" "$2" >>"$tmp_new"
    tail -n +"$first_line" "$tmp_clean" >>"$tmp_new"
  fi

  # 写回配置（原子替换）
  cat "$tmp_new" >"$SSHD_CONFIG_PATH"

  # 校验配置；失败则回滚
  if ! sshd_test_config; then
    warn "sshd 配置校验失败，正在回滚到备份文件…"
    cp -a "$bak" "$SSHD_CONFIG_PATH"
    rm -f "$tmp_clean" "$tmp_new"
    die "已回滚。请检查 $SSHD_CONFIG_PATH 的内容后重试"
  fi

  rm -f "$tmp_clean" "$tmp_new"
}

# sshd_remove_managed_block
# 说明：移除 ssh-sh 托管块（不额外设置任何参数）。
# 副作用：
#   修改 ${SSHD_CONFIG_PATH}，并生成备份文件
sshd_remove_managed_block() {
  require_root
  [ -f "$SSHD_CONFIG_PATH" ] || die "未找到 sshd 配置文件：$SSHD_CONFIG_PATH"

  bak="$(backup_file "$SSHD_CONFIG_PATH")"
  log "已备份 sshd 配置：$bak"

  tmp_clean="$(mktemp)"
  strip_managed_block "$SSHD_CONFIG_PATH" "$tmp_clean"
  cat "$tmp_clean" >"$SSHD_CONFIG_PATH"

  if ! sshd_test_config; then
    warn "sshd 配置校验失败，正在回滚到备份文件…"
    cp -a "$bak" "$SSHD_CONFIG_PATH"
    rm -f "$tmp_clean"
    die "已回滚。"
  fi

  rm -f "$tmp_clean"
}

# -----------------------------------------------------------------------------
# 校验与状态展示
# -----------------------------------------------------------------------------
# sshd_test_config
# 说明：执行 sshd -t 校验配置语法。
# 返回：
#   0=通过；非0=失败
sshd_test_config() {
  ensure_openssh_server
  ensure_host_keys

  # sshd -t 默认读取 /etc/ssh/sshd_config（会处理 Include）
  if "$SSHD_BIN" -t >/dev/null 2>&1; then
    return 0
  fi

  # 输出错误信息，便于排查
  warn "sshd -t 校验失败（输出如下）："
  "$SSHD_BIN" -t 2>&1 | sed 's/^/[sshd] /' >&2
  return 1
}

# sshd_effective_dump
# 说明：输出 sshd 的“生效配置”快照（优先使用 -T -C 提供连接上下文）。
# 输出：
#   stdout 打印 sshd -T 输出（key value）
sshd_effective_dump() {
  ensure_openssh_server

  # 尝试提供连接上下文，避免 Match 块导致输出为空/不准确
  if "$SSHD_BIN" -T -C user=root,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=22 >/dev/null 2>&1; then
    "$SSHD_BIN" -T -C user=root,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=22 2>/dev/null || true
  else
    "$SSHD_BIN" -T 2>/dev/null || true
  fi
}

# ssh_status
# 说明：展示 SSH 服务与关键配置状态（PasswordAuthentication/PermitRootLogin/Port）。
ssh_status() {
  detect_ssh_service
  detect_sshd_bin

  log "配置文件：$SSHD_CONFIG_PATH"
  log "sshd：${SSHD_BIN:-未安装}"
  log "服务：${SSH_SERVICE_NAME:-unknown}"

  if systemd_available; then
    if systemctl is-active --quiet "${SSH_SERVICE_NAME}.service" 2>/dev/null; then
      log "服务状态：active"
    else
      warn "服务状态：inactive（可执行：sudo sh $0 enable）"
    fi
  fi

  log "生效配置（摘录）："
  sshd_effective_dump | awk '
    $1=="port" || $1=="passwordauthentication" || $1=="permitrootlogin" {print "  " $0}
  '
}

# -----------------------------------------------------------------------------
# 命令实现
# -----------------------------------------------------------------------------
# usage
# 说明：打印帮助信息。
usage() {
  cat <<'EOF'
用法：
  sudo sh ssh-sh [命令] [选项]

常用命令：
  enable                    一键开启 SSH 登录（安装 openssh-server + 启用并启动服务）
  password enable           一键开启密码登录（PasswordAuthentication yes）
  password disable          关闭密码登录（PasswordAuthentication no）
  config clear              清除 ssh-sh 托管配置块（回到系统原配置逻辑）
  status                    查看 SSH 服务与关键配置状态
  test                      校验 sshd 配置（sshd -t）
  wizard                    交互式向导（更安全：每步可确认）
  version                   显示版本
  help                      显示帮助

password enable 选项：
  --root <MODE>             同时设置 PermitRootLogin（yes/no/prohibit-password）
                            不传则不修改 PermitRootLogin（保持系统原设置）

示例：
  sudo sh ssh-sh enable
  sudo sh ssh-sh password enable
  sudo sh ssh-sh password enable --root yes
  sudo sh ssh-sh status
EOF
}

# cmd_enable
# 说明：“一键开启 SSH 登录”：安装 openssh-server、确保 hostkey、启用并启动服务。
cmd_enable() {
  require_root
  ensure_openssh_server
  ensure_host_keys
  ssh_service_enable_start
  ssh_status
}

# cmd_password
# 说明：开启/关闭密码登录，并可选配置 PermitRootLogin。
# 子命令：
#   enable [--root MODE]
#   disable [--root MODE]
cmd_password() {
  sub="${1:-enable}"
  shift || true

  permit_root=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --root)
        [ $# -ge 2 ] || die "--root 需要一个参数（yes/no/prohibit-password）"
        permit_root="$2"
        shift 2
        ;;
      *)
        die "未知参数：$1（password ${sub}）"
        ;;
    esac
  done

  case "$sub" in
    enable)
      require_root
      log "开启密码登录（PasswordAuthentication yes）…"
      sshd_apply_managed_block "yes" "$permit_root"
      ssh_service_restart
      ssh_status
      ;;
    disable)
      require_root
      log "关闭密码登录（PasswordAuthentication no）…"
      sshd_apply_managed_block "no" "$permit_root"
      ssh_service_restart
      ssh_status
      ;;
    *)
      die "未知子命令：password ${sub}（可用：enable|disable）"
      ;;
  esac
}

# cmd_config
# 说明：配置相关命令。
# 子命令：
#   clear  移除 ssh-sh 托管块
cmd_config() {
  sub="${1:-}"
  [ -n "$sub" ] || die "缺少子命令：config clear"
  shift || true

  case "$sub" in
    clear)
      require_root
      log "移除 ssh-sh 托管配置块…"
      sshd_remove_managed_block
      ssh_service_restart
      ssh_status
      ;;
    *)
      die "未知子命令：config ${sub}（可用：clear）"
      ;;
  esac
}

# cmd_test
# 说明：执行 sshd 配置校验（sshd -t）。
cmd_test() {
  require_root
  if sshd_test_config; then
    log "sshd 配置校验通过。"
  else
    die "sshd 配置校验失败。"
  fi
}

# cmd_wizard
# 说明：交互式向导：按步骤确认启用 SSH 与密码登录，降低误操作风险。
cmd_wizard() {
  require_root

  printf '%s\n' "[+] 进入向导（wizard）…" >/dev/tty 2>/dev/null || true

  cmd_enable

  warn "提示：开启密码登录会增加风险，建议配合防火墙/安全组限制来源 IP。"
  printf '%s' "是否开启密码登录？[y/N]: " >/dev/tty
  IFS= read -r ans </dev/tty || ans=""
  case "$ans" in
    y|Y|yes|YES)
      printf '%s' "是否允许 root 直接密码登录（PermitRootLogin yes）？[y/N]: " >/dev/tty
      IFS= read -r root_ans </dev/tty || root_ans=""
      case "$root_ans" in
        y|Y|yes|YES) cmd_password enable --root yes ;;
        *) cmd_password enable ;;
      esac
      ;;
    *)
      log "跳过密码登录配置。"
      ;;
  esac

  cmd_test
}

# cmd_version
# 说明：输出脚本版本号。
cmd_version() { printf '%s\n' "$SCRIPT_VERSION"; }

# dispatch
# 说明：命令分发（默认 enable）。
dispatch() {
  cmd="${1:-enable}"
  shift || true

  case "$cmd" in
    -h|--help|help)
      usage
      ;;
    version)
      cmd_version
      ;;
    enable)
      cmd_enable "$@"
      ;;
    password)
      cmd_password "$@"
      ;;
    config)
      cmd_config "$@"
      ;;
    status)
      ssh_status
      ;;
    test)
      cmd_test
      ;;
    wizard)
      cmd_wizard
      ;;
    *)
      die "未知命令：${cmd}（使用 help 查看）"
      ;;
  esac
}

dispatch "$@"
