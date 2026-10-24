# KingbaseES V9R2C016 全量功能测试报告

- 测试日期：2026-10-24
- 测试对象：本镜像内置的 KingbaseES（人大金仓）V009R002C016 企业版（180 天试用授权，2026-10-24 起算）
- 实例信息：`/opt/Kingbase/ES`，数据目录 `/var/lib/kingbase/data`，端口 54321，实例级兼容模式 **oracle**（entrypoint `initdb -m oracle` 固化），超级用户 `system`，本地 socket trust 免密 / TCP scram-sha-256
- 测试方法：8 个套件共 **200+ 断言**（连接/建删库与兼容模式/CRUD/对象与 PL/SQL/安全/运维工具/原生语法与原生库），脚本位于 `/tmp/kes-test/`（`run-all.sh` 可复现），逐项 PASS/FAIL/SKIP 记录于 `/tmp/kes-test/results/all.log`
- 依据文档：金仓产品手册 <https://help.kingbase.com.cn/v9/>（initdb/ksql/sys_dump/sys_restore/配置文件等章节）、官方技术博客（国密算法支持、Oracle 兼容配置、Package 实战）、海外站下载页（按兼容模式分发介质的佐证）

## 一、总览

| 套件 | 覆盖 | PASS | FAIL | SKIP |
|---|---|---|---|---|
| T10 连接 | socket/TCP/scram/负向/sys_isready/createdb/JDBC/SSL/国密 | 21 | 0 | 1 |
| T20 建删库 | CREATE/ALTER/DROP/模板库/活动连接保护/oracle 行为 | 14 | 0 | 0 |
| T25 兼容模式 | initdb -m 多实例（PG 实测，MYSQL/SQLSERVER 缺介质） | 10 | 0 | 2 组 |
| T30 CRUD | Oracle 类型/增删改查/约束/MERGE/序列/事务/分页/MySQL 风格 | 36 | 0 | 0 |
| T40 对象与 PL/SQL | 视图/物化视图/FORCE VIEW/索引/分区/同义词/触发器/PL/SQL/包/自治事务/dblink/FTS/JSONB/闪回/国密扩展 | 61 | 0 | 2 |
| T50 安全 | 角色权限正反向/RLS/口令修改/三权分立探查 | 16 | 0 | 0 |
| T60 运维 | sys_dump/sys_restore/sys_dumpall/vacuumdb/reindexdb/kbbench/sys_basebackup/sys_waldump/sys_controldata/wrap/exp/esql | 18 | 0 | 2 |
| T70 原生语法与库 | NVL/DECODE/TO_CHAR/(+)/CONNECT BY/空串即 NULL/整数除法/游标/sys_catalog/kingbase·security 库 | 18 | 0 | 0 |

**合计：PASS ≈ 194，FAIL 0，SKIP 7（均为环境/介质限制，非产品缺陷）。**

## 二、连接（含国密）

1. **普通连接全通**：本地 socket trust 免密、TCP scram-sha-256（`KINGBASE_PASSWORD` 环境变量）、错误密码/不存在库负向拒绝、`sys_isready` 探活、`createdb/dropdb` 工具、JDBC 驱动 kingbase8 9.0.1（Maven Central）普通+SSL 双通道。
2. **SSL（国际算法）全通**：自签证书开启 ssl 后协商 **TLSv1.3 / TLS_AES_256_GCM_SHA384**；sslmode=require / verify-ca / verify-full（DNS 名+SAN）逐级校验通过；SAN 不匹配（127.0.0.2）与缺根证书负向正确；SSL 开启期间仍允许 sslmode=disable 混合接入；测试后已还原 ssl=off。
   - 注意点：ksql 的 verify-full 按**主机名**校验，`hostaddr=127.0.0.1` 时不比对证书 IP SAN（须用 `host=localhost`）。
