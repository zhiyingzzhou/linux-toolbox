#!/bin/sh
#
# =============================================================================
#  sysinfo-sh
# =============================================================================
#  一键输出 Linux 软硬件/驱动信息报告（尽量做到“像驱动精灵一样”的效果）
#
#  设计目标
#  - 只读：默认不修改系统
#  - 兼容：尽量适配常见发行版（Debian/Ubuntu/RHEL/Fedora/Arch/Alpine 等）
#  - 详细：硬件列表、驱动绑定、内核模块、网络/存储/图形等信息尽量齐全
#  - 降级：缺少工具时给出提示（如 lspci/lsusb/ethtool/dmidecode/lshw）
#
#  用法
#    sh sysinfo-sh.sh               # 输出文本报告（stdout）
#    sh sysinfo-sh.sh --md          # 输出 Markdown（更适合发工单/贴群里）
#    sh sysinfo-sh.sh --quick       # 只输出概览（更快）
#    sudo sh sysinfo-sh.sh --full   # 尽可能多输出（推荐）
#
#  常用示例
#    sudo sh sysinfo-sh.sh --full --md > sysinfo.md
#    sh sysinfo-sh.sh --quick > sysinfo.txt
#
# =============================================================================

set -eu
( set -o pipefail ) 2>/dev/null && set -o pipefail

SCRIPT_VERSION="0.2.0"

FORMAT="text"   # text | md
MODE="standard" # quick | standard | full
REDACT="1"      # 1=默认脱敏，0=不脱敏
SHOW_CMD="0"    # 1=显示采集命令行
COLOR_MODE="auto" # auto | on | off（仅 text）
COLOR_ON="0"

# 颜色码（由 init_color 初始化；这里先给空值，避免 set -u 报错）
C_RESET=""
C_BOLD=""
C_DIM=""
C_RED=""
C_GREEN=""
C_YELLOW=""
C_BLUE=""
C_MAGENTA=""
C_CYAN=""

DMESG_LINES="200"
JOURNAL_LINES="200"

MISSING_CMDS=""

log() { printf '%s\n' "[+] $*"; }
warn() { printf '%s\n' "[!] $*" >&2; }
die() { printf '%s\n' "[x] $*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_tty_stdout() { [ -t 1 ] 2>/dev/null; }

init_color() {
  # 仅对 text 输出启用颜色；Markdown 统一无颜色
  if [ "$FORMAT" != "text" ]; then
    COLOR_ON="0"
    return 0
  fi

  # 遵循 NO_COLOR 约定
  if [ -n "${NO_COLOR:-}" ]; then
    COLOR_ON="0"
    return 0
  fi

  case "$COLOR_MODE" in
    on|always|1|true|yes) COLOR_ON="1" ;;
    off|never|0|false|no) COLOR_ON="0" ;;
    auto|*)
      if is_tty_stdout; then COLOR_ON="1"; else COLOR_ON="0"; fi
      ;;
  esac

  if [ "$COLOR_ON" = "1" ]; then
    C_RESET="$(printf '\033[0m')"
    C_BOLD="$(printf '\033[1m')"
    C_DIM="$(printf '\033[2m')"
    C_RED="$(printf '\033[31m')"
    C_GREEN="$(printf '\033[32m')"
    C_YELLOW="$(printf '\033[33m')"
    C_BLUE="$(printf '\033[34m')"
    C_MAGENTA="$(printf '\033[35m')"
    C_CYAN="$(printf '\033[36m')"
  else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_MAGENTA=""
    C_CYAN=""
  fi
}

status_tag() {
  level="$1"
  case "$level" in
    ok) printf '%s[OK]%s' "${C_GREEN}" "${C_RESET}" ;;
    warn) printf '%s[WARN]%s' "${C_YELLOW}" "${C_RESET}" ;;
    bad) printf '%s[FAIL]%s' "${C_RED}" "${C_RESET}" ;;
    info|*) printf '%s[INFO]%s' "${C_CYAN}" "${C_RESET}" ;;
  esac
}

append_missing_cmd() {
  cmd="$1"
  case " $MISSING_CMDS " in
    *" $cmd "*) return 0 ;;
  esac
  MISSING_CMDS="${MISSING_CMDS}${MISSING_CMDS:+ }$cmd"
}

usage() {
  cat <<EOF
sysinfo-sh v$SCRIPT_VERSION

用法：
  sh $0 [选项]

选项：
  --md                 输出 Markdown
  --text               输出纯文本（默认）
  --quick              只输出概览（更快）
  --full               输出尽可能多的信息（可能需要 root）
  --no-redact          不脱敏（会包含 MAC/序列号/UUID 等敏感信息）
  --color              强制启用颜色（仅 text）
  --no-color           禁用颜色（仅 text；也可用环境变量 NO_COLOR=1）
  --show-cmd           在报告中显示采集命令
  --dmesg-lines N      dmesg 最多输出行数（默认：$DMESG_LINES）
  --journal-lines N    journalctl 最多输出行数（默认：$JOURNAL_LINES）
  --version, -v        显示版本
  --help, -h           显示帮助

示例：
  sudo sh $0 --full --md > sysinfo.md
  sh $0 --quick > sysinfo.txt
EOF
}

is_linux() { [ "$(uname -s 2>/dev/null || true)" = "Linux" ]; }
is_root() { [ "$(id -u 2>/dev/null || printf '1')" -eq 0 ]; }

now_iso() { date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date; }

read_os_release() {
  key="$1"
  [ -r /etc/os-release ] || return 1
  # shellcheck disable=SC2002
  cat /etc/os-release 2>/dev/null | sed -n "s/^${key}=//p" | head -n 1 | sed 's/^\"//; s/\"$//'
}

redact_mac() {
  mac="${1:-}"
  if [ "$REDACT" != "1" ]; then
    printf '%s' "$mac"
    return 0
  fi
  # 保留前 3 段（OUI），后 3 段打码：aa:bb:cc:xx:xx:xx
  printf '%s' "$mac" | awk -F: '
    BEGIN{OFS=":"}
    NF==6{
      $4="xx"; $5="xx"; $6="xx";
      print; next
    }
    {print}
  '
}

