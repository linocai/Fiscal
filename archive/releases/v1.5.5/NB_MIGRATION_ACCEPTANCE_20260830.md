# Fiscal 杭州→宁波生产迁移验收记录

日期：2026-08-30（Asia/Shanghai）

应用版本：v1.5.5（32，未改版号或 Build）

范围：只迁移 Fiscal；杭州及宁波的其他项目均不在本次操作范围内。

## 最终状态

- 生产主机：宁波 `114.66.2.205`。
- 公网域名：`fiscal.linotsai.top` 的启用 A 记录为 `114.66.2.205`，TTL 10 分钟。
- 应用 revision：`3eb49cbc4151aa06b0dacecc7025ad2ed7d85f42`，release 目录 `/opt/fiscal/releases/3eb49cbc4151`。
- 数据库：PostgreSQL 16，Alembic `20260823_0036`；只监听 loopback。
- 运行单元：`fiscal-api.service` 与 backup、restore-verify、health-check、disk-check 四个 timer 均 active + enabled。
- 网络边界：NPM 是公网 80/443 唯一入口；Fiscal API 的 `8010` 只允许 NPM Docker bridge 访问。

## 数据迁移与一致性

杭州于 `2026-08-30T11:13:32Z` 停止 Fiscal API，形成唯一写入冻结点。最终材料为：

- `/var/lib/fiscal/backups/fiscal-20260830T111344Z.dump`
- `/var/lib/fiscal/backups/fiscal-cutover-hz-20260830T111332Z.tar.gz`

材料经校验后传入宁波 `/var/lib/fiscal/backups/hz-cutover-20260830T111332Z/`。最终恢复结果：

- Alembic head：`20260823_0036`
- transactions：225
- postings：247
- orphan postings：0
- 非 migrator 所有的 public tables：0
- transaction fingerprint：`7f356e0e5e11587d3bbdb6f538245ba6`
- posting fingerprint：`86074c6e8d507a4832fde0da21d441d0`
- balance fingerprint：`bdccfeef802e8dd56fe9c0a5461d9b87`

上述计数与去隐私化指纹在停写后的杭州源库和宁波恢复库完全一致。宁波恢复后备份
`/var/lib/fiscal/backups/fiscal-20260830T112126Z.dump` 与最终当前态备份
`/var/lib/fiscal/backups/fiscal-20260830T115115Z.dump` 均通过 archive 校验；后者 SHA-256 为
`3015f0312f214433c1be4566e13a51faeb9aa10712ec913f9e1a495d355e0630`。restore verify 通过。

## NPM、TLS 与 DNS

- NPM `2.15.1` 通过官方管理面配置 `fiscal.linotsai.top → http://172.18.0.1:8010`。
- Block Common Exploits、Force SSL、HTTP/2、HSTS 已启用；公网 `/api/v1/health/ready` 被入口层拒绝为 403，宁波本机 readiness 为 200。
- 迁移证书 SHA-256 fingerprint：`81:45:DD:B1:43:1C:4D:CE:D5:B2:1B:0D:1C:59:17:21:79:8D:EC:03:48:25:1D:9C:8A:3D:DE:AF:69:32:35:23`，有效期至 2026-10-14，证书与私钥匹配校验通过。
- NPM 当前态备份：`/opt/npm/backups/npm-after-fiscal-tls-20260830T113343Z.tar.gz`，SHA-256 `f2f88ccd1e1c14f28ece710cdbdd758fcbfea57926d8ba4a58806e5a10e157ee`。
- 阿里云控制台确认唯一 `fiscal` A 记录启用并指向 `114.66.2.205`；AliDNS DoH、Cloudflare DoH 与杭州外部主机均解析到宁波。
- 公网验收：liveness 200、readiness 403、未鉴权受保护接口 401、证书严格验证通过。

## 真实客户端验收

- macOS `/Applications/Fiscal.app` v1.5.5（32）通过现有生产域名成功加载宁波数据，账户与当月流水均可见，无离线或连接错误。
- iPhone 上的 Fiscal v1.5.5（32）启动后，宁波日志确认 `/auth/status`、`/system/status`、核对待处理、月报与事实接口均为已鉴权 200。
- 现有设备密钥与 AI provider 配置在迁移后继续可用；验收记录不保存密钥、上游凭证、真实余额或流水原文。

## 杭州冷归档与清理

杭州共发现 50 个 `fiscal*` 数据库：1 个生产库和 49 个历史影子演练库。全部数据库先以 custom format 导出、逐个通过 `pg_restore --list` 与 SHA-256 校验，再连同 Fiscal 代码、配置、systemd units、Nginx 配置和证书材料形成冷归档：

- 宁波归档：`/var/lib/fiscal/backups/hz-retired-archive/fiscal-hz-retirement-20260830T115250Z.tar.gz`
- 大小：464,855,406 bytes
- SHA-256：`d54b9d05a948874f76bbe1330686e5a02cbb465b665fc20fe5334e0930bfc086`
- 权限：`0600 root:root`

两端 SHA-256 完全一致且归档目录可列出后，杭州完成 Fiscal-only 清理。最终缺失证明：

- Fiscal systemd unit 引用：0
- `fiscal*` 数据库：0
- Fiscal OS user/group：不存在
- Fiscal 活动路径：0
- `8010` 监听：关闭

杭州共享 Nginx 与 PostgreSQL 保持 active，Nginx 配置检查通过；LinoFinance 进程与其他项目未纳入本次修改。

## 回滚边界

- 不允许仅把 DNS 指回杭州：杭州 Fiscal 运行组件和数据库已清理，而且宁波切流后可能产生新写入。
- 若宁波应用故障但数据库健康，优先在宁波使用同 Alembic head 的 release 回滚，不回退数据库结构。
- 若必须跨主机恢复，先停止宁波 API 形成新的唯一停写点，再对宁波当前库制作并校验最终 dump；以该 dump 恢复目标主机后完成 head、计数、孤儿分录、readiness、TLS 和客户端验收，最后才允许切 DNS。
- 杭州历史状态只存在于宁波冷归档；任何恢复必须复制归档后操作，不能原地修改唯一归档件。
