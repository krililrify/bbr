````markdown
# VPS Init & Network Optimization

VPS 一键初始化与网络优化脚本。

主要用于 Debian / Ubuntu / CentOS VPS 的系统初始化、BBR、TCP 网络参数优化以及常用网络工具安装。

## 使用方式

直接执行：

```bash
curl -fsSL https://raw.githubusercontent.com/newxqkjfenxiang/docker-install/main/inits.sh | bash
````

如果当前用户不是 `root`，请使用：

```bash
curl -fsSL https://raw.githubusercontent.com/newxqkjfenxiang/docker-install/main/inits.sh | sudo bash
```

也可以先下载再执行：

```bash
wget -O inits.sh https://raw.githubusercontent.com/newxqkjfenxiang/docker-install/main/inits.sh
chmod +x inits.sh
bash inits.sh
```

---

## 功能特性

### 系统初始化

* ✅ 自动检测 Root 权限
* ✅ 自动检测操作系统
* ✅ 自动检测 CPU 架构
* ✅ 支持 Debian / Ubuntu / CentOS
* ✅ 更新系统软件包索引
* ✅ 优化文件句柄与进程限制

### 防火墙与云服务处理

* ⚠️ 自动停止并卸载 firewalld
* ⚠️ 自动停止并卸载 UFW
* ⚠️ 停止部分不必要的系统服务
* ⚠️ 检测并卸载腾讯云相关 Agent

### BBR

* ✅ 自动检测 Linux Kernel
* ✅ 自动加载 tcp_bbr
* ✅ 检查系统是否支持 BBR
* ✅ 启用 BBR
* ✅ 启用 FQ
* ✅ 配置：

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

安装完成后可以检查：

```bash
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_congestion_control
sysctl net.ipv4.tcp_available_congestion_control
```

正常情况下应该看到：

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

并且可用算法中包含：

```text
bbr
```

---

## TCP 网络优化

脚本包含以下 TCP 参数优化：

```text
net.ipv4.tcp_no_metrics_save
net.ipv4.tcp_ecn
net.ipv4.tcp_frto
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_rfc1337
net.ipv4.tcp_sack
net.ipv4.tcp_fack
net.ipv4.tcp_window_scaling
net.ipv4.tcp_adv_win_scale
net.ipv4.tcp_moderate_rcvbuf
net.ipv4.tcp_syncookies
net.ipv4.tcp_nopush
net.ipv4.tcp_dsack
net.ipv4.tcp_fastopen
net.ipv4.tcp_tw_reuse
net.ipv4.tcp_timestamps
```

### TCP Buffer

```text
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728

net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
```

### TCP Queue

```text
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
```

### TCP Port

```text
net.ipv4.ip_local_port_range = 1024 65535
```

---

## IPv4 Forwarding

默认开启：

```text
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
```

适用于：

* VPS 中转
* NAT
* 路由
* 代理
* 网络转发

同时关闭 IPv4 `rp_filter`：

```text
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
```

---

## IPv6

脚本不会关闭 IPv6。

默认：

```text
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
```

但是不会开启 IPv6 forwarding：

```text
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
```

---

## RPS

自动下载并配置 RPS：

```text
https://file.myluckys.org/script/rps.sh
```

配置完成后：

```text
/root/rps.sh
```

并加入 `/etc/rc.local`，服务器启动后自动执行。

---

## Swap

如果 VPS 没有 Swap：

* 自动创建 `/swapfile`
* 根据内存自动计算大小
* 最大 512 MB
* 最小 128 MB
* 自动加入 `/etc/fstab`

如果已经存在 Swap，则不会重复创建。

---

## irqbalance

脚本会检测并停止：

```text
irqbalance
```

并设置为不开机启动。

---

## systemd 日志

限制 systemd journal 最大使用空间：

```text
300 MB
```

配置文件：

```text
/etc/systemd/journald.conf.d/99-vps-init.conf
```

---

## 时区与时间同步

默认设置服务器时区：

```text
Asia/Shanghai
```

安装：

```text
rdate
```

并使用：

```text
time.nist.gov
```

进行时间同步。

---

## 常用网络工具

自动安装：

```text
iperf3
mtr
traceroute
nload
vnstat
curl
wget
lsof
htop
iftop
telnet
git
dnsutils
net-tools
vim
nano
tcptraceroute
```

---

## tcping

自动安装：

```text
/usr/bin/tcping
```

来源：

```text
https://file.myluckys.org/script/tcping
```

---

## speedtest

根据 CPU 架构自动安装：

```text
/usr/bin/speedtest
```

支持：

```text
x86_64
aarch64
```

---

## Bash Alias

自动添加以下快捷命令。

### nload

```bash
nload
```

### iperf3 Server

```bash
is
```

等价于：

```bash
iperf3 -s
```

### iperf3 Client

```bash
ic
```

等价于：

```bash
iperf3 -c
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

### SKY-BOX

```bash
tbox
```

---

## sysctl 配置

脚本会备份原有配置：

```text
/root/sysctl-backup-时间/
```

然后重新生成：

```text
/etc/sysctl.conf
```

同时清理：

```text
/etc/sysctl.d/*.conf
```

这样可以避免多个 sysctl 配置文件之间出现重复或参数覆盖。

---

## 注意事项

### 1. 必须使用 Root

脚本需要修改：

```text
/etc/sysctl.conf
/etc/security/limits.conf
/etc/rc.local
/etc/systemd/
```

以及系统服务，因此需要 Root 权限。

### 2. 防火墙会被卸载

脚本会停止并卸载：

```text
firewalld
ufw
```

运行脚本之前，请确认云厂商的安全组已经放行 SSH 端口。

### 3. 腾讯云 Agent

如果检测到：

```text
/usr/local/qcloud
```

脚本会尝试卸载腾讯云相关 Agent。

腾讯云 VPS 请谨慎运行。

### 4. sysctl.d

脚本会清理：

```text
/etc/sysctl.d/*.conf
```

执行前会自动备份到：

```text
/root/sysctl-backup-时间/
```

### 5. BBR

脚本不会仅通过：

```bash
lsmod | grep bbr
```

判断 BBR。

推荐使用：

```bash
sysctl net.ipv4.tcp_congestion_control
```

如果显示：

```text
net.ipv4.tcp_congestion_control = bbr
```

说明当前 TCP 拥塞控制算法已经使用 BBR。

### 6. 不会自动重启

脚本执行完成后不会自动重启服务器。

如果修改了 Kernel 或其他需要重启才能生效的系统组件，请根据实际情况手动重启。

---

## 支持系统

主要支持：

* Debian 11+
* Debian 12+
* Debian 13+
* Ubuntu 20.04+
* Ubuntu 22.04+
* Ubuntu 24.04+
* Ubuntu 26.04+
* CentOS 7+
* Rocky Linux
* AlmaLinux

建议优先使用较新的 Debian / Ubuntu LTS。

---

## 脚本地址

GitHub：

https://github.com/newxqkjfenxiang/docker-install

初始化脚本：

https://raw.githubusercontent.com/newxqkjfenxiang/docker-install/main/inits.sh

---

## License

MIT

```
```
