# linux-toolbox

一组我自己常用的 Linux 一键脚本：Docker、SSH、终端代理。

这个目录里放了几个我自己常用的一键脚本，都是单文件，下载下来直接跑就行。

快速跳转：[Docker](README-docker.md)｜[SSH](README-ssh.md)｜[终端代理](README-proxy.md)

- Docker 安装与配置：[`docker-sh.sh`](docker-sh.sh)（文档：[`README-docker.md`](README-docker.md)）
- SSH 启用与密码登录：[`ssh-sh.sh`](ssh-sh.sh)（文档：[`README-ssh.md`](README-ssh.md)）
- 终端代理开关：[`proxy-sh.sh`](proxy-sh.sh)（文档：[`README-proxy.md`](README-proxy.md)）

---

## 最常用的几条命令

### Docker

```sh
sudo sh docker-sh.sh wizard
sudo sh docker-sh.sh test all
```

如果在 Proxmox/PVE（或带 enterprise 源的 Debian）里 `apt-get update` 被 `enterprise.proxmox.com` 卡住：

```sh
sudo sh docker-sh.sh install --fix-apt
```

想把它装成命令（可选）：

```sh
sudo sh docker-sh.sh self-install
docker-sh wizard
sudo docker-sh self-uninstall
```

### SSH

```sh
sudo sh ssh-sh.sh enable
sudo sh ssh-sh.sh password enable
sudo sh ssh-sh.sh status
```

### 终端代理

```bash
bash proxy-sh.sh
source ~/.zshrc   # 或 source ~/.bashrc
proxy_on
proxy_status
```

---

## 详细文档

- Docker：[`README-docker.md`](README-docker.md)
- SSH：[`README-ssh.md`](README-ssh.md)
- 终端代理：[`README-proxy.md`](README-proxy.md)
