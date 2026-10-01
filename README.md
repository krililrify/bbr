# vps-init

一个面向 **Debian / Ubuntu VPS** 的保守型初始化与网络优化脚本。

目标不是堆砌所谓的“一键 TCP 神优化参数”，而是提供一套：

* **安全默认值**
* **可重复执行**
* **可排查**
* **可回滚**
* **配置独立**
* **不修改系统原始配置**
* **不下载第三方二进制**
* **适合长期维护**

的 VPS 初始化方案。

核心功能：

> **BBR + FQ + 保守 TCP 参数 + RPS/RFS + nofile + Swap + journald + 时区/NTP + 常用网络工具**

---

## 支持系统

| 系统     | 版本                    |
| ------ | --------------------- |
| Debian | 11 / 12               |
| Ubuntu | 22.04 / 24.04 / 26.04 |

要求：

* systemd
* root
* 使用发行版官方 APT 源
* 不支持 CentOS / RHEL / Alpine
* LXC / OpenVZ / Docker 等容器环境可能无法应用部分内核参数

脚本会使用 `systemd-detect-virt` 检测虚拟化环境，并在共享内核容器中给出警告。

---

## 快速开始

你可以选择**直接运行**，也可以先下载脚本并检查内容后再运行。

### 方式一：直接运行

如果你已经确认脚本来源可信，可以直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/krililrify/bbr/main/init.sh)
```

这种方式无需下载文件，直接获取 GitHub `main` 分支中的最新版本并运行。

### 方式二：下载后检查

如果希望在运行前查看脚本内容，可以先下载：

```bash
curl -fsSL -o init.sh https://raw.githubusercontent.com/krililrify/bbr/main/init.sh
```

查看脚本：

```bash
less init.sh
```

确认没有问题后运行：

```bash
bash init.sh
```

也可以使用：

```bash
chmod +x init.sh
./init.sh
```

> `less init.sh` 和 `chmod +x init.sh` 都不是必须步骤。
> `bash init.sh` 可以直接运行脚本，不需要执行权限。

### 查看帮助

直接查看帮助：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/krililrify/bbr/main/init.sh) --help
```

如果已经下载脚本：

```bash
bash init.sh --help
```

### 推荐

