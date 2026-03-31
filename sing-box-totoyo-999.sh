#!/usr/bin/env bash
# ============================================================
#  Sing-Box-totoyo-999 管理脚本（20 节点：直连 10 + WARP 10）
#  Version: v5.3.0
#  author：5090_Top_System_Architect_totoyo-999
#  Repo: https://github.com/totoyo-999/Totoyo999-SingBox
# ============================================================

set -Eeuo pipefail

stty erase ^H # 让退格键在终端里正常工作
# ===== [BEGIN] SBP 引导模块 v2.2.0+（包管理器优先 + 二进制回退） =====
# 模式与哨兵
: "${SBP_SOFT:=0}"                               # 1=宽松模式（失败尽量继续），默认 0=严格
: "${SBP_SKIP_DEPS:=0}"                          # 1=启动跳过依赖检查（只在菜单 1) 再装）
: "${SBP_FORCE_DEPS:=0}"                         # 1=强制重新安装依赖
: "${SBP_BIN_ONLY:=0}"                           # 1=强制走二进制模式，不用包管理器
: "${SBP_ROOT:=/var/lib/sing-box-plus}"
: "${SBP_BIN_DIR:=${SBP_ROOT}/bin}"
: "${SBP_DEPS_SENTINEL:=/var/lib/sing-box-plus/.deps_ok}"

mkdir -p "$SBP_BIN_DIR" 2>/dev/null || true
export PATH="$SBP_BIN_DIR:$PATH"

# 工具：下载器 + 轻量重试
dl() { # 用法：dl <URL> <OUT_PATH>
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 --connect-timeout 5 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    timeout 15 wget -qO "$out" --tries=2 "$url"
  else
    echo "[ERROR] 缺少 curl/wget：无法下载 $url"; return 1
  fi
}
with_retry() { local n=${1:-3}; shift; local i=1; until "$@"; do [ $i -ge "$n" ] && return 1; sleep $((i*2)); i=$((i+1)); done; }

# 工具：架构探测 + jq 静态兜底
detect_goarch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;;
    i386|i686)    echo 386   ;;
    *)            echo amd64 ;;
  esac
}
ensure_jq_static() {
  command -v jq >/dev/null 2>&1 && return 0
  local arch out="$SBP_BIN_DIR/jq" url alt
  arch="$(detect_goarch)"
  url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-${arch}"
  alt="https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"
  dl "$url" "$out" || { [ "$arch" = amd64 ] && dl "$alt" "$out" || true; }
  chmod +x "$out" 2>/dev/null || true
  command -v jq >/dev/null 2>&1
}

# 工具：核心命令自检
sbp_core_ok() {
  local need=(curl jq tar unzip openssl)
  local b; for b in "${need[@]}"; do command -v "$b" >/dev/null 2>&1 || return 1; done
  return 0
}

# —— 包管理器路径 —— #
sbp_detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then PM=apt
  elif command -v dnf      >/dev/null 2>&1; then PM=dnf
  elif command -v yum      >/dev/null 2>&1; then PM=yum
  elif command -v pacman   >/dev/null 2>&1; then PM=pacman
  elif command -v zypper   >/dev/null 2>&1; then PM=zypper
  else PM=unknown; fi
  [ "$PM" = unknown ] && return 1 || return 0
}

# apt 允许发行信息变化（stable→oldstable / Version 变化）
apt_allow_release_change() {
  cat >/etc/apt/apt.conf.d/99allow-releaseinfo-change <<'CONF'
Acquire::AllowReleaseInfoChange::Suite "true";
Acquire::AllowReleaseInfoChange::Version "true";
CONF
}

# 刷新软件仓（含各系兜底）
sbp_pm_refresh() {
  case "$PM" in
    apt)
      apt_allow_release_change
      [[ -f /etc/apt/sources.list ]] && sed -i 's#^deb http://#deb https://#' /etc/apt/sources.list 2>/dev/null || true
      # 修正 bullseye 的 security 行：bullseye/updates → debian-security bullseye-security
      [[ -f /etc/apt/sources.list ]] && sed -i -E 's#^(deb\s+https?://security\.debian\.org)(/debian-security)?\s+bullseye/updates(.*)$#\1/debian-security bullseye-security\3#' /etc/apt/sources.list || true

      local AOPT=""
      curl -6 -fsS --connect-timeout 2 https://deb.debian.org >/dev/null 2>&1 || AOPT='-o Acquire::ForceIPv4=true'

      if ! with_retry 3 apt-get update -y $AOPT; then
        # backports 404 临时注释再试
        sed -i 's#^\([[:space:]]*deb .* bullseye-backports.*\)#\# \1#' /etc/apt/sources.list 2>/dev/null || true
        with_retry 2 apt-get update -y $AOPT -o Acquire::Check-Valid-Until=false || [ "$SBP_SOFT" = 1 ]
      fi
      ;;
    dnf)
      dnf clean metadata || true
      with_retry 3 dnf makecache || [ "$SBP_SOFT" = 1 ]
      ;;
    yum)
      yum clean all || true
      with_retry 3 yum makecache fast || true
      yum install -y epel-release || true   # EL7/老环境便于装 jq 等
      ;;
    pacman)
      pacman-key --init >/dev/null 2>&1 || true
      pacman-key --populate archlinux >/dev/null 2>&1 || true
      with_retry 3 pacman -Syy --noconfirm || [ "$SBP_SOFT" = 1 ]
      ;;
    zypper)
      zypper -n ref || zypper -n ref --force || true
      ;;
  esac
}

# 逐包安装（单个失败不拖累整体）
sbp_pm_install() {
  case "$PM" in
    apt)
      local p; apt-get update -y >/dev/null 2>&1 || true
      for p in "$@"; do apt-get install -y --no-install-recommends "$p" || true; done
      ;;
    dnf)
      local p; for p in "$@"; do dnf install -y "$p" || true; done
      ;;
    yum)
      yum install -y epel-release || true
      local p; for p in "$@"; do yum install -y "$p" || true; done
      ;;
    pacman)
      pacman -Sy --noconfirm || [ "$SBP_SOFT" = 1 ]
      local p; for p in "$@"; do pacman -S --noconfirm --needed "$p" || true; done
      ;;
    zypper)
      zypper -n ref || true
      local p; for p in "$@"; do zypper --non-interactive install "$p" || true; done
      ;;
  esac
}

# 用包管理器装一轮依赖
sbp_install_prereqs_pm() {
  sbp_detect_pm || return 1
  sbp_pm_refresh

  case "$PM" in
    apt)    CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz-utils uuid-runtime iproute2 iptables ufw) ;;
    dnf|yum)CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute iptables iptables-nft firewalld) ;;
    pacman) CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute2 iptables) ;;
    zypper) CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute2 iptables firewalld) ;;
    *) return 1 ;;
  esac

  sbp_pm_install "${CORE[@]}" "${EXTRA[@]}"

  # jq 兜底：安装失败时下载静态 jq
  if ! command -v jq >/dev/null 2>&1; then
    echo "[INFO] 通过包管理器安装 jq 失败，尝试下载静态 jq ..."
    ensure_jq_static || { echo "[ERROR] 无法获取 jq"; return 1; }
  fi

  # 严格模式：核心仍缺则失败
  if ! sbp_core_ok; then
    [ "$SBP_SOFT" = 1 ] || return 1
    echo "[WARN] 核心依赖未就绪（宽松模式继续）"
  fi
  return 0
}

# —— 二进制模式：直接获取 sing-box 可执行文件 —— #
install_singbox_binary() {
  local arch goarch pkg tmp json url fn
  goarch="$(detect_goarch)"
  tmp="$(mktemp -d)" || return 1

  ensure_jq_static || { echo "[ERROR] 无法获取 jq，二进制模式失败"; rm -rf "$tmp"; return 1; }

json="$(with_retry 3 curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/tags/v1.12.22)" || { rm -rf "$tmp"; return 1; }
  url="$(printf '%s' "$json" | jq -r --arg a "$goarch" '
    .assets[] | select(.name|test("linux-" + $a + "\\.(tar\\.(xz|gz)|zip)$")) | .browser_download_url
  ' | head -n1)"

  if [ -z "$url" ] || [ "$url" = "null" ]; then
    echo "[ERROR] 未找到匹配架构($goarch)的 sing-box 资产"; rm -rf "$tmp"; return 1
  fi

  pkg="$tmp/pkg"
  with_retry 3 dl "$url" "$pkg" || { rm -rf "$tmp"; return 1; }

  case "$url" in
    *.tar.xz)  if command -v xz >/dev/null 2>&1; then tar -xJf "$pkg" -C "$tmp"; else echo "[ERROR] 缺少 xz；请安装 xz/xz-utils 或换 .tar.gz/.zip"; rm -rf "$tmp"; return 1; fi ;;
    *.tar.gz)  tar -xzf "$pkg" -C "$tmp" ;;
    *.zip)     unzip -q "$pkg" -d "$tmp" || { echo "[ERROR] 缺少 unzip"; rm -rf "$tmp"; return 1; } ;;
    *)         echo "[ERROR] 未知包格式：$url"; rm -rf "$tmp"; return 1 ;;
  esac

  fn="$(find "$tmp" -type f -name 'sing-box' | head -n1)"
  [ -n "$fn" ] || { echo "[ERROR] 包内未找到 sing-box"; rm -rf "$tmp"; return 1; }

  install -m 0755 "$fn" "$SBP_BIN_DIR/sing-box" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  echo "[OK] 已安装 sing-box 到 $SBP_BIN_DIR/sing-box"
}

# 证书兜底（有 openssl 就生成；没有就先跳过，由业务决定是否强制）
ensure_tls_cert() {
  local dir="$SBP_ROOT"
  mkdir -p "$dir"
  if command -v openssl >/dev/null 2>&1; then
    [[ -f "$dir/private.key" ]] || openssl ecparam -genkey -name prime256v1 -out "$dir/private.key" >/dev/null 2>&1
    [[ -f "$dir/cert.pem"    ]] || openssl req -new -x509 -days 36500 -key "$dir/private.key" -out "$dir/cert.pem" -subj "/CN=www.bing.com" >/dev/null 2>&1
  fi
}

# 标记哨兵
sbp_mark_deps_ok() {
  if sbp_core_ok; then
    mkdir -p "$(dirname "$SBP_DEPS_SENTINEL")" && : > "$SBP_DEPS_SENTINEL" || true
  fi
}

# 入口：装依赖 / 二进制回退
sbp_bootstrap() {
  [ "$EUID" -eq 0 ] || { echo "请以 root 运行（或 sudo）"; exit 1; }

  if [ "$SBP_SKIP_DEPS" = 1 ]; then
    echo "[INFO] 已跳过启动时依赖检查（SBP_SKIP_DEPS=1）"
    return 0
  fi

  # 已就绪则跳过
  if [ "$SBP_FORCE_DEPS" != 1 ] && sbp_core_ok && [ -f "$SBP_DEPS_SENTINEL" ] && [ "$SBP_BIN_ONLY" != 1 ]; then
    echo "依赖已安装"
    return 0
  fi

  # 强制二进制模式
  if [ "$SBP_BIN_ONLY" = 1 ]; then
    echo "[INFO] 二进制模式（SBP_BIN_ONLY=1）"
    install_singbox_binary || { echo "[ERROR] 二进制模式安装 sing-box 失败"; exit 1; }
    ensure_tls_cert
    return 0
  fi

  # 包管理器优先
  if sbp_install_prereqs_pm; then
    sbp_mark_deps_ok
    return 0
  fi

  # 回退到二进制模式
  echo "[WARN] 包管理器依赖安装失败，切换到二进制模式"
  install_singbox_binary || { echo "[ERROR] 二进制模式安装 sing-box 失败"; exit 1; }
  ensure_tls_cert
}
# ===== [END] SBP 引导模块 v2.2.0+ =====


