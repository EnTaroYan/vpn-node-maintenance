# ocserv 启动就绪与回滚网络清理设计

## 根因

Ubuntu 的 `ocserv.service` 使用 `Type=simple`。`systemctl restart` 在进程启动后立即返回，不等待 ocserv 完成 TCP/UDP socket bind。

当前安装器紧接着执行一次 `ss` 检查，因此会在 ocserv 尚未监听时误报：

```text
ERROR: no TCP listener on port ...
rolling back transaction
```

日志随后仍可能出现 ocserv 已开始监听，因为进程在回滚停止前完成了 bind。

回滚先恢复并删除 systemd drop-in，再停止服务，导致原 drop-in 的 `ExecStopPost=ocserv-network down` 不再执行，可能留下 `vpn_node_ocserv` nftables 表。

## 启动就绪检查

用 `wait_for_service_ready` 替换单次 `verify_service` 检查：

- 最长等待 15 秒。
- 每 200ms 检查一次。
- 必须同时满足：
  - `systemctl is-active --quiet ocserv.service`
  - 配置端口存在 TCP listener
  - 配置端口存在 UDP listener
- 三项全部成立后立即成功，不等待剩余时间。
- 启动过程短暂 inactive/failed 或单边 listener 缺失时继续轮询到超时。
- 不使用固定 sleep 作为最终判定。

超时后：

- 输出明确错误，指出 TCP/UDP 当前状态。
- 输出 `systemctl status ocserv.service --no-pager -l`。
- 输出最近的 ocserv journal。
- 返回失败并进入现有事务回滚。

诊断命令失败不得掩盖原始超时错误。

## 回滚网络清理

回滚在恢复受管文件之前清理本次启动创建的网络表：

1. 若当前 `/usr/local/libexec/vpn-node/ocserv-network` 存在、可执行且含管理标记，调用 `down`。
2. helper 不存在或调用失败时，检查 `ip vpn_node_ocserv` 表。
3. 只有表内存在 `_managed_by_vpn_node_maintenance` 哨兵 chain 时才删除该表。
4. 同名但没有哨兵 chain 的表视为外部资源，绝不删除。
5. 网络清理失败写入回滚日志，但继续恢复配置和服务状态。

回滚完成后，若安装前服务不活跃，则不得残留本工具的 nftables 表。

## 测试

自动化测试覆盖：

- listener 首次为空、随后 TCP/UDP 出现时轮询成功。
- readiness 满足后提前返回，不等待完整 15 秒。
- TCP 一直缺失时超时失败。
- UDP 一直缺失时超时失败。
- service 一直不 active 时超时失败。
- 超时执行 status/journal 诊断。
- 延迟 listener 场景证明旧单次检查会失败。
- 回滚使用受管 helper `down`。
- helper 缺失或失败时删除带哨兵的表。
- 未带哨兵的同名表不删除。
- 网络清理失败不阻止文件和服务状态恢复。

轮询间隔和次数通过只读变量或函数 seam 在测试中缩短，不提供生产命令行或环境绕过。

运行 Bash 语法检查、完整 mock 测试、real-tools staged validation 和 `git diff --check`。不运行真实安装，不启动服务，不修改现有配置。

## 非目标

- 不更改 ocserv 配置内容、端口、证书或用户逻辑。
- 不改变 systemd unit 类型。
- 不自动修改 Azure NSG。
- 不增加常驻监控服务。