**普通 VPS：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/krililrify/bbr/main/init.sh)
```

**生产环境或希望确认脚本内容：**

```bash
curl -fsSL -o init.sh https://raw.githubusercontent.com/krililrify/bbr/main/init.sh
less init.sh
bash init.sh
```

# 默认行为

直接运行：

```bash
bash init.sh
```

默认配置：

```text
TIMEZONE=Asia/Shanghai
ENABLE_FORWARD=0
DISABLE_RP_FILTER=0
ENABLE_RPS=1
MAKE_SWAP=1
SET_LIMITS=1
STOP_IRQBALANCE=0
REMOVE_FIREWALL=0
REMOVE_CLOUD_AGENTS=0
INSTALL_PACKAGES=1
JOURNAL_MAX_USE=300M
```

也就是说：

### 默认会做

* 安装常用网络诊断工具
* 尝试启用 BBR
* 设置 FQ
* 设置保守 TCP 参数
* 设置 nofile
* 设置 RPS/RFS
* 没有 Swap 时创建 128~512 MiB Swap
* 限制 journald 最大磁盘占用
* 设置时区
* 确保存在时间同步服务
* 清理本项目旧版 RPS 残留
* 写入一些常用 Shell 命令

### 默认不会做

* 不开启 IPv4 转发
* 不开启 `route_localnet`
* 不关闭 `rp_filter`
* 不关闭防火墙
* 不卸载云厂商 Agent
* 不关闭 tuned
* 不关闭 smartd
* 不更换内核
* 不安装第三方内核
* 不下载第三方二进制
* 不修改 `/etc/sysctl.conf`
* 不自动重启服务器

---

# 普通 VPS

普通 Web / Docker / Xray / RustDesk / Chatwoot / Nginx 等服务器：

```bash
bash init.sh
```

这是推荐的默认模式。

---

# 中转机 / NAT / VPN

如果服务器需要进行 IPv4 路由转发：

```bash
ENABLE_FORWARD=1 bash init.sh
```

例如：

* VPS 中转
* NAT
* WireGuard Gateway
* VPN Gateway
* 路由器
* 部分透明代理场景

IPv4 转发默认关闭，是因为普通 VPS 不需要它。

Linux 内核将 `ip_forward` 作为特殊 sysctl 处理，修改它会重置部分 IPv4 配置。因此本脚本在生成 sysctl 文件时，会先设置 `ip_forward`，再设置其它 IPv4 参数。

---

# 非对称路由 / 多网卡

普通 VPS 默认：

```text
rp_filter=1
```

如果服务器属于：

* 多网卡
* 非对称路由
* 特殊中转
* 多出口
* 某些 VPN / Relay
* 特殊策略路由

可以：

```bash
ENABLE_FORWARD=1 DISABLE_RP_FILTER=1 bash init.sh
```

此时：

```text
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
```

不要为了“优化”而无条件关闭 `rp_filter`。

---

# BBR + FQ

脚本会首先尝试加载：

```text
tcp_bbr
```

然后检测：

```text
/proc/sys/net/ipv4/tcp_available_congestion_control
```

如果当前内核支持 BBR：

```text
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
```

同时生成：

```text
/etc/modules-load.d/bbr.conf
```

保证后续启动时继续尝试加载 BBR。

脚本不会：

* 下载第三方内核
* 更换内核
* 修改 GRUB
* 安装第三方 BBR 模块

如果当前 VPS 内核本身不支持 BBR，脚本只会给出警告。

---

# 为什么不再使用大量“激进 TCP 参数”

本项目故意没有使用很多常见的一键优化参数，例如：

```text
tcp_retries2=8
tcp_orphan_retries=2
tcp_tw_reuse=1
tcp_no_metrics_save=1
tcp_fin_timeout=15
```

这些参数并不是“越小越快”。

例如 Linux 当前内核文档中：

* `tcp_retries2` 默认值为 15
* `tcp_orphan_retries` 默认值为 8
* `tcp_tw_reuse` 当前默认值为 2

并且内核文档特别提醒 `tcp_tw_reuse` 不应在没有专业建议的情况下随意修改。

因此本项目选择：

> **只调整比较明确、可解释、适合作为通用 VPS 默认值的参数。**

---

# TCP 参数

当前主要设置：

```text
tcp_syncookies=1
tcp_fastopen=3
tcp_mtu_probing=1
tcp_slow_start_after_idle=0
tcp_window_scaling=1
tcp_sack=1
tcp_moderate_rcvbuf=1
```

以及：

```text
net.core.somaxconn=65535
net.core.netdev_max_backlog=16384
net.ipv4.tcp_max_syn_backlog=16384
```

TCP buffer 上限：

```text
net.core.rmem_max=33554432
net.core.wmem_max=33554432

