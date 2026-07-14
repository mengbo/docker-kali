# AGENTS.md

本文件为 AI 编码助手（opencode、Claude Code、Cursor 等）提供项目背景与协作约定。人类用户请阅读 [README.md](./README.md)。

## 文档职责分工（AI 必读）

- **README.md = 用户操作手册**（见其章节顺序）。**AI 改业务逻辑/约定前先 `grep` README.md**，避免与用户文档不一致。
- **AGENTS.md = AI 协作约定**（本文件）：架构约束、红黑榜、`.env` 保护、验证清单、常见任务索引。**与 README 重复的内容不写这里**。
- **遇到不确定的领域**，先 `grep` README.md 与本文件交叉印证；两文件冲突时 README 优先（它是用户面对的），但 AGENTS.md 要立刻同步修订。

## 提交约定

- 提交信息中文，遵循 `type: 简短描述` 格式
- 常见 type：`feat` / `fix` / `docs` / `refactor` / `chore`
- 一次提交只做一件事
- **禁止**提交 `./data/` 下任何文件——`.gitignore` 已包含，AI 助手在 `git add` 前应再 `git status` 检查

## 项目概述

`docker-kali` 是基于 `kalilinux/kali-rolling` 官方镜像构建的 Kali Linux Docker 部署，预装 MCP-Kali-Server。它**不打包 Kali 系统本身**，只提供：

- `Dockerfile`：在官方镜像基础上 apt 装 msf + 11 个工具 + git clone MCP-Kali-Server 源码 + pip install 依赖 + COPY msf config
- `docker-compose.yml`：**两个 service**（`kali` + `postgres`）+ 双网络（`hermes-net` external + `kali-internal` private）+ named volume `postgres_data`
- `config/database.yml`：kali 镜像内 msf 数据库配置，指向 `postgres:5432`
- 两个 shell 脚本：`kali` / `kali.compose`，封装 `docker compose` 与构建/升级操作
- `./data`：通过卷挂载持久化容器内 `/root`（msf 配置 + shell history + 一切运行时数据）
- `postgres_data`：named volume，持久化 PG 数据目录

**不**提供 `dot.env.example` / `kali.setup` 等对标残骸——配置直接 hardcode 在 `docker-compose.yml` 中。

## 关键约束

### 作为 docker-hermes sidecar

- `kali` 容器加入 `hermes-net: external: true`，由 docker-hermes 创建
- `postgres` 容器**不**加入 `hermes-net`，只在私有网络 `kali-internal`
- hermes 侧用 `http://kali:5000` 访问 MCP-Kali-Server；看不到 `postgres`
- 5000 端口**默认不**映射宿主
- 用户想独立使用（如 Claude Desktop）需手动在 `docker-compose.yml` 取消 `# - "5000:5000"` 注释

### 双网络拓扑

- **`hermes-net`** (external)：从 docker-hermes 外部继承。`kali` 加入
- **`kali-internal`**：本项目私有网络（docker compose 自动管理）。`kali` 和 `postgres` 都加入
- **不要再加**第三个网络
- `hermes-net` 由 `kali.compose down` 维护：脚本走 `stop` + `rm -f`，**不**调用 `docker compose down`
- **不要**把 `postgres` 加到 `hermes-net`

### 共享网络生命周期

- 本项目 `./kali.compose down` 走 `docker compose stop` + `docker compose rm -f`，**不**调用 `docker compose down`，避免删除 `hermes-net` 影响 docker-hermes
- **不要**把 `down()` 改回 `docker compose down`
- 手动 `docker compose down` 会破坏 `hermes-net`：如需手工停容器，直接用 `./kali.compose down` 或分步 `docker compose stop` + `docker compose rm -f`

### 数据持久化（双容器版）

两个持久化位置，**完全独立**：

- **bind mount** `./data:/root`（在 `kali` 容器里）
  - `.msf4/`：msf 配置、workspaces、loot、history
  - `.bash_history`：shell 历史
  - `.local/`：`pip install --user` 装点
  - `.cache/`：工具缓存
- **named volume** `postgres_data:/var/lib/postgresql`（在 `postgres` 容器里）
  - **msf 数据库的实际存储**（workspaces、hosts、creds、loot 数据）
  - 用 named volume 而非 bind mount 的原因：Docker 自动管理 PG 用户/权限

