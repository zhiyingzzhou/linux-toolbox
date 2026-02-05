#!/bin/sh
#
# =============================================================================
#  docker-sh
# =============================================================================
#  一键安装 Docker Engine（国内网络友好，自动选择镜像）
#
#  设计目标
#  - 尽量“一条命令跑完”，并且可重复执行（幂等、易维护）
#  - 支持主流 Linux 发行版：
#      * Debian / Ubuntu 及其衍生（APT 系）
#      * CentOS / RHEL / Rocky / Alma / Oracle Linux（RPM 系）
#      * Fedora（RPM 系）
#  - 国内优先自动探测可用源：华为云/阿里云/清华/中科大，失败回退官方源
#
#  用法
#    sudo sh docker-sh [命令] [选项]
#
#  说明
#  - 安装：sudo sh docker-sh install
#  - 向导：sudo sh docker-sh wizard
#  - 配置：sudo sh docker-sh config proxy|mirrors
#  - 测试：sudo sh docker-sh test all|pull
#  - 安装为命令：sudo sh docker-sh self-install
#
#  可选环境变量
#    DOCKER_REPO_BASE           同 --mirror（通用）
#    DOCKER_APT_MIRROR          兼容旧写法（仅 APT；等价于 DOCKER_REPO_BASE）
#    DOCKER_SH_FIX_APT=1        自动修复 APT 源（仅处理 Proxmox Enterprise 源导致的 401/未签名失败）
#    DOCKER_FIX_APT=1           同 DOCKER_SH_FIX_APT（兼容别名）
#    DOCKER_SKIP_REMOVE_CONFLICTS=1  跳过移除冲突旧包（不建议）
#
#  备注
#  - 本脚本支持配置 Docker daemon 代理（systemd drop-in）与 registry-mirrors
#
# =============================================================================

set -eu
( set -o pipefail ) 2>/dev/null && set -o pipefail

# -----------------------------------------------------------------------------
# 版本与默认路径（可通过环境变量覆盖）
# -----------------------------------------------------------------------------
SCRIPT_VERSION="0.3.1"

# 安装为命令时的默认名称与路径
CLI_NAME_DEFAULT="docker-sh"
CLI_BIN_DIR_DEFAULT="/usr/local/bin"

# 可通过环境变量覆盖：DOCKER_SH_NAME / DOCKER_SH_BIN_DIR
CLI_NAME="${DOCKER_SH_NAME:-$CLI_NAME_DEFAULT}"
CLI_BIN_DIR="${DOCKER_SH_BIN_DIR:-$CLI_BIN_DIR_DEFAULT}"
CLI_PATH="${CLI_BIN_DIR%/}/$CLI_NAME"

# APT 源自动修复开关（默认关闭）
# - 仅针对常见的 Proxmox Enterprise 源（enterprise.proxmox.com）在无订阅时返回 401，
#   进而导致 apt-get update 失败的问题。
# - 可通过 --fix-apt / DOCKER_SH_FIX_APT=1 / DOCKER_FIX_APT=1 开启。
DOCKER_SH_FIX_APT="${DOCKER_SH_FIX_APT:-${DOCKER_FIX_APT:-0}}"

# Docker 配置文件路径
DOCKER_DAEMON_JSON_PATH="${DOCKER_DAEMON_JSON_PATH:-/etc/docker/daemon.json}"
DOCKER_SYSTEMD_DROPIN_DIR="${DOCKER_SYSTEMD_DROPIN_DIR:-/etc/systemd/system/docker.service.d}"
DOCKER_PROXY_DROPIN_PATH="${DOCKER_PROXY_DROPIN_PATH:-$DOCKER_SYSTEMD_DROPIN_DIR/proxy.conf}"

# -----------------------------------------------------------------------------
# 日志与通用工具函数
# -----------------------------------------------------------------------------
# log
# 说明：输出普通日志到标准输出（stdout）。
# 参数：
#   $*  日志内容（会拼成一行）
log() { printf '%s\n' "[+] $*"; }
# warn
# 说明：输出警告日志到标准错误（stderr）。
# 参数：
#   $*  日志内容（会拼成一行）
warn() { printf '%s\n' "[!] $*" >&2; }
# die
# 说明：输出错误日志到 stderr 并退出。
# 参数：
#   $*  错误信息
# 返回：
#   退出码固定为 1
die() { printf '%s\n' "[x] $*" >&2; exit 1; }

# is_true
# 说明：判断某个值是否为“真”（用于环境变量/开关）。
# 约定：
#   1/true/yes/y/on 视为真，其它视为假
# 参数：
#   $1  待判断的值
# 返回：
#   0=真，1=假
is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# need_cmd
# 说明：断言某命令存在，否则直接退出。
# 参数：
#   $1  命令名（如：curl）
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
# have_cmd
# 说明：判断某命令是否存在。
# 参数：
#   $1  命令名
# 返回：
#   0=存在，非0=不存在
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# require_root
# 说明：断言当前为 root 用户运行（例如 sudo），否则退出。
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 运行（例如：sudo sh $0）"
  fi
}

# curl_ok
# 说明：快速探测 URL 是否可访问（用于镜像源可用性检测）。
# 参数：
#   $1  URL
# 返回：
#   0=可访问，非0=不可访问
curl_ok() {
  # $1: url
  curl -fsSL --connect-timeout 5 --max-time 15 "$1" >/dev/null 2>&1
}

# usage
# 说明：打印帮助信息（用于 help/--help）。
usage() {
  cat <<'EOF'
用法：
  sudo sh docker-sh [命令] [选项]

常用命令：
  install                        安装/更新 Docker Engine（默认）
  wizard                         交互式向导（安装 + 配置 + 测试）
  config proxy                   配置 Docker daemon 代理（systemd drop-in）
  config mirrors                 配置 Docker 镜像站（registry-mirrors）
  config show                    显示当前代理/镜像配置
  test [all|proxy|mirrors|pull]  测试代理/镜像是否生效
  self-install                   安装为命令（默认：/usr/local/bin/docker-sh）
  self-uninstall                 卸载已安装命令
  version                        显示版本
  help                           显示帮助

install 选项：
  --mirror <URL>                 指定 Docker 安装仓库 base URL（APT/RPM 安装源）
  --fix-apt                      自动修复 APT 源（仅禁用 Proxmox Enterprise 源导致的 update 失败）

install 环境变量：
  DOCKER_REPO_BASE=<URL>             同 --mirror（通用）
  DOCKER_APT_MIRROR=<URL>            兼容旧写法（仅 APT；等价于 DOCKER_REPO_BASE）
  DOCKER_SH_FIX_APT=1                同 --fix-apt（兼容别名：DOCKER_FIX_APT=1）
  DOCKER_SKIP_REMOVE_CONFLICTS=1     跳过移除冲突旧包（不建议）

config proxy 选项：
  --interactive                  交互输入（默认）
  --clear                        清除代理配置
  --http <URL>                   设置 HTTP_PROXY / http_proxy
  --https <URL>                  设置 HTTPS_PROXY / https_proxy（默认同 --http）
  --no-proxy <LIST>              设置 NO_PROXY / no_proxy（逗号分隔）

config mirrors 选项：
  --interactive                  交互输入（默认）
  --clear                        清除 registry-mirrors
  --set <LIST>                   设置镜像站（空格或逗号分隔）

test pull 选项：
  --image <NAME[:TAG]>           实际拉取测试镜像（默认 hello-world:latest）

示例：
  sudo sh docker-sh
  sudo sh docker-sh wizard
  sudo sh docker-sh config proxy
  sudo sh docker-sh config mirrors --set "https://mirror1 https://mirror2"
  sudo sh docker-sh test all
  sudo sh docker-sh self-install && docker-sh wizard && docker-sh self-uninstall
EOF
}

