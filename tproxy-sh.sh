#!/bin/sh
#
# =============================================================================
#  tproxy-sh
# =============================================================================
#  一键开启/关闭“透明代理”（iptables REDIRECT）
#
#  适用场景
#  - 想让本机（以及可选：Docker 容器）所有 TCP 流量自动走代理
#  - 不想在每个应用里单独配 http_proxy / socks5
#
#  你需要先准备
#  - 一个“支持透明入站”的本机代理端口（常见：Clash 的 redir-port / sing-box 的 redirect 入站）
#  - 建议把代理进程跑在独立用户下（例如 clash 用户），脚本会自动绕过该 UID，避免回环
#
#  用法（推荐）
#    sudo sh tproxy-sh.sh enable --port 7892 --exclude-user clash
#    sudo sh tproxy-sh.sh enable --port 7892 --exclude-user clash --docker
#    sudo sh tproxy-sh.sh status
#    sudo sh tproxy-sh.sh disable
#
#  说明
#  - 本脚本默认只处理 TCP（Docker 拉镜像/apt/yum/curl 等都属于 TCP）
#  - UDP（例如部分 DNS）不在本脚本默认范围内
#
# =============================================================================

set -eu
( set -o pipefail ) 2>/dev/null && set -o pipefail

SCRIPT_VERSION="0.1.0"

DEFAULT_PORT="${TPROXY_PORT:-7892}"

CHAIN_OUT="TPROXY_SH_OUT"
CHAIN_PRE="TPROXY_SH_PRE"

# 常见保留地址/内网地址：默认不走透明代理，避免影响本地网络/路由/组播等
BYPASS_CIDRS="
0.0.0.0/8
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.168.0.0/16
198.18.0.0/15
224.0.0.0/4
240.0.0.0/4
255.255.255.255/32
"

log() { printf '%s\n' "[+] $*"; }
warn() { printf '%s\n' "[!] $*" >&2; }
die() { printf '%s\n' "[x] $*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { have_cmd "$1" || die "缺少命令：$1"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 运行（例如：sudo sh $0 ...）"
  fi
}

usage() {
  cat <<EOF
tproxy-sh v$SCRIPT_VERSION

用法：
  sudo sh $0 enable [选项]
  sudo sh $0 enable-http --proxy http://HOST:PORT [选项]
  sudo sh $0 disable
  sudo sh $0 status

enable 选项：
  --port PORT            透明入站端口（默认：$DEFAULT_PORT）
  --exclude-uid UID      不透明代理该 UID 的出站（可多次指定）
  --exclude-user USER    不透明代理该用户（可多次指定）
  --docker               同时代理 Docker/容器网络（会加 PREROUTING 规则）
  --force                跳过“端口必须在监听”的安全检查（不推荐）

enable-http 选项：
  --proxy HOST:PORT      远端 HTTP 代理（必须支持 CONNECT）
  --local-port PORT      本机 redsocks 监听端口（默认：12345）
  --user USER            上游 HTTP 代理用户名（可选）
  --pass PASS            上游 HTTP 代理密码（可选）
  --docker               同时代理 Docker/容器网络（会加 PREROUTING 规则）

示例：
  sudo sh $0 enable --port 7892 --exclude-user clash
  sudo sh $0 enable --port 7892 --exclude-user clash --docker
  sudo sh $0 enable-http --proxy 192.0.2.10:3128
  sudo sh $0 enable-http --proxy 192.0.2.10:3128 --docker
  sudo sh $0 disable
EOF
}

pkg_install() {
  if have_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "$@"
    return 0
  fi
  die "暂不支持自动安装依赖（未检测到 apt-get）。请手动安装：$*"
}

is_listen_tcp_port() {
  port="$1"
  if have_cmd ss; then
    ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -Eq ":${port}\$"
    return $?
  fi
  if have_cmd netstat; then
    netstat -lnt 2>/dev/null | awk 'NR>2{print $4}' | grep -Eq ":${port}\$"
    return $?
  fi
  return 1
}

