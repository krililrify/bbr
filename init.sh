#!/bin/bash
# =====================================================================
# vps-init — Conservative VPS initialization / network optimization
# Supports: Debian 11/12, Ubuntu 22.04/24.04/26.04
#
# Design:
#   - Safe defaults: no IPv4 forwarding, no route_localnet, no firewall removal
#   - BBR + FQ when the running kernel supports BBR
#   - Conservative sysctl tuning; avoids aggressive TCP retry/TIME-WAIT tweaks
#   - Optional RPS/RFS, swap, limits, firewall/cloud-agent cleanup
#   - No third-party binaries or scripts are downloaded
#   - Changes are written to drop-in files; original files are backed up
#   - Idempotent and leaves a detailed log
# =====================================================================

set -u
set -o pipefail

VERSION="2.1.0"

# ---------------------------- options ---------------------------------
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
ENABLE_FORWARD="${ENABLE_FORWARD:-0}"
DISABLE_RP_FILTER="${DISABLE_RP_FILTER:-0}"
ENABLE_RPS="${ENABLE_RPS:-1}"
MAKE_SWAP="${MAKE_SWAP:-1}"
SET_LIMITS="${SET_LIMITS:-1}"
STOP_IRQBALANCE="${STOP_IRQBALANCE:-0}"
REMOVE_FIREWALL="${REMOVE_FIREWALL:-0}"
REMOVE_CLOUD_AGENTS="${REMOVE_CLOUD_AGENTS:-0}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"
JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-300M}"

LOG="/var/log/vps-init.log"
BACKUP_DIR="/root/vps-init-backup-$(date +%Y%m%d-%H%M%S)"
SYSCTL_FILE="/etc/sysctl.d/99-zz-vps-init.conf"
LIMITS_FILE="/etc/security/limits.d/99-vps-init.conf"
SYSTEMD_LIMITS_FILE="/etc/systemd/system.conf.d/99-vps-init.conf"
JOURNAL_FILE="/etc/systemd/journald.conf.d/99-vps-init.conf"
RPS_SCRIPT="/usr/local/sbin/vps-init-rps.sh"
RPS_UNIT="/etc/systemd/system/vps-init-rps.service"
PROFILE_FILE="/etc/profile.d/99-vps-init.sh"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
plain='\033[0m'

info() {
    echo -e "${green}[OK]${plain}   $*"
}

warn() {
    echo -e "${yellow}[WARN]${plain} $*"
}

err() {
    echo -e "${red}[ERR]${plain}  $*"
}

step() {
    echo -e "\n${blue}==>${plain} $*"
}

usage() {
    cat <<EOF_USAGE
vps-init ${VERSION}

用法:
  sudo bash init.sh
  sudo ENV=VALUE bash init.sh
  bash init.sh --help

环境变量:
  TIMEZONE=Asia/Shanghai    设置系统时区
  ENABLE_FORWARD=0          IPv4 转发，普通 VPS 默认关闭；中转/NAT/VPN 设为 1
  DISABLE_RP_FILTER=0       rp_filter 默认严格模式；非对称路由/中转可设为 1
  ENABLE_RPS=1              RPS/RFS；多核 VPS 默认开启，脚本会按队列情况判断
  MAKE_SWAP=1               无 swap 时创建 128~512 MiB swapfile
  SET_LIMITS=1              设置 nofile=1000000（PAM + systemd 默认值）
  STOP_IRQBALANCE=0         是否停用 irqbalance
  REMOVE_FIREWALL=0         是否卸载 ufw / firewalld；默认绝不处理
  REMOVE_CLOUD_AGENTS=0     是否尝试卸载已存在的腾讯云/常见云代理；默认绝不处理
  INSTALL_PACKAGES=1        是否安装常用诊断工具
  JOURNAL_MAX_USE=300M      journald 最大磁盘占用

推荐:

  普通 VPS:
    bash init.sh

  中转 / NAT / VPN:
    ENABLE_FORWARD=1 bash init.sh

  非对称路由 / 多网卡中转:
    ENABLE_FORWARD=1 DISABLE_RP_FILTER=1 bash init.sh

  不想创建 Swap:
    MAKE_SWAP=0 bash init.sh

  不想启用 RPS/RFS:
    ENABLE_RPS=0 bash init.sh

注意:
  - 不会自动重启服务器。
  - 不会修改云厂商安全组。
  - 默认不卸载防火墙、不卸载云厂商组件、不关闭 tuned/smartd。
  - 不更换内核，不下载第三方二进制。
EOF_USAGE
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

[[ $EUID -eq 0 ]] || {
    err "必须使用 root 用户运行。"
    exit 1
}

mkdir -p "$(dirname "$LOG")" "$BACKUP_DIR"
: >"$LOG"

# 防止多个实例同时修改 sysctl / systemd 配置
exec 9>/run/lock/vps-init.lock

if ! flock -n 9 2>/dev/null; then
    err "检测到另一个 vps-init 正在运行。"
    exit 1
fi

log_cmd() {
    printf '\n[%s] +' "$(date '+%F %T')" >>"$LOG"
    printf ' %q' "$@" >>"$LOG"
    printf '\n' >>"$LOG"
}

run() {
    log_cmd "$@"
    "$@" >>"$LOG" 2>&1
}

run_shell() {
    log_cmd /bin/bash -c "$1"
    /bin/bash -c "$1" >>"$LOG" 2>&1
}

backup() {
    local f

    for f in "$@"; do
        [[ -e "$f" ]] || continue

        mkdir -p "$BACKUP_DIR$(dirname "$f")"
        cp -a "$f" "$BACKUP_DIR$f" 2>>"$LOG" || true
    done
}

unit_exists() {
    systemctl list-unit-files --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | grep -qx "$1.service"
}

valid_bool() {
    case "$2" in
        0|1)
            ;;
        *)
            err "$1 必须是 0 或 1，当前: $2"
            exit 1
            ;;
    esac
}