# -----------------------------------------------------------------------------
# 交互输入：统一从 /dev/tty 读取，避免 stdin 被管道/重定向影响
# -----------------------------------------------------------------------------
# tty_available
# 说明：判断是否存在可读写的交互终端（/dev/tty）。
# 返回：
#   0=可交互输入，非0=不可交互输入
tty_available() {
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

# prompt_line
# 说明：在终端提示用户输入一行文本（可带默认值）。
# 参数：
#   $1  提示语
#   $2  默认值（可选）
# 输出：
#   写入全局变量 PROMPT_RESULT
prompt_line() {
  # 用法：prompt_line "问题" "默认值"
  # 结果：写入全局变量 PROMPT_RESULT
  question="$1"
  default="${2:-}"

  tty_available || die "当前环境无法交互输入（/dev/tty 不可用）"

  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$question" "$default" >/dev/tty
  else
    printf '%s: ' "$question" >/dev/tty
  fi

  IFS= read -r answer </dev/tty || answer=""
  if [ -z "$answer" ]; then
    answer="$default"
  fi

  PROMPT_RESULT="$answer"
}

# prompt_yes_no
# 说明：在终端提示用户回答 y/n（带默认值），直到输入合法为止。
# 参数：
#   $1  提示语
#   $2  默认值（y 或 n，默认 n）
# 返回：
#   0=Yes，1=No
prompt_yes_no() {
  # 用法：prompt_yes_no "问题" "y|n"
  # 返回：0=Yes，1=No
  question="$1"
  default="${2:-n}"

  tty_available || die "当前环境无法交互输入（/dev/tty 不可用）"

  while :; do
    case "$default" in
      y|Y) yn_hint="Y/n" ;;
      n|N) yn_hint="y/N" ;;
      *) yn_hint="y/n" ;;
    esac

    printf '%s [%s]: ' "$question" "$yn_hint" >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
    [ -n "$answer" ] || answer="$default"

    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) printf '%s\n' "请输入 y 或 n" >/dev/tty ;;
    esac
  done
}

# normalize_space_comma_list
# 说明：将“逗号/换行/多空格分隔的列表”规范化为“单空格分隔的一行”。
# 参数：
#   $1  原始字符串
# 输出：
#   规范化后的字符串（stdout）
normalize_space_comma_list() {
  # 将“逗号/换行分隔的列表”标准化成“空格分隔的一行”
  # 示例：a,b  c  -> "a b c"
  printf '%s' "$1" | tr ',\n' '  ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# -----------------------------------------------------------------------------
# 系统识别：读取 /etc/os-release，并判断走 APT 还是 RPM 流程
# -----------------------------------------------------------------------------
# load_os_release
# 说明：读取并加载 /etc/os-release（为系统识别提供 ID / VERSION_CODENAME 等变量）。
# 副作用：
#   在当前 shell 环境中导入 /etc/os-release 内的变量
load_os_release() {
  [ -r /etc/os-release ] || die "未找到 /etc/os-release，无法识别系统版本"
  # shellcheck disable=SC1091
  . /etc/os-release
}

# detect_install_mode
# 说明：识别当前系统安装方式（APT 或 RPM），并导出后续安装/镜像选择所需变量。
# 输出（export）：
#   INSTALL_MODE  apt | rpm
#   OS_PRETTY     友好系统名称（用于日志）
#   APT_DISTRO    debian | ubuntu（仅 APT）
#   CODENAME      发行版代号（仅 APT；如 bookworm/jammy）
#   ARCH          dpkg 架构（仅 APT；如 amd64/arm64）
#   RPM_DISTRO    centos | rhel | fedora（仅 RPM）
# 返回：
#   0=成功识别；失败会调用 die 退出脚本
detect_install_mode() {
  # 输出变量：
  #   INSTALL_MODE: apt | rpm
  #   OS_PRETTY:    友好展示字符串
  #   APT_DISTRO:   debian | ubuntu（apt 模式才有）
  #   CODENAME:     版本代号（apt 模式才有）
  #   ARCH:         dpkg 架构（apt 模式才有）
  #   RPM_DISTRO:   centos | rhel | fedora（rpm 模式才有）
  #
  load_os_release
  OS_PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"

  # APT：优先根据 apt-get 判断（也支持 Debian/Ubuntu 衍生）
  if have_cmd apt-get; then
    INSTALL_MODE="apt"

    # 推断 Docker 仓库类型：Ubuntu 及衍生走 ubuntu；否则默认 debian
    APT_DISTRO="debian"
    if [ "${ID:-}" = "ubuntu" ] || printf '%s' "${ID_LIKE:-}" | grep -Eq '(^|[[:space:]])ubuntu([[:space:]]|$)'; then
      APT_DISTRO="ubuntu"
    fi

    CODENAME="${VERSION_CODENAME:-}"
    if [ -z "$CODENAME" ] && have_cmd lsb_release; then
      CODENAME="$(lsb_release -cs 2>/dev/null || true)"
    fi
    [ -n "$CODENAME" ] || die "无法识别系统代号（VERSION_CODENAME 为空），当前：$OS_PRETTY"

    need_cmd dpkg
    ARCH="$(dpkg --print-architecture)"

    export INSTALL_MODE OS_PRETTY APT_DISTRO CODENAME ARCH
    return 0
  fi

  # RPM：dnf/yum 环境
  if have_cmd dnf || have_cmd yum; then
    INSTALL_MODE="rpm"

    # 推断 Docker 仓库类型：Fedora 用 fedora；CentOS 用 centos；其它 RHEL 系用 rhel
    RPM_DISTRO="rhel"
    case "${ID:-}" in
      fedora) RPM_DISTRO="fedora" ;;
      centos) RPM_DISTRO="centos" ;;
      rhel|rocky|almalinux|ol) RPM_DISTRO="rhel" ;;
      *)
        if printf '%s' "${ID_LIKE:-}" | grep -Eq '(^|[[:space:]])fedora([[:space:]]|$)'; then
          RPM_DISTRO="fedora"
        elif printf '%s' "${ID_LIKE:-}" | grep -Eq '(^|[[:space:]])centos([[:space:]]|$)'; then
          RPM_DISTRO="centos"
        elif printf '%s' "${ID_LIKE:-}" | grep -Eq '(^|[[:space:]])rhel([[:space:]]|$)'; then
          RPM_DISTRO="rhel"
        fi
        ;;
    esac

    export INSTALL_MODE OS_PRETTY RPM_DISTRO
    return 0
  fi

  die "未检测到 apt-get 或 dnf/yum，暂不支持该系统：$OS_PRETTY"
}

# -----------------------------------------------------------------------------
# 镜像选择：根据系统类型组装候选 base URL，并探测可用项
# -----------------------------------------------------------------------------
# normalize_mirror_override
# 说明：统一镜像覆盖参数（兼容旧变量名 DOCKER_APT_MIRROR）。
# 规则：
#   - 若 DOCKER_REPO_BASE 未设置但 DOCKER_APT_MIRROR 已设置，则将其迁移到 DOCKER_REPO_BASE
# 副作用：
#   可能修改 DOCKER_REPO_BASE
normalize_mirror_override() {
  # 兼容旧变量名：DOCKER_APT_MIRROR
  if [ -z "${DOCKER_REPO_BASE:-}" ] && [ -n "${DOCKER_APT_MIRROR:-}" ]; then
    DOCKER_REPO_BASE="$DOCKER_APT_MIRROR"
  fi
}

