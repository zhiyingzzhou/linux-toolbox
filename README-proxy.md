# proxy-sh.sh（终端代理开关）

给当前终端装一组代理开关函数：本质就是设置/清理 `http_proxy/https_proxy/all_proxy` 等环境变量。  
脚本会自动识别 Bash / Zsh / Oh-My-Zsh / Bash-it，并把插件放到对应目录里，然后把加载语句写进 `~/.bashrc` 或 `~/.zshrc`。

## 快速开始

### 1. 下载安装

> **国内用户推荐使用 Gitee 镜像仓库，下载速度更快。**  
> **注意：**  
> **不要**使用 `curl ... | bash` 方式直接运行本脚本，否则交互输入会失效。  
> 请先下载脚本到本地，再执行。

#### Gitee 镜像（推荐国内用户）

```bash
curl -fsSL https://gitee.com/zhiyingzhou/linux-toolbox/raw/main/proxy-sh.sh -o proxy-sh.sh
bash proxy-sh.sh
```

或本地克隆后运行：

```bash
git clone https://gitee.com/zhiyingzhou/linux-toolbox.git
cd linux-toolbox
bash proxy-sh.sh
```

#### GitHub 源仓库

```bash
curl -fsSL https://raw.githubusercontent.com/zhiyingzzhou/linux-toolbox/main/proxy-sh.sh -o proxy-sh.sh
bash proxy-sh.sh
```

或本地克隆后运行：

```bash
git clone https://github.com/zhiyingzzhou/linux-toolbox.git
cd linux-toolbox
bash proxy-sh.sh
```

## 安装

交互式安装：

```bash
bash proxy-sh.sh
```

静默安装（适合自动化）：

```bash
bash proxy-sh.sh --silent --host 127.0.0.1 --port 7890 --protocol socks5
```

预览（不改任何文件）：

```bash
bash proxy-sh.sh --dry-run
```

安装后让它生效：

```bash
source ~/.zshrc
# 或：
source ~/.bashrc
```

## 命令

安装好之后，当前终端会多出这些命令：

- `proxy_on`：开启代理
- `proxy_off`：关闭代理
- `proxy_toggle`：开/关切换
- `proxy_status`：打印当前代理环境变量，并做一次连通性测试
- `proxy_config`：打印当前配置（host/port/protocol）
- `proxy_test [URL]`：测试访问指定 URL（默认 `https://www.google.com`）
- `proxy_edit`：交互式改配置（会尽量写回插件文件）
- `proxy_help`：帮助

支持协议：`http` / `socks5`。

## 卸载

```bash
bash proxy-sh.sh --uninstall
```

卸载预览：

```bash
bash proxy-sh.sh --uninstall --dry-run
```

## 参数

- `--host HOST`：代理地址
- `--port PORT`：代理端口
- `--protocol http|socks5`：代理协议
- `--install-dir DIR`：自定义插件安装目录
- `--silent`：静默安装（不问问题，直接用默认值或你给的参数）
- `--no-backup`：不备份 `~/.bashrc` / `~/.zshrc`
- `--dry-run`：预览模式
- `--uninstall`：卸载
- `--debug`：输出更多调试信息

## 默认安装位置

Bash：

- Bash-it：`$BASH_IT/plugins/available/proxy.plugin.bash`
- 标准 Bash：`~/.bash_plugins/proxy.plugin.bash`（并在 `~/.bashrc` 里加 `source ...`）

Zsh：

- Oh-My-Zsh：`${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/proxy/proxy.plugin.zsh`（并把 `proxy` 加进 `plugins=(...)`）
- 标准 Zsh：`~/.zsh_plugins/proxy.plugin.zsh`（并在 `~/.zshrc` 里加 `source ...`）

## 备注

- 交互式安装别用 `curl ... | bash`，否则读不到输入；想一行跑完就用 `--silent` 把参数写死。
- Oh-My-Zsh 环境下，如果你手动维护 `plugins=(...)`，确保里面有 `proxy`。
- 脚本运行失败会保留临时目录并提示日志文件路径；成功结束会自动清理临时文件。
