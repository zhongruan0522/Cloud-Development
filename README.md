# Cloud-Development

基于Docker环境构建的一个隔离开发虚拟环境

## 本项目的缘由

我需要一个可以快速拉起、撤销环境修改的容器，且具备隔离的Agent开发，以便我可以直接开完全访问模式

## 镜像变体

| Tag | 说明 |
|---|---|
| `vxxxxxxxx`（无后缀） | slim 版（NoDesktop-Base）：不含远程桌面，体积更小，`FROM :base` |
| `vxxxxxxxx-desktop` | 完整版（Desktop-Base，默认）：XFCE4/xrdp 远程桌面（端口 3390），`FROM :desktop` |

> 关于开发思路：
> 
> 由于Agent是更新比较频繁的，但是开发依赖却是更新频率较低的。
> 
> 所以本项目拆分成两层docker，一层为base，用于存放更新频率低的开发依赖、基础环境，一层为动态层，用于存放更新较为频繁的agent等用途
> 
> 如果你需要定制一个适用你的，可以直接从base入手，将开发依赖进行适配即可，动态层已经覆盖安装了主流的开发Agent（例如CC、OpenCode）

## 内置数据库

镜像内置五个本地开发数据库，统一密码取 `DB_PASSWORD`（仅首启初始化生效；openGauss 要求 >=8 位且大小写/数字/特殊字符至少三类，DM8 要求 8-48 位且含大小写+数字，弱密码会使二者首启初始化直接失败）。`docker-compose.yml` 部署时五库默认全部开启（`ENABLE_*` 缺省 1）；直接 `docker run` 不传环境变量时默认全关，按需设 `ENABLE_PG` / `ENABLE_MYSQL` / `ENABLE_OPENGAUSS` / `ENABLE_KINGBASE` / `ENABLE_DM` = 1。

| 数据库 | 容器内端口 | TCP 账户 | 容器内客户端（socket 免密） |
|---|---|---|---|
| PostgreSQL 17 | 5432 | postgres + DB_PASSWORD | `psql -U postgres` |
| MySQL 8.4 | 3306 | root + DB_PASSWORD | `mysql -u root` |
| openGauss 7.0.0 | 5433 | omm + DB_PASSWORD | `gsql -p 5433 -d postgres` |
| KingbaseES V9R2C16 | 54321 | system + DB_PASSWORD（oracle 兼容模式） | `ksql -p 54321 -U system` |
| DM8 | 5236 | SYSDBA / SYSAUDITOR + DB_PASSWORD | `disql SYSDBA/密码@localhost:5236` |

对外暴露由 compose `ports` 控制（默认注释不发布=仅容器内可达），详见 docker-compose.yml 注释；首启各库后台并行初始化，全部就绪最慢两分钟级。

### openGauss 兼容模式（DBCOMPATIBILITY）

openGauss 支持五种数据库兼容模式，建库时通过 `DBCOMPATIBILITY` 指定，**建库后不可修改**（`ALTER DATABASE` 不支持该子句）：

| 取值 | 兼容 | 说明 |
|---|---|---|
| `A` | Oracle | **默认**。本镜像 `gs_initdb --dbcompatibility=A` 初始化，postgres / template0 / template1 均为 A 模式（默认 postgres 库并不是 PG 模式）。空字符串按 NULL 处理，`DATE` 实为 `TIMESTAMP(0)` |
| `B` | MySQL | 建库时自动装入 dolphin 插件，反引号标识符、双引号字符串字面量等 MySQL 语法生效 |
| `C` | Teradata | TD 语法兼容 |
| `PG` | PostgreSQL | `CHAR`/`VARCHAR` 按字符计数（A/C/D 按字节），空串不转 NULL |
| `D` | Sybase | 7.0 新增（S 语法兼容） |

需要 PG 行为时显式建库：

```sql
CREATE DATABASE mydb DBCOMPATIBILITY 'PG';
```

客户端 DSN 连接注意事项（openGauss 7.0.0 实测）：

- 兼容模式是库级属性，DSN/连接串无法表达，建连握手也不返回（`server_version` 不含模式信息）。连上后识别：`SHOW sql_compatibility`（返回 A/B/C/PG/D）或 `SELECT datname, datcompatibility FROM pg_database;`
- 社区 openGauss 无 `db_compatibility` GUC（`SHOW db_compatibility` 报 unrecognized parameter），该写法属于华为云 GaussDB。
- 标准 PG 驱动（psql / libpq / 社区版 psycopg2）TCP 直连会被 openGauss 的 sha256 认证拒绝：`none of the server's SASL authentication mechanisms are supported`。远端连接需 openGauss 官方 JDBC / psycopg2 分支驱动，或经容器内 gsql（socket 免密）中转；这点与 PG/KingbaseES（scram-sha-256，社区驱动可连）不同。