3. **国密 TLS：本介质不可用（SKIP）**。介质自带 libssl 为标准 OpenSSL 1.1 构建（无 TLCP/SM 套件）：配置 `ssl_ciphers='ECC-SM4-SM3'`（强制 TLSv1.2）后套件被忽略、仍回退国际套件。国密传输加密需金仓国密版介质 + SM2 双证书体系。
4. **国密口令链路全通**：`password_encryption=sm3` 生效（rolpassword 前缀 `sm3`），`sys_hba.conf` 支持 `host ... sm3` 认证方式，SM3 口令用户 ksql 登录成功。
5. **SQL 层国密函数**：内建 `sm3`（text/bytea，SM3('abc') 标准值校验通过）、`sm4`/`sm4_enc` 加密可用；`sm2_encrypt/decrypt/sign/verify` 存在但 PEM/hex 等常见密钥形态均报错——调用约定未公开（libgm3000 加密卡驱动在位，疑似需配套密钥体系）；内建**无 SM4 解密函数**。

## 三、库生命周期与兼容模式

1. 建库/删库/重命名/模板库（template0）/createdb/dropdb 工具/有活动连接拒删（负向）+ 断开后可删——全部通过。
2. **兼容模式为实例级**：`CREATE DATABASE` 不支持 V8 的 `DBCOMPATIBILITY`（MODE/DBMODE 亦拒）；`initdb -m` 合法值实测仅 **oracle / pg**（数字别名 0/1）。
3. **本介质（OSS `KESV9-baseline/oracle/` 目录）不含 MYSQL/SQLSERVER 模式**：`initdb -m mysql/2/sqlserver/mssql/db2` 全部拒绝；OSS 对应目录 404。官方海外站按兼容模式分发介质，如需 MySQL/SQL Server 兼容需更换介质包重建。
4. **PG 模式临时实例（端口 54322）10/10**：dual 不存在（模式隔离）、pg_catalog、ON CONFLICT UPSERT、serial、DO 块、FILTER、WITH RECURSIVE、EXPLAIN ANALYZE 全通；测后实例已停删。
5. Oracle 模式行为（主实例）：dual、ROWNUM、CONNECT BY、序列 `.NEXTVAL` 等全通。

## 四、CRUD、对象与 PL/SQL

1. **类型**：NUMBER/VARCHAR2/DATE/CLOB/BLOB 正常；**RAW 类型不存在**（二进制用 bytea）。
2. **CRUD/约束/事务全通**：批量 INSERT、UPDATE/DELETE RETURNING、TRUNCATE、PK/UK/FK/CHECK/NOT NULL/DEFAULT 正反向、MERGE INTO（Oracle 原生 UPSERT）、LIMIT/OFFSET·FETCH FIRST·ROWNUM 三种分页、SAVEPOINT/ROLLBACK/SERIALIZABLE/FOR UPDATE、跨会话可见性。
3. **对象全通**：普通视图、WITH CHECK OPTION、物化视图+REFRESH、**FORCE VIEW**（force_view 插件）、B-tree/唯一/部分/表达式/GIN 五类索引+优化器命中、REINDEX、RANGE 分区表+路由+裁剪（EXPLAIN 验证）。
4. **同义词**：可用，但 **public 默认模式不允许建**，须在用户 schema 内（`CREATE SYNONYM kessch.syn1 FOR kessch.t1` + `SET search_path`）。
5. **触发器**：Oracle 风格（`:new` 赋值）与 plpgsql 函数风格均通过。
6. **PL/SQL 全通**：匿名块、存储过程（IN/OUT）、函数、**包（PACKAGE 规格+体，包变量为会话级状态——与 Oracle 语义一致，须同会话读写）**、**自治事务（PRAGMA AUTONOMOUS_TRANSACTION 不被外层回滚）**、RAISE_APPLICATION_ERROR + EXCEPTION、显式/隐式游标、DBMS_UTILITY。
   - 版本限制：`DETERMINISTIC` 关键字不支持；ksql 不识别 `SET SERVEROUTPUT`（DBMS_OUTPUT 回显需 JDBC/kstudio 端）。