for pair in \
    "ENABLE_FORWARD:$ENABLE_FORWARD" \
    "DISABLE_RP_FILTER:$DISABLE_RP_FILTER" \
    "ENABLE_RPS:$ENABLE_RPS" \
    "MAKE_SWAP:$MAKE_SWAP" \
    "SET_LIMITS:$SET_LIMITS" \
    "STOP_IRQBALANCE:$STOP_IRQBALANCE" \
    "REMOVE_FIREWALL:$REMOVE_FIREWALL" \
    "REMOVE_CLOUD_AGENTS:$REMOVE_CLOUD_AGENTS" \
    "INSTALL_PACKAGES:$INSTALL_PACKAGES"; do

    valid_bool "${pair%%:*}" "${pair#*:}"
done

# ---------------------------------------------------------------------
# 0. System detection
# ---------------------------------------------------------------------

[[ -f /etc/os-release ]] || {
    err "无法读取 /etc/os-release。"
    exit 1
}

. /etc/os-release

case "${ID:-}" in
    debian)
        case "${VERSION_ID:-}" in
            11|12)
                ;;
            *)
                err "仅支持 Debian 11/12，当前: ${PRETTY_NAME:-unknown}"
                exit 1
                ;;
        esac
        ;;

    ubuntu)
        case "${VERSION_ID:-}" in
            22.04|24.04|26.04)
                ;;
            *)
                err "仅支持 Ubuntu 22.04/24.04/26.04，当前: ${PRETTY_NAME:-unknown}"
                exit 1
                ;;
        esac
        ;;

    *)
        err "仅支持 Debian / Ubuntu，当前: ${ID:-unknown}"
        exit 1
        ;;
esac

command -v systemctl >/dev/null 2>&1 || {
    err "需要 systemd。"
    exit 1
}

command -v sysctl >/dev/null 2>&1 || {
    err "需要 procps/sysctl。"
    exit 1
}

if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT="$(systemd-detect-virt 2>/dev/null || true)"
else
    VIRT="unknown"
fi

VIRT="${VIRT:-none}"

KERNEL="$(uname -r)"
ARCH="$(uname -m)"

info "系统: ${PRETTY_NAME:-$ID} | 内核: $KERNEL | 架构: $ARCH | 虚拟化: $VIRT"

case "$VIRT" in
    lxc|lxc-libvirt|openvz|docker|podman|systemd-nspawn|pouch)
        warn "检测到容器/共享内核环境 ($VIRT)，部分 sysctl、内核模块、Swap、RPS 可能由宿主机控制。"
        ;;
esac

# 非交互环境
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none

APT_OPTS=(
    -y
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    -o DPkg::Lock::Timeout=300
)

# ---------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------

