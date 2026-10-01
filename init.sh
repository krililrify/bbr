#!/bin/bash
# =====================================================================
# vps-init  —  VPS 初始化 / 网络优化脚本
# 支持: Debian 11/12, Ubuntu 22.04/24.04/26.04
#
# 特点:
#   * 全程非交互，不会卡在 debconf / needrestart
#   * 所有输出写入日志，终端只显示进度
#   * 修改前自动备份；使用 drop-in 文件，不覆盖系统配置
#   * 不下载任何第三方二进制/脚本，只使用发行版官方源
#   * 可重复执行（幂等），并自动清理旧版脚本残留
#   * 结束时输出验证汇总
#
# 用法:   bash init.sh            (默认: 安全优化)
#         bash init.sh --help     (查看全部选项)
# =====================================================================

set -u

VERSION="2.0.0"

# ---------------------------- 可配置项 -------------------------------
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
ENABLE_FORWARD="${ENABLE_FORWARD:-1}"
ENABLE_RPS="${ENABLE_RPS:-1}"
MAKE_SWAP="${MAKE_SWAP:-1}"
STOP_IRQBALANCE="${STOP_IRQBALANCE:-0}"
REMOVE_FIREWALL="${REMOVE_FIREWALL:-0}"
REMOVE_CLOUD_AGENTS="${REMOVE_CLOUD_AGENTS:-0}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"

usage() {
    cat <<EOF
vps-init ${VERSION}

用法: [ENV=VALUE ...] bash init.sh

环境变量 (默认值):
  TIMEZONE=Asia/Shanghai    时区
  ENABLE_FORWARD=1          开启 IPv4 转发 (中转机需要; 非中转机设 0)
  ENABLE_RPS=1              开启 RPS/RFS (多核网卡软中断分流)
  MAKE_SWAP=1               没有 swap 时创建 (大小 = min(内存, 512M))
  STOP_IRQBALANCE=0         停止 irqbalance
  REMOVE_FIREWALL=0         停用并卸载 ufw / firewalld, 关闭 SELinux
  REMOVE_CLOUD_AGENTS=0     卸载腾讯云等云厂商监控组件, 停用 waagent 等
  INSTALL_PACKAGES=1        安装常用工具包

示例:
  bash init.sh
  ENABLE_FORWARD=0 bash init.sh
  REMOVE_FIREWALL=1 REMOVE_CLOUD_AGENTS=1 bash init.sh
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

LOG=/var/log/vps-init.log
BACKUP_DIR="/root/init-backup-$(date +%Y%m%d-%H%M%S)"
SYSCTL_FILE=/etc/sysctl.d/99-zz-vps-init.conf

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; plain='\033[0m'
info() { echo -e "${green}[OK]${plain}   $*"; }
warn() { echo -e "${yellow}[WARN]${plain} $*"; }
err()  { echo -e "${red}[ERR]${plain}  $*"; }
step() { echo -e "\n==> $*"; }

# 执行命令, 输出写入日志
run() { "$@" >>"$LOG" 2>&1; }

# ---------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------
[[ $EUID -ne 0 ]] && err "必须使用 root 用户运行此脚本！" && exit 1

mkdir -p "$BACKUP_DIR"
: >"$LOG"

echo "============================================================"
echo " vps-init ${VERSION}"
echo "============================================================"
echo "日志文件: $LOG"
echo "备份目录: $BACKUP_DIR"

[[ -f /etc/os-release ]] || { err "无法识别系统"; exit 1; }
. /etc/os-release
case "${ID:-}" in
    debian|ubuntu) ;;
    *) err "仅支持 Debian / Ubuntu，当前: ${ID:-unknown}"; exit 1 ;;
esac
command -v systemctl >/dev/null 2>&1 || { err "需要 systemd"; exit 1; }

if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT="$(systemd-detect-virt 2>/dev/null || true)"
else
    VIRT="unknown"
fi
info "系统: ${PRETTY_NAME:-$ID} | 内核: $(uname -r) | 架构: $(uname -m) | 虚拟化: ${VIRT:-none}"
case "$VIRT" in
    lxc|openvz|docker|podman)
        warn "检测到容器环境 ($VIRT)，sysctl / 内核模块 / swap 等部分设置可能无法生效" ;;
esac

# 非交互环境: 防止 debconf / needrestart 弹窗卡住
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none

APT_OPTS=(-y -q
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    -o DPkg::Lock::Timeout=300)