net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 16384 33554432
```

这些是上限/自动调节范围，并不是启动时一次性分配几十 MB 内存。

---

# TCP MTU Probing

脚本：

```text
net.ipv4.tcp_mtu_probing=1
```

这个模式不是强制所有 TCP 连接持续探测 MTU，而是在检测到可能的 ICMP black hole 时启用相关机制。

对于 VPS、跨境线路、隧道、中转等场景，这比强制模式更保守。

---

# RPS / RFS

默认：

```text
ENABLE_RPS=1
```

但不是无脑把所有网卡都分配给所有 CPU。

脚本会检查：

```text
CPU 数量
RX queue 数量
```

如果：

```text
RX queue >= CPU
```

则认为硬件 RSS 已经有足够的并行队列，避免额外增加软件 RPS 开销。

只有在软件分流可能有意义时，才设置：

```text
rps_cpus
rps_flow_cnt
```

RPS 配置脚本：

```text
/usr/local/sbin/vps-init-rps.sh
```

systemd 服务：

```text
/etc/systemd/system/vps-init-rps.service
```

查看状态：

```bash
systemctl status vps-init-rps.service
```

关闭：

```bash
ENABLE_RPS=0 bash init.sh
```

---

# 文件句柄

默认：

```text
SET_LIMITS=1
```

生成：

```text
/etc/security/limits.d/99-vps-init.conf
```

主要配置：

```text
*     soft   nofile    1000000
*     hard   nofile    1000000
root  soft   nofile    1000000
root  hard   nofile    1000000
```

同时为 systemd 写入：

```text
/etc/systemd/system.conf.d/99-vps-init.conf
```

配置：

```ini
[Manager]
DefaultLimitNOFILE=1000000
```

这样 PAM 登录会话和 systemd 默认启动的服务都可以获得更高的文件描述符上限。

注意：

> 已经运行的服务不会因为写入配置文件而自动改变限制。

例如 Docker / Nginx / Xray 等已经运行的服务，通常需要重启后才能继承新的 systemd 默认限制。

新 SSH 登录：

```bash
ulimit -n
```

查看。

---

# Swap

默认：

```text
MAKE_SWAP=1
```

如果系统已经存在 Swap：

```text
跳过
```

如果没有：

```text
128~512 MiB
```

具体大小根据物理内存计算：

|          内存 |    Swap |
| ----------: | ------: |
|    <128 MiB | 128 MiB |
| 128~512 MiB |   与内存接近 |
|    >512 MiB | 512 MiB |

Swap 文件：

```text
/swapfile
```

权限：

```text
600
```

并自动写入：

```text
/etc/fstab
```

如果不想创建：

```bash
MAKE_SWAP=0 bash init.sh
```

---

# journald

默认：

```text
300M
```

生成：

```text
/etc/systemd/journald.conf.d/99-vps-init.conf
```

内容：

```ini
[Journal]
SystemMaxUse=300M
```

目的主要是防止长期运行 VPS 的 journal 无限膨胀。

可以自定义：

```bash
JOURNAL_MAX_USE=500M bash init.sh
```

或者：

```bash
JOURNAL_MAX_USE=1G bash init.sh
```

---

# 时区

默认：

```text
Asia/Shanghai
```

例如：

```bash
TIMEZONE=Asia/Tokyo bash init.sh
```

或者：

```bash
TIMEZONE=UTC bash init.sh
```

---

# 时间同步

脚本首先检查：

```text
systemd-timesyncd
chrony
chronyd
```

如果已经存在并运行：

> 不重复安装。

如果没有：

> 使用发行版官方 APT 源安装 chrony。

不会下载第三方 NTP 软件。

---

# 常用工具

默认尝试安装：

```text
curl
wget
ca-certificates

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
```

如果某个发行版仓库没有某个包，会跳过该包，而不是因为一个包失败导致整个安装流程完全中断。

---

# Shell 辅助命令

脚本生成：

```text
/etc/profile.d/99-vps-init.sh
```

包含：

### nload

```bash
nload
```

### iperf3 服务端

```bash
is
```

等价于：

```bash
iperf3 -s
```

### iperf3 客户端

```bash
ic IP
```

等价于：

```bash
iperf3 -c IP
```

### 清理缓存

```bash
dropcache
```

### 禁止 Ping

```bash
banping
```

### 恢复 Ping

```bash
unbanping
```

这些命令不是初始化必须项，只是方便日常 VPS 管理。

---

# 防火墙

默认：

```text
REMOVE_FIREWALL=0
```

所以：

> 脚本不会碰现有防火墙。

不会自动：

```text
卸载 ufw
卸载 firewalld
关闭 nftables
修改 iptables
修改云安全组
```

如果明确需要卸载：

```bash
REMOVE_FIREWALL=1 bash init.sh
```

这属于危险选项。

公网服务器使用之前，请确保：

* 云厂商安全组已经配置
* SSH 端口已经放行
* 服务器有其它防护措施

---

# 云厂商 Agent

默认：

```text
REMOVE_CLOUD_AGENTS=0
```

因此：

> 不处理云厂商组件。

如果明确需要：

```bash
REMOVE_CLOUD_AGENTS=1 bash init.sh
```

目前主要处理脚本明确识别到的：

```text
walinuxagent
waagent
hypervkvpd
```

以及部分腾讯云：

```text
/usr/local/qcloud
```

相关卸载程序。

注意：

> `REMOVE_CLOUD_AGENTS=1` 不等于“删除所有云厂商监控”。

不同云厂商使用的 Agent 不一样。

例如本脚本不会把阿里云的所有监控/安全组件都当作统一对象删除。

---

# irqbalance

默认：

```text
STOP_IRQBALANCE=0
```

也就是说：

> 保留 irqbalance。

如果你明确知道自己的 VPS 不需要：

```bash
STOP_IRQBALANCE=1 bash init.sh
```

才会尝试停用。

---

# tuned / smartd

本版本**不会默认关闭**：

```text
tuned
smartd
```

这是刻意设计。

如果 VPS 已经安装这些服务：

> 说明它们可能是系统或用户主动配置的一部分。

初始化脚本不应该擅自删除或关闭。

---

# 配置文件

主要文件：

```text
/etc/sysctl.d/99-zz-vps-init.conf
/etc/security/limits.d/99-vps-init.conf
/etc/systemd/system.conf.d/99-vps-init.conf
/etc/systemd/journald.conf.d/99-vps-init.conf
/etc/modules-load.d/bbr.conf