# pick_repo_base_apt
# 说明：在 APT 系统上选择 Docker 安装仓库 base URL（国内优先，失败回退官方）。
# 输入：
#   依赖变量 APT_DISTRO / CODENAME（由 detect_install_mode 导出）
#   可选覆盖 DOCKER_REPO_BASE / DOCKER_APT_MIRROR
# 输出（export）：
#   REPO_BASE  选中的仓库 base URL
pick_repo_base_apt() {
  # APT 模式：
  # - base URL 例：
  #   https://mirrors.huaweicloud.com/docker-ce/linux/debian
  #   https://download.docker.com/linux/ubuntu
  # - 可用性判断：同时能访问 gpg 与 dists/<codename>/Release
  normalize_mirror_override

  if [ -n "${DOCKER_REPO_BASE:-}" ]; then
    REPO_BASE="$DOCKER_REPO_BASE"
    log "使用手动指定的仓库：$REPO_BASE"
    export REPO_BASE
    return 0
  fi

  # 国内优先：华为云/阿里云/清华/中科大，最后回退官方
  for base in \
    "https://mirrors.huaweicloud.com/docker-ce/linux/$APT_DISTRO" \
    "https://mirrors.aliyun.com/docker-ce/linux/$APT_DISTRO" \
    "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/$APT_DISTRO" \
    "https://mirrors.ustc.edu.cn/docker-ce/linux/$APT_DISTRO" \
    "https://download.docker.com/linux/$APT_DISTRO"
  do
    log "检测 Docker APT 源：$base"
    if curl_ok "$base/gpg" && curl_ok "$base/dists/$CODENAME/Release"; then
      REPO_BASE="$base"
      break
    fi
  done

  [ -n "${REPO_BASE:-}" ] || die "未能找到可用的 Docker APT 源（可用 --mirror 或 DOCKER_REPO_BASE 手动指定）"
  log "使用 Docker APT 源：$REPO_BASE"
  export REPO_BASE
}

# pick_repo_base_rpm
# 说明：在 RPM 系统上选择 Docker 安装仓库 base URL（国内优先，失败回退官方）。
# 输入：
#   依赖变量 RPM_DISTRO（由 detect_install_mode 导出）
#   可选覆盖 DOCKER_REPO_BASE / DOCKER_APT_MIRROR
# 输出（export）：
#   REPO_BASE  选中的仓库 base URL
pick_repo_base_rpm() {
  # RPM 模式：
  # - base URL 例：
  #   https://mirrors.huaweicloud.com/docker-ce/linux/rhel
  #   https://download.docker.com/linux/fedora
  # - 可用性判断：能访问 docker-ce.repo
  normalize_mirror_override

  if [ -n "${DOCKER_REPO_BASE:-}" ]; then
    REPO_BASE="$DOCKER_REPO_BASE"
    log "使用手动指定的仓库：$REPO_BASE"
    export REPO_BASE
    return 0
  fi

  for base in \
    "https://mirrors.huaweicloud.com/docker-ce/linux/$RPM_DISTRO" \
    "https://mirrors.aliyun.com/docker-ce/linux/$RPM_DISTRO" \
    "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/$RPM_DISTRO" \
    "https://mirrors.ustc.edu.cn/docker-ce/linux/$RPM_DISTRO" \
    "https://download.docker.com/linux/$RPM_DISTRO"
  do
    log "检测 Docker RPM 源：$base"
    if curl_ok "$base/docker-ce.repo"; then
      REPO_BASE="$base"
      break
    fi
  done

  [ -n "${REPO_BASE:-}" ] || die "未能找到可用的 Docker RPM 源（可用 --mirror 或 DOCKER_REPO_BASE 手动指定）"
  log "使用 Docker RPM 源：$REPO_BASE"
  export REPO_BASE
}

# -----------------------------------------------------------------------------
# APT 安装流程（Debian/Ubuntu）
# -----------------------------------------------------------------------------
# apt_find_source_files_containing
# 说明：在 APT 源配置中查找包含指定字符串的文件列表。
# 参数：
#   $1  需要匹配的字符串（如 enterprise.proxmox.com）
# 输出：
#   每行一个文件路径（stdout）
apt_find_source_files_containing() {
  pattern="$1"

  # /etc/apt/sources.list：只认为“未注释的行”是有效源（避免已禁用仍被误判）
  if [ -f /etc/apt/sources.list ] && grep -F "$pattern" /etc/apt/sources.list 2>/dev/null | grep -qv '^[[:space:]]*#'; then
    printf '%s\n' "/etc/apt/sources.list"
  fi

  # /etc/apt/sources.list.d：APT 只读取 .list / .sources
  if [ -d /etc/apt/sources.list.d ]; then
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
      [ -f "$f" ] || continue
      if grep -F "$pattern" "$f" 2>/dev/null | grep -qv '^[[:space:]]*#'; then
        printf '%s\n' "$f"
      fi
    done
  fi
}

# apt_has_proxmox_enterprise_sources
# 说明：判断系统是否启用了 Proxmox Enterprise 源（enterprise.proxmox.com）。
# 返回：
#   0=存在，1=不存在
apt_has_proxmox_enterprise_sources() {
  files="$(apt_find_source_files_containing "enterprise.proxmox.com" 2>/dev/null || true)"
  [ -n "${files:-}" ]
}

# apt_disable_proxmox_enterprise_sources
# 说明：禁用 Proxmox Enterprise 源（enterprise.proxmox.com），避免无订阅时 apt-get update 失败。
# 行为：
#   - 对 /etc/apt/sources.list：仅注释包含 enterprise.proxmox.com 的行
#   - 对 sources.list.d 下的文件：重命名为 *.docker-sh.disabled 使 APT 忽略
#   - 所有变更都会先备份为 *.bak.docker-sh.<timestamp>
# 副作用：
#   修改 /etc/apt 目录下源文件
apt_disable_proxmox_enterprise_sources() {
  require_root

  files="$(apt_find_source_files_containing "enterprise.proxmox.com" 2>/dev/null || true)"
  [ -n "${files:-}" ] || return 0

  ts="$(date '+%Y%m%d%H%M%S' 2>/dev/null || echo 'unknown')"
  log "检测到 Proxmox Enterprise 源（enterprise.proxmox.com），开始自动禁用（会备份）…"

  for f in $files; do
    [ -f "$f" ] || continue

    backup="${f}.bak.docker-sh.${ts}"
    cp -a "$f" "$backup"

    if [ "$f" = "/etc/apt/sources.list" ]; then
      # 仅注释命中行，尽量不影响其它正常源
      tmp="$(mktemp)"
      # 规则：含 enterprise.proxmox.com 且非注释行 -> 注释，并标记来源
      sed -e '/enterprise\.proxmox\.com/ { /^[[:space:]]*#/! s/^[[:space:]]*/# docker-sh disabled (proxmox enterprise): / }' "$f" >"$tmp"
      cat "$tmp" >"$f"
      rm -f "$tmp"
      log "已处理：$f（备份：$backup）"
      continue
    fi

    # sources.list.d：直接重命名禁用，避免解析 .sources stanza 的复杂度
    disabled="${f}.docker-sh.disabled"
    if [ -f "$disabled" ]; then
      warn "已存在禁用文件：$disabled，跳过禁用：$f（备份已保存：$backup）"
      continue
    fi

    mv "$f" "$disabled"
    log "已禁用：$f -> $disabled（备份：$backup）"
  done

  log "如需恢复：把 *.docker-sh.disabled 改回原名，或用 *.bak.docker-sh.* 备份覆盖。"
}