backup() {
    local f
    for f in "$@"; do
        [[ -e "$f" ]] && cp -a --parents "$f" "$BACKUP_DIR" 2>/dev/null
    done
    return 0
}

unit_exists() { systemctl list-unit-files 2>/dev/null | grep -q "^$1\.service"; }

# ---------------------------------------------------------------------
# 1. 软件包
# ---------------------------------------------------------------------
if [[ "$INSTALL_PACKAGES" == "1" ]]; then
    step "更新软件源并安装常用工具 (可能需要几分钟)"
    run apt-get update -q -o DPkg::Lock::Timeout=300 || warn "apt-get update 失败，见日志"

    PKGS=(wget curl ca-certificates net-tools mtr-tiny traceroute tcptraceroute bc
          nload vnstat lsof htop iftop telnet git dnsutils vim iperf3 ethtool
          iproute2 unzip jq)

    # iperf3 安装时会弹 debconf 问题, 预先回答 "不作为守护进程启动"
    echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections >>"$LOG" 2>&1

    if run apt-get install "${APT_OPTS[@]}" "${PKGS[@]}"; then
        info "常用工具已安装"
    else
        warn "部分软件包安装失败，日志末尾如下:"
        tail -n 8 "$LOG" | sed 's/^/        /'
    fi
fi

# ---------------------------------------------------------------------
# 2. 防火墙 / SELinux (默认不动)
# ---------------------------------------------------------------------
step "防火墙"
if [[ "$REMOVE_FIREWALL" == "1" ]]; then
    for svc in ufw firewalld; do
        if unit_exists "$svc"; then
            run systemctl disable --now "$svc"
            run apt-get purge "${APT_OPTS[@]}" "$svc"
            info "已停用并卸载 $svc"
        fi
    done
    if command -v setenforce >/dev/null 2>&1; then
        run setenforce 0
        [[ -f /etc/selinux/config ]] && sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
        info "已关闭 SELinux"
    fi
else
    info "跳过 (如需停用: REMOVE_FIREWALL=1)"
fi

# ---------------------------------------------------------------------
# 3. 云厂商组件 / 无用服务
# ---------------------------------------------------------------------
step "系统服务"
if [[ "$REMOVE_CLOUD_AGENTS" == "1" ]]; then
    for svc in waagent walinuxagent hypervkvpd; do
        if unit_exists "$svc"; then
            run systemctl disable --now "$svc"
            info "已停止 $svc"
        fi
    done

    if [[ -d /usr/local/qcloud ]]; then
        for s in /usr/local/qcloud/YunJing/uninst.sh \
                 /usr/local/qcloud/stargate/admin/uninstall.sh \
                 /usr/local/qcloud/monitor/barad/admin/uninstall.sh \
                 /usr/local/sa/agent/uninstall.sh; do
            [[ -x "$s" ]] && run "$s"
        done
        rm -rf /usr/local/qcloud
        [[ -f /etc/rc.local ]] && sed -i '/qcloud/d' /etc/rc.local
        info "已卸载腾讯云组件"
    fi
else
    info "跳过云厂商组件 (如需卸载: REMOVE_CLOUD_AGENTS=1)"
fi

for svc in tuned smartd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        run systemctl disable --now "$svc"
        info "已停止 $svc"
    fi
done

if [[ "$STOP_IRQBALANCE" == "1" ]] && unit_exists irqbalance; then
    run systemctl disable --now irqbalance
    info "已停止 irqbalance"
fi

# ---------------------------------------------------------------------
# 4. 文件句柄 / ulimit
# ---------------------------------------------------------------------
step "文件句柄与进程数限制"
backup /etc/security/limits.conf /etc/systemd/system.conf /etc/profile
mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d

cat >/etc/security/limits.d/99-vps-init.conf <<'EOF'
*     soft   nofile    1000000
*     hard   nofile    1000000
root  soft   nofile    1000000
root  hard   nofile    1000000
*     soft   nproc     1000000
*     hard   nproc     1000000
root  soft   nproc     1000000
root  hard   nproc     1000000
*     soft   memlock   unlimited
*     hard   memlock   unlimited
root  soft   memlock   unlimited
root  hard   memlock   unlimited
EOF

# systemd 服务 (不经过 PAM) 的默认限制
cat >/etc/systemd/system.conf.d/99-vps-init.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1000000
DefaultLimitNPROC=1000000
EOF

for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    if [[ -f "$f" ]] && ! grep -q 'pam_limits.so' "$f"; then
        echo "session required pam_limits.so" >>"$f"
    fi