get_listen_pid_tcp_port() {
  port="$1"
  if have_cmd ss; then
    ss -lntp 2>/dev/null \
      | awk -v p=":${port}" 'NR>1 && $4 ~ (p "$") {print; exit}' \
      | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'
    return 0
  fi
  if have_cmd netstat; then
    netstat -lntp 2>/dev/null \
      | awk -v p=":${port}" 'NR>2 && $4 ~ (p "$") {print $7; exit}' \
      | sed -n 's/^\([0-9][0-9]*\)\/.*$/\1/p'
    return 0
  fi
  return 0
}

uid_of_pid() {
  pid="$1"
  [ -n "$pid" ] || return 1
  [ -r "/proc/$pid/status" ] || return 1
  awk '/^Uid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null
}

iptables_chain_exists() {
  table="$1"
  chain="$2"
  iptables -t "$table" -L "$chain" >/dev/null 2>&1
}

iptables_ensure_chain() {
  table="$1"
  chain="$2"
  if iptables_chain_exists "$table" "$chain"; then
    iptables -t "$table" -F "$chain"
  else
    iptables -t "$table" -N "$chain"
  fi
}

iptables_insert_jump_once() {
  table="$1"
  from_chain="$2"
  jump_chain="$3"
  shift 3
  # shellcheck disable=SC2145
  if iptables -t "$table" -C "$from_chain" "$@" -j "$jump_chain" >/dev/null 2>&1; then
    return 0
  fi
  iptables -t "$table" -I "$from_chain" 1 "$@" -j "$jump_chain"
}

iptables_delete_jumps_to_chain() {
  table="$1"
  from_chain="$2"
  jump_chain="$3"

  # 用 iptables -S 反推删除参数，避免漏删（包含不同接口条件的规则）
  iptables -t "$table" -S "$from_chain" 2>/dev/null \
    | grep -F " -j $jump_chain" \
    | while IFS= read -r rule; do
        set -- $rule
        [ "${1:-}" = "-A" ] || continue
        [ "${2:-}" = "$from_chain" ] || continue
        shift 2
        # 变成：iptables -t nat -D <from_chain> <rest...>
        iptables -t "$table" -D "$from_chain" "$@" >/dev/null 2>&1 || true
      done
}

iptables_delete_chain_if_exists() {
  table="$1"
  chain="$2"
  if iptables_chain_exists "$table" "$chain"; then
    iptables -t "$table" -F "$chain" >/dev/null 2>&1 || true
    iptables -t "$table" -X "$chain" >/dev/null 2>&1 || true
  fi
}

apply_out_rules() {
  port="$1"
  exclude_uids="$2" # space-separated

  iptables_ensure_chain nat "$CHAIN_OUT"

  # 先绕过：代理进程所在 UID（避免回环）
  for uid in $exclude_uids; do
    iptables -t nat -A "$CHAIN_OUT" -m owner --uid-owner "$uid" -j RETURN
  done

  # 绕过：保留地址/内网地址
  for cidr in $BYPASS_CIDRS; do
    iptables -t nat -A "$CHAIN_OUT" -d "$cidr" -j RETURN
  done

  # 其它 TCP 流量：重定向到透明入站端口
  iptables -t nat -A "$CHAIN_OUT" -p tcp -j REDIRECT --to-ports "$port"

  # OUTPUT 链只处理 TCP
  iptables_insert_jump_once nat OUTPUT "$CHAIN_OUT" -p tcp
}

apply_pre_rules_for_ifaces() {
  port="$1"
  ifaces="$2" # space-separated, may be empty

  [ -n "$ifaces" ] || return 0

  iptables_ensure_chain nat "$CHAIN_PRE"

  for cidr in $BYPASS_CIDRS; do
    iptables -t nat -A "$CHAIN_PRE" -d "$cidr" -j RETURN
  done
  iptables -t nat -A "$CHAIN_PRE" -p tcp -j REDIRECT --to-ports "$port"

  for iface in $ifaces; do
    iptables_insert_jump_once nat PREROUTING "$CHAIN_PRE" -i "$iface" -p tcp
  done
}