# apt_update
# 说明：执行 apt-get update，并在检测到 Proxmox Enterprise 源时提供友好提示/可选自动修复。
# 控制：
#   - DOCKER_SH_FIX_APT=1 或 --fix-apt：自动禁用 enterprise.proxmox.com 源后再 update
# 返回：
#   0=成功，非0=失败（失败会打印排障提示）
apt_update() {
  title="${1:-更新 APT 索引}"
  export DEBIAN_FRONTEND=noninteractive

  # 若启用修复开关且命中 Proxmox Enterprise 源，则先禁用再更新
  if is_true "${DOCKER_SH_FIX_APT:-0}"; then
    if apt_has_proxmox_enterprise_sources; then
      apt_disable_proxmox_enterprise_sources || true
    fi
  else
    if apt_has_proxmox_enterprise_sources; then
      warn "检测到 Proxmox Enterprise APT 源（enterprise.proxmox.com）。无订阅环境下 apt-get update 常见报 401/未签名失败。"
      warn "可用一键修复：sudo sh docker-sh install --fix-apt"
    fi
  fi

  log "${title}…"
  if apt-get update -y; then
    return 0
  fi

  warn "apt-get update 失败：通常是系统 APT 源不可用/未签名/需要认证导致。"
  if apt_has_proxmox_enterprise_sources; then
    warn "仍检测到 Proxmox Enterprise 源（enterprise.proxmox.com），相关源文件："
    for f in $(apt_find_source_files_containing "enterprise.proxmox.com" 2>/dev/null || true); do
      warn "  - $f"
    done
    warn "建议启用自动修复：sudo sh docker-sh install --fix-apt"
  fi
  warn "请先修复 APT 源后重试（或查看 apt-get update 的具体报错仓库并禁用/替换）。"
  return 1
}

# apt_install_deps
# 说明：安装 APT 安装流程所需依赖（curl/gnupg/ca-certificates）。
# 副作用：
#   - 执行 apt-get update
#   - 安装依赖包
apt_install_deps() {
  # 依赖说明：
  # - ca-certificates：HTTPS 证书
  # - curl：下载 GPG key / 探测镜像
  # - gnupg：gpg --dearmor 生成 keyring 文件
  export DEBIAN_FRONTEND=noninteractive
  apt_update "更新 APT 索引（准备安装依赖）" || die "APT 更新失败，无法继续安装依赖"
  log "安装依赖…"
  apt-get install -y --no-install-recommends ca-certificates curl gnupg
}

# apt_remove_conflicts
# 说明：移除 Debian/Ubuntu 上可能与 docker-ce 冲突的旧包（官方推荐做法）。
# 控制：
#   DOCKER_SKIP_REMOVE_CONFLICTS=1 可跳过
# 副作用：
#   可能卸载 docker.io / containerd / runc 等包（若已安装）
apt_remove_conflicts() {
  # Docker 官方建议移除潜在冲突包，避免 containerd/runc 版本冲突导致安装失败
  if [ "${DOCKER_SKIP_REMOVE_CONFLICTS:-0}" = "1" ]; then
    warn "已设置 DOCKER_SKIP_REMOVE_CONFLICTS=1，跳过冲突包移除"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  log "移除可能冲突的旧包（如已安装则移除）…"
  apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc >/dev/null 2>&1 || true
}

# apt_setup_repo
# 说明：配置 Docker 的 APT 仓库（keyring + sources.list.d）。
# 依赖变量：
#   REPO_BASE / CODENAME / ARCH（由 pick_repo_base_apt + detect_install_mode 提供）
# 副作用：
#   - 写入 /etc/apt/keyrings/docker.gpg
#   - 写入 /etc/apt/sources.list.d/docker.list
apt_setup_repo() {
  # APT 源配置策略：
  # - keyring：/etc/apt/keyrings/docker.gpg
  # - 源文件：/etc/apt/sources.list.d/docker.list
  log "配置 Docker GPG Key 与 APT 源…"

  install -m 0755 -d /etc/apt/keyrings

  tmp_gpg="$(mktemp)"
  if ! curl -fsSL "$REPO_BASE/gpg" | gpg --dearmor >"$tmp_gpg"; then
    rm -f "$tmp_gpg"
    die "下载/转换 GPG Key 失败：$REPO_BASE/gpg"
  fi
  install -m 0644 "$tmp_gpg" /etc/apt/keyrings/docker.gpg
  rm -f "$tmp_gpg"

  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] $REPO_BASE $CODENAME stable
EOF
}

