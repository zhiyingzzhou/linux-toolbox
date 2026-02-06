# tproxy-sh.sh（透明代理开关）

`tproxy-sh.sh` 用来一键开启/关闭“透明代理”：通过 `iptables` 把本机的 **TCP 出站连接** 重定向到本机某个端口，让不支持代理配置的程序也能走代理（比如 `apt`、`docker pull`、各种后台服务）。

> 说明：脚本使用的是 `iptables REDIRECT`（常见的 redir 模式），默认只处理 TCP；UDP（例如部分 DNS）不在默认范围内。

---

## 快速开始

### 1. 下载安装

> **国内用户推荐使用 Gitee 镜像仓库，下载速度更快。**  
> **注意：**  
> **不要**使用 `curl ... | bash` 方式直接运行本脚本，否则交互输入会失效。  
> 请先下载脚本到本地，再执行。

#### Gitee 镜像（推荐国内用户）

```bash
curl -fsSL https://gitee.com/zhiyingzhou/linux-toolbox/raw/main/tproxy-sh.sh -o tproxy-sh.sh
sudo sh tproxy-sh.sh --help
```

或本地克隆后运行：

```bash
git clone https://gitee.com/zhiyingzhou/linux-toolbox.git
cd linux-toolbox
sudo sh tproxy-sh.sh --help
```

#### GitHub 源仓库

```bash
curl -fsSL https://raw.githubusercontent.com/zhiyingzzhou/linux-toolbox/main/tproxy-sh.sh -o tproxy-sh.sh
sudo sh tproxy-sh.sh --help
```

或本地克隆后运行：

```bash
git clone https://github.com/zhiyingzzhou/linux-toolbox.git
cd linux-toolbox
sudo sh tproxy-sh.sh --help
```

### 2. 基本使用

前提：你已经有一个“支持透明入站”的本机代理端口（例如 Clash 的 `redir-port` / sing-box 的 `redirect` 入站），假设端口是 `7892`。

只代理本机进程：

```sh
sudo sh tproxy-sh.sh enable --port 7892 --exclude-user clash
```

同时把 Docker/容器流量也纳入（会在 `PREROUTING` 加规则）：

```sh
sudo sh tproxy-sh.sh enable --port 7892 --exclude-user clash --docker
```

如果你只有远端 HTTP 代理（本机没有透明端口），用一条命令让脚本自动安装/配置 `redsocks`：

```sh
sudo sh tproxy-sh.sh enable-http --proxy PROXY_IP:PROXY_PORT
```

容器也走代理：

```sh
sudo sh tproxy-sh.sh enable-http --proxy PROXY_IP:PROXY_PORT --docker
```

查看状态：

```sh
sudo sh tproxy-sh.sh status
```

关闭：

```sh
sudo sh tproxy-sh.sh disable
```

---

## 注意事项

### 0) 如果代理服务器在另一台机器

透明代理（`iptables REDIRECT`）的前提是：本机必须有一个“透明入站端口”在监听，用来接管被重定向的连接，并读取原始目的地址（否则没法转发到真正的目标站点）。  
所以如果你的代理服务端是独立机器/远端 VPS，本机依然需要跑一个客户端（Clash/sing-box/redsocks 等）来提供这个本地端口；脚本 `--port` 填的就是 **本机端口**，不是远端服务器端口。

另一种情况是：那台“单独的代理服务器”本身就是网关/旁路由（负责全网透明代理）。这种就不需要在本机做 `REDIRECT`，而是把本机的默认网关/路由指向它（或用 VPN/WireGuard 把默认路由走隧道）。

### 0.1) Debian + 远端 HTTP 代理：用 redsocks 落地（推荐）

如果你手里只有一个 **远端 HTTP 代理**（例如 `http://PROXY_IP:PROXY_PORT`），本机没有 `redir-port`，最省事的做法是用 `redsocks` 在本机起一个“落地点端口”，把被透明抓到的 TCP 连接转成 `HTTP CONNECT` 发给远端代理。

一条命令（推荐，自动安装/配置 redsocks）：

```sh
sudo sh tproxy-sh.sh enable-http --proxy PROXY_IP:PROXY_PORT
```

容器也走代理：

```sh
sudo sh tproxy-sh.sh enable-http --proxy PROXY_IP:PROXY_PORT --docker
```

如需账号密码（可选）：

```sh
sudo sh tproxy-sh.sh enable-http --proxy PROXY_IP:PROXY_PORT --user USER --pass PASS
```

下面是手动步骤（备查）：

1）安装：

```sh
sudo apt-get update
sudo apt-get install -y redsocks iptables
```

2）配置 `redsocks`（示例：本机监听 `12345`，上游 HTTP 代理是 `PROXY_IP:PROXY_PORT`）：

```sh
sudo cp -a /etc/redsocks.conf "/etc/redsocks.conf.bak.$(date +%F_%H%M%S)"
sudo nano /etc/redsocks.conf
```

最小可用配置参考（按需改 IP/端口；要给 Docker 用就把 `local_ip` 设为 `0.0.0.0`）：

```conf
base {
  log_info = on;
  daemon = on;
  redirector = iptables;
}

redsocks {
  local_ip = 127.0.0.1;
  local_port = 12345;
  ip = PROXY_IP;
  port = PROXY_PORT;
  type = http-connect;
  # 如果上游需要账号密码（可选）：
  # login = "USER";
  # password = "PASS";
}
```

> 提醒：上游 HTTP 代理必须支持 `CONNECT`，否则 HTTPS（比如 `docker pull`/大多数站点）走不通。

3）启动并确认本机端口已监听：

```sh
sudo systemctl enable --now redsocks
sudo systemctl status redsocks --no-pager
ss -lntp | grep ':12345'
```

4）开启透明代理（建议绕过 `redsocks` 用户，避免回环）：

```sh
sudo sh tproxy-sh.sh enable --port 12345 --exclude-user redsocks
```

要让容器也走代理，再加 `--docker`（并确保 `redsocks` 监听不是只绑 `127.0.0.1`）：

```sh
sudo sh tproxy-sh.sh enable --port 12345 --exclude-user redsocks --docker
```

### 1) 远程机器操作，开启后断网/SSH 掉线

脚本默认会检查目标端口是否在监听；如果端口没起，开启后所有新建 TCP 连接都会被重定向到一个不存在的服务，看起来就像“断网”。  
不建议在远程只有一个会话的情况下直接开启；最好先准备一个备用会话或控制台通道。

### 2) 代理进程回环（代理自己也被透明代理了）

建议把代理进程跑在独立用户下（例如 `clash`），并用 `--exclude-user` 绕过它，避免回环：

```sh
sudo sh tproxy-sh.sh enable --port 7892 --exclude-user clash
```

### 3) 开了 `--docker` 但容器不生效

容器流量会从 `docker0`/`br-*`/`cni0` 等接口进入主机，脚本会在这些接口的 `PREROUTING` 做重定向。  
这通常要求你的透明入站端口不要只监听 `127.0.0.1`；如果代理只绑本地回环地址，来自容器网桥的流量可能接不进去。

### 4) 默认不会代理内网/保留地址

脚本会绕过常见内网段与保留地址（例如 `127.0.0.0/8`、`192.168.0.0/16` 等），避免影响本地通信。需要调整的话，直接改 `tproxy-sh.sh` 里的 `BYPASS_CIDRS`。