done
run systemctl daemon-reload
info "limits 已写入 (新登录会话 / 重启后的服务生效)"

# ---------------------------------------------------------------------
# 5. Swap
# ---------------------------------------------------------------------
mk_swap() {
    local swap_total mem_mb
    swap_total=$(free -m | awk '/^Swap:/{print $2}')
    if [[ "${swap_total:-0}" -gt 0 ]]; then
        info "已存在 swap (${swap_total}M)，跳过"
        return
    fi
    mem_mb=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
    [[ $mem_mb -gt 512 ]] && mem_mb=512
    [[ $mem_mb -lt 128 ]] && mem_mb=128

    if [[ -e /swapfile ]]; then
        warn "/swapfile 已存在但未启用，跳过"
        return
    fi
    if ! fallocate -l "${mem_mb}M" /swapfile 2>>"$LOG"; then
        dd if=/dev/zero of=/swapfile bs=1M count="$mem_mb" status=none 2>>"$LOG"
    fi
    chmod 600 /swapfile
    if run mkswap /swapfile && run swapon /swapfile; then
        grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap defaults 0 0' >>/etc/fstab
        info "已创建 ${mem_mb}M swap"
    else
        warn "swap 创建失败 (部分文件系统/容器不支持)，见日志"
        rm -f /swapfile
    fi
}
step "Swap"
if [[ "$MAKE_SWAP" == "1" ]]; then mk_swap; else info "跳过 (MAKE_SWAP=0)"; fi

# ---------------------------------------------------------------------
# 6. 内核网络参数 + BBR
# ---------------------------------------------------------------------
step "内核网络参数 / BBR"
backup /etc/sysctl.conf /etc/sysctl.d
mkdir -p /etc/sysctl.d

# 旧版本脚本(本项目 1.x)生成的文件
rm -f /etc/sysctl.d/99-custom.conf

run modprobe tcp_bbr
echo "tcp_bbr" >/etc/modules-load.d/bbr.conf

HAS_BBR=0
grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && HAS_BBR=1

cat >"$SYSCTL_FILE" <<'EOF'
# Generated by vps-init. Do not edit by hand; re-run the script instead.

# ---- 内存 / IO ----
vm.swappiness=10
vm.dirty_background_bytes=26214400
vm.dirty_bytes=52428800

# ---- 文件 ----
fs.file-max=1000000
fs.inotify.max_user_instances=131072

# ---- RFS: 同时活跃连接数的预期最大值 ----
net.core.rps_sock_flow_entries=65536

# ---- IPv6: 开启转发会导致 DHCP/SLAAC 拿不到地址, 因此保持 0 ----
net.ipv6.conf.all.forwarding=0
net.ipv6.conf.default.forwarding=0
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2

# ---- ICMP 重定向 ----
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.default.secure_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0

# ---- 反向路径过滤 (中转/多网卡场景关闭; 纯服务器可改为 1) ----
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0

# ---- TCP 连接管理 ----
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_retries2=8
net.ipv4.tcp_orphan_retries=2
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_tw_buckets=262144
net.ipv4.tcp_max_syn_backlog=262144
net.core.netdev_max_backlog=262144
net.core.somaxconn=65535
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=30

# ---- TCP 性能 ----
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 131072 67108864
net.ipv4.tcp_wmem=4096 16384 67108864
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# ---- 端口 / 其它 ----
net.ipv4.ip_local_port_range=10000 65535
net.ipv4.ping_group_range=0 2147483647
net.core.default_qdisc=fq
EOF

if [[ "$HAS_BBR" == "1" ]]; then
    echo "net.ipv4.tcp_congestion_control=bbr" >>"$SYSCTL_FILE"
else
    warn "当前内核不支持 BBR (容器/OpenVZ?)，已跳过 BBR 设置"
fi

if [[ "$ENABLE_FORWARD" == "1" ]]; then
    cat >>"$SYSCTL_FILE" <<'EOF'

# ---- IPv4 路由转发 ----
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
EOF
fi