redact_id() {
  v="${1:-}"
  if [ "$REDACT" != "1" ]; then
    printf '%s' "$v"
    return 0
  fi
  [ -n "$v" ] || { printf '%s' "$v"; return 0; }
  printf '%s' "<REDACTED>"
}

print_title() {
  title="$1"
  if [ "$FORMAT" = "md" ]; then
    printf '# %s\n\n' "$title"
  else
    printf '%s%s%s\n' "${C_BOLD}${C_CYAN}" "$title" "${C_RESET}"
    printf '%s%s%s\n' "${C_DIM}" "============================================================================== " "${C_RESET}"
  fi
}

section() {
  title="$1"
  if [ "$FORMAT" = "md" ]; then
    printf '## %s\n\n' "$title"
  else
    printf '\n%s%s%s\n' "${C_BOLD}${C_BLUE}" "== $title ==" "${C_RESET}"
  fi
}

kv() {
  k="$1"
  v="$2"
  if [ "$FORMAT" = "md" ]; then
    printf -- '- **%s**: %s\n' "$k" "$v"
  else
    # 24 列对齐
    printf '%-24s %s\n' "$k:" "$v"
  fi
}

hr_md() {
  [ "$FORMAT" = "md" ] || return 0
  printf '\n---\n\n'
}

cmd_block() {
  title="$1"
  shift
  cmd="$1"
  shift || true

  if ! have_cmd "$cmd"; then
    append_missing_cmd "$cmd"
    kv "$title" "(缺少命令：$cmd)"
    return 0
  fi

  if [ "$MODE" = "quick" ]; then
    kv "$title" "(已跳过：--quick)"
    return 0
  fi

  section "$title"
  if [ "$SHOW_CMD" = "1" ]; then
    if [ "$FORMAT" = "md" ]; then
      printf '`%s`\n\n' "$cmd $*"
    else
      printf '%s\n' "\$ $cmd $*"
    fi
  fi

  if [ "$FORMAT" = "md" ]; then
    printf '```text\n'
    "$cmd" "$@" 2>&1 || true
    printf '```\n\n'
  else
    "$cmd" "$@" 2>&1 || true
  fi
}

file_block() {
  title="$1"
  path="$2"
  if [ "$MODE" = "quick" ]; then
    kv "$title" "(已跳过：--quick)"
    return 0
  fi
  section "$title"
  if [ ! -r "$path" ]; then
    if [ "$FORMAT" = "md" ]; then
      printf '_无法读取：%s_\n\n' "$path"
    else
      printf '%s\n' "无法读取：$path"
    fi
    return 0
  fi
  if [ "$FORMAT" = "md" ]; then
    printf '```text\n'
    cat "$path" 2>/dev/null || true
    printf '```\n\n'
  else
    cat "$path" 2>/dev/null || true
  fi
}

safe_head() {
  n="$1"
  shift
  "$@" 2>&1 | head -n "$n" || true
}

safe_tail() {
  n="$1"
  shift
  "$@" 2>&1 | tail -n "$n" || true
}

uptime_pretty() {
  if have_cmd uptime; then
    if uptime -p >/dev/null 2>&1; then
      uptime -p 2>/dev/null || true
      return 0
    fi
  fi
  if [ -r /proc/uptime ]; then
    sec="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || true)"
    [ -n "${sec:-}" ] || return 0
    d=$((sec/86400))
    h=$(((sec%86400)/3600))
    m=$(((sec%3600)/60))
    if [ "$d" -gt 0 ]; then
      printf '%sd %sh %sm' "$d" "$h" "$m"
      return 0
    fi
    if [ "$h" -gt 0 ]; then
      printf '%sh %sm' "$h" "$m"
      return 0
    fi
    printf '%sm' "$m"
  fi
}

get_first_line() {
  # 读取文件第一行（去掉末尾换行）
  path="$1"
  [ -r "$path" ] || return 1
  head -n 1 "$path" 2>/dev/null || true
}

get_cpu_model() {
  if have_cmd lscpu; then
    v="$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1)"
    [ -n "${v:-}" ] && { printf '%s' "$v"; return 0; }
  fi
  if [ -r /proc/cpuinfo ]; then
    v="$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n 1)"
    [ -n "${v:-}" ] && { printf '%s' "$v"; return 0; }
    v="$(sed -n 's/^Hardware[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n 1)"
    [ -n "${v:-}" ] && { printf '%s' "$v"; return 0; }
  fi
  printf '%s' "未知"
}

get_mem_total_human() {
  if have_cmd free; then
    free -h 2>/dev/null | awk '/^Mem:/{print $2; exit}'
    return 0
  fi
  if [ -r /proc/meminfo ]; then
    kb="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    [ -n "${kb:-}" ] || return 0
    # 近似换算：KiB -> GiB
    awk -v kb="$kb" 'BEGIN{printf "%.1fGiB", kb/1024/1024}'
  fi
}

get_swap_total_human() {
  if have_cmd free; then
    free -h 2>/dev/null | awk '/^Swap:/{print $2; exit}'
    return 0
  fi
  if [ -r /proc/meminfo ]; then
    kb="$(awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    [ -n "${kb:-}" ] || return 0
    awk -v kb="$kb" 'BEGIN{printf "%.1fGiB", kb/1024/1024}'
  fi
}

get_disks_short() {
  # 输出示例：nvme0n1 476.9G Samsung...; sda 931.5G WDC... ...(+2)
  if ! have_cmd lsblk; then
    return 0
  fi

  out="$(lsblk -d -e7 -o NAME,SIZE,MODEL 2>/dev/null || true)"
  if [ -n "${out:-}" ]; then
    printf '%s\n' "$out" | awk '
      function trim(s){sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s}
      function trunc(s,n){ if (length(s)>n) return substr(s,1,n-3) "..."; return s}
      NR==1 && $1=="NAME" {next}
      {
        name=$1; size=$2;
        $1=""; $2="";
        sub(/^[ \t]+/, "", $0);
        model=trim($0);
        if (model=="" || model=="-") part=name " " size;
        else part=name " " size " " trunc(model, 24);
        count++;
        if (count<=2) arr[count]=part;
      }
      END{
        if (count==0) exit 1;
        s=arr[1];
        if (count>=2) s=s"; " arr[2];
        if (count>2) s=s " ...(+ " (count-2) ")";
        print s;
      }
    ' 2>/dev/null || true
    return 0
  fi

  # fallback：解析默认 lsblk 列（NAME ... SIZE ...）
  out="$(lsblk -d -e7 2>/dev/null || true)"
  [ -n "${out:-}" ] || return 0
  printf '%s\n' "$out" | awk '
    NR==1 && $1=="NAME" {next}
    {
      name=$1; size=$4;
      if (name=="" || size=="") next;
      count++;
      if (count<=2) arr[count]=name " " size;
    }
    END{
      if (count==0) exit 1;
      s=arr[1];
      if (count>=2) s=s"; " arr[2];
      if (count>2) s=s " ...(+ " (count-2) ")";
      print s;
    }
  ' 2>/dev/null || true
}