/usr/local/sbin/vps-init-rps.sh
/etc/systemd/system/vps-init-rps.service

/etc/profile.d/99-vps-init.sh
```

日志：

```text
/var/log/vps-init.log
```

备份：

```text
/root/vps-init-backup-YYYYMMDD-HHMMSS/
```

---

# 为什么使用 sysctl.d

本项目不会把大量参数直接追加到：

```text
/etc/sysctl.conf
```

而是使用：

```text
/etc/sysctl.d/99-zz-vps-init.conf
```

这样：

* 配置集中
* 容易查看
* 容易删除
* 不污染系统原始配置
* 可以通过文件名控制优先级

Linux 的 `sysctl.d` 会按照文件名排序，同名配置由优先级更高的位置覆盖；本项目使用 `99-zz-vps-init.conf`，目的是让本地管理员配置拥有较明确的覆盖空间，同时避免直接修改发行版的 `/etc/sysctl.conf`。

---

# 日志

运行日志：

```bash
cat /var/log/vps-init.log
```

实时查看：

```bash
tail -f /var/log/vps-init.log
```

只看最后 100 行：

```bash
tail -n 100 /var/log/vps-init.log
```

如果脚本出现：

```text
[WARN]
```

或者：

```text
[ERR]
```

优先查看：

```bash
/var/log/vps-init.log
```

---

# 验证

脚本结束时会自动检查：

```text
qdisc
BBR
IPv4 forwarding
IPv6 forwarding
rp_filter
TCP Fast Open
TCP MTU probing
时区
Swap
nofile 配置
RPS 服务
journald
```

例如：

```text
✔ 默认 qdisc: fq
✔ 拥塞控制: bbr
✔ IPv4 转发: 0
✔ IPv6 转发: 0
✔ rp_filter: 1
✔ tcp_fastopen: 3
✔ tcp_mtu_probing: 1
✔ 时区: Asia/Shanghai
```

---

# 手动检查 BBR

```bash
sysctl net.ipv4.tcp_congestion_control
```

应该：

```text
net.ipv4.tcp_congestion_control = bbr
```

查看可用拥塞控制：

```bash
sysctl net.ipv4.tcp_available_congestion_control
```

查看 qdisc：

```bash
sysctl net.core.default_qdisc
```

应该：

```text
net.core.default_qdisc = fq
```

---

# 手动检查 RPS

查看服务：

```bash
systemctl status vps-init-rps.service
```

查看：

```bash
cat /sys/class/net/eth0/queues/rx-0/rps_cpus
```

注意实际网卡名称可能不是 `eth0`：

```bash
ip link
```

---

# 手动检查文件句柄

当前 SSH：

```bash
ulimit -n
```

systemd 默认：

```bash
systemctl show --property=DefaultLimitNOFILE
```

单个服务：

```bash
systemctl show nginx --property=LimitNOFILE
```

已经运行的服务如果没有继承新的限制，可以：

```bash
systemctl restart nginx
```

---

# 回滚

本脚本所有主要配置都有独立文件，因此回滚比较简单。

## 1. 删除 sysctl

```bash
rm -f /etc/sysctl.d/99-zz-vps-init.conf
```

然后：

```bash
systemctl restart systemd-sysctl
```

注意：

> 如果系统当前运行状态需要立即恢复到原来的参数，建议从备份或系统默认配置中恢复，而不是单纯删除文件后假设所有 runtime 参数会自动恢复。

---

## 2. 删除 BBR modules-load

```bash
rm -f /etc/modules-load.d/bbr.conf
```

BBR 本身不需要为了回滚而更换内核。

---

## 3. 删除 RPS

```bash
systemctl disable --now vps-init-rps.service
```

然后：

```bash
rm -f \
  /etc/systemd/system/vps-init-rps.service \
  /usr/local/sbin/vps-init-rps.sh