# 旧配置残留: /etc/sysctl.conf 总是最后被读取, 会覆盖 sysctl.d 中的同名参数。
# 将其中与本脚本重复的键注释掉 (已备份)。
if [[ -f /etc/sysctl.conf ]]; then
    n=0
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        esc=${key//./\\.}
        if grep -qE "^[[:space:]]*${esc}[[:space:]]*=" /etc/sysctl.conf; then
            sed -i -E "s|^[[:space:]]*(${esc})[[:space:]]*=|#disabled-by-vps-init# \1=|" /etc/sysctl.conf
            n=$((n + 1))
        fi
    done < <(grep -E '^[a-z]' "$SYSCTL_FILE" | cut -d= -f1 | tr -d ' ')
    [[ $n -gt 0 ]] && info "已注释 /etc/sysctl.conf 中 $n 个重复参数 (防止覆盖，备份见 $BACKUP_DIR)"
fi

run sysctl --system
info "sysctl 已应用"

if [[ "$HAS_BBR" == "1" && "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "bbr" ]]; then
    warn "BBR 写入了配置但当前未生效，请检查其它 sysctl 配置是否覆盖，或查看 $LOG"
fi

# ---------------------------------------------------------------------
# 7. RPS / RFS (systemd 服务)
# ---------------------------------------------------------------------
step "RPS / RFS"
if [[ "$ENABLE_RPS" == "1" ]]; then
    ncpu=$(nproc)
    if [[ "$ncpu" -le 1 ]]; then
        info "单核 CPU，跳过 RPS"
    elif [[ "$ncpu" -gt 62 ]]; then
        warn "CPU 核数过多 (${ncpu})，跳过 RPS"
    else
        cat >/usr/local/sbin/vps-init-rps.sh <<'EOF'
#!/bin/bash
# 将网卡接收队列的软中断分散到全部 CPU
ncpu=$(nproc)
mask=$(printf '%x' $(( (1 << ncpu) - 1 )))
for dev in /sys/class/net/*; do
    name=$(basename "$dev")
    [[ "$name" == "lo" ]] && continue
    [[ "$name" == veth* || "$name" == docker* || "$name" == br-* ]] && continue
    queues=("$dev"/queues/rx-*)
    nq=${#queues[@]}
    [[ $nq -eq 0 || ! -e "${queues[0]}" ]] && continue
    flow=$(( 65536 / nq ))
    for q in "${queues[@]}"; do
        echo "$mask" >"$q/rps_cpus" 2>/dev/null
        echo "$flow" >"$q/rps_flow_cnt" 2>/dev/null
    done
done
exit 0
EOF
        chmod +x /usr/local/sbin/vps-init-rps.sh

        cat >/etc/systemd/system/vps-init-rps.service <<'EOF'
[Unit]
Description=Enable RPS/RFS on network interfaces (vps-init)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-init-rps.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        # 清理 1.x 版本的同类服务
        if [[ -f /etc/systemd/system/rps.service ]]; then
            run systemctl disable --now rps.service
            rm -f /etc/systemd/system/rps.service /usr/local/sbin/rps-setup.sh
        fi
        run systemctl daemon-reload
        run systemctl enable vps-init-rps.service
        run systemctl restart vps-init-rps.service
        info "RPS 已开启 (vps-init-rps.service)"
    fi
else
    info "跳过 (ENABLE_RPS=0)"
fi

# ---------------------------------------------------------------------
# 8. journald 日志限制
# ---------------------------------------------------------------------
step "systemd-journald"
mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/99-vps-init.conf <<'EOF'
[Journal]
SystemMaxUse=300M
EOF
run systemctl restart systemd-journald
info "日志最大占用 300M"

# ---------------------------------------------------------------------
# 9. 时区 + 时间同步
# ---------------------------------------------------------------------
step "时区与时间同步"
run timedatectl set-timezone "$TIMEZONE" || warn "设置时区失败: $TIMEZONE"

if ! systemctl is-active --quiet systemd-timesyncd 2>/dev/null \
   && ! systemctl is-active --quiet chrony 2>/dev/null \
   && ! systemctl is-active --quiet chronyd 2>/dev/null; then
    if run apt-get install "${APT_OPTS[@]}" chrony; then
        run systemctl enable --now chrony
        info "已安装并启用 chrony"
    else
        warn "时间同步服务安装失败"
    fi
else
    run timedatectl set-ntp true
    info "时间同步服务已在运行"
fi

# ---------------------------------------------------------------------
# 10. 旧版脚本残留清理
# ---------------------------------------------------------------------
step "清理旧版脚本残留"
cleaned=0
if [[ -f /etc/rc.local ]] && grep -qE 'rps\.sh|rdate|sysctl -p /etc/sysctl\.conf' /etc/rc.local; then
    backup /etc/rc.local
    sed -i -E '/rps\.sh|rdate|sysctl -p \/etc\/sysctl\.conf/d' /etc/rc.local
    cleaned=1
fi
if [[ -f /root/rps.sh ]]; then
    backup /root/rps.sh
    rm -f /root/rps.sh
    cleaned=1
fi
if [[ -f /root/.bashrc ]] && grep -qE '^[[:space:]]*alias (nload|banping|unbanping|is|ic|dropcache)=' /root/.bashrc; then
    backup /root/.bashrc
    sed -i -E '/^[[:space:]]*alias (nload|banping|unbanping|is|ic|dropcache)=/d' /root/.bashrc
    cleaned=1
fi
[[ $cleaned -eq 1 ]] && info "已清理 rc.local / .bashrc / rps.sh 中的旧条目" || info "无残留"

# ---------------------------------------------------------------------
# 11. 命令别名 / 函数
# ---------------------------------------------------------------------
cat >/etc/profile.d/99-vps-init.sh <<'EOF'
# Generated by vps-init
case $- in *i*) ;; *) return 0 ;; esac

alias nload='nload -i 2048000 -o 2048000'
alias is='iperf3 -s'
alias ic='iperf3 -c'
alias dropcache='sync && echo 3 > /proc/sys/vm/drop_caches'

# 禁 ping / 解禁 ping (立即生效并持久化)
banping() {
    printf 'net.ipv4.icmp_echo_ignore_all=1\nnet.ipv4.icmp_echo_ignore_broadcasts=1\nnet.ipv4.icmp_ignore_bogus_error_responses=1\n' >/etc/sysctl.d/98-banping.conf
    sysctl -p /etc/sysctl.d/98-banping.conf
}
unbanping() {
    rm -f /etc/sysctl.d/98-banping.conf
    sysctl -w net.ipv4.icmp_echo_ignore_all=0 net.ipv4.icmp_echo_ignore_broadcasts=1 net.ipv4.icmp_ignore_bogus_error_responses=1
}
EOF
info "别名已写入 /etc/profile.d/99-vps-init.sh (nload / is / ic / dropcache / banping / unbanping)"

# ---------------------------------------------------------------------
# 12. 验证汇总
# ---------------------------------------------------------------------
PASS=0; FAIL=0
check() {  # check "描述" "实际值" "期望值"
    if [[ "$2" == "$3" ]]; then
        echo -e "  ${green}✔${plain} $1: $2"; PASS=$((PASS + 1))
    else
        echo -e "  ${red}✘${plain} $1: $2 (期望 $3)"; FAIL=$((FAIL + 1))
    fi
}

echo
echo "============================================================"
echo " 验证汇总"
echo "============================================================"
check "默认队列算法 qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null)" "fq"
if [[ "$HAS_BBR" == "1" ]]; then
    check "拥塞控制" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "bbr"
else
    echo -e "  ${yellow}-${plain} 拥塞控制: 内核不支持 BBR, 当前 $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
fi
if [[ "$ENABLE_FORWARD" == "1" ]]; then
    check "IPv4 转发" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" "1"
fi
check "IPv6 转发" "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" "0"
check "rp_filter" "$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)" "0"
check "tcp_fastopen" "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)" "3"
check "时区" "$(timedatectl show -p Timezone --value 2>/dev/null)" "$TIMEZONE"
if [[ "$MAKE_SWAP" == "1" ]]; then
    sw=$(free -m | awk '/^Swap:/{print $2}')
    [[ "${sw:-0}" -gt 0 ]] && check "Swap(MB)" "$sw" "$sw" || check "Swap(MB)" "0" ">0"
fi
if [[ "$ENABLE_RPS" == "1" && -f /etc/systemd/system/vps-init-rps.service ]]; then
    check "RPS 服务" "$(systemctl is-active vps-init-rps.service 2>/dev/null)" "active"
fi
echo "  当前时间: $(date -R)"
echo
echo "  通过 ${PASS} 项, 失败 ${FAIL} 项"

echo
echo "============================================================"
echo -e " ${green}初始化完成${plain}"
echo "============================================================"
echo " 配置备份 : $BACKUP_DIR"
echo " 详细日志 : $LOG"
echo
echo " 提示:"
echo "  1. 重新登录 SSH 后, ulimit 对新会话生效; 已运行的服务需重启才会应用新的 nofile 限制"
echo "  2. 本脚本不会自动重启服务器"
if [[ -f /var/run/reboot-required ]]; then
    warn "系统提示需要重启 (/var/run/reboot-required)"
fi
[[ $FAIL -gt 0 ]] && warn "有 ${FAIL} 项验证未通过, 请查看上方结果与日志"
exit 0