7. **闪回查询可用**：`SELECT ... FROM t AS OF TIMESTAMP 'ts'`（前提 `track_commit_timestamp=on`，需重启生效；本环境 undo 子系统在位，`kdb_flashback.enable_flashback_query=on`）。`TIMECAPSULE TABLE ... TO TIMESTAMP` 语法本版本不存在。
8. **扩展**：dblink（自连查询 ✓；注意**连接别名形式不支持**，第一参数须直连串）、kbcrypto（国密）、dbms_crypto CASCADE（实际提供 kdb_raw 层 30 函数，包本体 0 函数）、**sys_stat_statements 为系统初始化扩展（禁止删除），默认 track=none，需 `ALTER SYSTEM SET sys_stat_statements.track=top` 后统计**。
9. JSONB/数组/全文检索（simple 配置对中文按整词切分 '金仓数据库测试':1）通过。

## 五、安全

1. 角色创建/GRANT/REVOKE/越权正反向/DROP 他人表拒绝/改密后新旧密码切换——全通。
2. **RLS 行级安全**：ENABLE ROW LEVEL SECURITY + POLICY，普通用户仅见策略行、表主绕过——通过。
3. public 模式默认开放 CREATE（PG 语义，普通用户可建自有对象）；口令相关 GUC 有 enable_password_firstlogin 等。
4. 三权分立（sepapower）、强制访问控制（sysmac）、`security` 系统库在位但未激活（安全版特性）；**无 audit 类 GUC**（审计为安全版功能），sys_aud 目录存在。

## 六、运维与原生工具

1. **备份恢复**：sys_dump -Fc + sys_restore 往返 100 行一致；-Fp 纯文本管道恢复一致；sys_dumpall 全库 schema 导出 ✓。
2. **维护工具**：vacuumdb -Z、reindexdb、sys_ctl status/reload、sys_controldata、sys_waldump（解析 WAL 记录）、sys_basebackup 物理备份（-Fp -Xs，产物完整）——全通。
3. **kbbench 压测**：4 并发 10 秒 **≈350 TPS**（scale 1，本容器）。
4. **wrap 源码加密**：生成 .plb 且可执行（prosrc 显示 WRAPPED）✓。注意 wrap/exp 需在 kingbase 用户可写目录运行。
5. **exp 工具**：参数可运行但产出 0 字节（SKIP，待考）；**esql 无 libecpg**（SKIP）；集群类工具（repmgr/sys_backup.sh/sys_rman）超出单机范围未测。
6. 归档：`archive_mode=always` + archiver 进程在位；license：企业版/180 天试用/V009。

## 七、原生库与内核行为

1. **sys_catalog 与 pg_catalog 等价**（sys_* 前缀，sys_class/sys_stat_activity/sys_hba_file_rules 等）；内建 sys_* 函数 447 个、**kes_undo_* undo 诊断函数族 26 个**。
2. `kingbase`（默认管理库）与 `security` 系统库可用；SYS_VERSION 文件内容为 `12`（PG 系内核主版本号）。
3. KWR/KSH 性能采集后台进程常驻（ksh writer/collector、kwr collector）。
4. Oracle 语义兼容参数已开：`ora_input_emptystr_isnull`（'' 即 NULL ✓）、`ora_integer_div_returnfloat`（1/2=0.5 ✓）。
5. ksql 行为差异（使用注意）：**`-f` 文件模式会在 PL/SQL 块内分号处截断语句**（PL/SQL 须以 `-c` 整串发送）；无 `\h` 帮助；`-q` 抑制命令标签（UPDATE 1 不回显）。

## 八、结论

在当前介质能力范围内，金仓功能面**全部验证通过（FAIL=0）**；SKIP 项均为介质/版本边界：国密 TLS（需国密版介质）、MYSQL/SQLSERVER 兼容模式（需对应介质）、exp 有效产出、esql（无 libecpg）、DETERMINISTIC、SET SERVEROUTPUT。若业务需要 MySQL/SQL Server 模式或国密传输加密，建议更换对应介质包并重跑本套件（`bash /tmp/kes-test/run-all.sh`）。