# apt_install_docker
# 说明：在 APT 系统上安装 Docker Engine 相关包（docker-ce 等）。
# 副作用：
#   - apt-get update
#   - 安装 docker-ce/docker-ce-cli/containerd.io/buildx/compose 插件
apt_install_docker() {
  export DEBIAN_FRONTEND=noninteractive
  apt_update "更新 APT 索引（准备安装 Docker）" || die "APT 更新失败，无法继续安装 Docker"
  log "安装 Docker Engine…"
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# -----------------------------------------------------------------------------
# RPM 安装流程（RHEL 系 / Fedora）
# -----------------------------------------------------------------------------
# rpm_pkg_mgr
# 说明：在 RPM 系统上选择包管理器（优先 dnf，其次 yum）。
# 输出：
#   stdout 打印 dnf 或 yum
# 返回：
#   0=成功，非0=未找到
rpm_pkg_mgr() {
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

# rpm_install_deps
# 说明：安装 RPM 安装流程所需依赖（curl/ca-certificates/gnupg2）。
# 输出（export）：
#   PKG_MGR  选中的包管理器（dnf/yum）
# 副作用：
#   安装依赖包（可能输出较多安装日志）
rpm_install_deps() {
  # 依赖说明：
  # - ca-certificates：HTTPS 证书
  # - curl：下载 repo 文件 / 探测镜像
  # - gnupg2：部分系统用于签名校验/导入（保险起见装上）
  PKG_MGR="$(rpm_pkg_mgr)" || die "未检测到 dnf 或 yum，无法继续"
  log "安装依赖（${PKG_MGR}）…"
  if ! "$PKG_MGR" install -y ca-certificates curl gnupg2; then
    "$PKG_MGR" install -y ca-certificates curl
  fi
  export PKG_MGR
}

# rpm_remove_conflicts
# 说明：移除 RPM 系统上可能与 docker-ce 冲突的旧 Docker 包（官方推荐做法）。
# 控制：
#   DOCKER_SKIP_REMOVE_CONFLICTS=1 可跳过
# 副作用：
#   可能卸载 docker/docker-engine 等旧包（若已安装）
rpm_remove_conflicts() {
  # 旧版本/发行版自带 docker 可能与 docker-ce 冲突；按官方建议尝试移除
  if [ "${DOCKER_SKIP_REMOVE_CONFLICTS:-0}" = "1" ]; then
    warn "已设置 DOCKER_SKIP_REMOVE_CONFLICTS=1，跳过冲突包移除"
    return 0
  fi

  log "移除可能冲突的旧包（如已安装则移除）…"
  "$PKG_MGR" remove -y \
    docker \
    docker-client \
    docker-client-latest \
    docker-common \
    docker-latest \
    docker-latest-logrotate \
    docker-logrotate \
    docker-engine >/dev/null 2>&1 || true
}

# rpm_setup_repo
# 说明：配置 Docker 的 RPM 仓库（下载 docker-ce.repo 到 /etc/yum.repos.d）。
# 依赖变量：
#   REPO_BASE（由 pick_repo_base_rpm 提供）
# 副作用：
#   - 写入 /etc/yum.repos.d/docker-ce.repo
#   - 尝试 rpm --import GPG key（失败不致命）
rpm_setup_repo() {
  # RPM 源配置策略：
  # - 直接下载 docker-ce.repo 到 /etc/yum.repos.d/docker-ce.repo
  # - 预先导入 GPG key，减少交互
  log "配置 Docker RPM 源…"
  mkdir -p /etc/yum.repos.d
  curl -fsSL "$REPO_BASE/docker-ce.repo" -o /etc/yum.repos.d/docker-ce.repo
  if curl_ok "$REPO_BASE/gpg"; then
    rpm --import "$REPO_BASE/gpg" >/dev/null 2>&1 || true
  fi
}

# rpm_install_docker
# 说明：在 RPM 系统上安装 Docker Engine 相关包（docker-ce 等）。
# 依赖变量：
#   PKG_MGR（由 rpm_install_deps 导出）
rpm_install_docker() {
  log "安装 Docker Engine…"
  "$PKG_MGR" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# -----------------------------------------------------------------------------
# 通用：启动服务、用户权限、验证安装
# -----------------------------------------------------------------------------
# enable_docker_service
# 说明：在 systemd 环境下启用并启动 Docker 服务（enable --now docker）。
# 兼容：
#   - 非 systemd 环境会打印警告并跳过
# 副作用：
#   可能启动 docker 服务并设置开机自启
enable_docker_service() {
  if have_cmd systemctl; then
    log "启动并设置 Docker 开机自启…"
    systemctl enable --now docker
  else
    warn "未检测到 systemctl，跳过 Docker 服务启用（可能不是 systemd 环境）"
  fi
}

# add_user_to_docker_group
# 说明：如果通过 sudo 执行脚本，则尝试把原始用户加入 docker 组，方便免 sudo 使用 docker。
# 注意：
#   - 需要重新登录/重新打开终端才会生效
#   - 仅在系统存在 docker 组且存在 usermod 时执行
add_user_to_docker_group() {
  # 仅在通过 sudo 运行时尝试把原用户加入 docker 组
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    if have_cmd getent && getent group docker >/dev/null 2>&1; then
      if have_cmd usermod; then
        usermod -aG docker "$SUDO_USER" || true
        log "已将用户 $SUDO_USER 加入 docker 组（需重新登录后生效）"
      fi
    fi
  fi
}

# verify_install
# 说明：验证 docker 与 docker compose 插件是否可用。
# 返回：
#   若 docker 命令缺失将直接退出（need_cmd）
verify_install() {
  log "验证安装："
  need_cmd docker
  docker --version
  docker compose version 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Docker 配置：代理与镜像站（registry-mirrors）
# -----------------------------------------------------------------------------
# detect_pkg_mgr
# 说明：探测当前系统可用的包管理器（用于自动安装缺失依赖）。
# 输出：
#   stdout 打印 apt-get | dnf | yum
# 返回：
#   0=找到；非0=未找到
detect_pkg_mgr() {
  # 返回：apt-get | dnf | yum | 空
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

# ensure_cmd
# 说明：确保某个命令存在；若不存在则尝试用包管理器安装对应软件包。
# 参数：
#   $1  命令名（如 curl）
#   $2  APT 包名（可选，默认同命令名）
#   $3  RPM 包名（可选，默认同命令名）
# 副作用：
#   可能执行 apt-get update/install 或 dnf/yum install
ensure_cmd() {
  # 用法：ensure_cmd curl [apt 包名] [rpm 包名]
  # - 若命令不存在则尝试用包管理器安装
  cmd="$1"
  apt_pkg="${2:-$cmd}"
  rpm_pkg="${3:-$cmd}"

  if have_cmd "$cmd"; then
    return 0
  fi

  PKG_MGR="$(detect_pkg_mgr 2>/dev/null || true)"
  [ -n "${PKG_MGR:-}" ] || die "缺少命令：${cmd}（且未检测到包管理器以自动安装）"

  log "缺少命令：${cmd}，尝试安装依赖（${PKG_MGR}）…"
	  case "$PKG_MGR" in
	    apt-get)
	      export DEBIAN_FRONTEND=noninteractive
	      apt_update "更新 APT 索引（安装依赖）" || die "APT 更新失败，无法自动安装依赖：${apt_pkg}"
	      apt-get install -y --no-install-recommends "$apt_pkg"
	      ;;
    dnf)
      dnf install -y "$rpm_pkg"
      ;;
    yum)
      yum install -y "$rpm_pkg"
      ;;
    *)
      die "未知包管理器：$PKG_MGR"
      ;;
  esac

  have_cmd "$cmd" || die "依赖安装失败：$cmd"
}

# systemd_escape_env_value
# 说明：转义 systemd drop-in 中 Environment="KEY=VALUE" 的 VALUE（避免引号/反斜杠破坏语法）。
# 参数：
#   $1  原始值
# 输出：
#   转义后的值（stdout）
systemd_escape_env_value() {
  # - 反斜杠与双引号需要转义
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# docker_systemd_reload_restart
# 说明：在 systemd 环境下重载 unit 并尽量重启 Docker 服务，让配置即时生效。
# 兼容：
#   - 若 Docker 尚未安装，restart 可能失败（此处不视为致命错误）
# 副作用：
#   systemctl daemon-reload / systemctl restart docker
docker_systemd_reload_restart() {
  if ! have_cmd systemctl; then
    warn "未检测到 systemctl，无法自动重载/重启 Docker（可能不是 systemd 环境）"
    return 0
  fi

  systemctl daemon-reload
  # Docker 未安装时重启会失败，这里不强制退出，方便先写配置再安装
  systemctl restart docker >/dev/null 2>&1 || true
}

# docker_proxy_show
# 说明：展示当前 Docker daemon 代理配置（systemd drop-in + systemctl show）。
# 输出：
#   打印 proxy.conf 内容（若存在）以及 systemctl show 的 Environment 字段
docker_proxy_show() {
  if [ -f "$DOCKER_PROXY_DROPIN_PATH" ]; then
    log "当前 Docker 代理配置（${DOCKER_PROXY_DROPIN_PATH}）："
    sed -n '1,200p' "$DOCKER_PROXY_DROPIN_PATH"
  else
    log "当前未发现 Docker 代理配置（$DOCKER_PROXY_DROPIN_PATH 不存在）"
  fi

  if have_cmd systemctl; then
    log "systemctl show docker（Environment）："
    systemctl show -p Environment docker 2>/dev/null || true
  fi
}

# docker_proxy_clear
# 说明：清除 Docker daemon 代理配置（删除 systemd drop-in 文件并重载/重启）。
# 副作用：
#   删除 ${DOCKER_PROXY_DROPIN_PATH}（若存在），并尝试重启 docker 服务
docker_proxy_clear() {
  require_root
  if [ -f "$DOCKER_PROXY_DROPIN_PATH" ]; then
    log "清除 Docker 代理配置…"
    rm -f "$DOCKER_PROXY_DROPIN_PATH"
    docker_systemd_reload_restart
  else
    log "无需清除：未发现 $DOCKER_PROXY_DROPIN_PATH"
  fi
}

# docker_proxy_set
# 说明：设置 Docker daemon 代理（写入 systemd drop-in，并重载/重启 docker）。
# 参数：
#   $1  HTTP 代理（必填，如 http://127.0.0.1:7890）
#   $2  HTTPS 代理（可为空，空则默认同 $1）
#   $3  NO_PROXY 列表（逗号分隔）
# 副作用：
#   写入 ${DOCKER_PROXY_DROPIN_PATH}，并尝试重启 docker 服务
docker_proxy_set() {
  require_root
  ensure_cmd curl curl curl

  http_proxy="$1"
  https_proxy="$2"
  no_proxy="$3"

  [ -n "$http_proxy" ] || die "HTTP 代理不能为空（如需清除请用：config proxy --clear）"
  [ -n "$https_proxy" ] || https_proxy="$http_proxy"

  http_proxy_esc="$(systemd_escape_env_value "$http_proxy")"
  https_proxy_esc="$(systemd_escape_env_value "$https_proxy")"
  no_proxy_esc="$(systemd_escape_env_value "$no_proxy")"

  log "写入 Docker 代理配置（systemd drop-in）…"
  mkdir -p "$DOCKER_SYSTEMD_DROPIN_DIR"
  cat >"$DOCKER_PROXY_DROPIN_PATH" <<EOF
[Service]
Environment="HTTP_PROXY=$http_proxy_esc" "http_proxy=$http_proxy_esc" "HTTPS_PROXY=$https_proxy_esc" "https_proxy=$https_proxy_esc" "NO_PROXY=$no_proxy_esc" "no_proxy=$no_proxy_esc"
EOF

  docker_systemd_reload_restart
  log "已设置 Docker 代理。"
}

# docker_proxy_interactive
# 说明：以交互方式配置或清除 Docker daemon 代理。
# 行为：
#   - 展示当前配置
#   - 让用户输入 HTTP/HTTPS/NO_PROXY
#   - HTTP 代理留空则执行清除
docker_proxy_interactive() {
  require_root
  have_cmd systemctl || die "当前系统未检测到 systemctl，无法以 systemd drop-in 方式配置 Docker 代理"

  docker_proxy_show

  default_no_proxy="localhost,127.0.0.1,::1,*.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  prompt_line "请输入 HTTP 代理（例如：http://127.0.0.1:7890；留空表示清除）" ""
  http_proxy="$PROMPT_RESULT"
  if [ -z "$http_proxy" ]; then
    docker_proxy_clear
    return 0
  fi

  prompt_line "请输入 HTTPS 代理（留空默认同 HTTP 代理）" ""
  https_proxy="$PROMPT_RESULT"
  [ -n "$https_proxy" ] || https_proxy="$http_proxy"

  prompt_line "请输入 NO_PROXY（逗号分隔；留空使用默认）" "$default_no_proxy"
  no_proxy="$PROMPT_RESULT"

  docker_proxy_set "$http_proxy" "$https_proxy" "$no_proxy"
}

# ensure_python3
# 说明：确保系统存在 python3（用于安全编辑 JSON：/etc/docker/daemon.json）。
# 行为：
#   - 若 python3 不存在且当前为 root，则尝试通过包管理器安装
# 返回：
#   0=已具备 python3；失败会 die 退出
ensure_python3() {
  if have_cmd python3; then
    return 0
  fi
  require_root
  PKG_MGR="$(detect_pkg_mgr 2>/dev/null || true)"
  [ -n "${PKG_MGR:-}" ] || die "缺少 python3（且未检测到包管理器以自动安装）"

  log "未找到 python3，尝试安装（用于安全编辑 ${DOCKER_DAEMON_JSON_PATH}）…"
	  case "$PKG_MGR" in
	    apt-get)
	      export DEBIAN_FRONTEND=noninteractive
	      apt_update "更新 APT 索引（安装 python3）" || die "APT 更新失败，无法自动安装 python3"
	      apt-get install -y --no-install-recommends python3
	      ;;
    dnf)
      dnf install -y python3
      ;;
    yum)
      yum install -y python3
      ;;
    *)
      die "未知包管理器：$PKG_MGR"
      ;;
  esac

  have_cmd python3 || die "python3 安装失败"
}