list_container_ifaces() {
  # 固定名
  for x in docker0 podman0 cni0; do
    [ -d "/sys/class/net/$x" ] && printf '%s\n' "$x"
  done

  # 动态桥：br-xxxxx
  if have_cmd ip; then
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}' | grep '^br-' || true
  else
    ls /sys/class/net 2>/dev/null | grep '^br-' || true
  fi
}

strip_http_scheme() {
  s="$1"
  case "$s" in
    http://*) printf '%s' "${s#http://}" ;;
    https://*) printf '%s' "${s#https://}" ;;
    *) printf '%s' "$s" ;;
  esac
}

parse_host_port() {
  s="$1"
  # 去掉可能的路径部分（例如 http://host:port/xxx）
  s="${s%%/*}"

  case "$s" in
    *:*)
      host="${s%:*}"
      port="${s##*:}"
      ;;
    *)
      die "地址格式应为 HOST:PORT：$1"
      ;;
  esac

  [ -n "$host" ] || die "HOST 不能为空：$1"
  case "$port" in
    ''|*[!0-9]*) die "PORT 必须是数字：$1" ;;
  esac
  [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || die "PORT 范围应为 1-65535：$1"

  printf '%s\n' "$host" "$port"
}

write_redsocks_conf_http() {
  local_ip="$1"
  local_port="$2"
  upstream_host="$3"
  upstream_port="$4"
  upstream_user="${5:-}"
  upstream_pass="${6:-}"

  conf_path="${REDSOCKS_CONF:-/etc/redsocks.conf}"
  ts="$(date +%F_%H%M%S)"

  if [ -f "$conf_path" ]; then
    cp -a "$conf_path" "${conf_path}.bak.tproxy-sh.${ts}"
  fi

  tmp="${conf_path}.tmp.tproxy-sh.${ts}"
  {
    printf '%s\n' "base {"
    printf '%s\n' "  log_info = on;"
    printf '%s\n' "  daemon = on;"
    printf '%s\n' "  redirector = iptables;"
    printf '%s\n' "}"
    printf '\n'
    printf '%s\n' "redsocks {"
    printf '%s\n' "  local_ip = ${local_ip};"
    printf '%s\n' "  local_port = ${local_port};"
    printf '%s\n' "  ip = ${upstream_host};"
    printf '%s\n' "  port = ${upstream_port};"
    printf '%s\n' "  type = http-connect;"
    if [ -n "$upstream_user" ] || [ -n "$upstream_pass" ]; then
      printf '%s\n' "  login = \"${upstream_user}\";"
      printf '%s\n' "  password = \"${upstream_pass}\";"
    fi
    printf '%s\n' "}"
  } >"$tmp"

  mv "$tmp" "$conf_path"
}

start_redsocks() {
  if have_cmd systemctl; then
    systemctl enable --now redsocks >/dev/null 2>&1 || true
    systemctl restart redsocks
    return 0
  fi
  if have_cmd service; then
    service redsocks restart || service redsocks start
    return 0
  fi
  warn "未检测到 systemctl/service，无法自动启动 redsocks"
  return 1
}

