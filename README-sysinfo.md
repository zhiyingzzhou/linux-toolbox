# sysinfo-sh.sh（Linux 配置/驱动信息报告）

`sysinfo-sh.sh` 用来一键输出当前机器的 **系统概览、硬件列表、驱动绑定、内核模块、网络/存储/图形** 等信息，适合：

- 新装系统后核对硬件识别是否正常
- 排查“网卡/显卡/声卡驱动不工作”“固件缺失”等问题
- 把信息整理成一份可分享的报告（发工单/发群里）

脚本默认 **只读**，不修改系统。

---

## 快速开始

直接在当前目录运行：

```sh
sh sysinfo-sh.sh
```

建议（更完整）：

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