# docker_mirrors_show
# 说明：展示 Docker daemon.json（若存在）以及 docker info 中的 Registry Mirrors。
# 输出：
#   打印 ${DOCKER_DAEMON_JSON_PATH}（若存在）与 docker info 片段
docker_mirrors_show() {
  if [ -f "$DOCKER_DAEMON_JSON_PATH" ]; then
    log "当前 Docker daemon 配置（${DOCKER_DAEMON_JSON_PATH}）："
    sed -n '1,200p' "$DOCKER_DAEMON_JSON_PATH"
  else
    log "当前未发现 ${DOCKER_DAEMON_JSON_PATH}（将视为未配置 registry-mirrors）"
  fi

  if have_cmd docker; then
    log "docker info（Registry Mirrors，可能包含实际生效值）："
    docker info 2>/dev/null | sed -n '/Registry Mirrors/,+10p' || true
  fi
}

# docker_mirrors_set
# 说明：设置（或清除）registry-mirrors，并重载/重启 docker 服务。
# 参数：
#   $@  镜像站 URL 列表；若为空则表示清除 registry-mirrors
# 副作用：
#   - 以“合并更新”的方式修改 ${DOCKER_DAEMON_JSON_PATH}
#   - 尝试重启 docker 服务使其生效
docker_mirrors_set() {
  require_root
  ensure_python3

  # 通过 python3 合并/更新 JSON，避免破坏用户已有其它配置
  python3 - "$DOCKER_DAEMON_JSON_PATH" "$@" <<'PY'
import json, os, sys

path = sys.argv[1]
mirrors = sys.argv[2:]

os.makedirs(os.path.dirname(path), exist_ok=True)

data = {}
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        try:
            data = json.load(f) or {}
        except Exception as e:
            print(f"[x] {path} 不是合法 JSON：{e}", file=sys.stderr)
            sys.exit(2)

if mirrors:
    data["registry-mirrors"] = mirrors
else:
    data.pop("registry-mirrors", None)

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False, sort_keys=True)
    f.write("\n")
os.replace(tmp, path)
print(path)
PY

  docker_systemd_reload_restart
}

# docker_mirrors_clear
# 说明：清除 registry-mirrors（等价于 docker_mirrors_set 不带参数）。
docker_mirrors_clear() {
  require_root
  log "清除 registry-mirrors…"
  docker_mirrors_set
  log "已清除 registry-mirrors。"
}

# docker_mirrors_interactive
# 说明：以交互方式配置或清除 registry-mirrors。
# 行为：
#   - 展示当前配置
#   - 让用户输入镜像站列表（空格/逗号分隔）
#   - 留空则清除
docker_mirrors_interactive() {
  require_root
  docker_mirrors_show

  prompt_line "请输入 registry-mirrors（多个用空格或逗号分隔；留空表示清除）" ""
  raw="$PROMPT_RESULT"
  raw="$(normalize_space_comma_list "$raw")"

  if [ -z "$raw" ]; then
    docker_mirrors_clear
    return 0
  fi

  # shellcheck disable=SC2086
  set -- $raw
  docker_mirrors_set "$@"
  log "已设置 registry-mirrors。"
}

# -----------------------------------------------------------------------------
# 测试：验证代理/镜像是否生效
# -----------------------------------------------------------------------------
# curl_http_code
# 说明：对指定 URL 发起一次快速请求并返回 HTTP 状态码（用于连通性探测）。
# 参数：
#   $@  curl 参数与 URL（最后一个参数通常是 URL）
# 输出：
#   stdout 打印 3 位状态码；失败时输出 000
curl_http_code() {
  # 用法：curl_http_code [curl 参数...] URL
  # 输出：http 状态码（失败返回 000）
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "$@" 2>/dev/null || true)"
  case "$code" in
    ""|000) printf '%s' "000" ;;
    *) printf '%s' "$code" ;;
  esac
}

# test_proxy_effective
# 说明：测试已配置的 Docker 代理是否“能用”（通过代理访问 Docker Registry /v2/）。
# 返回：
#   0=通过；1=失败
# 注意：
#   若未检测到代理配置文件，会打印警告并返回 0（视为“无代理也不算失败”）
test_proxy_effective() {
  ensure_cmd curl curl curl

  if [ ! -f "$DOCKER_PROXY_DROPIN_PATH" ]; then
    warn "未检测到代理配置：$DOCKER_PROXY_DROPIN_PATH"
    return 0
  fi

  # 尝试从 drop-in 提取 HTTP_PROXY（假设无空格）
  http_proxy="$(sed -n 's/.*HTTP_PROXY=\([^" ]*\).*/\1/p' "$DOCKER_PROXY_DROPIN_PATH" | head -n 1)"
  if [ -z "$http_proxy" ]; then
    warn "未能从 $DOCKER_PROXY_DROPIN_PATH 提取 HTTP_PROXY"
    return 1
  fi

  log "测试代理可用性（curl -x HTTP_PROXY -> https://registry-1.docker.io/v2/）…"
  code="$(curl_http_code -x "$http_proxy" https://registry-1.docker.io/v2/)"
  case "$code" in
    200|401)
      log "代理测试通过：HTTP $code"
      return 0
      ;;
    407)
      warn "代理需要认证：HTTP 407（能连通但需用户名/密码）"
      return 1
      ;;
    000)
      warn "代理测试失败：无法通过代理访问（HTTP 000）"
      return 1
      ;;
    *)
      warn "代理测试异常：HTTP $code"
      return 1
      ;;
  esac
}