# ===== 提前设默认，避免 set -u 早期引用未定义变量导致脚本直接退出 =====
SYSTEMD_SERVICE=${SYSTEMD_SERVICE:-sing-box.service}
BIN_PATH=${BIN_PATH:-/usr/local/bin/sing-box}
SB_DIR=${SB_DIR:-/opt/sing-box}
CONF_JSON=${CONF_JSON:-$SB_DIR/config.json}
DATA_DIR=${DATA_DIR:-$SB_DIR/data}
CERT_DIR=${CERT_DIR:-$SB_DIR/cert}
WGCF_DIR=${WGCF_DIR:-$SB_DIR/wgcf}

# 功能开关（保持稳定默认）
ENABLE_WARP=${ENABLE_WARP:-true}
ENABLE_VLESS_REALITY=${ENABLE_VLESS_REALITY:-true}
ENABLE_VLESS_GRPCR=${ENABLE_VLESS_GRPCR:-true}
ENABLE_TROJAN_REALITY=${ENABLE_TROJAN_REALITY:-true}
ENABLE_HYSTERIA2=${ENABLE_HYSTERIA2:-true}
ENABLE_VMESS_WS=${ENABLE_VMESS_WS:-true}
ENABLE_HY2_OBFS=${ENABLE_HY2_OBFS:-true}
ENABLE_SS2022=${ENABLE_SS2022:-true}
ENABLE_SS=${ENABLE_SS:-true}
ENABLE_TUIC=${ENABLE_TUIC:-true}
ENABLE_ANYTLS=${ENABLE_ANYTLS:-true}

# 常量
SCRIPT_NAME="Sing-Box-totoyo-999 管理脚本"
SCRIPT_VERSION="v5.3.0"
REALITY_SERVER=${REALITY_SERVER:-www.microsoft.com}
REALITY_SERVER_PORT=${REALITY_SERVER_PORT:-443}
GRPC_SERVICE=${GRPC_SERVICE:-grpc}
VMESS_WS_PATH=${VMESS_WS_PATH:-/vm}

# 兼容 sing-box 1.12.x 的旧 wireguard 出站
export ENABLE_DEPRECATED_WIREGUARD_OUTBOUND=${ENABLE_DEPRECATED_WIREGUARD_OUTBOUND:-true}

# ===== 颜色 =====
C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
C_RED="\033[31m";  C_GREEN="\033[32m"; C_YELLOW="\033[33m"
C_BLUE="\033[34m"; C_CYAN="\033[36m"; C_MAGENTA="\033[35m"
hr(){ printf "${C_DIM}=============================================================${C_RESET}\n"; }

# ===== 基础工具 =====
info(){ echo -e "[${C_CYAN}信息${C_RESET}] $*"; }
ok(){   echo -e "[${C_GREEN}成功${C_RESET}] $*"; }
warn(){ echo -e "[${C_YELLOW}警告${C_RESET}] $*"; }
err(){  echo -e "[${C_RED}错误${C_RESET}] $*" >&2; }
die(){  echo -e "[${C_RED}错误${C_RESET}] $*" >&2; exit 1; }

# --- 架构映射：uname -m -> 发行资产名 ---
arch_map() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l)       echo "armv7" ;;   # 上游无 armv6，回退 armv7
    i386|i686)    echo "386"  ;;
    *)            echo "amd64" ;;
  esac
}