get_disk_total_human() {
  # 物理盘总容量（近似；以 lsblk 的磁盘 SIZE 汇总）
  if ! have_cmd lsblk; then
    return 0
  fi
  bytes="$(lsblk -b -d -e7 -n -o SIZE 2>/dev/null | awk '{sum+=$1} END{if (sum>0) print sum}' || true)"
  [ -n "${bytes:-}" ] || return 0
  awk -v b="$bytes" '
    function human(x){
      split("B KB MB GB TB PB EB", u, " ");
      i=1;
      while (x>=1024 && i<7){ x/=1024; i++; }
      if (i==1) return sprintf("%d%s", x, u[i]);
      return sprintf("%.1f%s", x, u[i]);
    }
    BEGIN{print human(b)}
  ' 2>/dev/null || true
}

get_disk_summary() {
  # 优先：总容量 + 前两块盘的名称/大小/型号
  total="$(get_disk_total_human 2>/dev/null || true)"
  short="$(get_disks_short 2>/dev/null || true)"
  if [ -n "${total:-}" ] && [ -n "${short:-}" ]; then
    printf '总 %s（%s）' "$total" "$short"
    return 0
  fi
  if [ -n "${short:-}" ]; then
    printf '%s' "$short"
    return 0
  fi
  # 退化：至少给根分区容量（不等同于整盘，但总比没有强）
  if have_cmd df; then
    df -h / 2>/dev/null | awk 'NR==2{print $2"（根分区容量）"; exit}' || true
    return 0
  fi
  printf '%s' "-"
}

get_root_fs() {
  if have_cmd df; then
    df -Th / 2>/dev/null | awk 'NR==2{print $2" "$3"/"$4" used="$6; exit}'
  fi
}

get_gpu_summary() {
  if have_cmd lspci; then
    # VGA/3D/Display
    lspci 2>/dev/null | grep -E 'VGA compatible controller|3D controller|Display controller' | head -n 1 || true
    return 0
  fi
  printf '%s' "（建议安装 pciutils 获取 GPU 详情）"
}

clean_lspci_desc() {
  # 输入：lspci 的整行
  # 输出：尽量短、可读的描述（去掉 bus id / class 前缀 / rev）
  line="${1:-}"
  printf '%s\n' "$line" | awk '{
    $1=""
    sub(/^[[:space:]]+/, "", $0)
    sub(/ \\(rev [^)]*\\)$/, "", $0)
    sub(/^[^:]*:[[:space:]]*/, "", $0)
    print
  }'
}

get_gpu_desc_short() {
  if ! have_cmd lspci; then
    return 0
  fi
  line="$(lspci 2>/dev/null | grep -E 'VGA compatible controller|3D controller|Display controller' | head -n 1 || true)"
  [ -n "${line:-}" ] || return 0
  clean_lspci_desc "$line"
}

get_gpu_driver_in_use() {
  if ! have_cmd lspci; then
    return 0
  fi
  # 只取第一个 GPU/显示设备块里的 driver in use
  lspci -nnk 2>/dev/null | awk '
    BEGIN{in_block=0}
    /^[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]\\./{
      if ($0 ~ /(VGA compatible controller|3D controller|Display controller)/) {in_block=1; next}
      if (in_block==1) {exit}
    }
    in_block==1 && /Kernel driver in use:/{
      sub(/^[[:space:]]*Kernel driver in use:[[:space:]]*/, "", $0)
      print $0
      exit
    }
  '
}

default_route_summary() {
  if have_cmd ip; then
    ip route show default 2>/dev/null | head -n 1 || true
    return 0
  fi
  if have_cmd route; then
    route -n 2>/dev/null | awk 'NR==3{print; exit}' || true
  fi
}

dns_summary() {
  if [ -r /etc/resolv.conf ]; then
    awk '/^nameserver[[:space:]]+/{print $2}' /etc/resolv.conf 2>/dev/null | head -n 5 || true
  fi
}

print_how_to_read() {
  [ "$FORMAT" = "text" ] || return 0
  section "怎么看（先看这几行就够了）"
  printf '%s\n' "1) 先看【一眼结论】：CPU/内存/磁盘/GPU/网卡是否识别正常。"
  printf '%s\n' "2) 再看【硬件->驱动绑定】：driver=正在使用的内核驱动（最关键）。"
  printf '%s\n' "3) 有异常看【可能问题】：自动从 dmesg/journal 里扫描固件缺失/驱动报错/I/O 错误。"
  printf '%s\n' "4) 需要发工单/贴群：用 --md；需要原始细节：用 --full。"
}