**不要**：
- 把 `./data` 拆成多个挂载（如 `./data/msf4:/root/.msf4`）——分散违背简洁原则
- 把 `postgres_data` 改成 bind mount——Docker 自动管权限，避免宿主手工 `chown`
- 把 mcp-kali-server 源码也挂出去——源码固化在 `/opt/MCP-Kali-Server/`，升级靠 rebuild 镜像
- 改 `config/database.yml` 后忘了 COPY 进镜像——这是构建期决定，运行时修改不生效

### 源码固化（不挂载）

- MCP-Kali-Server 源码 `git clone` 到 `/opt/MCP-Kali-Server/`，是镜像的一部分
- msf `config/database.yml` 也是 `COPY config/...` 进镜像
- 升级方式：`./kali.compose update`（`docker compose build --pull --no-cache` + `docker compose up -d`）

### msf schema 初始化（手动 + 脚本）

- Dockerfile **不**管 msf schema 初始化——schema 是运行时数据，不是系统基础
- Dockerfile CMD 只负责 `exec python3 server.py`，干净简单
- 初始化由 `scripts/init-msf-db.sh` 负责，通过 `./kali.compose init-db` 触发
- 脚本逻辑：
  1. `pg_isready -h postgres -U msf -d msf` 等 PG（最多 30s）
  2. `msfconsole -q -x 'db_status; exit'` 触发 msf 框架自动建 schema（msf 6.x 没有 db_migrate，框架自动 ActiveRecord 迁移）
  3. `SELECT count(*) FROM information_schema.tables` 验证 == 73，否则 exit 1
- 触发时机（**全部手动**）：
  - 首次启动
  - `docker compose down --volumes` 重建 PG volume 后
  - 任何需要重新建表的情况
- 脚本放项目仓库（git 跟踪），通过 `docker-compose.yml` 的 read-only bind mount 注入容器 `/usr/local/bin/init-msf-db.sh`
- **不要**在 Dockerfile CMD 里自动跑 init-db——会污染"运行时 ≠ 构建期"原则
- **不要**写标记文件——手动触发逻辑更清晰
- **不要**用 `db_migrate` 命令——msf 6.x 框架**已删除**该命令
- **不要**在镜像里跑 `msfdb init`——会冲突（msfdb 检测非 root + tty + args 各种边界）
- **不要**删除 `config/database.yml`——移除它 msfconsole 找不到 PG
- **不要**改 `db_migrated` 标记文件名（代码里 hardcode）

### 镜像源

- 默认 DaoCloud 加速器：`m.daocloud.io/docker.io/kalilinux/kali-rolling`
- Dockerfile 内 apt 源改为清华：`mirrors.tuna.tsinghua.edu.cn/kali`
- postgres 镜像：`m.daocloud.io/docker.io/library/postgres:18-alpine`（用 18 对应 Kali 默认 PG 版本）
- 时区 hardcode `TZ=Asia/Shanghai`，写在 `docker-compose.yml`
- 国内用户免配；海外用户需改 `image:` 与 Dockerfile 的 apt 源 sed 行

### Shell 脚本风格

- `kali` / `kali.compose` 两个脚本遵循 docker-hermes / docker-mysql 风格：
  - 顶部 `#!/bin/bash`（`kali` 用 `#!/bin/sh`）
  - `case "$1" in` 分发子命令
  - 默认子命令 + 用法提示
  - 所有 shell 脚本必须可执行（`chmod +x`）
- 改完脚本后**检查可执行权限是否保留**

## 文件职责

| 文件 | 谁改 | 说明 |
| --- | --- | --- |
| `Dockerfile` | 改 | 添加新工具时同步更新；改完触发 `./kali.compose update` |
| `config/database.yml` | 少改 | msf 数据库配置；改动需确保 host=`postgres`（不是 `localhost`） |
| `docker-compose.yml` | 慎改 | 服务编排、双网络、端口；用户可能基于此改 |
| `.gitignore` | 少改 | 新增需要忽略的产物类型时 |
| `kali` | 少改 | 单行 `docker exec` 包装 |
| `kali.compose` | 改 | 增删子命令时 |
| `scripts/init-msf-db.sh` | 少改 | msf 数据库初始化脚本；通过 read-only bind mount 注入容器 |
| `README.md` | 改 | 文档同步；保持与 `docker-compose.yml` 一致 |
| `AGENTS.md` | 改 | 架构或约定变更时 |

## 验证清单

修改后必须验证：

1. **Compose 语法**（改了 compose 时）：
   ```bash
   docker compose -f docker-compose.yml config
   ```
   本项目**没有** `.env`，直接 `config` 即可
2. **脚本语法**（改了 shell 时）：
   ```bash
   bash -n kali.compose
   sh -n kali
   ```