# --- 依赖安装：兼容 apt / yum / dnf / apk / pacman / zypper ---
ensure_deps() {
  local pkgs=("$@") miss=()
  for p in "${pkgs[@]}"; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
  ((${#miss[@]}==0)) && return 0

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "${miss[@]}" || apt-get install -y --no-install-recommends "${miss[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${miss[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${miss[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${miss[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "${miss[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "${miss[@]}"
  else
    err "无法自动安装依赖：${miss[*]}，请手动安装后重试"
    return 1
  fi
}

b64enc(){ base64 -w 0 2>/dev/null || base64; }
urlenc(){ # 纯 bash urlencode（不依赖 python）
  local s="$1" out="" c
  for ((i=0; i<${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      ' ') out+="%20" ;;
      *) printf -v out "%s%%%02X" "$out" "'$c" ;;
    esac
  done
  printf "%s" "$out"
}

safe_source_env(){ # 安全 source，忽略不存在文件
  local f="$1"; [[ -f "$f" ]] || return 1
  set +u; # 避免未定义变量报错
  # shellcheck disable=SC1090
  source "$f"
  set -u
}

get_ip4(){ # 多源获取公网 IPv4
  local ip
  ip=$(curl -4 -fsSL ipv4.icanhazip.com 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -4 -fsSL ifconfig.me 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -4 -fsSL ip.sb 2>/dev/null || true)
  echo "${ip:-127.0.0.1}"
}

get_ip6(){ # 多源获取公网 IPv6（无 IPv6 则返回空）
  local ip
  ip=$(curl -6 -fsSL ipv6.icanhazip.com 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -6 -fsSL ifconfig.me 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -6 -fsSL ip.sb 2>/dev/null || true)
  echo "${ip:-}"
}

# 兼容旧调用：默认返回 IPv4
get_ip(){ get_ip4; }

# URI/分享链接里：IPv6 需要用 [addr] 包起来
fmt_host_for_uri(){
  local ip="$1"
  [[ "$ip" == *:* ]] && printf '[%s]' "$ip" || printf '%s' "$ip"
}

is_uuid(){ [[ "$1" =~ ^[0-9a-fA-F-]{36}$ ]]; }

ensure_dirs(){ mkdir -p "$SB_DIR" "$DATA_DIR" "$CERT_DIR" "$WGCF_DIR"; }

# ===== 端口（18 个互不重复） =====
PORTS=()
gen_port() {
  while :; do
    p=$(( ( RANDOM % 55536 ) + 10000 ))
    [[ $p -le 65535 ]] || continue
    [[ " ${PORTS[*]-} " != *" $p "* ]] && { PORTS+=("$p"); echo "$p"; return; }
  done
}
rand_ports_reset(){ PORTS=(); }

PORT_VLESSR=""; PORT_VLESS_GRPCR=""; PORT_TROJANR=""; PORT_HY2=""; PORT_VMESS_WS=""
PORT_HY2_OBFS=""; PORT_SS2022=""; PORT_SS=""; PORT_TUIC=""; PORT_ANYTLS=""
PORT_VLESSR_W=""; PORT_VLESS_GRPCR_W=""; PORT_TROJANR_W=""; PORT_HY2_W=""; PORT_VMESS_WS_W=""
PORT_HY2_OBFS_W=""; PORT_SS2022_W=""; PORT_SS_W=""; PORT_TUIC_W=""; PORT_ANYTLS_W=""

save_ports(){ cat > "$SB_DIR/ports.env" <<EOF
PORT_VLESSR=$PORT_VLESSR
PORT_VLESS_GRPCR=$PORT_VLESS_GRPCR
PORT_TROJANR=$PORT_TROJANR
PORT_HY2=$PORT_HY2
PORT_VMESS_WS=$PORT_VMESS_WS
PORT_HY2_OBFS=$PORT_HY2_OBFS
PORT_SS2022=$PORT_SS2022
PORT_SS=$PORT_SS
PORT_TUIC=$PORT_TUIC
PORT_ANYTLS=$PORT_ANYTLS
PORT_VLESSR_W=$PORT_VLESSR_W
PORT_VLESS_GRPCR_W=$PORT_VLESS_GRPCR_W
PORT_TROJANR_W=$PORT_TROJANR_W
PORT_HY2_W=$PORT_HY2_W
PORT_VMESS_WS_W=$PORT_VMESS_WS_W
PORT_HY2_OBFS_W=$PORT_HY2_OBFS_W
PORT_SS2022_W=$PORT_SS2022_W
PORT_SS_W=$PORT_SS_W
PORT_TUIC_W=$PORT_TUIC_W
PORT_ANYTLS_W=$PORT_ANYTLS_W
EOF
}
load_ports(){ safe_source_env "$SB_DIR/ports.env" || return 1; }

save_all_ports(){
  rand_ports_reset
  for v in PORT_VLESSR PORT_VLESS_GRPCR PORT_TROJANR PORT_HY2 PORT_VMESS_WS PORT_HY2_OBFS PORT_SS2022 PORT_SS PORT_TUIC PORT_ANYTLS \
           PORT_VLESSR_W PORT_VLESS_GRPCR_W PORT_TROJANR_W PORT_HY2_W PORT_VMESS_WS_W PORT_HY2_OBFS_W PORT_SS2022_W PORT_SS_W PORT_TUIC_W PORT_ANYTLS_W; do
    [[ -n "${!v:-}" ]] && PORTS+=("${!v}")
  done
  [[ -z "${PORT_VLESSR:-}" ]] && PORT_VLESSR=$(gen_port)
  [[ -z "${PORT_VLESS_GRPCR:-}" ]] && PORT_VLESS_GRPCR=$(gen_port)
  [[ -z "${PORT_TROJANR:-}" ]] && PORT_TROJANR=$(gen_port)
  [[ -z "${PORT_HY2:-}" ]] && PORT_HY2=$(gen_port)
  [[ -z "${PORT_VMESS_WS:-}" ]] && PORT_VMESS_WS=$(gen_port)
  [[ -z "${PORT_HY2_OBFS:-}" ]] && PORT_HY2_OBFS=$(gen_port)
  [[ -z "${PORT_SS2022:-}" ]] && PORT_SS2022=$(gen_port)
  [[ -z "${PORT_SS:-}" ]] && PORT_SS=$(gen_port)
  [[ -z "${PORT_TUIC:-}" ]] && PORT_TUIC=$(gen_port)
  [[ -z "${PORT_ANYTLS:-}" ]] && PORT_ANYTLS=$(gen_port)
  [[ -z "${PORT_VLESSR_W:-}" ]] && PORT_VLESSR_W=$(gen_port)
  [[ -z "${PORT_VLESS_GRPCR_W:-}" ]] && PORT_VLESS_GRPCR_W=$(gen_port)
  [[ -z "${PORT_TROJANR_W:-}" ]] && PORT_TROJANR_W=$(gen_port)
  [[ -z "${PORT_HY2_W:-}" ]] && PORT_HY2_W=$(gen_port)
  [[ -z "${PORT_VMESS_WS_W:-}" ]] && PORT_VMESS_WS_W=$(gen_port)
  [[ -z "${PORT_HY2_OBFS_W:-}" ]] && PORT_HY2_OBFS_W=$(gen_port) || true
  [[ -z "${PORT_SS2022_W:-}" ]] && PORT_SS2022_W=$(gen_port)
  [[ -z "${PORT_SS_W:-}" ]] && PORT_SS_W=$(gen_port)
  [[ -z "${PORT_TUIC_W:-}" ]] && PORT_TUIC_W=$(gen_port)
  [[ -z "${PORT_ANYTLS_W:-}" ]] && PORT_ANYTLS_W=$(gen_port)
  save_ports
}

# ===== env / creds / warp =====
save_env(){ cat > "$SB_DIR/env.conf" <<EOF
BIN_PATH=$BIN_PATH
ENABLE_VLESS_REALITY=$ENABLE_VLESS_REALITY
ENABLE_VLESS_GRPCR=$ENABLE_VLESS_GRPCR
ENABLE_TROJAN_REALITY=$ENABLE_TROJAN_REALITY
ENABLE_HYSTERIA2=$ENABLE_HYSTERIA2
ENABLE_VMESS_WS=$ENABLE_VMESS_WS
ENABLE_HY2_OBFS=$ENABLE_HY2_OBFS
ENABLE_SS2022=$ENABLE_SS2022
ENABLE_SS=$ENABLE_SS
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_ANYTLS=$ENABLE_ANYTLS
ENABLE_WARP=$ENABLE_WARP
REALITY_SERVER=$REALITY_SERVER
REALITY_SERVER_PORT=$REALITY_SERVER_PORT
GRPC_SERVICE=$GRPC_SERVICE
VMESS_WS_PATH=$VMESS_WS_PATH
EOF
}
load_env(){ safe_source_env "$SB_DIR/env.conf" || true; }

save_creds(){ cat > "$SB_DIR/creds.env" <<EOF
UUID=$UUID
HY2_PWD=$HY2_PWD
REALITY_PRIV=$REALITY_PRIV
REALITY_PUB=$REALITY_PUB
REALITY_SID=$REALITY_SID
HY2_PWD2=$HY2_PWD2
HY2_OBFS_PWD=$HY2_OBFS_PWD
SS2022_KEY=$SS2022_KEY
SS_PWD=$SS_PWD
TUIC_UUID=$TUIC_UUID
TUIC_PWD=$TUIC_PWD
ANYTLS_PWD=$ANYTLS_PWD
EOF
}
load_creds(){ safe_source_env "$SB_DIR/creds.env" || return 1; }

save_warp(){ cat > "$SB_DIR/warp.env" <<EOF
WARP_PRIVATE_KEY=$WARP_PRIVATE_KEY
WARP_PEER_PUBLIC_KEY=$WARP_PEER_PUBLIC_KEY
WARP_ENDPOINT_HOST=$WARP_ENDPOINT_HOST
WARP_ENDPOINT_PORT=$WARP_ENDPOINT_PORT
WARP_ADDRESS_V4=$WARP_ADDRESS_V4
WARP_ADDRESS_V6=$WARP_ADDRESS_V6
WARP_RESERVED_1=$WARP_RESERVED_1
WARP_RESERVED_2=$WARP_RESERVED_2
WARP_RESERVED_3=$WARP_RESERVED_3
EOF
}
load_warp(){ safe_source_env "$SB_DIR/warp.env" || return 1; }

# ===== 节点图标 =====
NODE_ICON=${NODE_ICON:-}
save_icon(){ printf 'NODE_ICON=%s\n' "$NODE_ICON" > "$SB_DIR/icon.env"; }
load_icon(){ safe_source_env "$SB_DIR/icon.env" || true; }

# 生成 8 字节十六进制（16 个 hex 字符）
rand_hex8(){
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8 | tr -d "\n"
  else
    # 兜底：没有 openssl 时用 hexdump
    hexdump -v -n 8 -e '1/1 "%02x"' /dev/urandom
  fi
}
rand_b64_32(){ openssl rand -base64 32 | tr -d "\n"; }

gen_uuid(){
  local u=""
  if [[ -x "$BIN_PATH" ]]; then u=$("$BIN_PATH" generate uuid 2>/dev/null | head -n1); fi
  if [[ -z "$u" ]] && command -v uuidgen >/dev/null 2>&1; then u=$(uuidgen | head -n1); fi
  if [[ -z "$u" ]]; then u=$(cat /proc/sys/kernel/random/uuid | head -n1); fi
  printf '%s' "$u" | tr -d '\r\n'
}
gen_reality(){ "$BIN_PATH" generate reality-keypair; }

mk_cert(){
  local crt="$CERT_DIR/fullchain.pem" key="$CERT_DIR/key.pem"
  if [[ ! -s "$crt" || ! -s "$key" ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes \
      -keyout "$key" -out "$crt" -subj "/CN=$REALITY_SERVER" \
      -addext "subjectAltName=DNS:$REALITY_SERVER" >/dev/null 2>&1
  fi
}

ensure_creds(){
  [[ -z "${UUID:-}" ]] && UUID=$(gen_uuid)
  is_uuid "$UUID" || UUID=$(gen_uuid)
  [[ -z "${HY2_PWD:-}" ]] && HY2_PWD=$(rand_b64_32)
  if [[ -z "${REALITY_PRIV:-}" || -z "${REALITY_PUB:-}" || -z "${REALITY_SID:-}" ]]; then
    readarray -t RKP < <(gen_reality)
    REALITY_PRIV=$(printf "%s\n" "${RKP[@]}" | awk '/PrivateKey/{print $2}')
    REALITY_PUB=$(printf "%s\n" "${RKP[@]}" | awk '/PublicKey/{print $2}')
    REALITY_SID=$(rand_hex8)
  fi
  [[ -z "${HY2_PWD2:-}" ]] && HY2_PWD2=$(rand_b64_32)
  [[ -z "${HY2_OBFS_PWD:-}" ]] && HY2_OBFS_PWD=$(openssl rand -base64 16 | tr -d "\n")
  [[ -z "${SS2022_KEY:-}" ]] && SS2022_KEY=$(rand_b64_32)
  [[ -z "${SS_PWD:-}" ]] && SS_PWD=$(openssl rand -base64 24 | tr -d "=\n" | tr "+/" "-_")
  TUIC_UUID="$UUID"; TUIC_PWD="$UUID"
  [[ -z "${ANYTLS_PWD:-}" ]] && ANYTLS_PWD=$(openssl rand -base64 24 | tr -d "=\n" | tr "+/" "-_")
  save_creds
}

# ===== WARP（wgcf） =====
WGCF_BIN=/usr/local/bin/wgcf
install_wgcf_disabled(){
  [[ -x "$WGCF_BIN" ]] && return 0
  local GOA url tmp
  case "$(arch_map)" in
    amd64) GOA=amd64;; arm64) GOA=arm64;; armv7) GOA=armv7;; 386) GOA=386;; *) GOA=amd64;;
  esac
  url=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest \
        | jq -r ".assets[] | select(.name|test(\"linux_${GOA}$\")) | .browser_download_url" | head -n1)
  [[ -n "$url" ]] || { warn "获取 wgcf 下载地址失败"; return 1; }
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/wgcf"
  install -m0755 "$tmp/wgcf" "$WGCF_BIN"
  rm -rf "$tmp"
}

# —— Base64 清理 + 补齐：去掉引号/空白，长度 %4==2 补“==”，%4==3 补“=” ——
pad_b64(){
  local s="${1:-}"
  # 去引号/空格/回车
  s="$(printf '%s' "$s" | tr -d '\r\n\" ')"
  # 去掉已有尾随 =，按需重加
  s="${s%%=*}"
  local rem=$(( ${#s} % 4 ))
  if   (( rem == 2 )); then s="${s}=="
  elif (( rem == 3 )); then s="${s}="
  fi
  printf '%s' "$s"
}


# ===== WARP（官方 warp-cli，proxy 模式）一键安装/修复 =====
# 说明：
# - 本脚本强制使用官方 cloudflare-warp (warp-cli) 提供本地 SOCKS5 (默认 127.0.0.1:40000)
# - sing-box 的 tag=warp 出站固定走该 SOCKS5
WARP_SOCKS_HOST="${WARP_SOCKS_HOST:-127.0.0.1}"
WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-40000}"

install_warpcli(){
  command -v warp-cli >/dev/null 2>&1 && return 0

  if command -v apt-get >/dev/null 2>&1; then
    info "安装 cloudflare-warp (Debian/Ubuntu)..."
    apt-get update -y
    apt-get install -y curl gpg lsb-release ca-certificates >/dev/null 2>&1 || true
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main"       > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -y
    apt-get install -y cloudflare-warp
  elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
    info "安装 cloudflare-warp (CentOS/RHEL)..."
    curl -fsSl https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y cloudflare-warp
    else
      yum install -y cloudflare-warp
    fi
  else
    err "未识别的包管理器，无法自动安装 cloudflare-warp"
    return 1
  fi

  command -v warp-cli >/dev/null 2>&1
}

ensure_warpcli_proxy(){
  [[ "${ENABLE_WARP:-true}" == "true" ]] || return 0

  install_warpcli || return 1

  systemctl enable --now warp-svc >/dev/null 2>&1 || true

  # 已注册则跳过；未注册则自动同意条款
  if ! warp-cli registration show >/dev/null 2>&1; then
    info "正在初始化 Cloudflare WARP"

    # warp-cli 强制检测 TTY，非 TTY 拒绝输入，需模拟真实终端注入 y
    # 优先级：python3 pty（最可靠）→ expect → 安装 python3 兜底
    _warp_reg_ok=0

    if command -v python3 >/dev/null 2>&1; then
      python3 - <<'PYEOF' 2>/dev/null && _warp_reg_ok=1 || true
import pty, os, time, select, sys

def run():
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("warp-cli", ["warp-cli", "registration", "new"])
    else:
        answered = False
        for _ in range(30):
            r, _, _ = select.select([fd], [], [], 1)
            if r:
                try:
                    data = os.read(fd, 4096).decode(errors="ignore")
                except OSError:
                    break
                if not answered and ("y/N" in data or "y/n" in data):
                    time.sleep(0.2)
                    os.write(fd, b"y\n")
                    answered = True
                if "Success" in data:
                    sys.exit(0)
            try:
                ret = os.waitpid(pid, os.WNOHANG)
                if ret[0] != 0:
                    break
            except ChildProcessError:
                break
        try:
            os.waitpid(pid, 0)
        except Exception:
            pass
        sys.exit(1)

run()
PYEOF

    elif command -v expect >/dev/null 2>&1; then
      expect -c '
        spawn warp-cli registration new
        expect -re {[yY]/[nN]}
        send "y\r"
        expect eof
      ' >/dev/null 2>&1 && _warp_reg_ok=1 || true

    else
      # 尝试安装 python3（兜底）
      warn "未找到 python3/expect，尝试安装 python3..."
      if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y python3 >/dev/null 2>&1 || true
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 >/dev/null 2>&1 || true
      elif command -v yum >/dev/null 2>&1; then
        yum install -y python3 >/dev/null 2>&1 || true
      elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm python >/dev/null 2>&1 || true
      elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install python3 >/dev/null 2>&1 || true
      fi

      if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PYEOF' 2>/dev/null && _warp_reg_ok=1 || true
import pty, os, time, select, sys

def run():
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("warp-cli", ["warp-cli", "registration", "new"])
    else:
        answered = False
        for _ in range(30):
            r, _, _ = select.select([fd], [], [], 1)
            if r:
                try:
                    data = os.read(fd, 4096).decode(errors="ignore")
                except OSError:
                    break
                if not answered and ("y/N" in data or "y/n" in data):
                    time.sleep(0.2)
                    os.write(fd, b"y\n")
                    answered = True
                if "Success" in data:
                    sys.exit(0)
            try:
                ret = os.waitpid(pid, os.WNOHANG)
                if ret[0] != 0:
                    break
            except ChildProcessError:
                break
        try:
            os.waitpid(pid, 0)
        except Exception:
            pass
        sys.exit(1)

run()
PYEOF
      else
        err "无法自动完成 WARP 注册（缺少 python3/expect），请手动运行：warp-cli registration new"
        return 1
      fi
    fi

    sleep 2
    if ! warp-cli registration show >/dev/null 2>&1; then
      err "WARP 注册失败，请手动运行：warp-cli registration new"; return 1
    fi
  fi

  # proxy 模式：不改系统默认路由
  warp-cli mode proxy >/dev/null 2>&1 || true

  # 连接
  warp-cli connect >/dev/null 2>&1 || return 1

  # 等待 socks 端口监听
  for i in {1..12}; do
    if ss -lntp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT}\b" || netstat -lntp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT}\b"; then
      break
    fi
    sleep 1
  done

  if !( ss -lntp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT}\b" || netstat -lntp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT}\b" ); then
    err "WARP SOCKS5 端口 ${WARP_SOCKS_PORT} 未监听（warp-svc/warp-cli 可能未正常工作）"
    systemctl status warp-svc --no-pager | head -80 || true
    journalctl -u warp-svc -n 120 --no-pager || true
    return 1
  fi

  # 真正测试 warp=on
  if ! curl -fsSL --proxy "socks5://${WARP_SOCKS_HOST}:${WARP_SOCKS_PORT}" https://cloudflare.com/cdn-cgi/trace | grep -q "warp=on"; then
    err "WARP 代理测试失败：未检测到 warp=on"
    warp-cli status || true
    return 1
  fi

  ok "WARP proxy 已就绪"
  return 0
}

# ===== WARP（wgcf）配置生成/修复（已废弃/不再默认使用，保留旧代码以兼容历史） =====

ensure_wgcf_profile(){
  [[ "${ENABLE_WARP:-true}" == "true" ]] || return 0

  # 先尝试读取旧 env，并做一次规范化补齐
  if load_warp 2>/dev/null; then
    WARP_PRIVATE_KEY="$(pad_b64 "${WARP_PRIVATE_KEY:-}")"
    WARP_PEER_PUBLIC_KEY="$(pad_b64 "${WARP_PEER_PUBLIC_KEY:-}")"
    # 允许之前没写 reserved，给默认 0
    : "${WARP_RESERVED_1:=0}" "${WARP_RESERVED_2:=0}" "${WARP_RESERVED_3:=0}"
    save_warp
    # 如果关键字段都在，就直接用旧的（已经补齐），无需重建
    if [[ -n "$WARP_PRIVATE_KEY" && -n "$WARP_PEER_PUBLIC_KEY" && -n "${WARP_ENDPOINT_HOST:-}" && -n "${WARP_ENDPOINT_PORT:-}" ]]; then
      return 0
    fi
  fi

  # 走到这里说明旧 env 不完整；开始用 wgcf 重建
  install_wgcf_disabled || { warn "wgcf 安装失败，禁用 WARP 节点"; ENABLE_WARP=false; save_env; return 0; }

  local wd="$SB_DIR/wgcf"; mkdir -p "$wd"
  if [[ ! -f "$wd/wgcf-account.toml" ]]; then
    "$WGCF_BIN" register --accept-tos --config "$wd/wgcf-account.toml" >/dev/null
  fi
  "$WGCF_BIN" generate --config "$wd/wgcf-account.toml" --profile "$wd/wgcf-profile.conf" >/dev/null

  local prof="$wd/wgcf-profile.conf"
  # 提取并规范化
  WARP_PRIVATE_KEY="$(pad_b64 "$(awk -F'= *' '/^PrivateKey/{gsub(/\r/,"");print $2; exit}' "$prof")")"
  WARP_PEER_PUBLIC_KEY="$(pad_b64 "$(awk -F'= *' '/^PublicKey/{gsub(/\r/,"");print $2; exit}' "$prof")")"

  # Endpoint 可能是域名或 [IPv6]:port
  local ep host port
  ep="$(awk -F'= *' '/^Endpoint/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  if [[ "$ep" =~ ^\[(.+)\]:(.+)$ ]]; then host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"; else host="${ep%:*}"; port="${ep##*:}"; fi
  WARP_ENDPOINT_HOST="$host"
  WARP_ENDPOINT_PORT="$port"

  # 内网地址与 reserved
  local ad rs
  ad="$(awk -F'= *' '/^Address/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  WARP_ADDRESS_V4="${ad%%,*}"
  WARP_ADDRESS_V6="${ad##*,}"
  rs="$(awk -F'= *' '/^Reserved/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  WARP_RESERVED_1="${rs%%,*}"; rs="${rs#*,}"
  WARP_RESERVED_2="${rs%%,*}"; WARP_RESERVED_3="${rs##*,}"
  : "${WARP_RESERVED_1:=0}" "${WARP_RESERVED_2:=0}" "${WARP_RESERVED_3:=0}"

  save_warp
}

# ===== 依赖与安装 =====
install_deps(){
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y ca-certificates curl wget jq tar iproute2 openssl coreutils uuid-runtime >/dev/null 2>&1 || true
}

# ===== 安装 / 更新 sing-box（GitHub Releases）=====
install_singbox() {

  # 已安装则直接返回
  if command -v "$BIN_PATH" >/dev/null 2>&1; then
    info "检测到 sing-box: $("$BIN_PATH" version | head -n1)"
    return 0
  fi

  # 依赖
  ensure_deps curl jq tar || return 1
  command -v xz >/dev/null 2>&1 || ensure_deps xz-utils >/dev/null 2>&1 || true
  command -v unzip >/dev/null 2>&1 || ensure_deps unzip   >/dev/null 2>&1 || true

  local repo="SagerNet/sing-box"
  local tag="${SINGBOX_TAG:-v1.12.22}"   # 允许用环境变量固定版本，如 v1.12.7
  local arch; arch="$(arch_map)"
  local api url tmp pkg re rel_url

  info "下载 sing-box (${arch}) ..."

  # 取 release JSON
  if [[ "$tag" = "latest" ]]; then
    rel_url="https://api.github.com/repos/${repo}/releases/latest"
  else
    rel_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"
  fi

  # 资产名匹配：兼容 tar.gz / tar.xz / zip
  # 典型名称：sing-box-1.12.7-linux-amd64.tar.gz
  re="^sing-box-.*-linux-${arch}\\.(tar\\.(gz|xz)|zip)$"

  # 先在目标 release 里找；找不到再从所有 releases 里兜底
  url="$(curl -fsSL "$rel_url" | jq -r --arg re "$re" '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1)"
  if [[ -z "$url" ]]; then
    url="$(curl -fsSL "https://api.github.com/repos/${repo}/releases" \
           | jq -r --arg re "$re" '[ .[] | .assets[] | select(.name | test($re)) | .browser_download_url ][0]')"
  fi
  [[ -n "$url" ]] || { err "下载 sing-box 失败：未匹配到发行包（arch=${arch} tag=${tag})"; return 1; }


  tmp="$(mktemp -d)"; pkg="${tmp}/pkg"
  if ! curl -fL "$url" -o "$pkg"; then
    rm -rf "$tmp"; err "下载 sing-box 失败"; return 1
  fi

  # 解压
  if echo "$url" | grep -qE '\.tar\.gz$|\.tgz$'; then
    tar -xzf "$pkg" -C "$tmp"
  elif echo "$url" | grep -qE '\.tar\.xz$'; then
    tar -xJf "$pkg" -C "$tmp"
  elif echo "$url" | grep -qE '\.zip$'; then
    unzip -q "$pkg" -d "$tmp"
  else
    rm -rf "$tmp"; err "未知包格式：$url"; return 1
  fi

  # 找到二进制并安装
  local bin
  bin="$(find "$tmp" -type f -name 'sing-box' | head -n1)"
  [[ -n "$bin" ]] || { rm -rf "$tmp"; err "解压失败：未找到 sing-box 可执行文件"; return 1; }

  install -m 0755 "$bin" "$BIN_PATH"
  rm -rf "$tmp"
  info "安装完成：$("$BIN_PATH" version | head -n1)"
}

# ===== systemd =====
write_systemd(){ cat > "/etc/systemd/system/${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Sing-Box-totoyo-999 (20 nodes: direct 10 + WARP 10)
After=network-online.target warp-svc.service
Wants=network-online.target warp-svc.service
Requires=network-online.target

[Service]
Type=simple
Environment=ENABLE_DEPRECATED_WIREGUARD_OUTBOUND=true
ExecStart=${BIN_PATH} run -c ${CONF_JSON} -D ${DATA_DIR}
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
}

# ===== 写 config.json（使用你提供的稳定配置逻辑） =====
write_config(){
  ensure_dirs; load_env || true; load_creds || true; load_ports || true
  ensure_creds; save_all_ports; mk_cert
  [[ "$ENABLE_WARP" == "true" ]] && ensure_warpcli_proxy

  local CRT="$CERT_DIR/fullchain.pem" KEY="$CERT_DIR/key.pem"
  jq -n \
  --arg RS "$REALITY_SERVER" --argjson RSP "${REALITY_SERVER_PORT:-443}" --arg UID "$UUID" \
  --arg WSHOST "$WARP_SOCKS_HOST" --argjson WSPORT "$WARP_SOCKS_PORT" \
  --arg RPR "$REALITY_PRIV" --arg RPB "$REALITY_PUB" --arg SID "$REALITY_SID" \
  --arg HY2 "$HY2_PWD" --arg HY22 "$HY2_PWD2" --arg HY2O "$HY2_OBFS_PWD" \
  --arg GRPC "$GRPC_SERVICE" --arg VMWS "$VMESS_WS_PATH" --arg CRT "$CRT" --arg KEY "$KEY" \
  --arg SS2022 "$SS2022_KEY" --arg SSPWD "$SS_PWD" --arg TUICUUID "$TUIC_UUID" --arg TUICPWD "$TUIC_PWD" \
  --arg ATPWD "$ANYTLS_PWD" \
  --argjson P1 "$PORT_VLESSR" --argjson P2 "$PORT_VLESS_GRPCR" --argjson P3 "$PORT_TROJANR" \
  --argjson P4 "$PORT_HY2" --argjson P5 "$PORT_VMESS_WS" --argjson P6 "$PORT_HY2_OBFS" \
  --argjson P7 "$PORT_SS2022" --argjson P8 "$PORT_SS" --argjson P9 "$PORT_TUIC" \
  --argjson P10 "$PORT_ANYTLS" \
  --argjson PW1 "$PORT_VLESSR_W" --argjson PW2 "$PORT_VLESS_GRPCR_W" --argjson PW3 "$PORT_TROJANR_W" \
  --argjson PW4 "$PORT_HY2_W" --argjson PW5 "$PORT_VMESS_WS_W" --argjson PW6 "$PORT_HY2_OBFS_W" \
  --argjson PW7 "$PORT_SS2022_W" --argjson PW8 "$PORT_SS_W" --argjson PW9 "$PORT_TUIC_W" \
  --argjson PW10 "$PORT_ANYTLS_W" \
  --arg ENABLE_WARP "$ENABLE_WARP" \
  --arg EN_VR   "${ENABLE_VLESS_REALITY:-true}" \
  --arg EN_VG   "${ENABLE_VLESS_GRPCR:-true}" \
  --arg EN_TR   "${ENABLE_TROJAN_REALITY:-true}" \
  --arg EN_HY2  "${ENABLE_HYSTERIA2:-true}" \
  --arg EN_VM   "${ENABLE_VMESS_WS:-true}" \
  --arg EN_HO   "${ENABLE_HY2_OBFS:-true}" \
  --arg EN_SS2  "${ENABLE_SS2022:-true}" \
  --arg EN_SS   "${ENABLE_SS:-true}" \
  --arg EN_TU   "${ENABLE_TUIC:-true}" \
  --arg EN_AT   "${ENABLE_ANYTLS:-true}" \
  --arg WPRIV "${WARP_PRIVATE_KEY:-}" --arg WPPUB "${WARP_PEER_PUBLIC_KEY:-}" \
  --arg WHOST "${WARP_ENDPOINT_HOST:-}" --argjson WPORT "${WARP_ENDPOINT_PORT:-0}" \
  --arg W4 "${WARP_ADDRESS_V4:-}" --arg W6 "${WARP_ADDRESS_V6:-}" \
  --argjson WR1 "${WARP_RESERVED_1:-0}" --argjson WR2 "${WARP_RESERVED_2:-0}" --argjson WR3 "${WARP_RESERVED_3:-0}" \
  '
  def inbound_vless($port): {type:"vless", listen:"::", listen_port:$port, users:[{uuid:$UID}], tls:{enabled:true, server_name:$RS, reality:{enabled:true, handshake:{server:$RS, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}};
  def inbound_vless_flow($port): {type:"vless", listen:"::", listen_port:$port, users:[{uuid:$UID, flow:"xtls-rprx-vision"}], tls:{enabled:true, server_name:$RS, reality:{enabled:true, handshake:{server:$RS, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}};
  def inbound_trojan($port): {type:"trojan", listen:"::", listen_port:$port, users:[{password:$UID}], tls:{enabled:true, server_name:$RS, reality:{enabled:true, handshake:{server:$RS, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}};
  def inbound_hy2($port): {type:"hysteria2", listen:"::", listen_port:$port, users:[{name:"hy2", password:$HY2}], tls:{enabled:true, certificate_path:$CRT, key_path:$KEY}};
  def inbound_vmess_ws($port): {type:"vmess", listen:"::", listen_port:$port, users:[{uuid:$UID}], transport:{type:"ws", path:$VMWS}};
  def inbound_hy2_obfs($port): {type:"hysteria2", listen:"::", listen_port:$port, users:[{name:"hy2", password:$HY22}], obfs:{type:"salamander", password:$HY2O}, tls:{enabled:true, certificate_path:$CRT, key_path:$KEY, alpn:["h3"]}};
  def inbound_ss2022($port): {type:"shadowsocks", listen:"::", listen_port:$port, method:"2022-blake3-aes-256-gcm", password:$SS2022};
  def inbound_ss($port): {type:"shadowsocks", listen:"::", listen_port:$port, method:"aes-256-gcm", password:$SSPWD};
  def inbound_tuic($port): {type:"tuic", listen:"::", listen_port:$port, users:[{uuid:$TUICUUID, password:$TUICPWD}], congestion_control:"bbr", tls:{enabled:true, certificate_path:$CRT, key_path:$KEY, alpn:["h3"]}};
  def inbound_anytls($port): {type:"anytls", listen:"::", listen_port:$port, users:[{password:$ATPWD}], tls:{enabled:true, certificate_path:$CRT, key_path:$KEY}};

  def warp_outbound:
    {type:"socks", tag:"warp", server:$WSHOST, server_port:$WSPORT};


  {
    log:{level:"info", timestamp:true},
    dns:{ servers:[ {tag:"dns-remote", address:"https://1.1.1.1/dns-query", detour:"direct"}, {address:"tls://dns.google", detour:"direct"} ], strategy:"prefer_ipv4" },
    inbounds:[
      (if $EN_VR  =="true" then [(inbound_vless_flow($P1) + {tag:"vless-reality"})]    else [] end)[],
      (if $EN_VG  =="true" then [(inbound_vless($P2) + {tag:"vless-grpcr", transport:{type:"grpc", service_name:$GRPC}})] else [] end)[],
      (if $EN_TR  =="true" then [(inbound_trojan($P3) + {tag:"trojan-reality"})]       else [] end)[],
      (if $EN_HY2 =="true" then [(inbound_hy2($P4) + {tag:"hy2"})]                    else [] end)[],
      (if $EN_VM  =="true" then [(inbound_vmess_ws($P5) + {tag:"vmess-ws"})]           else [] end)[],
      (if $EN_HO  =="true" then [(inbound_hy2_obfs($P6) + {tag:"hy2-obfs"})]          else [] end)[],
      (if $EN_SS2 =="true" then [(inbound_ss2022($P7) + {tag:"ss2022"})]               else [] end)[],
      (if $EN_SS  =="true" then [(inbound_ss($P8) + {tag:"ss"})]                       else [] end)[],
      (if $EN_TU  =="true" then [(inbound_tuic($P9) + {tag:"tuic-v5"})]               else [] end)[],
      (if $EN_AT  =="true" then [(inbound_anytls($P10) + {tag:"anytls"})]             else [] end)[],

      (if $ENABLE_WARP=="true" and $EN_VR  =="true" then [(inbound_vless_flow($PW1) + {tag:"vless-reality-warp"})]    else [] end)[],
      (if $ENABLE_WARP=="true" and $EN_VG  =="true" then [(inbound_vless($PW2) + {tag:"vless-grpcr-warp", transport:{type:"grpc", service_name:$GRPC}})] else [] end)[],
      (if $ENABLE_WARP=="true" and $EN_TR  =="true" then [(inbound_trojan($PW3) + {tag:"trojan-reality-warp"})]       else [] end)[],
      (if $ENABLE_WARP=="true" and $EN_HY2 =="true" then [(inbound_hy2($PW4) + {tag:"hy2-warp"})]                    else [] end)[],
      (if $ENABLE_WARP=="true" and $EN_VM  =="true" then [(inbound_vmess_ws($PW5) + {tag:"vmess-ws-warp"})]           else [] end)[],
      (if $ENABLE_WARP=="true" and $EN_HO  =="true" then [(inbound_hy2_obfs($PW6) + {tag:"hy2-obfs-warp"})]          else [] end)[],
      (if $ENABLE_WARP=="true" and $EN_SS2 =="true" then [(inbound_ss2022($PW7) + {tag:"ss2022-warp"})]               else [] end)[],
      (if $ENABLE_WARP=="true" and $EN_SS  =="true" then [(inbound_ss($PW8) + {tag:"ss-warp"})]                       else [] end)[],
      (if $ENABLE_WARP=="true" and $EN_TU  =="true" then [(inbound_tuic($PW9) + {tag:"tuic-v5-warp"})]               else [] end)[],
      (if $ENABLE_WARP=="true" and $EN_AT  =="true" then [(inbound_anytls($PW10) + {tag:"anytls-warp"})]             else [] end)[]
    ],
    outbounds: (
      if $ENABLE_WARP=="true" then
        [{type:"direct", tag:"direct"}, {type:"block", tag:"block"}, warp_outbound]
      else
        [{type:"direct", tag:"direct"}, {type:"block", tag:"block"}]
      end
    ),
    route: (
      if $ENABLE_WARP=="true" then
        { default_domain_resolver:"dns-remote", rules:[
            { inbound: (
                [ (if $EN_VR =="true" then "vless-reality-warp"  else null end),
                  (if $EN_VG =="true" then "vless-grpcr-warp"    else null end),
                  (if $EN_TR =="true" then "trojan-reality-warp"  else null end),
                  (if $EN_HY2=="true" then "hy2-warp"            else null end),
                  (if $EN_VM =="true" then "vmess-ws-warp"        else null end),
                  (if $EN_HO =="true" then "hy2-obfs-warp"       else null end),
                  (if $EN_SS2=="true" then "ss2022-warp"          else null end),
                  (if $EN_SS =="true" then "ss-warp"              else null end),
                  (if $EN_TU =="true" then "tuic-v5-warp"         else null end),
                  (if $EN_AT =="true" then "anytls-warp"          else null end)
                ] | [.[] | select(. != null)]
              ), outbound:"warp" }
          ],
          final:"direct"
        }
      else
        { final:"direct" }
      end
    )
  }' > "$CONF_JSON"
  save_env
}

# ===== 协议开关管理 =====
manage_protos(){
  load_env || true; load_ports || true

  # 默认全开
  : "${ENABLE_VLESS_REALITY:=true}"
  : "${ENABLE_VLESS_GRPCR:=true}"
  : "${ENABLE_TROJAN_REALITY:=true}"
  : "${ENABLE_HYSTERIA2:=true}"
  : "${ENABLE_VMESS_WS:=true}"
  : "${ENABLE_HY2_OBFS:=true}"
  : "${ENABLE_SS2022:=true}"
  : "${ENABLE_SS:=true}"
  : "${ENABLE_TUIC:=true}"
  : "${ENABLE_ANYTLS:=true}"

  local names=(
    "vless-reality"
    "vless-grpcr"
    "trojan-reality"
    "hysteria2"
    "vmess-ws"
    "hy2-obfs"
    "ss2022"
    "ss"
    "tuic-v5"
    "anytls"
  )
  local vars=(
    ENABLE_VLESS_REALITY
    ENABLE_VLESS_GRPCR
    ENABLE_TROJAN_REALITY
    ENABLE_HYSTERIA2
    ENABLE_VMESS_WS
    ENABLE_HY2_OBFS
    ENABLE_SS2022
    ENABLE_SS
    ENABLE_TUIC
    ENABLE_ANYTLS
  )

  while true; do
    clear
    echo -e "\n  ${C_BLUE}=== 节点开关管理（直连/WARP 同步切换）===${C_RESET}\n"
    local i
    for i in "${!names[@]}"; do
      local varname="${vars[$i]}"
      local val="${!varname}"
      if [[ "$val" == "true" ]]; then
        echo -e "  ${C_GREEN}[$((i+1))] [ON] ${C_RESET}${names[$i]}"
      else
        echo -e "  ${C_RED}[$((i+1))] [OFF]${C_RESET}${names[$i]}"
      fi
    done
    echo ""
    echo -e "  ${C_BLUE}[a]${C_RESET} 全部开启   ${C_RED}[x]${C_RESET} 全部关闭"
    echo -e "  ${C_GREEN}[s]${C_RESET} 保存并重启服务   ${C_RED}[0]${C_RESET} 放弃退出"
    echo ""
    read -rp "  输入编号切换（多个用空格，如: 1 3 5）: " input || true

    case "${input:-}" in
      0) return ;;
      a)
        for v in "${vars[@]}"; do eval "$v=true"; done
        echo -e "  ${C_GREEN}全部已开启${C_RESET}"
        ;;
      x)
        for v in "${vars[@]}"; do eval "$v=false"; done
        echo -e "  ${C_RED}全部已关闭（至少保留 1 个才能正常运行）${C_RESET}"
        ;;
      s)
        save_env
        echo -e "\n  ${C_BLUE}[信息] 正在重写配置并重启服务...${C_RESET}"
        write_config || { echo "[ERR] 生成配置失败"; read -rp "回车返回..." _ || true; return; }
        systemctl restart "${SYSTEMD_SERVICE}" 2>/dev/null || true
        echo -e "  ${C_GREEN}完成！服务已重启。${C_RESET}"
        sleep 1
        return
        ;;
      *)
        for num in $input; do
          if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#vars[@]} )); then
            local idx=$(( num - 1 ))
            local vname="${vars[$idx]}"
            if [[ "${!vname}" == "true" ]]; then
              eval "$vname=false"
            else
              eval "$vname=true"
            fi
          fi
        done
        ;;
    esac
  done
}

# ===== 防火墙 =====
open_firewall(){
  local rules=()
  rules+=("${PORT_VLESSR}/tcp" "${PORT_VLESS_GRPCR}/tcp" "${PORT_TROJANR}/tcp" "${PORT_VMESS_WS}/tcp" "${PORT_ANYTLS}/tcp")
  rules+=("${PORT_HY2}/udp" "${PORT_HY2_OBFS}/udp" "${PORT_TUIC}/udp")
  rules+=("${PORT_SS2022}/tcp" "${PORT_SS2022}/udp" "${PORT_SS}/tcp" "${PORT_SS}/udp")
  rules+=("${PORT_VLESSR_W}/tcp" "${PORT_VLESS_GRPCR_W}/tcp" "${PORT_TROJANR_W}/tcp" "${PORT_VMESS_WS_W}/tcp" "${PORT_ANYTLS_W}/tcp")
  rules+=("${PORT_HY2_W}/udp" "${PORT_HY2_OBFS_W}/udp" "${PORT_TUIC_W}/udp")
  rules+=("${PORT_SS2022_W}/tcp" "${PORT_SS2022_W}/udp" "${PORT_SS_W}/tcp" "${PORT_SS_W}/udp")

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q -E "active|活跃"; then
    for r in "${rules[@]}"; do ufw allow "$r" >/dev/null 2>&1 || true; done
    ufw reload >/dev/null 2>&1 || true

  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    systemctl enable --now firewalld >/dev/null 2>&1 || true
    for r in "${rules[@]}"; do firewall-cmd --permanent --add-port="$r" >/dev/null 2>&1 || true; done
    firewall-cmd --reload >/dev/null 2>&1 || true

  else
    local p proto
    for r in "${rules[@]}"; do
      p="${r%/*}"; proto="${r#*/}"

      # IPv4
      if [[ "$proto" == tcp ]]; then
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
      fi
      if [[ "$proto" == udp ]]; then
        iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT
      fi

      # IPv6（关键补全）
      if command -v ip6tables >/dev/null 2>&1; then
        if [[ "$proto" == tcp ]]; then
          ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT
        fi
        if [[ "$proto" == udp ]]; then
          ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$p" -j ACCEPT
        fi
      fi
    done

    # 保存（netfilter-persistent 通常会把 v4/v6 一起保存）
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

# ===== 分享链接（分组输出 + 提示） =====
print_links_grouped(){
  load_env; load_creds; load_ports; load_icon
  local mode="${1:-4}" ip host
  local I="${NODE_ICON:-}"
  if [[ "$mode" == "6" ]]; then
    ip="$(get_ip6)"
    if [[ -z "$ip" ]]; then
      warn "未检测到公网 IPv6，自动回退到 IPv4"
      ip="$(get_ip4)"
      mode="4"
    fi
  else
    ip="$(get_ip4)"
  fi
  host="$(fmt_host_for_uri "$ip")"
  local links_direct=() links_warp=()
  # 直连 10
  links_direct+=("vless://${UUID}@${host}:${PORT_VLESSR}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#${I}vless-reality")
  links_direct+=("vless://${UUID}@${host}:${PORT_VLESS_GRPCR}?encryption=none&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#${I}vless-grpc-reality")
  links_direct+=("trojan://${UUID}@${host}:${PORT_TROJANR}?security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#${I}trojan-reality")
  links_direct+=("hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#${I}hysteria2")
  local VMESS_JSON; VMESS_JSON=$(cat <<JSON
{"v":"2","ps":"${I}vmess-ws","add":"${ip}","port":"${PORT_VMESS_WS}","id":"${UUID}","aid":"0","net":"ws","type":"none","host":"","path":"${VMESS_WS_PATH}","tls":""}
JSON
  )
  links_direct+=("vmess://$(printf "%s" "$VMESS_JSON" | b64enc)")
  links_direct+=("hy2://$(urlenc "${HY2_PWD2}")@${host}:${PORT_HY2_OBFS}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#${I}hysteria2-obfs")
  links_direct+=("ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${host}:${PORT_SS2022}#${I}ss2022")
  links_direct+=("ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${host}:${PORT_SS}#${I}ss")
  links_direct+=("tuic://${UUID}:$(urlenc "${UUID}")@${host}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#${I}tuic-v5")
  links_direct+=("anytls://$(urlenc "${ANYTLS_PWD}")@${host}:${PORT_ANYTLS}?insecure=1&sni=${REALITY_SERVER}#${I}anytls")

  # WARP 10
  links_warp+=("vless://${UUID}@${host}:${PORT_VLESSR_W}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#${I}vless-reality-warp")
  links_warp+=("vless://${UUID}@${host}:${PORT_VLESS_GRPCR_W}?encryption=none&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#${I}vless-grpc-reality-warp")
  links_warp+=("trojan://${UUID}@${host}:${PORT_TROJANR_W}?security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#${I}trojan-reality-warp")
  links_warp+=("hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2_W}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#${I}hysteria2-warp")
  local VMESS_JSON_W; VMESS_JSON_W=$(cat <<JSON
{"v":"2","ps":"${I}vmess-ws-warp","add":"${ip}","port":"${PORT_VMESS_WS_W}","id":"${UUID}","aid":"0","net":"ws","type":"none","host":"","path":"${VMESS_WS_PATH}","tls":""}
JSON
  )
  links_warp+=("vmess://$(printf "%s" "$VMESS_JSON_W" | b64enc)")
  links_warp+=("hy2://$(urlenc "${HY2_PWD2}")@${host}:${PORT_HY2_OBFS_W}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#${I}hysteria2-obfs-warp")
  links_warp+=("ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${host}:${PORT_SS2022_W}#${I}ss2022-warp")
  links_warp+=("ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${host}:${PORT_SS_W}#${I}ss-warp")
  links_warp+=("tuic://${UUID}:$(urlenc "${UUID}")@${host}:${PORT_TUIC_W}?congestion_control=bbr&alpn=h3&insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#${I}tuic-v5-warp")
  links_warp+=("anytls://$(urlenc "${ANYTLS_PWD}")@${host}:${PORT_ANYTLS_W}?insecure=1&sni=${REALITY_SERVER}#${I}anytls-warp")

  echo -e "${C_BLUE}${C_BOLD}分享链接（20 个）${C_RESET}"
  hr
  echo -e "${C_CYAN}${C_BOLD}【直连节点（10）】${C_RESET}（vless-reality / vless-grpc-reality / trojan-reality / vmess-ws / hy2 / hy2-obfs / ss2022 / ss / tuic / anytls）"
  for l in "${links_direct[@]}"; do echo "  $l"; done
  hr
  echo -e "${C_CYAN}${C_BOLD}【WARP 节点（10）】${C_RESET}（同上 10 种，带 -warp）"
  echo -e "${C_DIM}说明：带 -warp 的 10 个节点走 Cloudflare WARP 出口，流媒体解锁更友好${C_RESET}"
  echo -e "${C_DIM}提示：TUIC 默认 allowInsecure=1，v2rayN 导入即用${C_RESET}"
  for l in "${links_warp[@]}"; do echo "  $l"; done
  hr
}

# ===== BBR =====
enable_bbr(){
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    info "BBR 已启用"
  else
    echo "net.core.default_qdisc=fq" >/etc/sysctl.d/99-bbr.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.d/99-bbr.conf
    sysctl --system >/dev/null 2>&1 || true
    info "已尝试开启 BBR（如内核不支持需自行升级）"
  fi
}

# ===== 显示状态与 banner =====
sb_service_state(){
  systemctl is-active --quiet "${SYSTEMD_SERVICE:-sing-box.service}" && echo -e "${C_GREEN}运行中${C_RESET}" || echo -e "${C_RED}未运行/未安装${C_RESET}"
}
bbr_state(){
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && echo -e "${C_GREEN}已启用 BBR${C_RESET}" || echo -e "${C_RED}未启用 BBR${C_RESET}"
}

banner(){
  clear >/dev/null 2>&1 || true
  hr
  echo -e " ${C_CYAN}🚀 ${SCRIPT_NAME} ${SCRIPT_VERSION} 🚀${C_RESET}"
  echo -e "${C_CYAN} Matrix_Core_System: https://github.com/totoyo-999/Matrix-Core${C_RESET}"

  hr
  echo -e "系统加速状态：$(bbr_state)"
  echo -e "Sing-Box 启动状态：$(sb_service_state)"
  hr
  echo -e "  ${C_BLUE}1)${C_RESET} 安装/部署（20 节点）"
  echo -e "  ${C_GREEN}2)${C_RESET} 查看分享链接（IPv4）"
  echo -e "  ${C_GREEN}6)${C_RESET} 查看分享链接（IPv6）"
  echo -e "  ${C_GREEN}3)${C_RESET} 重启服务"
  echo -e "  ${C_GREEN}4)${C_RESET} 一键更换所有端口"
  echo -e "  ${C_GREEN}5)${C_RESET} 一键开启 BBR"
  echo -e "  ${C_YELLOW}7)${C_RESET} 节点开关管理"
  echo -e "  ${C_RED}8)${C_RESET} 卸载"
  hr
  echo -e "  ${C_CYAN}9)${C_RESET}  节点测速"
  echo -e "  ${C_CYAN}10)${C_RESET} 订阅链接生成"
  echo -e "  ${C_CYAN}11)${C_RESET} 配置备份"
  echo -e "  ${C_CYAN}12)${C_RESET} 配置恢复"
  echo -e "  ${C_CYAN}13)${C_RESET} 实时日志"
  echo -e "  ${C_MAGENTA}14)${C_RESET} 设置节点图标"
  hr
  echo -e "  ${C_RED}0)${C_RESET} 退出"
  hr
}

# ===== 业务流程 =====
restart_service(){
  systemctl restart "${SYSTEMD_SERVICE}" || die "重启失败"
  systemctl --no-pager status "${SYSTEMD_SERVICE}" | sed -n '1,6p' || true
}

# ===== 节点测速 =====
speed_test(){
  ensure_installed_or_hint || return 0
  load_ports; load_env; load_creds
  local ip=$(get_ip4)
  echo -e "\n${C_CYAN}=== 节点延迟测试 (TCP Ping) ===${C_RESET}"
  echo -e "服务器IP: ${ip}\n"
  
  # 安装 tcping 如果不存在
  if ! command -v tcping >/dev/null 2>&1; then
    info "正在安装 tcping..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y >/dev/null 2>&1 && apt-get install -y tcping >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
      # 从源码安装 tcping
      local tmp=$(mktemp -d)
      curl -fsSL -o "$tmp/tcping" https://github.com/pouriyajamshidi/tcping/releases/latest/download/tcping-linux-amd64 2>/dev/null || true
      if [[ -f "$tmp/tcping" ]]; then
        chmod +x "$tmp/tcping"
        mv "$tmp/tcping" /usr/local/bin/tcping
      fi
      rm -rf "$tmp"
    fi
  fi
  
  # 使用 tcping 或 nc 作为备选
  local has_tcping=false
  command -v tcping >/dev/null 2>&1 && has_tcping=true
  
  test_port(){
    local name="$1" port="$2"
    if [[ -z "$port" ]]; then
      echo -e "${C_DIM}${name}: 未启用${C_RESET}"
      return
    fi
    
    if [[ "$has_tcping" == "true" ]]; then
      local result=$(tcping -c 3 -t 3 "$ip" "$port" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+ms' | head -1)
      if [[ -n "$result" ]]; then
        echo -e "${C_GREEN}${name}${C_RESET} (${port}): ${result} ✓"
      else
        echo -e "${C_RED}${name}${C_RESET} (${port}): 超时 ✗"
      fi
    else
      # 使用 nc 测试端口连通性
      if nc -z -w 3 "$ip" "$port" 2>/dev/null; then
        echo -e "${C_GREEN}${name}${C_RESET} (${port}): 连通 ✓"
      else
        echo -e "${C_RED}${name}${C_RESET} (${port}): 不通 ✗"
      fi
    fi
  }
  
  echo -e "${C_BOLD}【直连节点】${C_RESET}"
  [[ "${ENABLE_VLESS_REALITY:-true}" == "true" ]] && test_port "vless-reality" "$PORT_VLESSR"
  [[ "${ENABLE_VLESS_GRPCR:-true}" == "true" ]] && test_port "vless-grpcr" "$PORT_VLESS_GRPCR"
  [[ "${ENABLE_TROJAN_REALITY:-true}" == "true" ]] && test_port "trojan-reality" "$PORT_TROJANR"
  [[ "${ENABLE_HYSTERIA2:-true}" == "true" ]] && test_port "hysteria2" "$PORT_HY2"
  [[ "${ENABLE_VMESS_WS:-true}" == "true" ]] && test_port "vmess-ws" "$PORT_VMESS_WS"
  [[ "${ENABLE_HY2_OBFS:-true}" == "true" ]] && test_port "hy2-obfs" "$PORT_HY2_OBFS"
  [[ "${ENABLE_SS2022:-true}" == "true" ]] && test_port "ss2022" "$PORT_SS2022"
  [[ "${ENABLE_SS:-true}" == "true" ]] && test_port "ss" "$PORT_SS"
  [[ "${ENABLE_TUIC:-true}" == "true" ]] && test_port "tuic-v5" "$PORT_TUIC"
  [[ "${ENABLE_ANYTLS:-true}" == "true" ]] && test_port "anytls" "$PORT_ANYTLS"
  
  if [[ "${ENABLE_WARP:-true}" == "true" ]]; then
    echo -e "\n${C_BOLD}【WARP 节点】${C_RESET}"
    [[ "${ENABLE_VLESS_REALITY:-true}" == "true" ]] && test_port "vless-reality-warp" "$PORT_VLESSR_W"
    [[ "${ENABLE_VLESS_GRPCR:-true}" == "true" ]] && test_port "vless-grpcr-warp" "$PORT_VLESS_GRPCR_W"
    [[ "${ENABLE_TROJAN_REALITY:-true}" == "true" ]] && test_port "trojan-reality-warp" "$PORT_TROJANR_W"
    [[ "${ENABLE_HYSTERIA2:-true}" == "true" ]] && test_port "hysteria2-warp" "$PORT_HY2_W"
    [[ "${ENABLE_VMESS_WS:-true}" == "true" ]] && test_port "vmess-ws-warp" "$PORT_VMESS_WS_W"
    [[ "${ENABLE_HY2_OBFS:-true}" == "true" ]] && test_port "hy2-obfs-warp" "$PORT_HY2_OBFS_W"
    [[ "${ENABLE_SS2022:-true}" == "true" ]] && test_port "ss2022-warp" "$PORT_SS2022_W"
    [[ "${ENABLE_SS:-true}" == "true" ]] && test_port "ss-warp" "$PORT_SS_W"
    [[ "${ENABLE_TUIC:-true}" == "true" ]] && test_port "tuic-v5-warp" "$PORT_TUIC_W"
    [[ "${ENABLE_ANYTLS:-true}" == "true" ]] && test_port "anytls-warp" "$PORT_ANYTLS_W"
  fi
  
  echo ""
  read -rp "回车返回..." _ || true
}

# ===== 订阅链接生成 =====
gen_subscription(){
  ensure_installed_or_hint || return 0
  load_env; load_creds; load_ports; load_icon
  local ip=$(get_ip4)
  local host=$(fmt_host_for_uri "$ip")
  local I="${NODE_ICON:-}"
  
  echo -e "\n${C_CYAN}=== 生成订阅链接 ===${C_RESET}\n"
  
  # 收集所有启用的节点链接
  local links=""
  
  add_link(){
    local link="$1"
    if [[ -n "$links" ]]; then
      links="${links}\n${link}"
    else
      links="${link}"
    fi
  }
  
  # 直连节点
  if [[ "${ENABLE_VLESS_REALITY:-true}" == "true" ]]; then
    add_link "vless://${UUID}@${host}:${PORT_VLESSR}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#${I}vless-reality"
  fi
  if [[ "${ENABLE_VLESS_GRPCR:-true}" == "true" ]]; then
    add_link "vless://${UUID}@${host}:${PORT_VLESS_GRPCR}?encryption=none&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#${I}vless-grpc-reality"
  fi
  if [[ "${ENABLE_TROJAN_REALITY:-true}" == "true" ]]; then
    add_link "trojan://${UUID}@${host}:${PORT_TROJANR}?security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#${I}trojan-reality"
  fi
  if [[ "${ENABLE_HYSTERIA2:-true}" == "true" ]]; then
    add_link "hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#${I}hysteria2"
  fi
  if [[ "${ENABLE_VMESS_WS:-true}" == "true" ]]; then
    local VMESS_JSON=$(cat <<JSON
{"v":"2","ps":"${I}vmess-ws","add":"${ip}","port":"${PORT_VMESS_WS}","id":"${UUID}","aid":"0","net":"ws","type":"none","host":"","path":"${VMESS_WS_PATH}","tls":""}
JSON
)
    add_link "vmess://$(printf "%s" "$VMESS_JSON" | b64enc)"
  fi
  if [[ "${ENABLE_HY2_OBFS:-true}" == "true" ]]; then
    add_link "hy2://$(urlenc "${HY2_PWD2}")@${host}:${PORT_HY2_OBFS}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#${I}hysteria2-obfs"
  fi
  if [[ "${ENABLE_SS2022:-true}" == "true" ]]; then
    add_link "ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${host}:${PORT_SS2022}#${I}ss2022"
  fi
  if [[ "${ENABLE_SS:-true}" == "true" ]]; then
    add_link "ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${host}:${PORT_SS}#${I}ss"
  fi
  if [[ "${ENABLE_TUIC:-true}" == "true" ]]; then
    add_link "tuic://${UUID}:$(urlenc "${UUID}")@${host}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#${I}tuic-v5"
  fi
  if [[ "${ENABLE_ANYTLS:-true}" == "true" ]]; then
    add_link "anytls://$(urlenc "${ANYTLS_PWD}")@${host}:${PORT_ANYTLS}?insecure=1&sni=${REALITY_SERVER}#${I}anytls"
  fi
  
  # WARP 节点
  if [[ "${ENABLE_WARP:-true}" == "true" ]]; then
    if [[ "${ENABLE_VLESS_REALITY:-true}" == "true" ]]; then
      add_link "vless://${UUID}@${host}:${PORT_VLESSR_W}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#${I}vless-reality-warp"
    fi
    if [[ "${ENABLE_VLESS_GRPCR:-true}" == "true" ]]; then
      add_link "vless://${UUID}@${host}:${PORT_VLESS_GRPCR_W}?encryption=none&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#${I}vless-grpc-reality-warp"
    fi
    if [[ "${ENABLE_TROJAN_REALITY:-true}" == "true" ]]; then
      add_link "trojan://${UUID}@${host}:${PORT_TROJANR_W}?security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#${I}trojan-reality-warp"
    fi
    if [[ "${ENABLE_HYSTERIA2:-true}" == "true" ]]; then
      add_link "hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2_W}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#${I}hysteria2-warp"
    fi
    if [[ "${ENABLE_VMESS_WS:-true}" == "true" ]]; then
      local VMESS_JSON_W=$(cat <<JSON
{"v":"2","ps":"${I}vmess-ws-warp","add":"${ip}","port":"${PORT_VMESS_WS_W}","id":"${UUID}","aid":"0","net":"ws","type":"none","host":"","path":"${VMESS_WS_PATH}","tls":""}
JSON
)
      add_link "vmess://$(printf "%s" "$VMESS_JSON_W" | b64enc)"
    fi
    if [[ "${ENABLE_HY2_OBFS:-true}" == "true" ]]; then
      add_link "hy2://$(urlenc "${HY2_PWD2}")@${host}:${PORT_HY2_OBFS_W}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#${I}hysteria2-obfs-warp"
    fi
    if [[ "${ENABLE_SS2022:-true}" == "true" ]]; then
      add_link "ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${host}:${PORT_SS2022_W}#${I}ss2022-warp"
    fi
    if [[ "${ENABLE_SS:-true}" == "true" ]]; then
      add_link "ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${host}:${PORT_SS_W}#${I}ss-warp"
    fi
    if [[ "${ENABLE_TUIC:-true}" == "true" ]]; then
      add_link "tuic://${UUID}:$(urlenc "${UUID}")@${host}:${PORT_TUIC_W}?congestion_control=bbr&alpn=h3&insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#${I}tuic-v5-warp"
    fi
    if [[ "${ENABLE_ANYTLS:-true}" == "true" ]]; then
      add_link "anytls://$(urlenc "${ANYTLS_PWD}")@${host}:${PORT_ANYTLS_W}?insecure=1&sni=${REALITY_SERVER}#${I}anytls-warp"
    fi
  fi
  
  # 生成 base64 订阅
  local sub_b64=$(printf "%b" "$links" | base64 -w 0 2>/dev/null || printf "%b" "$links" | base64)
  local sub_web="/var/www/html/sub/singbox.txt"
  
  # 确保目录存在
  mkdir -p /var/www/html/sub
  
  # 同时保存到 web 目录和本地
  echo "$sub_b64" > "$sub_web"
  local local_ip=$(get_ip4)
  
  echo -e "${C_GREEN}订阅链接已生成！${C_RESET}\n"
  echo -e "${C_BOLD}v2rayN 订阅地址:${C_RESET}"
  echo -e "${C_YELLOW}  http://${local_ip}/sub/singbox.txt${C_RESET}\n"
  echo -e "${C_BOLD}节点数量:${C_RESET} $(echo -e "$links" | wc -l)\n"
  echo -e "${C_YELLOW}提示: 在 v2rayN 中添加订阅 → 填入上面的 URL → 点击更新${C_RESET}"
  
  read -rp "\n回车返回..." _ || true
}

# ===== 设置节点图标 =====
set_node_icon(){
  load_icon
  echo -e "\n${C_CYAN}=== 设置节点图标 ===${C_RESET}\n"
  echo -e "${C_DIM}图标会加到所有节点别名前面，方便区分不同 VPS${C_RESET}\n"
  if [[ -n "$NODE_ICON" ]]; then
    echo -e "当前图标: ${C_BOLD}${C_GREEN}${NODE_ICON}${C_RESET}  示例: ${NODE_ICON}vless-reality"
  else
    echo -e "当前图标: ${C_DIM}未设置${C_RESET}"
  fi
  echo ""
  echo -e " ${C_BLUE}【动物】${C_RESET}"
  echo -e "  1) 🦊 狐狸   2) 🐉 龙     3) 🦁 狮子   4) 🐆 豹子"
  echo -e "  5) 🦅 鹰     6) 🐬 海豚   7) 🦈 鲨鱼   8) 🐺 狼"
  echo -e "  9) 🐝 蜜蜂  10) 🐈 猫    11) 🦉 猫头鹰 12) 🐧 企鹅"
  echo -e " 13) 🐊 鳄鱼  14) 🦩 火烈鸟 15) 🥷 忍者   16) 🐰 兔子"
  echo -e " 17) 🐻 熊    18) 🐶 狗    19) 🦋 蝴蝶   20) 🐢 乌龟"
  echo ""
  echo -e " ${C_BLUE}【协议/科技】${C_RESET}"
  echo -e " 21) ⚡ 闪电  22) 🔒 锁    23) 🛡️ 盾牌   24) 🚀 火箭"
  echo -e " 25) 🔗 链接  26) 🌀 旋涡   27) 🌊 浪花   28) 📡 卫星"
  echo -e " 29) 🔥 火焰  30) 💎 钻石   31) 🎯 靶心   32) 🧊 冰块"
  echo -e " 33) ⚙ 齿轮  34) ☢ 辐射   35) 💠 花形   36) 🔱 三叉戟"
  echo ""
  echo -e " ${C_BLUE}【国旗】${C_RESET}"
  echo -e " 37) 🇺🇸 美国  38) 🇯🇵 日本  39) 🇭🇰 香港  40) 🇸🇬 新加坡"
  echo -e " 41) 🇰🇷 韩国  42) 🇩🇪 德国  43) 🇬🇧 英国  44) 🇹🇼 台湾"
  echo ""
  echo -e " ${C_BLUE}【纯符号】${C_RESET}"
  echo -e " 45) ▲ 三角   46) ● 圆     47) ◆ 菱形   48) ★ 星"
  echo -e " 49) ❖ 菱花   50) ✦ 四角星 51) 🔴 红圆   52) 🔵 蓝圆"
  echo -e " 53) 🟢 绿圆  54) 🟡 黄圆  55) 🟣 紫圆   56) ⬛ 黑方"
  echo ""
  echo -e "  ${C_YELLOW}0)${C_RESET} 清除图标（不带图标）"
  echo -e "  ${C_YELLOW}c)${C_RESET} 自定义输入"
  echo -e "  ${C_RED}q)${C_RESET} 返回"
  echo ""
  read -rp "选择图标编号: " choice || true

  case "${choice:-}" in
    1)  NODE_ICON="🦊" ;;
    2)  NODE_ICON="🐉" ;;
    3)  NODE_ICON="🦁" ;;
    4)  NODE_ICON="🐆" ;;
    5)  NODE_ICON="🦅" ;;
    6)  NODE_ICON="🐬" ;;
    7)  NODE_ICON="🦈" ;;
    8)  NODE_ICON="🐺" ;;
    9)  NODE_ICON="🐝" ;;
    10) NODE_ICON="🐈" ;;
    11) NODE_ICON="🦉" ;;
    12) NODE_ICON="🐧" ;;
    13) NODE_ICON="🐊" ;;
    14) NODE_ICON="🦩" ;;
    15) NODE_ICON="🥷" ;;
    16) NODE_ICON="🐰" ;;
    17) NODE_ICON="🐻" ;;
    18) NODE_ICON="🐶" ;;
    19) NODE_ICON="🦋" ;;
    20) NODE_ICON="🐢" ;;
    21) NODE_ICON="⚡" ;;
    22) NODE_ICON="🔒" ;;
    23) NODE_ICON="🛡️" ;;
    24) NODE_ICON="🚀" ;;
    25) NODE_ICON="🔗" ;;
    26) NODE_ICON="🌀" ;;
    27) NODE_ICON="🌊" ;;
    28) NODE_ICON="📡" ;;
    29) NODE_ICON="🔥" ;;
    30) NODE_ICON="💎" ;;
    31) NODE_ICON="🎯" ;;
    32) NODE_ICON="🧊" ;;
    33) NODE_ICON="⚙" ;;
    34) NODE_ICON="☢" ;;
    35) NODE_ICON="💠" ;;
    36) NODE_ICON="🔱" ;;
    37) NODE_ICON="🇺🇸" ;;
    38) NODE_ICON="🇯🇵" ;;
    39) NODE_ICON="🇭🇰" ;;
    40) NODE_ICON="🇸🇬" ;;
    41) NODE_ICON="🇰🇷" ;;
    42) NODE_ICON="🇩🇪" ;;
    43) NODE_ICON="🇬🇧" ;;
    44) NODE_ICON="🇹🇼" ;;
    45) NODE_ICON="▲" ;;
    46) NODE_ICON="●" ;;
    47) NODE_ICON="◆" ;;
    48) NODE_ICON="★" ;;
    49) NODE_ICON="❖" ;;
    50) NODE_ICON="✦" ;;
    51) NODE_ICON="🔴" ;;
    52) NODE_ICON="🔵" ;;
    53) NODE_ICON="🟢" ;;
    54) NODE_ICON="🟡" ;;
    55) NODE_ICON="🟣" ;;
    56) NODE_ICON="⬛" ;;
    0)
      NODE_ICON=""
      save_icon
      echo -e "\n${C_GREEN}图标已清除${C_RESET}"
      read -rp "回车返回... " _ || true
      return
      ;;
    c)
      echo ""
      read -rp "输入自定义图标（直接粘贴 emoji/符号）: " custom || true
      if [[ -n "${custom:-}" ]]; then
        NODE_ICON="$custom"
      else
        echo -e "${C_DIM}已取消${C_RESET}"
        return
      fi
      ;;
    q) return ;;
    *)
      echo -e "${C_RED}无效选择${C_RESET}"
      read -rp "回车返回... " _ || true
      return
      ;;
  esac

  save_icon
  echo -e "\n${C_GREEN}图标已设置为: ${C_BOLD}${NODE_ICON}${C_RESET}"
  echo -e "${C_DIM}节点别名示例: ${NODE_ICON}vless-reality / ${NODE_ICON}hysteria2-warp${C_RESET}"
  echo -e "${C_DIM}重新生成订阅链接后生效（菜单 10）${C_RESET}"
  read -rp "回车返回... " _ || true
}

