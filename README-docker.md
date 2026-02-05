# docker-sh.sh（装 Docker 的一键脚本）

目标：在 Debian 12/13（以及常见 Linux）上把 Docker 装起来，并顺手把常用配置（代理、镜像站）一起做了。  
国内网络默认会优先探测华为云/阿里云/清华/中科大，必要时回退官方源。

## 快速开始

### 1. 下载安装

> **国内用户推荐使用 Gitee 镜像仓库，下载速度更快。**  
> **注意：**  
> **不要**使用 `curl ... | bash` 方式直接运行本脚本，否则交互输入会失效。  
> 请先下载脚本到本地，再执行。

#### Gitee 镜像（推荐国内用户）

```bash
curl -fsSL https://gitee.com/zhiyingzhou/linux-toolbox/raw/main/docker-sh.sh -o docker-sh.sh
sudo sh docker-sh.sh
```

或本地克隆后运行：

```bash
git clone https://gitee.com/zhiyingzhou/linux-toolbox.git
cd linux-toolbox
sudo sh docker-sh.sh
```

#### GitHub 源仓库

```bash
curl -fsSL https://raw.githubusercontent.com/zhiyingzzhou/linux-toolbox/main/docker-sh.sh -o docker-sh.sh
sudo sh docker-sh.sh
```

或本地克隆后运行：

```bash
git clone https://github.com/zhiyingzzhou/linux-toolbox.git
cd linux-toolbox
sudo sh docker-sh.sh
```

## 安装 / 更新

```sh
sudo sh docker-sh.sh
```

向导（安装 + 配置 + 测试）：

```sh
sudo sh docker-sh.sh wizard
```

### Proxmox / PVE 场景：apt-get update 被 enterprise 源卡住

如果 `apt-get update` 因为 `enterprise.proxmox.com`（401 / 未签名）直接失败，可以用这个开关：

```sh
sudo sh docker-sh.sh install --fix-apt
```

脚本做的事：

- 会把包含 `enterprise.proxmox.com` 的源文件备份为 `*.bak.docker-sh.<timestamp>`
- `sources.list.d` 下的对应文件会被重命名为 `*.docker-sh.disabled` 以禁用
- 如需恢复，把 `*.docker-sh.disabled` 改回原名，或用备份文件覆盖即可

## 安装源镜像（装 Docker 用）

`--mirror`/`DOCKER_REPO_BASE` 是 **Docker 安装包仓库源**（apt/yum），不是镜像加速。

```sh
sudo sh docker-sh.sh --mirror https://mirrors.huaweicloud.com/docker-ce/linux/debian
# 或：
DOCKER_REPO_BASE=https://mirrors.huaweicloud.com/docker-ce/linux/debian sudo sh docker-sh.sh
```

## 命令式使用（可卸载）

把脚本安装到 `/usr/local/bin`，之后就能直接敲 `docker-sh ...`：

```sh
sudo sh docker-sh.sh self-install
docker-sh wizard
```

卸载这个命令：

```sh
sudo docker-sh self-uninstall
```

## 配置（拉镜像用）

下面配置的是 **Docker daemon 拉镜像** 用的代理/镜像站，和上面的 `--mirror` 不是一回事。

配置 Docker daemon 代理（systemd 环境）：

```sh
sudo sh docker-sh.sh config proxy
```

配置 Docker 镜像站（写 `registry-mirrors` 到 `/etc/docker/daemon.json`）：

```sh
sudo sh docker-sh.sh config mirrors
```

查看当前配置：

```sh
sudo sh docker-sh.sh config show
```

## 测试

```sh
sudo sh docker-sh.sh test all
```

```sh
sudo sh docker-sh.sh test pull --image hello-world:latest
```

相关脚本：

- SSH：`README-ssh.md`
- 终端代理：`README-proxy.md`

---

## 附：手动安装 Docker（备查）

下面是手动安装 Docker 的常见步骤（不推荐日常使用；优先用 `docker-sh.sh` 一键安装）。

```sh
# 1) 安装依赖并创建 keyrings 目录
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings

# 2) 下载并转换 GPG Key（示例：华为云镜像）
curl -fsSL https://mirrors.huaweicloud.com/docker-ce/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# 3) 写入 APT 源（自动识别架构与版本代号）
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.huaweicloud.com/docker-ce/linux/debian $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

# 4) 安装 Docker Engine 并验证
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
docker -v
```
