# ocserv 已有配置替换确认设计

## 目标

`ocserv-deploy.sh install` 不再判断已有 `/etc/ocserv/ocserv.conf` 是否由本工具或发行版管理。只要配置文件已经存在，就要求用户明确确认；确认后备份并使用新生成配置替换，拒绝则中止。

## 交互流程

`install` 获取安装锁、加载并校验 `/etc/vpn-maintenance.env` 后：

1. 若 `ocserv.conf` 不存在，直接继续。
2. 若存在，确认标准输入连接到交互终端。
3. 非交互 stdin、EOF 或读取失败时立即中止。
4. 显示已有配置路径和即将备份、替换的提示。
5. 仅输入 `y` 或 `Y` 表示确认；其他输入全部视为拒绝。
6. 拒绝时不创建备份、不安装包、不修改配置。
7. 确认后复制原配置到：

   ```text
   /etc/ocserv/ocserv.conf.pre-vpn-node-<UTC时间戳>.bak
   ```

8. 备份路径不得覆盖已有文件；同一秒冲突时生成带递增序号的新名称。
9. 备份成功后才继续端口、路由、依赖、证书和事务安装流程。

不在确认后立即裸删原配置。最终配置仍通过现有事务和同目录原子替换机制安装，以避免中途留下缺失配置。

## 事务与失败处理

- 开始事务时仍快照原配置。
- 用户确认后若任何后续步骤失败，事务恢复原配置和原服务状态。
- 用户确认前创建的时间戳备份永久保留，不随事务回滚删除。
- 备份创建失败时立即中止，原配置保持不变。
- 每次重复执行 `install`，即使配置包含本工具管理标记，也再次提示并备份。

## 其他受管文件

该行为只适用于 `/etc/ocserv/ocserv.conf`。

以下路径继续使用现有保护规则：存在但没有本工具管理标记时拒绝覆盖或删除：

- `/usr/local/libexec/vpn-node/ocserv-network`
- `/etc/systemd/system/ocserv.service.d/10-network.conf`
- `/etc/letsencrypt/renewal-hooks/deploy/20-ocserv`

密码库 `/etc/ocserv/ocpasswd` 继续保留并由用户管理命令维护。

## 测试

自动化测试覆盖：

- 配置不存在时不提示、不备份并继续。
- 受管配置和非受管配置都要求确认。
- 输入 `y` 与 `Y` 时创建内容、权限、时间属性一致的备份并继续。
- 输入 `n`、其他文本、EOF 时中止且不备份。
- 非 TTY stdin 时中止且不备份。
- 同名备份冲突时创建递增序号，不覆盖旧备份。
- 备份失败时中止并保留原配置。
- 用户确认后后续安装失败时原配置恢复，时间戳备份保留。
- 其他非受管 helper/drop-in/hook 仍被拒绝。

运行 Bash 语法检查、完整 mock 测试、real-tools staged validation 和 `git diff --check`。

## 文档

README 的 ocserv 安装步骤增加一句：

> 若 `/etc/ocserv/ocserv.conf` 已存在，安装器会要求输入 `y` 确认，先备份原配置，再用新配置替换；无交互终端时会中止。