# test_mirrors_effective
# 说明：读取 docker info 中的 Registry Mirrors，并输出镜像站列表（每行一个）。
# 输出：
#   stdout 打印镜像站 URL（每行一个）
# 返回：
#   0=正常（即使未配置也返回 0）；失败会 die 或由 python3 返回非 0
test_mirrors_effective() {
  ensure_cmd curl curl curl

  # 优先从 docker info 获取“实际生效”的 mirrors
  mirrors_json=""
  if have_cmd docker; then
    mirrors_json="$(docker info --format '{{json .RegistryConfig.Mirrors}}' 2>/dev/null || true)"
  fi

  if [ -z "$mirrors_json" ] || [ "$mirrors_json" = "null" ] || [ "$mirrors_json" = "[]" ]; then
    warn "docker info 未发现生效的 Registry Mirrors（可能未配置或 Docker 未运行）"
    return 0
  fi

  ensure_python3
  python3 - "$mirrors_json" <<'PY'
import json, sys
mirrors = json.loads(sys.argv[1])
for m in mirrors:
    print(m)
PY
}

# test_mirror_endpoints
# 说明：逐个探测镜像站的 /v2/ 端点（HTTP 200/401 视为可用）。
# 输入：
#   stdin 每行一个镜像站 URL
# 返回：
#   0=全部通过；非0=存在失败
test_mirror_endpoints() {
  # 逐个测试 /v2/ 端点（200/401 视为成功）
  ok=0
  bad=0
  while IFS= read -r mirror; do
    [ -n "$mirror" ] || continue
    m="${mirror%/}"
    log "测试镜像站：$m/v2/ …"
    code="$(curl_http_code "$m/v2/")"
    case "$code" in
      200|401)
        log "镜像站可用：HTTP $code"
        ok=$((ok + 1))
        ;;
      000)
        warn "镜像站不可达：HTTP 000"
        bad=$((bad + 1))
        ;;
      *)
        warn "镜像站可能不可用：HTTP $code"
        bad=$((bad + 1))
        ;;
    esac
  done

  log "镜像站测试汇总：OK=${ok}, FAIL=${bad}"
  [ "$bad" -eq 0 ]
}

# test_pull_image
# 说明：执行一次真实 docker pull，用于最终验证网络/代理/镜像站是否满足拉取需求。
# 参数：
#   $1  镜像名（含 tag，如 hello-world:latest）
# 返回：
#   继承 docker pull 的退出码
test_pull_image() {
  image="$1"
  need_cmd docker
  log "执行实际拉取测试：docker pull $image"
  docker pull "$image"
  log "拉取完成：$image"
}

# -----------------------------------------------------------------------------
# 自身安装/卸载：把脚本安装为可执行命令，便于“命令式启动”
# -----------------------------------------------------------------------------
# cmd_self_install
# 说明：将当前脚本复制安装为一个系统命令（默认 /usr/local/bin/docker-sh）。
# 选项：
#   --bin-dir <DIR>  安装目录（默认 /usr/local/bin）
#   --name <NAME>    命令名（默认 docker-sh）
# 副作用：
#   写入目标路径并赋予可执行权限
cmd_self_install() {
  require_root

  bin_dir="$CLI_BIN_DIR"
  name="$CLI_NAME"

  while [ $# -gt 0 ]; do
    case "$1" in
      --bin-dir)
        [ $# -ge 2 ] || die "--bin-dir 需要一个目录参数"
        bin_dir="$2"
        shift 2
        ;;
      --name)
        [ $# -ge 2 ] || die "--name 需要一个名称参数"
        name="$2"
        shift 2
        ;;
      *)
        die "未知参数：$1（self-install）"
        ;;
    esac
  done

  target="${bin_dir%/}/$name"
  [ -f "$0" ] || die "当前脚本不是从文件执行，无法 self-install（请保存为文件后再运行）"
  mkdir -p "$bin_dir"

  log "安装命令：$target"
  if have_cmd install; then
    install -m 0755 "$0" "$target"
  else
    cp -f "$0" "$target"
    chmod 0755 "$target"
  fi

  log "安装完成：现在可运行 ${name}（例如：${name} wizard）"
}

# cmd_self_uninstall
# 说明：卸载通过 cmd_self_install 安装的命令。
# 选项：
#   --bin-dir <DIR>  命令所在目录（默认 /usr/local/bin）
#   --name <NAME>    命令名（默认 docker-sh）
# 副作用：
#   删除目标文件（若存在）
cmd_self_uninstall() {
  require_root

  bin_dir="$CLI_BIN_DIR"
  name="$CLI_NAME"

  while [ $# -gt 0 ]; do
    case "$1" in
      --bin-dir)
        [ $# -ge 2 ] || die "--bin-dir 需要一个目录参数"
        bin_dir="$2"
        shift 2
        ;;
      --name)
        [ $# -ge 2 ] || die "--name 需要一个名称参数"
        name="$2"
        shift 2
        ;;
      *)
        die "未知参数：$1（self-uninstall）"
        ;;
    esac
  done

  target="${bin_dir%/}/$name"
  if [ -f "$target" ]; then
    log "卸载命令：$target"
    rm -f "$target"
    log "卸载完成。"
  else
    log "未发现已安装命令：$target"
  fi
}

# -----------------------------------------------------------------------------
# 子命令实现：install / wizard / config / test / version / help
# -----------------------------------------------------------------------------
# parse_install_args
# 说明：解析 install 子命令参数，并写入对应环境变量（目前仅 --mirror）。
# 参数：
#   $@  install 子命令参数
# 副作用：
#   可能设置 DOCKER_REPO_BASE
parse_install_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --mirror)
        [ $# -ge 2 ] || die "--mirror 需要一个 URL 参数"
        DOCKER_REPO_BASE="$2"
        shift 2
        ;;
      --fix-apt)
        DOCKER_SH_FIX_APT="1"
        shift
        ;;
      *)
        die "未知参数：$1（install）"
        ;;
    esac
  done
}

# cmd_install
# 说明：安装或更新 Docker Engine（自动识别 APT/RPM 并选择国内镜像源）。
# 参数：
#   $@  install 选项（例如 --mirror <URL>）
# 副作用：
#   - 配置 Docker 安装仓库（APT: keyring + sources；RPM: docker-ce.repo）
#   - 安装 docker-ce 等组件
#   - 尝试启用并启动 docker 服务
cmd_install() {
  parse_install_args "$@"
  require_root

  detect_install_mode
  log "系统识别：${OS_PRETTY}（mode=${INSTALL_MODE}）"

  if [ "$INSTALL_MODE" = "apt" ]; then
    apt_install_deps
    pick_repo_base_apt
    apt_remove_conflicts
    apt_setup_repo
    apt_install_docker
  else
    rpm_install_deps
    pick_repo_base_rpm
    rpm_remove_conflicts
    rpm_setup_repo
    rpm_install_docker
  fi

  enable_docker_service
  add_user_to_docker_group
  verify_install
  log "安装完成。"
}