cmd_enable_http() {
  require_root
  need_cmd iptables

  PROXY_ADDR=""
  LOCAL_PORT="12345"
  PROXY_USER=""
  PROXY_PASS=""
  DOCKER=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --proxy)
        [ $# -ge 2 ] || die "--proxy 需要参数"
        PROXY_ADDR="$2"; shift 2 ;;
      --local-port)
        [ $# -ge 2 ] || die "--local-port 需要参数"
        LOCAL_PORT="$2"; shift 2 ;;
      --user)
        [ $# -ge 2 ] || die "--user 需要参数"
        PROXY_USER="$2"; shift 2 ;;
      --pass)
        [ $# -ge 2 ] || die "--pass 需要参数"
        PROXY_PASS="$2"; shift 2 ;;
      --docker)
        DOCKER=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "未知参数：$1（可用 --help 查看）" ;;
    esac
  done

  [ -n "$PROXY_ADDR" ] || die "enable-http 需要指定 --proxy HOST:PORT"
  case "$LOCAL_PORT" in
    ''|*[!0-9]*) die "端口必须是数字：$LOCAL_PORT" ;;
  esac
  [ "$LOCAL_PORT" -ge 1 ] 2>/dev/null && [ "$LOCAL_PORT" -le 65535 ] 2>/dev/null || die "端口范围应为 1-65535：$LOCAL_PORT"

  # 解析上游代理地址
  PROXY_ADDR="$(strip_http_scheme "$PROXY_ADDR")"
  set -- $(parse_host_port "$PROXY_ADDR")
  UP_HOST="$1"
  UP_PORT="$2"

  # 安装并配置 redsocks
  if ! have_cmd redsocks; then
    log "安装依赖：redsocks"
    pkg_install redsocks
  fi

  if [ "$DOCKER" -eq 1 ]; then
    RED_LOCAL_IP="0.0.0.0"
  else
    RED_LOCAL_IP="127.0.0.1"
  fi

  write_redsocks_conf_http "$RED_LOCAL_IP" "$LOCAL_PORT" "$UP_HOST" "$UP_PORT" "$PROXY_USER" "$PROXY_PASS"
  start_redsocks || true

  if ! is_listen_tcp_port "$LOCAL_PORT"; then
    warn "redsocks 未监听 ${LOCAL_PORT}/tcp，无法开启透明代理"
    if have_cmd systemctl; then
      systemctl status redsocks --no-pager || true
    fi
    die "请检查 /etc/redsocks.conf（上游 HTTP 代理需支持 CONNECT）"
  fi

  if [ "$DOCKER" -eq 1 ]; then
    cmd_enable --port "$LOCAL_PORT" --docker
  else
    cmd_enable --port "$LOCAL_PORT"
  fi
}

parse_enable_args() {
  PORT="$DEFAULT_PORT"
  DOCKER=0
  FORCE=0
  EXCLUDE_UIDS=""
  EXCLUDE_USERS=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --port)
        [ $# -ge 2 ] || die "--port 需要参数"
        PORT="$2"; shift 2 ;;
      --exclude-uid)
        [ $# -ge 2 ] || die "--exclude-uid 需要参数"
        EXCLUDE_UIDS="${EXCLUDE_UIDS} $2"; shift 2 ;;
      --exclude-user)
        [ $# -ge 2 ] || die "--exclude-user 需要参数"
        EXCLUDE_USERS="${EXCLUDE_USERS} $2"; shift 2 ;;
      --docker)
        DOCKER=1; shift ;;
      --force)
        FORCE=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "未知参数：$1（可用 --help 查看）" ;;
    esac
  done

  # 校验端口
  case "$PORT" in
    ''|*[!0-9]*) die "端口必须是数字：$PORT" ;;
  esac
  [ "$PORT" -ge 1 ] 2>/dev/null && [ "$PORT" -le 65535 ] 2>/dev/null || die "端口范围应为 1-65535：$PORT"

  # 解析用户 -> UID
  for u in $EXCLUDE_USERS; do
    uid="$(id -u "$u" 2>/dev/null || true)"
    [ -n "$uid" ] || die "找不到用户：$u"
    EXCLUDE_UIDS="${EXCLUDE_UIDS} $uid"
  done

  # 去重（简单处理）
  if [ -n "$EXCLUDE_UIDS" ]; then
    EXCLUDE_UIDS="$(printf '%s\n' $EXCLUDE_UIDS | awk '!seen[$0]++' | tr '\n' ' ')"
  fi
}