if [[ "$INSTALL_PACKAGES" == "1" ]]; then

    step "安装常用系统/网络诊断工具"

    if run apt-get update -q -o DPkg::Lock::Timeout=300; then

        PKGS=(
            ca-certificates
            curl
            wget

            iproute2
            iputils-ping
            net-tools
            ethtool

            mtr-tiny
            traceroute
            tcptraceroute

            nload
            vnstat
            htop
            iftop
            lsof

            dnsutils
            iperf3

            git
            vim
            jq
            unzip
        )

        AVAILABLE=()

        for pkg in "${PKGS[@]}"; do
            if apt-cache show "$pkg" >/dev/null 2>&1; then
                AVAILABLE+=("$pkg")
            else
                warn "软件包不可用，跳过: $pkg"
            fi
        done

        if command -v debconf-set-selections >/dev/null 2>&1 \
           && printf '%s\n' "${AVAILABLE[@]}" | grep -qx iperf3; then

            printf '%s\n' \
                'iperf3 iperf3/start_daemon boolean false' \
                | debconf-set-selections >>"$LOG" 2>&1 || true
        fi

        if ((${#AVAILABLE[@]})); then
            if run apt-get install "${APT_OPTS[@]}" "${AVAILABLE[@]}"; then
                info "常用工具安装完成。"
            else
                warn "部分软件包安装失败，请查看: $LOG"
            fi
        fi

    else
        warn "apt-get update 失败；跳过软件包安装，请查看: $LOG"
    fi

else
    info "跳过软件包安装 (INSTALL_PACKAGES=0)"
fi

# ---------------------------------------------------------------------
# 2. Firewall
# ---------------------------------------------------------------------

step "防火墙"

if [[ "$REMOVE_FIREWALL" == "1" ]]; then

    warn "REMOVE_FIREWALL=1：即将卸载 ufw / firewalld。请确认 SSH 已由云安全组或其它防火墙保护。"

    for svc in ufw firewalld; do

        if unit_exists "$svc" \
           || dpkg-query -W -f='${Status}\n' "$svc" 2>/dev/null \
              | grep -q 'install ok installed'; then

            backup \
                "/etc/ufw/ufw.conf" \
                "/etc/firewalld/firewalld.conf"

            run systemctl disable --now "$svc" || true
            run apt-get purge "${APT_OPTS[@]}" "$svc" || true

            info "已处理 $svc"
        fi
    done

else
    info "保留现有防火墙配置。"
fi

# ---------------------------------------------------------------------
# 3. Cloud agents
# ---------------------------------------------------------------------

step "云厂商组件"

if [[ "$REMOVE_CLOUD_AGENTS" == "1" ]]; then

    warn "REMOVE_CLOUD_AGENTS=1：仅处理脚本明确识别到的组件，不代表所有云厂商 agent。"

    for svc in walinuxagent waagent hypervkvpd; do

        if unit_exists "$svc"; then
            run systemctl disable --now "$svc" || true
            info "已停止 $svc.service"
        fi

    done

    if [[ -d /usr/local/qcloud ]]; then

        for s in \
            /usr/local/qcloud/YunJing/uninst.sh \
            /usr/local/qcloud/stargate/admin/uninstall.sh \
            /usr/local/qcloud/monitor/barad/admin/uninstall.sh \
            /usr/local/sa/agent/uninstall.sh; do

            if [[ -x "$s" ]]; then
                backup "$s"
                run "$s" || warn "云厂商卸载程序返回非 0: $s"
            fi

        done

        rm -rf /usr/local/qcloud

        if [[ -f /etc/rc.local ]]; then
            backup /etc/rc.local
            sed -i '/qcloud/d' /etc/rc.local
        fi

        info "已处理 /usr/local/qcloud。"

    else
        info "未发现 /usr/local/qcloud。"
    fi

else
    info "不处理云厂商组件。"
fi

# 不再默认关闭 tuned / smartd
if [[ "$STOP_IRQBALANCE" == "1" ]]; then

    if unit_exists irqbalance; then
        run systemctl disable --now irqbalance || true
        info "已停止 irqbalance。"
    else
        info "未发现 irqbalance。"
    fi

else
    info "保留 irqbalance（如需停用: STOP_IRQBALANCE=1）。"
fi

# ---------------------------------------------------------------------
# 4. File descriptor limits
# ---------------------------------------------------------------------

step "文件句柄限制"

if [[ "$SET_LIMITS" == "1" ]]; then

    backup \
        /etc/security/limits.conf \
        /etc/systemd/system.conf

    mkdir -p \
        /etc/security/limits.d \
        /etc/systemd/system.conf.d

    cat >"$LIMITS_FILE" <<'EOF_LIMITS'
# Generated by vps-init. Safe to remove to roll back.

*     soft   nofile    1000000
*     hard   nofile    1000000
root  soft   nofile    1000000
root  hard   nofile    1000000
EOF_LIMITS

    cat >"$SYSTEMD_LIMITS_FILE" <<'EOF_SYSTEMD_LIMITS'
# Generated by vps-init. Safe to remove to roll back.

[Manager]
DefaultLimitNOFILE=1000000
EOF_SYSTEMD_LIMITS

    PAM_LIMITS_MODULE=""

    for candidate in \
        /usr/lib/*/security/pam_limits.so \
        /lib/*/security/pam_limits.so \
        /usr/lib/security/pam_limits.so \
        /lib/security/pam_limits.so; do

        if [[ -f "$candidate" ]]; then
            PAM_LIMITS_MODULE="$candidate"
            break
        fi

    done

    if [[ -n "$PAM_LIMITS_MODULE" ]]; then

        for f in \
            /etc/pam.d/common-session \
            /etc/pam.d/common-session-noninteractive; do

            if [[ -f "$f" ]] \
               && ! grep -Eq \
                    '^[[:space:]]*session[[:space:]]+.*pam_limits\.so' \
                    "$f"; then

                backup "$f"

                printf '\nsession required pam_limits.so\n' >>"$f"

                info "已启用 pam_limits: $f"
            fi
        done
    fi

    run systemctl daemon-reload

    info "nofile=1000000 已写入；新登录会话/新启动的 systemd 服务生效。"

else
    info "跳过 limits (SET_LIMITS=0)。"
fi

# ---------------------------------------------------------------------
# 5. Swap
# ---------------------------------------------------------------------

step "Swap"

create_swap() {

    local swap_total
    local mem_mb
    local swap_path=/swapfile

    swap_total="$(
        awk '/^SwapTotal:/{printf "%d", $2/1024}' \
        /proc/meminfo 2>/dev/null || echo 0
    )"

    if [[ "${swap_total:-0}" -gt 0 ]]; then
        info "已有 Swap: ${swap_total} MiB，跳过。"
        return 0
    fi

    if [[ -e "$swap_path" ]]; then
        warn "$swap_path 已存在但当前未启用，脚本不会接管它。"
        return 0
    fi

    mem_mb="$(
        awk '/^MemTotal:/{printf "%d", $2/1024}' \
        /proc/meminfo 2>/dev/null || echo 512
    )"

    [[ "$mem_mb" -gt 512 ]] && mem_mb=512
    [[ "$mem_mb" -lt 128 ]] && mem_mb=128

    if command -v fallocate >/dev/null 2>&1 \
       && fallocate -l "${mem_mb}M" "$swap_path" 2>>"$LOG"; then
        :

    elif command -v dd >/dev/null 2>&1; then

        if ! dd \
            if=/dev/zero \
            of="$swap_path" \
            bs=1M \
            count="$mem_mb" \
            status=none >>"$LOG" 2>&1; then

            rm -f "$swap_path"
            warn "Swap 文件创建失败。"
            return 1
        fi

    else
        warn "系统没有 fallocate/dd，无法创建 Swap。"
        return 1
    fi

    chmod 600 "$swap_path"

    if run mkswap "$swap_path" \
       && run swapon "$swap_path"; then

        if ! grep -Eq '^/swapfile[[:space:]]' /etc/fstab; then
            backup /etc/fstab
            echo '/swapfile none swap defaults 0 0' >>/etc/fstab
        fi

        info "已创建并启用 ${mem_mb} MiB Swap。"

    else
        rm -f "$swap_path"
        warn "Swap 启用失败；常见原因是容器环境或文件系统限制。"
        return 1
    fi
}

if [[ "$MAKE_SWAP" == "1" ]]; then
    create_swap || true
else
    info "跳过 Swap (MAKE_SWAP=0)。"
fi

# ---------------------------------------------------------------------
# 6. Sysctl + BBR/FQ
# ---------------------------------------------------------------------

step "内核网络参数 / BBR / FQ"

mkdir -p \
    /etc/sysctl.d \
    /etc/modules-load.d

backup \
    "$SYSCTL_FILE" \
    /etc/sysctl.conf

# 删除早期版本已知配置
rm -f \
    /etc/sysctl.d/99-custom.conf \
    /etc/sysctl.d/99-vps-init.conf

BBR_AVAILABLE=0

if command -v modprobe >/dev/null 2>&1; then
    run modprobe tcp_bbr || true
fi

if grep -qw bbr \
    /proc/sys/net/ipv4/tcp_available_congestion_control \
    2>/dev/null; then

    BBR_AVAILABLE=1
    echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf
fi

# ---------------------------------------------------------------------
# IMPORTANT:
#
# Linux documents ip_forward as a special variable:
# changing it resets IPv4 configuration parameters to host/router defaults.
#
# Therefore ip_forward is intentionally written BEFORE the other
# IPv4 conf.* parameters below.
# ---------------------------------------------------------------------

cat >"$SYSCTL_FILE" <<EOF_SYSCTL
# Generated by vps-init ${VERSION}
# Conservative defaults; remove this file to roll back.

# ---- IPv4 forwarding ----
net.ipv4.ip_forward=$([[ "$ENABLE_FORWARD" == "1" ]] && echo 1 || echo 0)

# ---- IPv6 forwarding ----
net.ipv6.conf.all.forwarding=0
net.ipv6.conf.default.forwarding=0
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0

# ---- Redirects / routing safety ----
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.default.secure_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0

# Keep strict reverse-path filtering by default.
# For asymmetric routing / multi-homing / relay designs:
# DISABLE_RP_FILTER=1
net.ipv4.conf.all.rp_filter=$(
    [[ "${DISABLE_RP_FILTER:-0}" == "1" ]] && echo 0 || echo 1
)
net.ipv4.conf.default.rp_filter=$(
    [[ "${DISABLE_RP_FILTER:-0}" == "1" ]] && echo 0 || echo 1
)

# ---- TCP: conservative changes only ----
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_moderate_rcvbuf=1

# Reasonable socket/backlog ceilings for busy VPS workloads.
# These are ceilings, not pre-allocated memory.
net.core.somaxconn=65535
net.core.netdev_max_backlog=16384
net.ipv4.tcp_max_syn_backlog=16384

# Keepalive is opt-in at the socket/application level.
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

# ---- TCP buffers ----
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 16384 33554432

# ---- Ports / VM ----
net.ipv4.ip_local_port_range=10000 65535
vm.swappiness=10

# ---- Queue discipline ----
net.core.default_qdisc=fq
EOF_SYSCTL

if [[ "$BBR_AVAILABLE" == "1" ]]; then
    echo 'net.ipv4.tcp_congestion_control=bbr' >>"$SYSCTL_FILE"
else
    warn "当前内核没有可用的 BBR；不会更换内核。"
fi

# 只应用自己的 drop-in。
# 不使用 sysctl --system，避免把 /etc/sysctl.conf 一起重新处理。
if command -v systemd-sysctl >/dev/null 2>&1; then

    if run systemd-sysctl "$SYSCTL_FILE"; then
        info "sysctl drop-in 已应用。"
    else
        warn "systemd-sysctl 返回非 0；容器环境可能拒绝部分参数，请查看日志。"
    fi

else

    if run sysctl -p "$SYSCTL_FILE"; then
        info "sysctl drop-in 已应用。"
    else
        warn "sysctl 应用部分失败，请查看日志。"
    fi
fi

if [[ "$ENABLE_FORWARD" == "1" ]]; then
    run sysctl -w net.ipv4.conf.all.forwarding=1 || true
    run sysctl -w net.ipv4.conf.default.forwarding=1 || true
fi

# ---------------------------------------------------------------------
# 7. RPS / RFS
# ---------------------------------------------------------------------

step "RPS / RFS"

remove_rps_service() {

    run systemctl disable --now vps-init-rps.service || true

    rm -f \
        "$RPS_UNIT" \
        "$RPS_SCRIPT"

    run systemctl daemon-reload || true
}

if [[ "$ENABLE_RPS" == "1" ]]; then

    CPU_COUNT="$(nproc 2>/dev/null || echo 1)"

    if [[ "$CPU_COUNT" -le 1 ]]; then

        remove_rps_service

        info "单核 VPS 不启用 RPS。"

    elif [[ "$CPU_COUNT" -gt 62 ]]; then

        remove_rps_service

        warn "CPU 核数 $CPU_COUNT > 62，跳过 RPS，避免 Bash 位掩码限制。"

    else

        cat >"$RPS_SCRIPT" <<'EOF_RPS'
#!/bin/bash

# Generated by vps-init.
# Apply conservative RPS/RFS settings.

set -u

CPU_COUNT="$(nproc 2>/dev/null || echo 1)"

[[ "$CPU_COUNT" -gt 1 && "$CPU_COUNT" -le 62 ]] || exit 0

MASK="$(printf '%x' $(( (1 << CPU_COUNT) - 1 )))"

for dev in /sys/class/net/*; do

    name="$(basename "$dev")"

    case "$name" in
        lo)
            continue
            ;;
        docker*)
            continue
            ;;
        br-*)
            continue
            ;;
        veth*)
            continue
            ;;
        cni*)
            continue
            ;;
        flannel*)
            continue
            ;;
        cal*)
            continue
            ;;
    esac

    mapfile -t queues < <(
        compgen -G "$dev/queues/rx-*"
    )

    nq="${#queues[@]}"

    (( nq > 0 )) || continue

    # If the NIC already exposes at least as many RX queues as CPUs,
    # hardware RSS is normally sufficient. Avoid unnecessary software
    # steering overhead.
    if (( nq >= CPU_COUNT )); then

        for q in "${queues[@]}"; do

            if [[ -e "$q/rps_cpus" ]]; then
                printf '0\n' >"$q/rps_cpus" 2>/dev/null || true
            fi

            if [[ -e "$q/rps_flow_cnt" ]]; then
                printf '0\n' >"$q/rps_flow_cnt" 2>/dev/null || true
            fi

        done

        continue
    fi

    flow=$((65536 / nq))

    (( flow > 0 )) || flow=1

    for q in "${queues[@]}"; do

        if [[ -e "$q/rps_cpus" ]]; then
            printf '%s\n' "$MASK" \
                >"$q/rps_cpus" 2>/dev/null || true
        fi

        if [[ -e "$q/rps_flow_cnt" ]]; then
            printf '%s\n' "$flow" \
                >"$q/rps_flow_cnt" 2>/dev/null || true
        fi

    done
done

exit 0
EOF_RPS

        chmod 0755 "$RPS_SCRIPT"

        cat >"$RPS_UNIT" <<'EOF_RPS_UNIT'
[Unit]
Description=vps-init RPS/RFS configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-init-rps.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_RPS_UNIT

        # 清理旧版服务
        if [[ -f /etc/systemd/system/rps.service ]]; then

            run systemctl disable --now rps.service || true

            rm -f \
                /etc/systemd/system/rps.service \
                /usr/local/sbin/rps-setup.sh \
                /root/rps.sh
        fi

        run systemctl daemon-reload

        if run systemctl enable --now vps-init-rps.service \
           && run systemctl restart vps-init-rps.service; then

            info "RPS/RFS 服务已启用。"

        else
            warn "RPS/RFS 服务启动失败，请查看: $LOG"
        fi
    fi

else

    remove_rps_service

    info "跳过 RPS/RFS (ENABLE_RPS=0)。"
fi

# ---------------------------------------------------------------------
# 8. journald
# ---------------------------------------------------------------------

step "systemd-journald"

mkdir -p /etc/systemd/journald.conf.d

backup "$JOURNAL_FILE"

cat >"$JOURNAL_FILE" <<EOF_JOURNAL
# Generated by vps-init.

[Journal]
SystemMaxUse=$JOURNAL_MAX_USE
EOF_JOURNAL

if run systemctl restart systemd-journald; then
    info "journald 磁盘上限: $JOURNAL_MAX_USE"
else
    warn "重启 systemd-journald 失败，请查看日志。"
fi

# ---------------------------------------------------------------------
# 9. Timezone + NTP
# ---------------------------------------------------------------------

step "时区与时间同步"

if command -v timedatectl >/dev/null 2>&1; then

    if run timedatectl set-timezone "$TIMEZONE"; then
        info "时区已设置为 $TIMEZONE"
    else
        warn "设置时区失败: $TIMEZONE"
    fi

else
    warn "未找到 timedatectl，跳过时区设置。"
fi

if systemctl is-active --quiet systemd-timesyncd 2>/dev/null \
   || systemctl is-active --quiet chrony 2>/dev/null \
   || systemctl is-active --quiet chronyd 2>/dev/null; then

    run timedatectl set-ntp true || true

    info "时间同步服务已在运行。"

else

    if command -v apt-get >/dev/null 2>&1; then

        if run apt-get install "${APT_OPTS[@]}" chrony; then

            if unit_exists chrony; then
                run systemctl enable --now chrony || true

            elif unit_exists chronyd; then
                run systemctl enable --now chronyd || true
            fi

            info "已安装并启用 chrony。"

        else
            warn "chrony 安装失败，请查看日志。"
        fi
    fi
fi

# ---------------------------------------------------------------------
# 10. Old residue cleanup
# ---------------------------------------------------------------------

step "清理旧版 vps-init / RPS 残留"

cleaned=0

if [[ -f /etc/rc.local ]] \
   && grep -Eq \
      'rps\.sh|rdate|sysctl -p /etc/sysctl\.conf' \
      /etc/rc.local; then

    backup /etc/rc.local

    sed -i -E \
        '/rps\.sh|rdate|sysctl -p \/etc\/sysctl\.conf/d' \
        /etc/rc.local

    cleaned=1
fi

for f in \
    /root/rps.sh \
    /usr/local/sbin/rps-setup.sh; do

    if [[ -e "$f" ]]; then
        backup "$f"
        rm -f "$f"
        cleaned=1
    fi
done

if [[ -f /etc/systemd/system/rps.service ]]; then

    run systemctl disable --now rps.service || true

    backup /etc/systemd/system/rps.service

    rm -f /etc/systemd/system/rps.service

    cleaned=1
fi

# 清理旧版 root bashrc 中的脚本别名
if [[ -f /root/.bashrc ]] \
   && grep -Eq \
      '^[[:space:]]*alias (nload|banping|unbanping|is|ic|dropcache)=' \
      /root/.bashrc; then

    backup /root/.bashrc

    sed -i -E \
        '/^[[:space:]]*alias (nload|banping|unbanping|is|ic|dropcache)=/d' \
        /root/.bashrc

    cleaned=1
fi

if [[ "$cleaned" -eq 1 ]]; then
    info "已清理旧残留。"
else
    info "未发现旧残留。"
fi

# ---------------------------------------------------------------------
# 11. Shell helpers
# ---------------------------------------------------------------------

step "Shell 辅助命令"

cat >"$PROFILE_FILE" <<'EOF_PROFILE'
# Generated by vps-init.
# Loaded for interactive shells only.

case $- in
    *i*)
        ;;
    *)
        return 0
        ;;
esac

alias nload='nload -i 2048000 -o 2048000'
alias is='iperf3 -s'
alias ic='iperf3 -c'
alias dropcache='sync && echo 3 > /proc/sys/vm/drop_caches'

# Disable/restore ICMP echo replies.
# These are opt-in convenience commands.

banping() {

    cat >/etc/sysctl.d/98-vps-init-banping.conf <<'EOF_BANPING'
# Generated by vps-init banping()

net.ipv4.icmp_echo_ignore_all=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
EOF_BANPING

    sysctl -p /etc/sysctl.d/98-vps-init-banping.conf
}

unbanping() {

    rm -f /etc/sysctl.d/98-vps-init-banping.conf

    sysctl -w \
        net.ipv4.icmp_echo_ignore_all=0 \
        >/dev/null

    sysctl -w \
        net.ipv4.icmp_echo_ignore_broadcasts=1 \
        >/dev/null

    sysctl -w \
        net.ipv4.icmp_ignore_bogus_error_responses=1 \
        >/dev/null
}
EOF_PROFILE

info "已写入 $PROFILE_FILE"
info "可用: nload / is / ic / dropcache / banping / unbanping"

# ---------------------------------------------------------------------
# 12. Verification
# ---------------------------------------------------------------------

step "验证汇总"

PASS=0
FAIL=0

check_eq() {

    local label="$1"
    local actual="$2"
    local expected="$3"

    if [[ "$actual" == "$expected" ]]; then

        echo -e \
            "  ${green}✔${plain} $label: $actual"

        PASS=$((PASS + 1))

    else

        echo -e \
            "  ${red}✘${plain} $label: $actual (期望 $expected)"

        FAIL=$((FAIL + 1))
    fi
}

QDISC="$(
    sysctl -n \
        net.core.default_qdisc \
        2>/dev/null || true
)"

check_eq \
    "默认 qdisc" \
    "$QDISC" \
    "fq"

CC="$(
    sysctl -n \
        net.ipv4.tcp_congestion_control \
        2>/dev/null || true
)"

if [[ "$BBR_AVAILABLE" == "1" ]]; then

    check_eq \
        "拥塞控制" \
        "$CC" \
        "bbr"

else

    echo -e \
        "  ${yellow}-${plain} 拥塞控制: 当前内核无 BBR ($CC)"

fi

check_eq \
    "IPv4 转发" \
    "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" \
    "$ENABLE_FORWARD"

check_eq \
    "IPv6 转发" \
    "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || true)" \
    "0"

check_eq \
    "rp_filter" \
    "$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || true)" \
    "$(
        [[ "${DISABLE_RP_FILTER:-0}" == "1" ]] \
        && echo 0 \
        || echo 1
    )"

check_eq \
    "tcp_fastopen" \
    "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || true)" \
    "3"

check_eq \
    "tcp_mtu_probing" \
    "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || true)" \
    "1"

check_eq \
    "时区" \
    "$(timedatectl show -p Timezone --value 2>/dev/null || true)" \
    "$TIMEZONE"

if [[ "$MAKE_SWAP" == "1" ]]; then

    SWAP_MB="$(
        awk '/^SwapTotal:/{printf "%d", $2/1024}' \
        /proc/meminfo 2>/dev/null || echo 0
    )"

    if [[ "${SWAP_MB:-0}" -gt 0 ]]; then

        echo -e \
            "  ${green}✔${plain} Swap: ${SWAP_MB} MiB"

        PASS=$((PASS + 1))

    else

        echo -e \
            "  ${yellow}-${plain} Swap: 未启用（容器/文件系统可能不支持）"

    fi
fi

if [[ "$SET_LIMITS" == "1" ]]; then

    if [[ -f "$LIMITS_FILE" ]]; then

        echo -e \
            "  ${green}✔${plain} limits.d: $LIMITS_FILE"

        PASS=$((PASS + 1))

    else

        echo -e \
            "  ${red}✘${plain} limits.d 文件不存在"

        FAIL=$((FAIL + 1))
    fi

    if [[ -f "$SYSTEMD_LIMITS_FILE" ]]; then

        echo -e \
            "  ${green}✔${plain} systemd limits: $SYSTEMD_LIMITS_FILE"

        PASS=$((PASS + 1))

    else

        echo -e \
            "  ${red}✘${plain} systemd limits 文件不存在"

        FAIL=$((FAIL + 1))
    fi
fi

if [[ "$ENABLE_RPS" == "1" && -f "$RPS_UNIT" ]]; then

    RPS_STATE="$(
        systemctl is-active \
            vps-init-rps.service \
            2>/dev/null || true
    )"

    check_eq \
        "RPS 服务" \
        "$RPS_STATE" \
        "active"
fi

JOURNAL_STATE="$(
    systemctl show \
        systemd-journald \
        -p ActiveState \
        --value \
        2>/dev/null || true
)"

if [[ "$JOURNAL_STATE" == "active" ]]; then

    echo -e \
        "  ${green}✔${plain} systemd-journald: active"

    PASS=$((PASS + 1))

else

    echo -e \
        "  ${yellow}-${plain} systemd-journald: $JOURNAL_STATE"

fi

if [[ -f /var/run/reboot-required ]]; then

    warn "系统提示需要重启 (/var/run/reboot-required)。本脚本不会自动重启。"

fi

# ---------------------------------------------------------------------
# Final
# ---------------------------------------------------------------------

echo

echo "============================================================"
echo -e " ${green}vps-init ${VERSION} 完成${plain}"
echo "============================================================"

echo "配置文件 : $SYSCTL_FILE"
echo "备份目录 : $BACKUP_DIR"
echo "日志文件 : $LOG"
echo "通过     : $PASS"
echo "失败     : $FAIL"

echo

echo "重要提示:"
echo "  1. SSH 新会话才能看到新的 ulimit；已有服务通常需要重启才会继承新的 LimitNOFILE。"
echo "  2. 默认不启用 IPv4 转发；中转/NAT/VPN 请使用 ENABLE_FORWARD=1。"
echo "  3. 非对称路由/多网卡中转可使用 DISABLE_RP_FILTER=1。"
echo "  4. 默认不会修改 /etc/sysctl.conf，也不会卸载防火墙或云厂商组件。"
echo "  5. RPS 只在软件分流可能有意义时启用；硬件 RX 队列足够时会主动跳过。"
echo "  6. 本脚本不会自动重启服务器。"

exit 0