# cmd_config
# 说明：配置相关入口（config proxy / config mirrors / config show）。
# 参数：
#   $1  子命令：proxy | mirrors | show
#   其余参数根据子命令不同而不同（见 usage 输出）
# 副作用：
#   - proxy：写入/删除 systemd drop-in，并重启 docker
#   - mirrors：合并更新 daemon.json，并重启 docker
cmd_config() {
  sub="${1:-}"
  [ -n "$sub" ] || die "缺少子命令：config proxy|mirrors|show"
  shift || true

  case "$sub" in
    proxy)
      mode="interactive"
      http_proxy=""
      https_proxy=""
      no_proxy=""
      clear="0"

      while [ $# -gt 0 ]; do
        case "$1" in
          --interactive)
            mode="interactive"
            shift
            ;;
          --clear)
            clear="1"
            shift
            ;;
          --http)
            [ $# -ge 2 ] || die "--http 需要一个 URL 参数"
            mode="noninteractive"
            http_proxy="$2"
            shift 2
            ;;
          --https)
            [ $# -ge 2 ] || die "--https 需要一个 URL 参数"
            mode="noninteractive"
            https_proxy="$2"
            shift 2
            ;;
          --no-proxy)
            [ $# -ge 2 ] || die "--no-proxy 需要一个 LIST 参数"
            mode="noninteractive"
            no_proxy="$2"
            shift 2
            ;;
          *)
            die "未知参数：$1（config proxy）"
            ;;
        esac
      done

      if [ "$clear" = "1" ]; then
        docker_proxy_clear
        return 0
      fi

      if [ "$mode" = "interactive" ]; then
        docker_proxy_interactive
      else
        [ -n "$no_proxy" ] || no_proxy="localhost,127.0.0.1,::1"
        docker_proxy_set "$http_proxy" "$https_proxy" "$no_proxy"
      fi
      ;;

    mirrors|mirror)
      mode="interactive"
      clear="0"
      set_list=""

      while [ $# -gt 0 ]; do
        case "$1" in
          --interactive)
            mode="interactive"
            shift
            ;;
          --clear)
            clear="1"
            shift
            ;;
          --set)
            [ $# -ge 2 ] || die "--set 需要一个 LIST 参数"
            mode="noninteractive"
            set_list="$2"
            shift 2
            ;;
          *)
            die "未知参数：$1（config mirrors）"
            ;;
        esac
      done

      if [ "$clear" = "1" ]; then
        docker_mirrors_clear
        return 0
      fi

      if [ "$mode" = "interactive" ]; then
        docker_mirrors_interactive
      else
        set_list="$(normalize_space_comma_list "$set_list")"
        if [ -z "$set_list" ]; then
          docker_mirrors_clear
          return 0
        fi
        # shellcheck disable=SC2086
        set -- $set_list
        docker_mirrors_set "$@"
      fi
      ;;

    show)
      docker_proxy_show
      docker_mirrors_show
      ;;

    *)
      die "未知子命令：config $sub"
      ;;
  esac
}

# cmd_test
# 说明：测试配置是否生效（test all|proxy|mirrors|pull）。
# 参数：
#   $1  子命令：all（默认）| proxy | mirrors | pull
# 返回：
#   子命令会尽量返回真实测试结果（pull 继承 docker pull 退出码）
cmd_test() {
  sub="${1:-all}"
  shift || true

  case "$sub" in
    all)
      log "测试 Docker 是否可用…"
      if have_cmd docker; then
        docker info >/dev/null 2>&1 && log "Docker 运行正常" || warn "Docker 可能未运行或未安装（docker info 失败）"
      else
        warn "未找到 docker 命令"
      fi

      docker_proxy_show
      test_proxy_effective || true

      # 镜像站：先拿到 mirrors 列表，再逐个测 /v2/
      if mirrors_list="$(test_mirrors_effective 2>/dev/null || true)"; then
        if [ -n "$mirrors_list" ]; then
          printf '%s\n' "$mirrors_list" | test_mirror_endpoints || true
        fi
      fi
      ;;

    proxy)
      docker_proxy_show
      test_proxy_effective
      ;;

    mirrors|mirror)
      docker_mirrors_show
      mirrors_list="$(test_mirrors_effective 2>/dev/null || true)"
      if [ -z "$mirrors_list" ]; then
        warn "未获取到 Registry Mirrors 列表（可能未配置或 Docker 未运行）"
        return 1
      fi
      printf '%s\n' "$mirrors_list" | test_mirror_endpoints
      ;;

    pull)
      image="hello-world:latest"
      while [ $# -gt 0 ]; do
        case "$1" in
          --image)
            [ $# -ge 2 ] || die "--image 需要一个镜像名"
            image="$2"
            shift 2
            ;;
          *)
            die "未知参数：$1（test pull）"
            ;;
        esac
      done
      test_pull_image "$image"
      ;;

    *)
      die "未知子命令：test ${sub}（可用：all|proxy|mirrors|pull）"
      ;;
  esac
}

# cmd_wizard
# 说明：交互式向导：引导完成安装、代理/镜像站配置与测试。
# 注意：
#   需要 /dev/tty 可用（非交互环境会退出）
cmd_wizard() {
  require_root
  tty_available || die "wizard 需要交互输入（/dev/tty 不可用）"

  # wizard 接受与 install 相同的选项（例如 --mirror / --fix-apt）
  parse_install_args "$@"

  log "进入交互式向导（wizard）…"

  if prompt_yes_no "是否安装/更新 Docker Engine？" "y"; then
    # 向导模式下：若检测到 Proxmox Enterprise 源且未启用自动修复，则先提示用户
    detect_install_mode
    if [ "$INSTALL_MODE" = "apt" ] && apt_has_proxmox_enterprise_sources && ! is_true "${DOCKER_SH_FIX_APT:-0}"; then
      warn "检测到 Proxmox Enterprise 源（enterprise.proxmox.com）。无订阅环境下 apt-get update 常见会失败。"
      if prompt_yes_no "是否自动禁用这些源并继续安装？（推荐）" "y"; then
        DOCKER_SH_FIX_APT="1"
      fi
    fi

    cmd_install
  fi

  if prompt_yes_no "是否配置 Docker daemon 代理（HTTP/HTTPS）？" "n"; then
    docker_proxy_interactive
  fi

  if prompt_yes_no "是否配置 Docker 镜像站（registry-mirrors）？" "n"; then
    docker_mirrors_interactive
  fi

  if prompt_yes_no "是否立即测试代理/镜像是否生效？" "y"; then
    cmd_test all || true
    if prompt_yes_no "是否进行实际拉取测试（docker pull hello-world）？" "n"; then
      cmd_test pull --image hello-world:latest || true
    fi
  fi

  if [ -f "$CLI_PATH" ] && prompt_yes_no "是否卸载已安装命令（${CLI_PATH}）？" "n"; then
    cmd_self_uninstall
  fi

  log "向导结束。"
}

# cmd_version
# 说明：输出脚本版本号。
cmd_version() {
  printf '%s\n' "$SCRIPT_VERSION"
}

# cmd_help
# 说明：输出帮助信息。
cmd_help() {
  usage
}

# dispatch
# 说明：顶层命令分发器（默认 install）。
# 参数：
#   $1  命令名（install/wizard/config/test/self-install/self-uninstall/version/help）
#   其余参数传递给对应子命令
dispatch() {
  cmd="${1:-install}"

  case "$cmd" in
    -h|--help|help)
      cmd_help
      ;;
    version)
      cmd_version
      ;;
    install)
      shift || true
      cmd_install "$@"
      ;;
    wizard|setup)
      shift || true
      cmd_wizard "$@"
      ;;
    config)
      shift || true
      cmd_config "$@"
      ;;
    test)
      shift || true
      cmd_test "$@"
      ;;
    self-install)
      shift || true
      cmd_self_install "$@"
      ;;
    self-uninstall)
      shift || true
      cmd_self_uninstall "$@"
      ;;
    --mirror|--fix-apt)
      # 兼容“无子命令直接传 install 选项”的用法：
      #   sudo sh docker-sh --mirror <URL>
      #   sudo sh docker-sh --fix-apt
      cmd_install "$@"
      ;;
    *)
      die "未知命令：${cmd}（使用 help 查看）"
      ;;
  esac
}

dispatch "$@"