print_summary() {
  section "一眼结论"

  kv "生成时间" "$(now_iso)"
  kv "主机名" "$(hostname 2>/dev/null || true)"
  kv "当前用户" "$(id -un 2>/dev/null || true) (uid=$(id -u 2>/dev/null || true))"
  if is_root; then
    kv "权限" "root（完整信息）"
  else
    kv "权限" "非 root（部分信息可能缺失，建议 sudo --full）"
  fi

  os_pretty="$(read_os_release PRETTY_NAME 2>/dev/null || true)"
  [ -n "${os_pretty:-}" ] || os_pretty="$(uname -s 2>/dev/null || true)"
  kv "系统" "$os_pretty"
  kv "内核" "$(uname -r 2>/dev/null || true)"
  kv "架构" "$(uname -m 2>/dev/null || true)"
  kv "运行时长" "$(uptime_pretty 2>/dev/null || true)"

  virt=""
  if have_cmd systemd-detect-virt; then
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    [ -n "${virt:-}" ] && kv "虚拟化" "$virt"
  fi

  kv "CPU" "$(get_cpu_model 2>/dev/null || true)"
  if have_cmd nproc; then
    kv "CPU 线程" "$(nproc 2>/dev/null || true)"
  fi
  kv "内存" "$(get_mem_total_human 2>/dev/null || true)"
  kv "交换分区" "$(get_swap_total_human 2>/dev/null || true)"
  kv "硬盘" "$(get_disk_summary 2>/dev/null || true)"
  kv "根分区" "$(get_root_fs 2>/dev/null || true)"
  gpu_desc="$(get_gpu_desc_short 2>/dev/null || true)"
  [ -n "${gpu_desc:-}" ] || gpu_desc="$(get_gpu_summary 2>/dev/null || true)"
  kv "GPU" "$gpu_desc"
  gpu_drv="$(get_gpu_driver_in_use 2>/dev/null || true)"
  [ -n "${gpu_drv:-}" ] && kv "GPU 驱动" "$gpu_drv"

  kv "默认路由" "$(default_route_summary 2>/dev/null || true)"
  dns="$(dns_summary 2>/dev/null | tr '\n' ' ' || true)"
  [ -n "${dns:-}" ] && kv "DNS" "$dns"

  hr_md
}

lspci_key_bindings_tsv() {
  # 输出：类别 \t 设备描述 \t driver \t modules
  lspci -nnk 2>/dev/null | awk '
    function trim(s){gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s}
    function clean_dev(line){
      sub(/^[0-9a-fA-F:.]+[[:space:]]+/, "", line)
      sub(/ \\(rev [^)]*\\)$/, "", line)
      sub(/^[^:]*:[[:space:]]*/, "", line)
      return line
    }
    function category(line){
      if (line ~ /(VGA compatible controller|3D controller|Display controller)/) return "GPU"
      if (line ~ /Ethernet controller/) return "有线网卡"
      if (line ~ /Network controller/) return "无线网卡"
      if (line ~ /Non-Volatile memory controller/) return "NVMe"
      if (line ~ /(SATA controller|RAID bus controller|Serial Attached SCSI controller|IDE interface|Mass storage controller)/) return "存储控制器"
      if (line ~ /Audio device/) return "音频"
      if (line ~ /USB controller/) return "USB 控制器"
      return ""
    }
    function flush(){
      if (devline=="") return
      c = category(devline)
      if (c=="") {devline=""; drv=""; mods=""; return}
      d = clean_dev(devline)
      drv = trim(drv); mods = trim(mods)
      if (drv=="") drv="-"
      if (mods=="") mods="-"
      print c "\t" d "\t" drv "\t" mods
      devline=""; drv=""; mods=""
    }
    /^[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]\\./{flush(); devline=$0; next}
    /Kernel driver in use:/{sub(/^[[:space:]]*Kernel driver in use:[[:space:]]*/, "", $0); drv=$0; next}
    /Kernel modules:/{sub(/^[[:space:]]*Kernel modules:[[:space:]]*/, "", $0); mods=$0; next}
    END{flush()}
  '
}

print_key_device_bindings() {
  section "硬件 -> 驱动绑定（重点）"

  if ! have_cmd lspci; then
    append_missing_cmd "lspci"
    kv "提示" "缺少 lspci（建议安装 pciutils），无法生成驱动绑定摘要"
    return 0
  fi

  if [ "$FORMAT" = "text" ]; then
    printf '%s%s%s\n' "${C_DIM}" "说明：driver=正在使用的内核驱动（最关键）；modules=可用模块（不一定已加载）" "${C_RESET}"
  else
    printf '%s\n\n' "说明：driver=正在使用的内核驱动（最关键）；modules=可用模块（不一定已加载）"
  fi

  rows="$(lspci_key_bindings_tsv 2>/dev/null || true)"
  if [ -z "${rows:-}" ]; then
    kv "结果" "未识别到关键设备（或 lspci 输出异常）"
    return 0
  fi

  if [ "$FORMAT" = "md" ]; then
    printf '```text\n'
  fi

  printf '%-10s %-54s %-18s %s\n' "类别" "设备" "driver(in use)" "modules"
  printf '%-10s %-54s %-18s %s\n' "----------" "------------------------------------------------------" "------------------" "-----------------------------"
  printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r cat desc drv mods; do
    # 设备描述太长会影响可读性：截断到 54 列
    desc_short="$(printf '%s\n' "$desc" | awk '{if(length($0)>54) print substr($0,1,51) "..."; else print $0}')"
    drv_show="$drv"
    # 给“缺少 driver”的条目标注
    if [ "$drv" = "-" ] || [ -z "${drv:-}" ]; then
      if [ "$FORMAT" = "text" ]; then
        drv_show="$(status_tag warn) -"
      else
        drv_show="-"
      fi
    else
      if [ "$FORMAT" = "text" ]; then
        drv_show="$(status_tag ok) $drv"
      else
        drv_show="$drv"
      fi
    fi
    if [ "$FORMAT" = "text" ]; then
      # 注意：这里不做严格列对齐（有颜色码）；以可读性优先
      printf '%-10s %-54s %-18s %s\n' "$cat" "$desc_short" "$drv_show" "$mods"
    else
      printf '%-10s %-54s %-18s %s\n' "$cat" "$desc_short" "$drv_show" "$mods"
    fi
  done

  if [ "$FORMAT" = "md" ]; then
    printf '```\n\n'
  fi
}

iface_operstate() {
  iface="$1"
  if [ -r "/sys/class/net/$iface/operstate" ]; then
    cat "/sys/class/net/$iface/operstate" 2>/dev/null | head -n 1 || true
  fi
}

iface_speed_mbps() {
  iface="$1"
  if [ -r "/sys/class/net/$iface/speed" ]; then
    s="$(cat "/sys/class/net/$iface/speed" 2>/dev/null | head -n 1 || true)"
    case "${s:-}" in
      ""|-1) printf '%s' "-" ;;
      *) printf '%sMb/s' "$s" ;;
    esac
  else
    printf '%s' "-"
  fi
}

