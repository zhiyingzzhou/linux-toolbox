# SSH 一键脚本（ssh-sh.sh）

`ssh-sh.sh` 用于在新装/重装系统后，快速把 SSH “能连上、能用”：

- 自动安装 `openssh-server`
- 自动启用并启动服务（兼容 `ssh` / `sshd`）
- 一键开启/关闭密码登录（可选开启 root 密码登录）
- 修改配置前后会做 `sshd -t` 校验，失败自动回滚，避免把自己锁在门外

> 安全提醒：开启密码登录会显著增加被爆破风险。强烈建议配合安全组/防火墙仅放行可信 IP，并尽量使用强密码或仅临时开启。

---

## 快速开始

### 1. 下载安装

> **国内用户推荐使用 Gitee 镜像仓库，下载速度更快。**  
> **注意：**  
> **不要**使用 `curl ... | bash` 方式直接运行本脚本，否则交互输入会失效。  
> 请先下载脚本到本地，再执行。

#### Gitee 镜像（推荐国内用户）

```bash
curl -fsSL https://gitee.com/zhiyingzhou/linux-toolbox/raw/main/ssh-sh.sh -o ssh-sh.sh
sudo sh ssh-sh.sh enable
```

或本地克隆后运行：

```bash
git clone https://gitee.com/zhiyingzhou/linux-toolbox.git
cd linux-toolbox
sudo sh ssh-sh.sh enable
```

#### GitHub 源仓库

```bash
curl -fsSL https://raw.githubusercontent.com/zhiyingzzhou/linux-toolbox/main/ssh-sh.sh -o ssh-sh.sh
sudo sh ssh-sh.sh enable
```

或本地克隆后运行：

```bash
git clone https://github.com/zhiyingzzhou/linux-toolbox.git
cd linux-toolbox
sudo sh ssh-sh.sh enable
```

### 2. 基本使用

一键开启 SSH 登录（安装 openssh-server + 启用并启动服务）：

```sh
sudo sh ssh-sh.sh enable
```

一键开启密码登录（`PasswordAuthentication yes`）：

```sh
sudo sh ssh-sh.sh password enable
```

如果你确认需要 root 也能用密码登录（风险更高）：

```sh
sudo sh ssh-sh.sh password enable --root yes
```

查看 SSH 服务与关键配置（`PasswordAuthentication` / `PermitRootLogin` / `Port`）：

```sh
sudo sh ssh-sh.sh status
```

校验 sshd 配置语法（`sshd -t`）：

```sh
sudo sh ssh-sh.sh test
```

---

## 常用命令

开启 SSH 服务（含自动安装）：

```sh
sudo sh ssh-sh.sh enable
```

开启/关闭密码登录：

```sh
sudo sh ssh-sh.sh password enable
sudo sh ssh-sh.sh password disable
```

开启/关闭 root 密码登录（仅在你明确需要时使用）：

```sh
sudo sh ssh-sh.sh password enable --root yes
sudo sh ssh-sh.sh password enable --root no
```

交互式向导（按提示一步步做）：

```sh
sudo sh ssh-sh.sh wizard
```

清理脚本托管的配置块（恢复为“只移除 ssh-sh 托管段”的状态）：

```sh
sudo sh ssh-sh.sh config clear
```

---

## 常见问题

### 1) 报错：`ssh-sh: 1: sh-sh: not found`

这通常是脚本文件开头被“多插入了一行”（上传/复制粘贴时误带），确保第 1 行是 `#!/bin/sh` 即可：

```sh
nl -ba ssh-sh.sh | sed -n '1,5p'
```

如果第 1 行是 `sh-sh`，删掉它：

```sh
sed -i '1{/^sh-sh$/d;}' ssh-sh.sh
```

顺手去掉 Windows 换行（可选）：

```sh
sed -i 's/\r$//' ssh-sh.sh
```

### 2) 开启密码登录后仍无法用密码登录

请先确认服务与配置生效情况：

```sh
sudo sh ssh-sh.sh status
sudo sh ssh-sh.sh test
```

如果你改动过 `sshd_config`，优先以 `ssh-sh` 的输出为准（脚本会把托管配置块插到“第一条有效指令之前”，从而确保生效）。
