# 平台限制与 README 精简设计

## 目标

- 移除 `ocserv-deploy.sh` 对 Linux 发行版、Ubuntu 版本和 CPU 架构的硬编码限制。
- 保持同一套部署流程兼容已验证的 Ubuntu `amd64` 与 `arm64`。
- 让其他使用 apt、systemd、nftables 和发行版 ocserv 包的平台可以直接尝试安装，由实际依赖和配置检查决定结果。
- 将 README 重写为简短的顺序式部署指南。

## 平台行为

删除：

- `/etc/os-release` 的 `ID`、`VERSION_ID` 检查。
- Ubuntu `22.04|24.04` 白名单。
- `dpkg --print-architecture` 的 `amd64|arm64` 白名单。
- 相关平台拒绝错误和测试 fixture。

安装流程不再根据平台名称或版本提前拒绝。它只确认安装阶段需要的命令存在，并调用：

```bash
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ocserv nftables openssl iproute2 util-linux
```

包不存在、包管理器不兼容、systemd 不可用或 ocserv 配置指令不兼容时，保留底层命令的明确失败，不添加成功形状的回退。

README 只声明该项目在 Ubuntu `amd64` 和 `arm64` 上完成测试。其他 apt/systemd 平台可能兼容，但不承诺已验证。

## README 结构

README 删除现有长篇原理说明，保留以下结构：

1. 项目用途与文件列表。
2. 准备共享配置文件。
3. **DDNS（可选）**
   - 仅在公网 IP 会变化且需要域名自动跟随时使用。
   - 给出必要 Cloudflare 字段、安装和启用 timer 的命令。
4. **Let's Encrypt 证书（可选）**
   - 使用 `selfsigned` 模式时可跳过。
   - 给出 ACME Token 文件、证书字段、签发与续签 timer 命令。
5. **OpenConnect / ocserv 部署**
   - 给出五个 ocserv 配置项、安装、添加/删除用户、Azure TCP/UDP 端口提醒。
   - 简述 `letsencrypt` 与 `selfsigned` 的选择。
6. **SoftEther 部署**
   - 只保留“待实现”的占位说明。
7. 最短状态检查与安全提醒。

README 明确说明前两步相互独立且均为可选步骤：

- 不需要 DDNS 时可跳过第 1 步。
- 使用自签名证书时可跳过第 2 步。
- 若两步都跳过，可使用裸 IP 或固定域名配合 `selfsigned` 直接部署 ocserv。

详细架构、事务、hook、nftables 和回滚设计继续保留在 `docs/superpowers/specs/` 与 `docs/superpowers/plans/`，不在 README 重复。

## 测试

- 删除“接受 Ubuntu 22.04/24.04”和“拒绝其他 Ubuntu 版本/发行版/架构”的测试。
- 删除只为平台判断存在的 os-release 与 dpkg 架构 mock。
- 新增测试确认依赖安装不读取 OS、版本或架构信息，并仍以正确参数调用 apt。
- 保留全部配置、证书、网络、事务、用户和 real-tools 测试。
- 运行 Bash 语法检查、完整 mock 测试、real-tools staged validation 和 `git diff --check`。

## 非目标

- 不为非 apt 包管理器增加适配层。
- 不承诺所有 Debian 衍生发行版均兼容。
- 不改变 DDNS、证书、ocserv、nftables、systemd 或用户管理行为。
- 不实现 SoftEther 安装脚本。