iface_driver_name() {
  iface="$1"
  if have_cmd ethtool; then
    d="$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver:/{print $2; exit}' || true)"
    [ -n "${d:-}" ] && { printf '%s' "$d"; return 0; }
  fi
  # sysfs fallback
  if [ -L "/sys/class/net/$iface/device/driver/module" ]; then
    if have_cmd readlink; then
      m="$(readlink "/sys/class/net/$iface/device/driver/module" 2>/dev/null || true)"
      [ -n "${m:-}" ] && printf '%s' "$(printf '%s' "$m" | awk -F/ '{print $NF}')"
      return 0
    fi
  fi
  printf '%s' "-"
}

print_network_brief() {
  section "网络（重点）"
  ifaces="$(list_net_ifaces 2>/dev/null || true)"
  if [ -z "${ifaces:-}" ]; then
    kv "结果" "未检测到网卡接口"
    return 0
  fi

  if [ "$FORMAT" = "md" ]; then
    printf '```text\n'
  fi

  printf '%-12s %-8s %-10s %-16s %s\n' "接口" "状态" "速度" "驱动" "MAC(脱敏)"
  printf '%-12s %-8s %-10s %-16s %s\n' "------------" "--------" "----------" "----------------" "-----------------"
  for iface in $ifaces; do
    [ "$iface" = "lo" ] && continue
    st="$(iface_operstate "$iface" 2>/dev/null || true)"
    [ -n "${st:-}" ] || st="-"
    sp="$(iface_speed_mbps "$iface" 2>/dev/null || true)"
    dr="$(iface_driver_name "$iface" 2>/dev/null || true)"
    mac="$(iface_mac "$iface" 2>/dev/null || true)"
    [ -n "${mac:-}" ] && mac="$(redact_mac "$mac")"
    [ -n "${mac:-}" ] || mac="-"
    if [ "$FORMAT" = "text" ]; then
      case "$st" in
        up) st="${C_GREEN}up${C_RESET}" ;;
        down) st="${C_YELLOW}down${C_RESET}" ;;
      esac
    fi
    printf '%-12s %-8s %-10s %-16s %s\n' "$iface" "$st" "$sp" "$dr" "$mac"
  done

  if [ "$FORMAT" = "md" ]; then
    printf '```\n\n'
  fi

  if ! have_cmd ethtool; then
    append_missing_cmd "ethtool"
  fi
}

print_storage_brief() {
  section "磁盘（重点）"
  if ! have_cmd lsblk; then
    append_missing_cmd "lsblk"
    kv "提示" "缺少 lsblk，无法输出磁盘摘要"
    return 0
  fi

  if [ "$FORMAT" = "text" ]; then
    printf '%s%s%s\n' "${C_DIM}" "说明：ROTA=0 通常表示 SSD；ROTA=1 通常表示机械盘（仅供参考）" "${C_RESET}"
  else
    printf '%s\n\n' "说明：ROTA=0 通常表示 SSD；ROTA=1 通常表示机械盘（仅供参考）"
  fi

  if [ "$FORMAT" = "md" ]; then
    printf '```text\n'
  fi
  # 只列出物理盘（-d），不含 loop（-e7）
  lsblk_out="$(lsblk -d -e7 -o NAME,SIZE,MODEL,TRAN,ROTA 2>/dev/null || true)"
  if [ -z "${lsblk_out:-}" ]; then
    # 兼容极简系统（BusyBox/旧 util-linux）
    lsblk_out="$(lsblk -d 2>/dev/null || lsblk 2>/dev/null || true)"
  fi
  printf '%s\n' "$lsblk_out"
  if [ "$FORMAT" = "md" ]; then
    printf '```\n\n'
  fi

  if have_cmd df; then
    df_out="$(df -Th / 2>/dev/null || true)"
    if [ -z "${df_out:-}" ]; then
      df_out="$(df -h / 2>/dev/null || true)"
    fi
    if [ "$FORMAT" = "md" ]; then printf '```text\n'; fi
    printf '%s\n' "$df_out"
    if [ "$FORMAT" = "md" ]; then printf '```\n\n'; fi
  else
    append_missing_cmd "df"
  fi
}

collect_dmesg_warn() {
  if ! have_cmd dmesg; then
    return 0
  fi
  if dmesg --help 2>/dev/null | grep -q -- '--level'; then
    dmesg --level=err,warn 2>/dev/null | tail -n "$DMESG_LINES" || true
  else
    dmesg 2>/dev/null | grep -Ei 'error|fail|firmware|segfault|timed out|i/o error|critical|panic|taint' | tail -n "$DMESG_LINES" || true
  fi
}

collect_journal_warn() {
  if ! have_cmd journalctl; then
    return 0
  fi
  journalctl -b -p warning..alert --no-pager 2>/dev/null | tail -n "$JOURNAL_LINES" || true
}

