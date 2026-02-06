# sysinfo-sh.sh（Linux 配置/驱动信息报告）

`sysinfo-sh.sh` 用来一键输出当前机器的 **系统概览、硬件列表、驱动绑定、内核模块、网络/存储/图形** 等信息，适合：

- 新装系统后核对硬件识别是否正常
- 排查“网卡/显卡/声卡驱动不工作”“固件缺失”等问题
- 把信息整理成一份可分享的报告（发工单/发群里）

脚本默认 **只读**，不修改系统。

---

## 快速开始

### 1. 下载安装

> **国内用户推荐使用 Gitee 镜像仓库，下载速度更快。**  
> 安全建议：不推荐 `curl ... | sh` 这种“边下边跑”的方式；请先下载到本地，再执行。

#### Gitee 镜像（推荐国内用户）

```bash
curl -fsSL https://gitee.com/zhiyingzhou/linux-toolbox/raw/main/sysinfo-sh.sh -o sysinfo-sh.sh
sh sysinfo-sh.sh --help
```

或本地克隆后运行：

```bash
git clone https://gitee.com/zhiyingzhou/linux-toolbox.git
cd linux-toolbox
sh sysinfo-sh.sh --help
```

#### GitHub 源仓库

```bash
curl -fsSL https://raw.githubusercontent.com/zhiyingzzhou/linux-toolbox/main/sysinfo-sh.sh -o sysinfo-sh.sh
sh sysinfo-sh.sh --help
```

或本地克隆后运行：

```bash
git clone https://github.com/zhiyingzzhou/linux-toolbox.git
cd linux-toolbox
sh sysinfo-sh.sh --help
```

### 2. 基本使用

> 说明：脚本仅支持 Linux；在 macOS/Windows 上运行会直接提示不支持。

直接运行（默认更“给人看的”摘要，会先给出“一眼结论/驱动绑定/可能问题”）：

```sh
sh sysinfo-sh.sh
```

建议（更完整，推荐，会追加“原始详细信息”用于排障）：

```sh
sudo sh sysinfo-sh.sh --full
```

更适合分享（Markdown）：

```sh
sudo sh sysinfo-sh.sh --full --md > sysinfo.md
```

只要概览（更快）：

```sh
sh sysinfo-sh.sh --quick
```

颜色说明（仅 text 输出）：

- 终端直接运行会自动启用颜色（更易读）
- 重定向到文件时会自动关闭颜色
- 也可用 `--no-color` 或 `NO_COLOR=1` 强制禁用

---

## 隐私/脱敏

默认会对 **MAC 地址/序列号/UUID** 等做基础脱敏（避免你把报告贴到公开场合时泄露敏感信息）。

如果你确认报告只在可信环境内流转，可以关闭脱敏：

```sh
sudo sh sysinfo-sh.sh --full --no-redact
```

---

## 可选依赖（推荐安装，信息会更完整）

脚本会自动检测缺失命令并在报告末尾提示。常见命令与包名映射：

- `lspci` → `pciutils`
- `lsusb` → `usbutils`
- `dmidecode` → `dmidecode`
- `lshw` → `lshw`
- `ethtool` → `ethtool`
- `glxinfo` → `mesa-utils`（或 `mesa-demos`）
- `vulkaninfo` → `vulkan-tools`
- `smartctl` → `smartmontools`