```

最后：

```bash
systemctl daemon-reload
```

---

## 4. 删除 limits

```bash
rm -f \
  /etc/security/limits.d/99-vps-init.conf \
  /etc/systemd/system.conf.d/99-vps-init.conf
```

然后：

```bash
systemctl daemon-reload
```

重新登录 SSH。

---

## 5. 删除 journald 配置

```bash
rm -f /etc/systemd/journald.conf.d/99-vps-init.conf
systemctl restart systemd-journald
```

---

## 6. 删除 Shell 辅助命令

```bash
rm -f /etc/profile.d/99-vps-init.sh
```

重新登录 SSH。

---

## 7. 删除 Swap

只有确认 `/swapfile` 是本项目创建的情况下：

```bash
swapoff /swapfile
rm -f /swapfile
sed -i '\#^/swapfile[[:space:]]#d' /etc/fstab
```

---

# 自动备份

每次运行都会创建：

```text
/root/vps-init-backup-YYYYMMDD-HHMMSS/
```

例如：

```text
/root/vps-init-backup-20261001-162500/
```

如果某个系统文件在修改前存在，脚本会优先备份。

查看：

```bash
ls -lah /root/vps-init-backup-*/
```

---

# 重复执行

脚本设计为幂等。

可以重复运行：

```bash
bash init.sh
```

不会不断追加：

```text
limits
aliases
sysctl
RPS service
journald
```

而是重新生成本项目自己的配置文件。

例如：

```bash
bash init.sh
bash init.sh
bash init.sh
```

不会生成：

```text
alias nload=...
alias nload=...
alias nload=...
```

---

# 推荐使用方式

## 普通 VPS

```bash
bash init.sh
```

## 中转 VPS

```bash
ENABLE_FORWARD=1 bash init.sh
```

## 中转 + 非对称路由

```bash
ENABLE_FORWARD=1 DISABLE_RP_FILTER=1 bash init.sh
```

## 不创建 Swap

```bash
MAKE_SWAP=0 bash init.sh
```

## 不使用 RPS

```bash
ENABLE_RPS=0 bash init.sh
```

## 不安装工具

```bash
INSTALL_PACKAGES=0 bash init.sh
```

## UTC

```bash
TIMEZONE=UTC bash init.sh
```

## 东京

```bash
TIMEZONE=Asia/Tokyo bash init.sh
```

---

# 设计原则

本项目不追求：

> “sysctl 参数越多越快”。

而是遵循：

> **默认保守，特殊需求通过环境变量开启。**

尤其不默认修改：

```text
tcp_retries2
tcp_orphan_retries
tcp_tw_reuse
tcp_no_metrics_save
route_localnet
```

也不默认：

```text
关闭 rp_filter
开启 IPv4 forwarding
卸载防火墙
卸载云厂商 Agent
关闭 tuned
关闭 smartd
更换 Linux 内核
```

这样同一个脚本可以用于：

```text
普通 Web VPS
Docker VPS
Xray VPS
中转 VPS
VPN VPS
RustDesk VPS
Nginx VPS
数据库 VPS
```

而不需要为了不同机器维护大量完全不同的一键脚本。

---

# 安全说明

这是一个系统初始化脚本。

执行前请确认：

1. SSH 当前可以正常登录。
2. 云厂商安全组已经放行 SSH。
3. 不要在不了解 `REMOVE_FIREWALL=1` 后果的情况下使用它。
4. 中转机才需要开启 `ENABLE_FORWARD=1`。
5. 非对称路由场景才考虑 `DISABLE_RP_FILTER=1`。
6. 容器 VPS 可能不允许修改部分内核参数。
7. 脚本不会自动重启服务器。

建议：

> **先在测试 VPS 上执行，再用于生产服务器。**

---

# License

MIT License

本项目仅提供系统配置自动化。

使用前请自行评估服务器环境和业务需求。