3. **脚本可执行权限**：
   ```bash
   ls -l kali kali.compose
   # 期望看到 -rwxr-xr-x
   ```
4. **可选：实际构建**（用户有 Docker 环境时）：
   ```bash
   ./kali.compose up    # 首次自动 build
   ```

验证完成后**不**主动清理 `./data` 或 `postgres_data`（除非用户明确要求）。

### 长时间任务约定（红线）

凡是下列类型的操作，**禁止 AI 自己执行**，必须由用户跑：

1. **`./kali.compose update`** —— 重建镜像（5-15 分钟），输出缓冲会导致 `tail`/grep 都看不到实时进度
2. **`docker compose down --volumes`** —— 删除 named volume（如 `postgres_data`），会**永久**丢失 msf 数据库
3. **首次启动后 30 秒内的 `db_migrate` 等待** —— 需要看 logs 实时进度，不能用一次性 tail/grep 替代
4. **`rm -rf ./data` 或 `./kali.compose reset-db`** —— 破坏性，需用户明确指令

AI 可以跑：短命令（`config` / `bash -n` / `ls -l` / `docker compose ps` / `docker exec <短命令>` / `docker logs --tail N`）。

AI 应**先给用户完整计划**（含所有命令 + 预期输出），用户跑完贴结果后再分析。AI 自行 `tail -f` 或 `tail` 长输出是反模式——用户看不到进度，AI 也看不到全部输出。

### 测试覆盖约定（必须用项目脚本）

测试/验证时，**必须用项目封装的脚本**（`./kali.compose <cmd>`），**禁止直接调用 `docker` / `docker compose` 命令**。

直接调用 docker 命令 = 测试覆盖范围丢失：
- 不能验证 `./kali.compose` 的封装逻辑（`--progress plain` 参数、`stop` + `rm -f` 不删网络、`update` 双重保护等）
- 出问题回归成本高（用户命令正常、AI 调 docker 也正常，到底哪层坏的？）
- 偏离"模拟真实用户使用"原则

**例外**（只能短暂用 docker 原生命令）：
1. `./kali.compose` 不支持的破坏性操作（如 `docker compose down --volumes`，用于干净重置测试环境）
2. 容器**内部**的 `docker exec` 命令（如 `docker exec postgres pg_isready`）—— 这是进容器执行命令，不算项目脚本

**典型反模式举例**：
- ❌ `docker compose config`（应用 `docker compose config`）
- ❌ `docker compose up -d`（用 `./kali.compose up`）
- ❌ `docker compose ps`（用 `./kali.compose status`）
- ❌ `docker compose restart kali`（用 `./kali.compose restart`）

凡是项目脚本能 cover 的，**必须**走 `./kali.compose`。

## 不做的事

- **不**添加 `dot.env.example` / `.env` / `kali.setup` —— 全部配置 hardcode 在 `docker-compose.yml`
- **不**让 `postgres` service 加入 `hermes-net`
- **不**在 `docker-compose.yml` 中使用过时的 `version: '3'` 字段
- **不**用 `${VAR:-default}` 形式的环境变量引用（本项目无 `.env`）
- **不**主动添加 LICENSE 文件
- **不**添加 CI/CD 工作流
- **不**引入新依赖（如 `make`、Python 脚本等），保持"裸 shell + docker compose"最小化

## 常见修改任务

| 任务 | 涉及文件 |
| --- | --- |
| 改时区 | `docker-compose.yml`（`TZ=`）、`README.md` |
| 换基础镜像源 | `docker-compose.yml`（`kali.image`）、`README.md` |
| 换 PG 镜像版本 | `docker-compose.yml`（`postgres.image`）、`README.md` |
| 添加新 Kali 工具 | `Dockerfile`（apt install 列表）、`README.md` |
| 升级 mcp-kali-server 依赖 | `Dockerfile`（requirements.txt 重新 pip install）、`README.md` |
| 重置 msf 数据库 | `./kali.compose reset-db` → `./kali.compose up` → `./kali.compose init-db` |
| 改 msf 数据库账号密码 | `config/database.yml` + `docker-compose.yml`（POSTGRES_*）+ `README.md` |
| 改 msf 数据库 host（端口/库名） | `config/database.yml` + `README.md` |
| 添加新 compose 子命令 | `kali.compose`、`README.md` 命令表 |
| 加挂额外持久化路径 | 评估是否符合简洁原则（默认不加） |
| 改默认 apt 源 | `Dockerfile`（sed 行）、`README.md` |