# ===== 配置备份 =====
backup_config(){
  ensure_installed_or_hint || return 0
  local backup_file="/root/sing-box-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  
  echo -e "\n${C_CYAN}=== 配置备份 ===${C_RESET}\n"
  
  if tar -czf "$backup_file" -C "$(dirname "$SB_DIR")" "$(basename "$SB_DIR")" 2>/dev/null; then
    echo -e "${C_GREEN}备份成功！${C_RESET}"
    echo -e "备份文件: ${C_BOLD}${backup_file}${C_RESET}"
    echo -e "文件大小: $(du -h "$backup_file" | cut -f1)\n"
    echo -e "${C_YELLOW}提示: 请妥善保管此文件，恢复时需要用到${C_RESET}"
  else
    err "备份失败"
  fi
  
  read -rp "\n回车返回..." _ || true
}

# ===== 配置恢复 =====
restore_config(){
  echo -e "\n${C_CYAN}=== 配置恢复 ===${C_RESET}\n"
  
  # 查找备份文件
  local backups=($(ls -t /root/sing-box-backup-*.tar.gz 2>/dev/null))
  
  if [[ ${#backups[@]} -eq 0 ]]; then
    err "未找到备份文件 (/root/sing-box-backup-*.tar.gz)"
    read -rp "回车返回..." _ || true
    return
  fi
  
  echo -e "${C_BOLD}可用备份文件:${C_RESET}"
  local i
  for i in "${!backups[@]}"; do
    echo -e "  [${C_GREEN}$((i+1))${C_RESET}] ${backups[$i]} ($(du -h "${backups[$i]}" | cut -f1))"
  done
  echo -e "  [${C_RED}0${C_RESET}] 取消"
  
  read -rp "\n选择要恢复的备份: " choice
  
  if [[ "$choice" == "0" ]]; then
    return
  fi
  
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#backups[@]} )); then
    local selected="${backups[$((choice-1))]}"
    echo -e "\n${C_YELLOW}警告: 恢复将覆盖当前配置！${C_RESET}"
    read -rp "确认恢复? (y/N): " confirm
    
    if [[ "${confirm,,}" == "y" ]]; then
      systemctl stop "${SYSTEMD_SERVICE}" 2>/dev/null || true
      rm -rf "$SB_DIR"
      if tar -xzf "$selected" -C "$(dirname "$SB_DIR")" 2>/dev/null; then
        systemctl start "${SYSTEMD_SERVICE}" 2>/dev/null || true
        echo -e "${C_GREEN}恢复成功！服务已重启。${C_RESET}"
      else
        err "恢复失败"
      fi
    else
      echo -e "${C_DIM}已取消${C_RESET}"
    fi
  else
    err "无效选择"
  fi
  
  read -rp "\n回车返回..." _ || true
}

# ===== 实时日志 =====
view_logs(){
  ensure_installed_or_hint || return 0
  echo -e "\n${C_CYAN}=== 实时日志 (按 Ctrl+C 退出) ===${C_RESET}\n"
  echo -e "${C_DIM}显示最近 50 行日志，并实时更新...${C_RESET}\n"
  journalctl -u "${SYSTEMD_SERVICE}" -n 50 -f --no-pager || true
  echo ""
  read -rp "回车返回..." _ || true
}

rotate_ports(){
  ensure_installed_or_hint || return 0
  load_ports || true
  rand_ports_reset

  # 清空 20 项端口变量，触发重新分配不重复端口
  PORT_VLESSR=""; PORT_VLESS_GRPCR=""; PORT_TROJANR=""; PORT_HY2=""; PORT_VMESS_WS=""
  PORT_HY2_OBFS=""; PORT_SS2022=""; PORT_SS=""; PORT_TUIC=""; PORT_ANYTLS=""
  PORT_VLESSR_W=""; PORT_VLESS_GRPCR_W=""; PORT_TROJANR_W=""; PORT_HY2_W=""; PORT_VMESS_WS_W=""
  PORT_HY2_OBFS_W=""; PORT_SS2022_W=""; PORT_SS_W=""; PORT_TUIC_W=""; PORT_ANYTLS_W=""

  save_all_ports          # 重新生成并保存 20 个不重复端口
  write_config            # 用新端口重写 /opt/sing-box/config.json
  open_firewall           # ★ 新增：把“当前配置中的端口”全部放行
  systemctl restart "${SYSTEMD_SERVICE}"

  info "已更换端口并重启。"
  read -p "回车返回..." _ || true
}


uninstall_all(){
  systemctl stop "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SYSTEMD_SERVICE}"
  systemctl daemon-reload
  rm -rf "$SB_DIR"
  echo -e "${C_GREEN}已卸载并清理完成。${C_RESET}"
  exit 0
}

deploy_native(){
  install_deps
  install_singbox
  write_config
  info "检查配置 ..."
  ENABLE_DEPRECATED_WIREGUARD_OUTBOUND=true "$BIN_PATH" check -c "$CONF_JSON"
  info "写入并启用 systemd 服务 ..."
  write_systemd
    fix_dns
  open_firewall
  echo; echo -e "${C_BOLD}${C_GREEN}★ 部署完成（20 节点）${C_RESET}"; echo
  # 打印链接并直接退出
  print_links_grouped 4
  exit 0
}

ensure_installed_or_hint(){
  if [[ ! -f "$CONF_JSON" ]]; then
    warn "尚未安装，请先选择 1) 安装/部署（20 节点）"
    return 1
  fi
  return 0
}

# ===== DNS 兼容性修复 =====
fix_dns() {
    mkdir -p /etc/systemd/system/sing-box.service.d
    cat > /etc/systemd/system/sing-box.service.d/override.conf << 'FIX'
[Service]
Environment=ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
FIX
    systemctl daemon-reload
    systemctl restart sing-box
    echo -e "\033[0;32m✅ DNS 兼容性已修复\033[0m"
}

# ===== 菜单 =====
menu(){
  banner
  read -rp "选择: " op || true
  case "${op:-}" in
  1)
  sbp_bootstrap                                     # 依赖/二进制回退
  set +e                                            # ← 关闭严格退出，避免中途被杀掉
  echo -e "${C_BLUE}[信息] 正在检查 sing-box 安装状态...${C_RESET}"
  install_singbox            || true
  ensure_warpcli_proxy        || true
  write_config               || { echo "[ERR] 生成配置失败"; }
  write_systemd              || true
    fix_dns
  systemctl restart "${SYSTEMD_SERVICE}" || true
  set -e                                            # ← 恢复严格模式
  print_links_grouped
  exit 0                                          # ← 打印后直接退出
  ;;
  2) if ensure_installed_or_hint; then print_links_grouped 4; exit 0; fi ;;

  6) if ensure_installed_or_hint; then print_links_grouped 6; exit 0; fi ;;
    3) if ensure_installed_or_hint; then restart_service; fi; read -rp "回车返回..." _ || true; menu ;;
   4) if ensure_installed_or_hint; then rotate_ports; fi; menu ;;
    5) enable_bbr; read -rp "回车返回..." _ || true; menu ;;
    7) if ensure_installed_or_hint; then manage_protos; fi; menu ;;
    8) uninstall_all ;; # 直接退出
    9) if ensure_installed_or_hint; then speed_test; fi; menu ;;
    10) if ensure_installed_or_hint; then gen_subscription; fi; menu ;;
    11) if ensure_installed_or_hint; then backup_config; fi; menu ;;
    12) restore_config; menu ;;
    13) if ensure_installed_or_hint; then view_logs; fi; menu ;;
    14) set_node_icon; menu ;;
    0) exit 0 ;;
    *) menu ;;
  esac
}

menu

# ===== 入口 =====
