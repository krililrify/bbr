# vps-init

一个面向 **Debian / Ubuntu** 的 VPS 初始化与网络优化脚本：BBR + FQ、TCP 参数调优、文件句柄、RPS、Swap、日志限制、时区与时间同步、常用网络工具，一条命令完成。

设计目标：**非交互、可排查、可回滚、不执行任何第三方二进制。**

## 支持的系统

| 系统 | 版本 |
|---|---|
| Debian | 11 / 12 |
| Ubuntu | 22.04 / 24.04 / 26.04 |

> 仅支持 systemd 系统。CentOS / RHEL 系不在支持范围内。

## 快速开始

建议先下载、阅读，再运行（不推荐直接 `curl | bash` 以 root 执行未审阅的脚本）：

```bash
curl -fsSL -o init.sh https://raw.githubusercontent.com/<your-name>/vps-init/main/init.sh
less init.sh          # 先看一遍
sudo bash init.sh
```

默认模式只做"安全优化"，不会卸载防火墙，也不会卸载云厂商组件。

## 选项（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `TIMEZONE` | `Asia/Shanghai` | 时区 |
| `ENABLE_FORWARD` | `1` | 开启 IPv4 转发（中转机需要，普通服务器建议设为 `0`） |
| `ENABLE_RPS` | `1` | 开启 RPS/RFS，多核机器把网卡软中断分散到所有 CPU |
| `MAKE_SWAP` | `1` | 没有 swap 时创建，大小为 `min(内存, 512MB)` |
| `STOP_IRQBALANCE` | `0` | 停止 `irqbalance` |
| `REMOVE_FIREWALL` | `0` | 停用并卸载 ufw / firewalld，并关闭 SELinux |
| `REMOVE_CLOUD_AGENTS` | `0` | 卸载腾讯云监控组件，停用 waagent / walinuxagent / hypervkvpd |
| `INSTALL_PACKAGES` | `1` | 安装常用工具包 |

示例：

```bash
# 普通服务器（非中转）
sudo ENABLE_FORWARD=0 bash init.sh

# 中转机，并且清理云厂商组件和防火墙
sudo REMOVE_FIREWALL=1 REMOVE_CLOUD_AGENTS=1 bash init.sh

# 查看帮助
bash init.sh --help
```

## 脚本做了什么

1. **安装常用工具**：`curl wget mtr traceroute tcptraceroute nload vnstat htop iftop lsof iperf3 dnsutils ethtool git vim jq` 等。
2. **文件句柄 / 进程数**：`nofile`/`nproc` 设为 1000000，同时设置 systemd 的 `DefaultLimitNOFILE`，对 systemd 管理的服务也生效。
3. **BBR + FQ**：加载 `tcp_bbr`，写入 `default_qdisc=fq` 与 `tcp_congestion_control=bbr`。上述系统自带内核均支持 BBR，**不会更换内核**。
4. **TCP / 网络参数**：缓冲区、backlog、keepalive、`tcp_fastopen`、`tcp_mtu_probing`、关闭 ICMP 重定向、`rp_filter=0` 等。
5. **IPv4 转发**：开启；**IPv6 转发保持关闭**，避免破坏 DHCP/SLAAC 获取地址。
6. **RPS / RFS**：自带脚本 + systemd 服务，开机自动应用。
7. **Swap**：没有 swap 时创建 `/swapfile`。
8. **journald**：日志最大占用 300MB。
9. **时区与时间同步**：设置时区；若没有 `systemd-timesyncd` / `chrony` 在运行，则安装 `chrony`。
10. **别名与函数**：`nload`、`is`（iperf3 服务端）、`ic`（iperf3 客户端）、`dropcache`、`banping` / `unbanping`。
11. **清理旧版脚本残留**：`rc.local` 中的 `rps.sh` / `rdate` / `sysctl -p` 条目、`/root/rps.sh`、`.bashrc` 中旧别名，以及 `/etc/sysctl.conf` 中与本脚本重复的参数（会覆盖 `sysctl.d`，因此被注释掉）。
12. **验证汇总**：结束时输出 qdisc、拥塞控制、转发、时区、swap、RPS 等的实际状态。

## 和常见"一键优化脚本"的区别

| | 常见脚本 | vps-init |
|---|---|---|
| 非交互（不卡在 debconf / needrestart） | ✘ | ✔ |
| 输出写入日志，便于排查 | ✘（常被 `>/dev/null` 吞掉） | ✔ `/var/log/vps-init.log` |
| 下载并 root 执行第三方二进制 | 常见 | **无** |
| 激进操作（卸载防火墙等） | 默认执行 | 默认关闭，需显式开启 |
| 配置方式 | 覆盖 `sysctl.conf` / `limits.conf` | drop-in 文件，原文件先备份 |
| 对 systemd 服务生效的 nofile | 常被忽略 | ✔ |
| 重复执行 | 可能重复追加 | 幂等，并清理旧残留 |