cmd_enable() {
  require_root
  need_cmd iptables

  parse_enable_args "$@"

  if [ "$FORCE" -ne 1 ]; then
    if ! is_listen_tcp_port "$PORT"; then
      die "本机未监听 ${PORT}/tcp。开启透明代理会直接断网；请先启动代理，或加 --force 跳过检查。"
    fi
  fi

  # 自动绕过透明代理端口的监听进程 UID（尽量避免回环）
  # 注意：如果代理进程是 root（UID=0），这里不会自动加入绕过（否则会导致大量 root 流量不走代理）。
  # 建议把代理进程跑在独立用户下，再用 --exclude-user 指定。
  if [ -z "$(printf '%s' "$EXCLUDE_UIDS" | tr -d ' ')" ]; then
    pid="$(get_listen_pid_tcp_port "$PORT" || true)"
    uid="$(uid_of_pid "$pid" || true)"
    if [ -n "$uid" ] && [ "$uid" -ne 0 ]; then
      EXCLUDE_UIDS="$uid"
      log "自动绕过 UID=$uid（监听 ${PORT}/tcp 的进程）"
    elif [ -n "$uid" ] && [ "$uid" -eq 0 ]; then
      warn "检测到监听 ${PORT}/tcp 的进程为 root（UID=0）。建议把代理进程改为独立用户运行，然后用 --exclude-user 指定。"
    fi
  fi

  # 幂等：先清理旧规则再写入
  cmd_disable_internal >/dev/null 2>&1 || true

  apply_out_rules "$PORT" "$EXCLUDE_UIDS"

  if [ "$DOCKER" -eq 1 ]; then
    ifaces="$(list_container_ifaces | tr '\n' ' ')"
    if [ -z "$(printf '%s' "$ifaces" | tr -d ' ')" ]; then
      warn "未发现 docker0/br-*/cni0 等容器网卡，已跳过 PREROUTING 规则"
    else
      apply_pre_rules_for_ifaces "$PORT" "$ifaces"
      log "已启用容器流量透明代理（接口：$ifaces）"
    fi
  fi

  log "已开启透明代理：TCP -> 127.0.0.1:$PORT（关闭：sudo sh $0 disable）"
}

cmd_disable_internal() {
  need_cmd iptables

  # 先删 jump，再删 chain
  iptables_delete_jumps_to_chain nat OUTPUT "$CHAIN_OUT"
  iptables_delete_jumps_to_chain nat PREROUTING "$CHAIN_PRE"

  iptables_delete_chain_if_exists nat "$CHAIN_OUT"
  iptables_delete_chain_if_exists nat "$CHAIN_PRE"
}

cmd_disable() {
  require_root
  cmd_disable_internal
  log "已关闭透明代理"
}

cmd_status() {
  need_cmd iptables

  enabled_out=0
  enabled_pre=0

  if iptables -t nat -S OUTPUT 2>/dev/null | grep -Fq " -j $CHAIN_OUT"; then
    enabled_out=1
  fi
  if iptables -t nat -S PREROUTING 2>/dev/null | grep -Fq " -j $CHAIN_PRE"; then
    enabled_pre=1
  fi

  if [ "$enabled_out" -eq 1 ] || [ "$enabled_pre" -eq 1 ]; then
    log "已启用（OUTPUT=$enabled_out, PREROUTING=$enabled_pre）"
    return 0
  fi
  warn "未启用"
  return 1
}

main() {
  cmd="${1:-help}"
  shift || true

  case "$cmd" in
    enable) cmd_enable "$@" ;;
    enable-http) cmd_enable_http "$@" ;;
    disable) cmd_disable "$@" ;;
    status) cmd_status "$@" ;;
    -h|--help|help) usage ;;
    version) printf '%s\n' "$SCRIPT_VERSION" ;;
    *) die "未知命令：$cmd（可用：enable/disable/status/help）" ;;
  esac
}

main "$@"