print_issue_scan() {
  section "可能问题（自动扫描）"

  dmesg_out="$(collect_dmesg_warn 2>&1 || true)"
  journal_out="$(collect_journal_warn 2>&1 || true)"

  # dmesg 常见权限问题提示
  if printf '%s\n' "$dmesg_out" | grep -qiE 'operation not permitted|not permitted'; then
    kv "dmesg" "无权限读取（可能是 kernel.dmesg_restrict=1；建议 sudo --full）"
    dmesg_out=""
  fi

  # 提取一些“更好理解”的子集
  fw_lines="$(printf '%s\n%s\n' "$dmesg_out" "$journal_out" | grep -Ei 'firmware|Direct firmware load' | head -n 30 || true)"
  io_lines="$(printf '%s\n%s\n' "$dmesg_out" "$journal_out" | grep -Ei 'I/O error|EXT4-fs error|XFS.*error|btrfs.*error' | head -n 30 || true)"
  gpu_lines="$(printf '%s\n%s\n' "$dmesg_out" "$journal_out" | grep -Ei 'amdgpu|i915|nouveau|nvidia' | head -n 30 || true)"

  any="0"
  if [ -n "${fw_lines:-}" ]; then
    any="1"
    kv "固件/firmware" "$(status_tag warn) 发现相关报错（常见原因：固件包缺失）"
    if [ "$FORMAT" = "md" ]; then printf '```text\n'; fi
    printf '%s\n' "$fw_lines"
    if [ "$FORMAT" = "md" ]; then printf '```\n\n'; fi
    if [ "$FORMAT" = "text" ]; then
      printf '%s\n' "建议：优先安装/更新 linux-firmware（或发行版对应 firmware 包），然后重启再观察。"
    else
      printf '%s\n\n' "建议：优先安装/更新 linux-firmware（或发行版对应 firmware 包），然后重启再观察。"
    fi
  fi

  if [ -n "${io_lines:-}" ]; then
    any="1"
    kv "磁盘/I-O" "$(status_tag warn) 发现 I/O/文件系统相关报错"
    if [ "$FORMAT" = "md" ]; then printf '```text\n'; fi
    printf '%s\n' "$io_lines"
    if [ "$FORMAT" = "md" ]; then printf '```\n\n'; fi
    if [ "$FORMAT" = "text" ]; then
      printf '%s\n' "建议：检查硬盘 SMART（smartctl），以及线缆/供电/磁盘健康。"
    else
      printf '%s\n\n' "建议：检查硬盘 SMART（smartctl），以及线缆/供电/磁盘健康。"
    fi
  fi

  if [ -n "${gpu_lines:-}" ]; then
    any="1"
    kv "显卡相关" "$(status_tag info) 发现显卡相关日志（不一定是错误）"
    if [ "$FORMAT" = "md" ]; then printf '```text\n'; fi
    printf '%s\n' "$gpu_lines"
    if [ "$FORMAT" = "md" ]; then printf '```\n\n'; fi
  fi

  if [ "$any" = "0" ]; then
    kv "结果" "$(status_tag ok) 未发现明显错误（基于 dmesg/journal 的节选；不代表绝对无问题）"
    if [ "$MODE" != "full" ]; then
      kv "提示" "需要更详细日志请用：sudo sh $0 --full"
    fi
  fi
}

print_os_kernel() {
  section "操作系统与内核"
  kv "PRETTY_NAME" "$(read_os_release PRETTY_NAME 2>/dev/null || true)"
  kv "ID" "$(read_os_release ID 2>/dev/null || true)"
  kv "VERSION_ID" "$(read_os_release VERSION_ID 2>/dev/null || true)"
  if have_cmd lsb_release; then
    kv "lsb_release" "$(lsb_release -ds 2>/dev/null || true)"
  else
    append_missing_cmd "lsb_release"
  fi
  kv "uname -a" "$(uname -a 2>/dev/null || true)"

  if [ "$MODE" != "quick" ]; then
    if [ -r /proc/cmdline ]; then
      kv "启动参数(/proc/cmdline)" "$(get_first_line /proc/cmdline 2>/dev/null || true)"
    fi
    if [ -r /etc/default/grub ]; then
      if [ "$FORMAT" = "md" ]; then
        printf '\n'
      else
        printf '\n'
      fi
      file_block "GRUB（如存在）" "/etc/default/grub"
    fi
  fi

  if have_cmd ps; then
    kv "PID 1" "$(ps -p 1 -o comm= 2>/dev/null || true)"
  fi

  if have_cmd sysctl; then
    if [ "$MODE" = "full" ]; then
      cmd_block "内核关键开关（节选）" sysctl \
        kernel.dmesg_restrict kernel.kptr_restrict kernel.unprivileged_bpf_disabled \
        net.ipv4.ip_forward net.ipv6.conf.all.forwarding
    fi
  else
    append_missing_cmd "sysctl"
  fi
}

print_cpu_mem() {
  section "CPU 与内存"
  kv "CPU 型号" "$(get_cpu_model 2>/dev/null || true)"
  if have_cmd lscpu; then
    cmd_block "lscpu" lscpu
  else
    append_missing_cmd "lscpu"
  fi
  if have_cmd free; then
    cmd_block "free" free -h
  else
    append_missing_cmd "free"
  fi
  if [ -r /proc/meminfo ]; then
    if [ "$MODE" = "full" ]; then
      file_block "/proc/meminfo" "/proc/meminfo"
    fi
  fi
}

print_storage() {
  section "磁盘与文件系统"
  if have_cmd lsblk; then
    if [ "$REDACT" = "1" ]; then
      # 不展示序列号（SERIAL）
      cmd_block "lsblk（脱敏）" lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,TRAN,ROTA
    else
      cmd_block "lsblk" lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL,UUID,TRAN,ROTA
    fi
  else
    append_missing_cmd "lsblk"
  fi
  if have_cmd df; then
    cmd_block "df" df -Th
  else
    append_missing_cmd "df"
  fi
  if have_cmd mount; then
    if [ "$MODE" = "full" ]; then
      cmd_block "mount" mount
    fi
  fi
  if have_cmd blkid; then
    if [ "$MODE" = "full" ]; then
      if [ "$REDACT" = "1" ]; then
        section "blkid（脱敏）"
        if [ "$FORMAT" = "md" ]; then printf '```text\n'; fi
        blkid 2>/dev/null | sed 's/ UUID=\"[^\"]*\"/ UUID=\"<REDACTED>\"/g; s/ PARTUUID=\"[^\"]*\"/ PARTUUID=\"<REDACTED>\"/g' || true
        if [ "$FORMAT" = "md" ]; then printf '```\n\n'; fi
      else
        cmd_block "blkid" blkid
      fi
    fi
  else
    append_missing_cmd "blkid"
  fi
}

print_pci_usb() {
  section "PCI/USB 设备与驱动绑定"
  if have_cmd lspci; then
    cmd_block "lspci（设备列表）" lspci -nn
    cmd_block "lspci（包含驱动/模块）" lspci -nnk
  else
    append_missing_cmd "lspci"
    kv "lspci" "(缺少命令：lspci；建议安装 pciutils)"
  fi

  if have_cmd lsusb; then
    cmd_block "lsusb（设备列表）" lsusb
    cmd_block "lsusb -t（拓扑/驱动）" lsusb -t
  else
    append_missing_cmd "lsusb"
    kv "lsusb" "(缺少命令：lsusb；建议安装 usbutils)"
  fi

  if have_cmd lshw; then
    if [ "$MODE" = "full" ]; then
      cmd_block "lshw（摘要）" lshw -short
      cmd_block "lshw（网络）" lshw -class network
      cmd_block "lshw（显示）" lshw -class display
    fi
  else
    append_missing_cmd "lshw"
  fi
}

