# docker-kali

基于 [kalilinux/kali-rolling](https://hub.docker.com/r/kalilinux/kali-rolling) 官方镜像构建的 Kali Linux Docker 部署，预装 [MCP-Kali-Server](https://github.com/Wh0am123/MCP-Kali-Server)，作为 [docker-hermes](https://github.com/mengbo/docker-hermes) 的 sidecar，让 Hermes Agent 通过 MCP 协议控制 Kali 工具链。

项目启动**两个容器**：`kali`（metasploit + MCP server）+ `postgres`（msf 数据库）。PG 容器在项目私有网络 `kali-internal` 里，不暴露给 hermes。

## 前置

- Docker 20.10+
- Docker Compose v2（`docker compose` 命令）
- 已部署 [docker-hermes](https://github.com/mengbo/docker-hermes)（提供 `hermes-net` 网络）
- 国内用户：默认使用 DaoCloud 加速器拉基础镜像和 postgres 镜像；apt 源用清华镜像 `https://mirrors.tuna.tsinghua.edu.cn/kali`，无需额外配置

## 快速开始

```bash
# 启动容器（首次会自动构建镜像，5-15 分钟；输出逐行原始 build 日志）
./kali.compose up

# 检查容器状态与日志
./kali.compose status
./kali.compose logs
```

启动顺序：
1. `postgres` 容器先起，等 PG 监听 5432
2. `kali` 容器起来，MCP-Kali-Server 监听 5000

### msf 数据库初始化（`./kali.compose init-db`）

msf 数据库 schema（73 张表）是**运行时数据**，不在镜像里，需要手动初始化。

**需要跑 init-db 的场景**：
- **首次使用**（PG volume 为空）
- `docker compose down --volumes` 删了 PG volume 后重建

**不需要跑 init-db 的场景**：
- `./kali.compose update`（重建镜像，PG volume 保留）
- `./kali.compose restart` / `down` + `up`（容器重建，PG volume 保留）

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `./kali.compose up` | 启动两个容器（首次自动构建，逐行日志） |
| `./kali.compose start` | 启动已停止的容器 |
| `./kali.compose stop` | 停止所有容器 |
| `./kali.compose restart` | 重启 |
| `./kali.compose status` | 查看容器状态 |
| `./kali.compose logs` | 查看日志（`-f` 持续跟踪） |
| `./kali.compose update` | 强制重建 `kali` 镜像并重启 |
| `./kali.compose init-db` | 初始化 msf 数据库（首次 / 重建 PG volume 后手动跑一次，~30s） |
| `./kali.compose down` | 停止并移除容器（保留 `./data`、`postgres_data` 和外部网络） |

进 `kali` 容器：`./kali`（透传到 `docker exec -it kali bash`）。
进 `postgres` 容器：`docker exec -it postgres bash`。

## 网络拓扑

```
[ hermes-net ]  (由 docker-hermes 创建)
       │
       └── kali      ← 加入 hermes-net（让 hermes 通过容器名访问）
                      │
[ kali-internal ]     │
       │              │
       ├── kali       │
       └── postgres   ← 加入 hermes-net？不！只在私有网络
```

- **`hermes-net`**：外部网络，由 docker-hermes 创建。`kali` 加入此网络以便 hermes 通过容器名 `kali` 访问 MCP-Kali-Server。**postgres 不加入**。
- **`kali-internal`**：本项目私有 bridge 网络。`kali` 和 `postgres` 同时加入此网络，通过容器名 `postgres` 通信。hermes 看不到此网络，也 ping 不通 postgres。
- **DATABASE_URL**：`postgresql://msf:msf@postgres:5432/msf`（在 kali 容器内的 `config/database.yml` 已固化）
- **msf schema**：首次启动时 msfconsole 自动跑 `db_migrate`，以后秒级可用

### 网络行为

| 操作 | `hermes-net` | `postgres_data` |
| --- | --- | --- |
| `./kali.compose up` / `update` / `start` / `stop` / `restart` / `down` | 保留 | 保留 |
| 手动 `docker compose down` | **会删除**（破坏 hermes） | 保留 |
| `docker volume rm postgres_data` | n/a | 删除（msf 数据丢） |

⚠️ **不要**执行 `docker compose down`——会破坏 `hermes-net` 影响 docker-hermes。

## 数据持久化

两个持久化位置，**完全独立**：

- **bind mount** `./data:/root`（在 `kali` 容器里）
  - `.msf4/` —— Metasploit 配置（`config`）、历史（`history`）、工作区（`workspaces/`）、loot
  - `.bash_history` —— shell 历史
  - `.local/` —— `pip install --user` 装点
  - `.cache/` —— 工具缓存
- **named volume** `postgres_data:/var/lib/postgresql`（在 `postgres` 容器里）
  - **Metasploit 数据库的实际存储**（workspaces、hosts、creds、loot 数据）
  - Docker 自动管理 PG 用户/权限，无需宿主手工 `chown`
  - 数据落在 `/var/lib/docker/volumes/postgres_data/_data/`，宿主不可见但安全

**源码固化在镜像内**：MCP-Kali-Server 装在 `/opt/MCP-Kali-Server/`，升级靠 `./kali.compose update` 重新构建镜像。

### 备份与迁移 PG 数据

```bash
# 备份
docker run --rm -v postgres_data:/data -v $(pwd):/backup alpine tar czf /backup/pgdata-$(date +%Y%m%d).tar.gz -C /data .

# 恢复
docker run --rm -v postgres_data:/data -v $(pwd):/backup alpine tar xzf /backup/pgdata-<date>.tar.gz -C /data

# 查看数据位置
docker volume inspect postgres_data --format '{{ .Mountpoint }}'
```

## 升级

```bash
./kali.compose update
```

仅重建 `kali` 镜像（PG 容器不变）。期间 `kali` 重启几秒，msf 数据库完全保留。

## 修改配置

| 场景 | 操作 |
| --- | --- |
| 改时区 | `docker-compose.yml` 中 `TZ=Asia/Shanghai` → `./kali.compose up -d` 重建 |
| 换基础镜像源 | `docker-compose.yml` 中 `image:` → `./kali.compose update` |
| 换 PG 镜像源/版本 | `docker-compose.yml` 中 postgres 的 `image:` → `./kali.compose up -d` 重建 |
| 独立使用 5000 端口（暴露宿主） | `kali` service 取消 `# - "5000:5000"` 注释 → 重建 |
| 改 Dockerfile（如装额外工具） | 编辑 → `./kali.compose update` |
| 改 msf 数据库配置 | 编辑 `config/database.yml` → `./kali.compose update` |
| 重置 msf 数据库 | `./kali.compose reset-db` → `./kali.compose up` → `./kali.compose init-db` |
| 重置 kali 配置 | `rm -rf ./data` → `./kali.compose up -d` 重建 |

## 独立使用 5000 端口（可选）

默认情况下 `kali` 容器只通过 `hermes-net` 与 hermes 通信，5000 不暴露宿主。如需用 Claude Desktop / 5ire / opencode 等 MCP 客户端**直接**连接 `kali`：

1. 编辑 `docker-compose.yml`，在 `kali` service 下取消 `ports` 注释：
   ```yaml
   ports:
     - "5000:5000"
   ```
2. `./kali.compose up -d` 重建
3. 客户端连接 `http://localhost:5000`

`opencode.json` / `claude_desktop_config.json` / 5ire 配置示例：

```json
{
  "mcpServers": {
    "mcp-kali-server": {
      "command": "python3",
      "args": ["/absolute/path/to/client.py", "--server", "http://localhost:5000/"]
    }
  }
}
```

⚠️ 警告：开启公网端口前请配置 reverse proxy + TLS，避免 Kali 工具 API 被未授权访问。

## 已装工具集

按 [mcp-kali-server](https://github.com/Wh0am123/MCP-Kali-Server) Recommends 列表：

- **扫描**：`nmap`、`nikto`
- **目录爆破**：`gobuster`、`dirb`
- **注入**：`sqlmap`
- **爆破**：`hydra`、`john`
- **CMS**：`wpscan`
- **SMB**：`enum4linux`
- **框架**：`metasploit-framework`（PG 数据库在独立容器）
- **字典**：`wordlists`（Kali 默认字典）

容器内直接可用：`nmap <target>`、`msfconsole`、`hydra -L users.txt -P pass.txt ssh://target` 等。

## 故障排查

### 容器启动后立即退出

```bash
./kali.compose logs
```

常见原因：
- `hermes-net` 不存在：先启动 docker-hermes
- Dockerfile apt 装包失败：检查网络，确认清华镜像可达
- 镜像构建不完整：重新 `./kali.compose update`

### msfconsole 连接不到数据库

```bash
# 在 kali 容器内
docker exec -it kali msfconsole -q -x 'db_status; exit'
# 或
docker exec -it kali msfconsole -q -x 'db_connect; exit'

# 验证 PG 连通性
docker exec -it postgres pg_isready -U msf -d msf
docker exec -it postgres psql -U msf -d msf -c '\dt'
```

### 端口 5000 不可达（独立使用时）

- 确认 `docker-compose.yml` 取消了端口注释
- 确认 `./kali.compose up -d` 已执行
- 容器内测试：`docker exec -it kali curl http://localhost:5000/health`

### 清理

```bash
./kali.compose down              # 仅移除容器，保留 ./data / postgres_data / hermes-net
```

⚠️ **不要**执行 `docker compose down` / `docker compose down -v`——前者删除 `hermes-net`（破坏 docker-hermes），后者删除 `./data` / `postgres_data`（不可恢复）。

## 集成到 docker-hermes

为 hermes 提供的配置说明（直接复制下面的代码块作为 system prompt）：

```
你需要通过 MCP-Kali-Server 项目使用远程的 Kali Linux 系统。
具体配置见 https://github.com/Wh0am123/MCP-Kali-Server 。
MCP-Kali-Server 的服务器已经配置好了，在 http://kali:5000 可以访问，你配置 client。
```

## 参考

- [MCP-Kali-Server](https://github.com/Wh0am123/MCP-Kali-Server)
- [docker-hermes](https://github.com/mengbo/docker-hermes)
- [Kali Linux 官方 Docker 镜像文档](https://www.kali.org/docs/containers/official-kalilinux-docker-images/)
- [PostgreSQL 官方 Docker 镜像](https://hub.docker.com/_/postgres)
- [Metasploit Database Support](https://docs.metasploit.com/docs/using-metasploit/intermediate/metasploit-database-support.html)