## 文件与改动位置

| 路径 | 用途 |
|---|---|
| `/etc/sysctl.d/99-zz-vps-init.conf` | 内核网络参数 |
| `/etc/security/limits.d/99-vps-init.conf` | 用户级 limits |
| `/etc/systemd/system.conf.d/99-vps-init.conf` | systemd 默认 limits |
| `/etc/systemd/journald.conf.d/99-vps-init.conf` | journald 限制 |
| `/etc/modules-load.d/bbr.conf` | 开机加载 `tcp_bbr` |
| `/usr/local/sbin/vps-init-rps.sh` | RPS 设置脚本 |
| `/etc/systemd/system/vps-init-rps.service` | RPS 开机服务 |
| `/etc/profile.d/99-vps-init.sh` | 别名与函数 |
| `/swapfile` | Swap（仅在原本没有 swap 时创建） |
| `/var/log/vps-init.log` | 运行日志 |
| `/root/init-backup-<时间戳>/` | 修改前的配置备份 |

## 回滚

```bash
# 1. 删除脚本生成的配置
sudo rm -f /etc/sysctl.d/99-zz-vps-init.conf \
           /etc/security/limits.d/99-vps-init.conf \
           /etc/systemd/system.conf.d/99-vps-init.conf \
           /etc/systemd/journald.conf.d/99-vps-init.conf \
           /etc/modules-load.d/bbr.conf \
           /etc/profile.d/99-vps-init.sh

# 2. 停用并删除 RPS 服务
sudo systemctl disable --now vps-init-rps.service
sudo rm -f /etc/systemd/system/vps-init-rps.service /usr/local/sbin/vps-init-rps.sh

# 3. 重新加载
sudo systemctl daemon-reload
sudo sysctl --system

# 4. 如果修改过 /etc/sysctl.conf，从备份中恢复（被注释的行以 "#disabled-by-vps-init#" 开头）
ls /root/init-backup-*/etc/
```

Swap 如需移除：

```bash
sudo swapoff /swapfile && sudo rm -f /swapfile && sudo sed -i '\#^/swapfile #d' /etc/fstab
```

## 注意事项

- **云厂商安全组**：脚本不会处理云厂商侧的安全组 / 防火墙，请确认 SSH 端口已放行。
- **`REMOVE_FIREWALL=1` 会降低主机安全性**，公网机器请自行配合云厂商安全组或其它防护。
- **`rp_filter=0`** 适合中转 / 多网卡 / 非对称路由场景。纯服务器可以在 `/etc/sysctl.d/99-zz-vps-init.conf` 中改为 `1`，但注意重新运行脚本会覆盖该文件。
- **容器型 VPS（LXC / OpenVZ）**：很多内核参数、内核模块、swap 无法在容器内修改，脚本会给出警告，但不保证全部生效。
- **已运行的服务**需要重启后才会应用新的文件句柄限制；SSH 需要重新登录。
- 脚本不会自动重启服务器。
- 请先在测试机上运行，再用于生产环境。

## 常见问题

**Q：为什么很多脚本在"安装常用命令"时卡住？**
通常是 `apt` 弹出了交互界面（`iperf3` 的 debconf 对话框，或 Ubuntu 22.04+ 的 `needrestart` 服务重启提示），但脚本把输出重定向到了 `/dev/null`，看起来就像卡死。本脚本设置了 `DEBIAN_FRONTEND=noninteractive`、`NEEDRESTART_MODE=a`，并把输出写入日志。

**Q：运行后 BBR 没有生效？**
在脚本结尾的验证汇总里查看"拥塞控制"一项。常见原因：容器型虚拟化不允许修改；或其它 sysctl 配置覆盖了本脚本（查看 `sysctl -a | grep congestion`，以及 `/etc/sysctl.conf` 和 `/etc/sysctl.d/`）。

**Q：国内机器如何改 NTP 服务器？**
脚本使用发行版默认的时间同步服务。如需指定，可在 `/etc/systemd/timesyncd.conf.d/` 下添加 `NTP=` 配置，或修改 `/etc/chrony/chrony.conf`。

**Q：需要 speedtest / tcping 怎么办？**
脚本不下载第三方二进制。可使用 `apt install speedtest-cli`，或按 Ookla 官方文档添加其 apt 源。`tcptraceroute` 已默认安装。

## 许可证

MIT License。使用前请自行评估风险，**作者不对因运行本脚本造成的任何损失负责**。