list_net_ifaces() {
  if have_cmd ip; then
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1
    return 0
  fi
  if have_cmd ifconfig; then
    ifconfig -a 2>/dev/null | awk -F: '/flags=/{print $1}'
  fi
}

iface_mac() {
  iface="$1"
  if [ -r "/sys/class/net/$iface/address" ]; then
    cat "/sys/class/net/$iface/address" 2>/dev/null | head -n 1 || true
    return 0
  fi
  if have_cmd ip; then
    ip link show dev "$iface" 2>/dev/null | awk '/link\/ether/{print $2; exit}' || true
  fi
}

print_network() {
  section "网络"
  if have_cmd ip; then
    cmd_block "ip -br link" ip -br link
    cmd_block "ip -br addr" ip -br addr
    cmd_block "ip route" ip route
  else
    append_missing_cmd "ip"
    if have_cmd ifconfig; then
      cmd_block "ifconfig -a" ifconfig -a
    else
      append_missing_cmd "ifconfig"
      kv "网络工具" "(缺少 ip/ifconfig)"
    fi
  fi

  if have_cmd resolvectl; then
    if [ "$MODE" = "full" ]; then
      cmd_block "resolvectl status" resolvectl status
    fi
  fi

  ifaces="$(list_net_ifaces 2>/dev/null || true)"
  if [ -n "${ifaces:-}" ]; then
    for iface in $ifaces; do
      # 跳过 lo
      [ "$iface" = "lo" ] && continue
      mac="$(iface_mac "$iface" 2>/dev/null || true)"
      [ -n "${mac:-}" ] && mac="$(redact_mac "$mac")"
      section "网卡：$iface"
      [ -n "${mac:-}" ] && kv "MAC" "$mac"

      if have_cmd ethtool; then
        if [ "$MODE" != "quick" ]; then
          if [ "$FORMAT" = "md" ]; then
            printf '```text\n'
            ethtool -i "$iface" 2>&1 || true
            printf '```\n\n'
          else
            ethtool -i "$iface" 2>&1 || true
          fi
        fi
      else
        append_missing_cmd "ethtool"
        kv "ethtool" "(缺少命令：ethtool)"
      fi

      if have_cmd iw; then
        if iw dev "$iface" info >/dev/null 2>&1; then
          cmd_block "iw dev $iface info" iw dev "$iface" info
        fi
      else
        # iw 不是必需的，只在无线时提示
        :
      fi
    done
  fi
}

collect_driver_modules_from_lspci() {
  if ! have_cmd lspci; then
    return 0
  fi
  lspci -nnk 2>/dev/null \
    | sed -n 's/^[[:space:]]*Kernel driver in use:[[:space:]]*//p; s/^[[:space:]]*Kernel modules:[[:space:]]*//p' \
    | tr ',' '\n' \
    | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); if ($0!="") print $0; }' \
    | sort -u
}

collect_driver_modules_from_ethtool() {
  if ! have_cmd ethtool; then
    return 0
  fi
  ifaces="$(list_net_ifaces 2>/dev/null || true)"
  [ -n "${ifaces:-}" ] || return 0
  for iface in $ifaces; do
    [ "$iface" = "lo" ] && continue
    ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver:/{print $2; exit}' || true
  done | awk 'NF{print}' | sort -u
}

print_modinfo_brief() {
  mod="$1"
  if [ -z "${mod:-}" ]; then
    return 0
  fi
  if ! have_cmd modinfo; then
    append_missing_cmd "modinfo"
    return 0
  fi
  section "modinfo：$mod"
  if [ "$FORMAT" = "md" ]; then printf '```text\n'; fi
  # 只取常见字段，避免输出过长
  modinfo "$mod" 2>/dev/null \
    | awk '
      /^filename:|^version:|^description:|^author:|^license:|^srcversion:|^vermagic:|^depends:|^retpoline:|^intree:|^name:|^firmware:/{print}
    ' \
    | head -n 60 || true
  if [ "$FORMAT" = "md" ]; then printf '```\n\n'; fi
}

print_drivers() {
  section "驱动/内核模块（摘要）"

  if have_cmd lsmod; then
    cmd_block "lsmod" lsmod
  else
    append_missing_cmd "lsmod"
  fi

  if [ "$MODE" = "quick" ]; then
    return 0
  fi

  mods=""
  mods_lspci="$(collect_driver_modules_from_lspci 2>/dev/null || true)"
  mods_eth="$(collect_driver_modules_from_ethtool 2>/dev/null || true)"
  mods="$(printf '%s\n%s\n' "$mods_lspci" "$mods_eth" | awk 'NF{print}' | sort -u)"

  if [ -n "${mods:-}" ]; then
    section "关键驱动模块信息（自动提取）"
    count=0
    echo "$mods" | while IFS= read -r mod; do
      [ -n "$mod" ] || continue
      count=$((count+1))
      # 限制数量，避免报告过长
      if [ "$count" -gt 30 ]; then
        break
      fi
      print_modinfo_brief "$mod"
    done
  fi
}

print_graphics_audio() {
  section "图形/显示/音频"
  if have_cmd lspci; then
    if [ "$MODE" != "quick" ]; then
      cmd_block "GPU/显示相关（lspci 过滤）" sh -c "lspci -nnk | grep -A3 -E 'VGA compatible controller|3D controller|Display controller' || true"
      cmd_block "音频相关（lspci 过滤）" sh -c "lspci -nnk | grep -A3 -i 'audio' || true"
    fi
  fi

  if have_cmd glxinfo; then
    cmd_block "glxinfo -B（OpenGL）" glxinfo -B
  else
    append_missing_cmd "glxinfo"
  fi

  if have_cmd vulkaninfo; then
    if [ "$MODE" = "full" ]; then
      cmd_block "vulkaninfo --summary（Vulkan）" vulkaninfo --summary
    fi
  else
    append_missing_cmd "vulkaninfo"
  fi

  if have_cmd nvidia-smi; then
    cmd_block "nvidia-smi" nvidia-smi
  fi

  if have_cmd pactl; then
    cmd_block "pactl info" pactl info
    cmd_block "pactl list short sinks" pactl list short sinks
  else
    append_missing_cmd "pactl"
  fi

  if have_cmd aplay; then
    cmd_block "aplay -l" aplay -l
  else
    append_missing_cmd "aplay"
  fi
}

print_dmi_firmware() {
  section "主板/BIOS/DMI（需要 root 才完整）"
  if have_cmd dmidecode; then
    if is_root; then
      if [ "$MODE" = "full" ]; then
        if [ "$REDACT" = "1" ]; then
          section "dmidecode（脱敏节选）"
          if [ "$FORMAT" = "md" ]; then printf '```text\n'; fi
          dmidecode 2>/dev/null \
            | sed 's/\\(Serial Number:\\).*/\\1 <REDACTED>/; s/\\(UUID:\\).*/\\1 <REDACTED>/' \
            | head -n 240 || true
          if [ "$FORMAT" = "md" ]; then printf '```\n\n'; fi
        else
          if [ "$FORMAT" = "md" ]; then printf '```text\n'; fi
          dmidecode 2>/dev/null | head -n 240 || true
          if [ "$FORMAT" = "md" ]; then printf '```\n\n'; fi
        fi
      else
        # 标准模式仅展示更短摘要
        if [ "$FORMAT" = "md" ]; then printf '```text\n'; fi
        dmidecode -t system -t baseboard -t bios 2>/dev/null \
          | sed 's/\\(Serial Number:\\).*/\\1 <REDACTED>/; s/\\(UUID:\\).*/\\1 <REDACTED>/' \
          | head -n 180 || true
        if [ "$FORMAT" = "md" ]; then printf '```\n\n'; fi
      fi
    else
      kv "dmidecode" "需要 root（sudo）"
    fi
  else
    append_missing_cmd "dmidecode"
    kv "dmidecode" "(缺少命令：dmidecode)"
  fi
}

print_kernel_logs() {
  if [ "$MODE" != "full" ]; then
    return 0
  fi

section "内核日志（节选）"

  if have_cmd dmesg; then
    section "dmesg（最近 $DMESG_LINES 行，优先错误/警告）"
    if [ "$FORMAT" = "md" ]; then printf '```text\n'; fi
    if dmesg --help 2>/dev/null | grep -q -- '--level'; then
      dmesg --level=err,warn 2>/dev/null | tail -n "$DMESG_LINES" || true
    else
      dmesg 2>/dev/null | grep -Ei 'error|fail|firmware|iwlwifi|nvidia|amdgpu|i915' | tail -n "$DMESG_LINES" || true
    fi
    if [ "$FORMAT" = "md" ]; then printf '```\n\n'; fi
  else
    append_missing_cmd "dmesg"
    kv "dmesg" "(缺少命令：dmesg)"
  fi

  if have_cmd journalctl; then
    if [ "$FORMAT" = "md" ]; then printf '```text\n'; fi
    journalctl -b -p warning..alert --no-pager 2>/dev/null | tail -n "$JOURNAL_LINES" || true
    if [ "$FORMAT" = "md" ]; then printf '```\n\n'; fi
  else
    # 非 systemd 场景 journalctl 不一定有
    :
  fi
}

print_missing_tools_hint() {
  [ -n "${MISSING_CMDS:-}" ] || return 0

  section "建议安装的工具（可选）"
  if [ "$FORMAT" = "md" ]; then
    printf '当前系统缺少：`%s`\n\n' "$MISSING_CMDS"
    printf '常见包名（不同发行版可能略有差异）：\n\n'
    printf -- '- `lspci` → `pciutils`\n'
    printf -- '- `lsusb` → `usbutils`\n'
    printf -- '- `dmidecode` → `dmidecode`\n'
    printf -- '- `lshw` → `lshw`\n'
    printf -- '- `ethtool` → `ethtool`\n'
    printf -- '- `glxinfo` → `mesa-utils`（或 `mesa-demos`）\n'
    printf -- '- `vulkaninfo` → `vulkan-tools`\n'
    printf -- '- `smartctl` → `smartmontools`\n\n'
  else
    printf '%s\n' "当前系统缺少：$MISSING_CMDS"
    printf '%s\n' "常见包名（不同发行版可能略有差异）："
    printf '%s\n' "  lspci      -> pciutils"
    printf '%s\n' "  lsusb      -> usbutils"
    printf '%s\n' "  dmidecode  -> dmidecode"
    printf '%s\n' "  lshw       -> lshw"
    printf '%s\n' "  ethtool    -> ethtool"
    printf '%s\n' "  glxinfo    -> mesa-utils（或 mesa-demos）"
    printf '%s\n' "  vulkaninfo -> vulkan-tools"
    printf '%s\n' "  smartctl   -> smartmontools"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --md) FORMAT="md"; shift ;;
      --text) FORMAT="text"; shift ;;
      --quick) MODE="quick"; shift ;;
      --full) MODE="full"; shift ;;
      --no-redact) REDACT="0"; shift ;;
      --color) COLOR_MODE="on"; shift ;;
      --no-color) COLOR_MODE="off"; shift ;;
      --show-cmd) SHOW_CMD="1"; shift ;;
      --dmesg-lines)
        shift
        [ "$#" -gt 0 ] || die "--dmesg-lines 需要一个数字"
        DMESG_LINES="$1"
        shift
        ;;
      --journal-lines)
        shift
        [ "$#" -gt 0 ] || die "--journal-lines 需要一个数字"
        JOURNAL_LINES="$1"
        shift
        ;;
      --version|-v)
        printf '%s\n' "sysinfo-sh v$SCRIPT_VERSION"
        exit 0
        ;;
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        die "未知参数：$1（用 --help 查看用法）"
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  init_color
  is_linux || die "该脚本仅支持 Linux（当前：$(uname -s 2>/dev/null || true)）"

  title="Linux 配置/驱动信息报告（sysinfo-sh）"
  print_title "$title"

  print_how_to_read
  print_summary
  print_key_device_bindings
  print_network_brief
  print_storage_brief
  print_issue_scan

  if [ "$MODE" = "full" ]; then
    section "详细信息（原始输出，用于进一步排障）"
    print_os_kernel
    print_cpu_mem
    print_storage
    print_pci_usb
    print_network
    print_graphics_audio
    print_dmi_firmware
    print_drivers
    print_kernel_logs
  fi

  print_missing_tools_hint

  if [ "$FORMAT" = "md" ]; then
    printf '\n'
  fi
}

main "$@"
