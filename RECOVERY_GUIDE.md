# Chatwoot 企业版备份恢复指南

> 本文档记录了 Chatwoot 企业版从备份完整恢复的全过程，包括踩过的坑和解决方案。

## 📋 目录

1. [环境信息](#环境信息)
2. [备份文件清单](#备份文件清单)
3. [遇到的问题和坑](#遇到的问题和坑)
4. [完整恢复步骤](#完整恢复步骤)
5. [验证和测试](#验证和测试)
6. [关键配置说明](#关键配置说明)

---

## 环境信息

### 系统环境
- **操作系统**: Linux 6.8.0-86-generic
- **Docker**: 使用 Docker Compose 部署
- **PostgreSQL**: 17.7 (1Panel 管理的容器)
- **Redis**: 6.x (1Panel 管理的容器)
- **Chatwoot**: 企业版 (源码构建)

### 网络架构
```
┌─────────────────────────────────────────────┐
│  1panel-network (Docker external network)   │
│                                             │
│  ┌──────────────┐  ┌──────────────┐       │
│  │ Rails        │  │ Sidekiq      │       │
│  │ (3000)       │  │              │       │
│  └──────────────┘  └──────────────┘       │
│         │                  │               │
│  ┌──────▼──────────────────▼──┐           │
│  │  1Panel-postgresql-GKlm    │           │
│  │  (PostgreSQL 17.7)         │           │
│  └────────────────────────────┘           │
│         │                                  │
│  ┌──────▼──────────────────────┐          │
│  │  1Panel-redis-z3FT          │          │
│  │  (Redis)                    │          │
│  └─────────────────────────────┘          │
└─────────────────────────────────────────────┘
```

---

## 备份文件清单

### 1. 数据库备份
**文件路径**: `/opt/1panel/apps/postgresql/postgresql/chatwoot_production_202512041522594fpch.sql`
- **格式**: PostgreSQL custom format dump
- **大小**: ~几十 MB
- **包含内容**:
  - 85 个数据表
  - 完整的 schema 和数据
  - Captain AI 相关数据 (199 个助手响应)
  - 用户、会话、消息等核心数据

### 2. 存储文件备份
**文件路径**: `/data/sufe/chatwoot-develop/chatwoot-develop_storage_data.zip`
- **格式**: ZIP 压缩包
- **大小**: 60 MB (解压后 64 MB)
- **包含内容**:
  - 164 个 ActiveStorage 文件
  - 用户头像、聊天图片、附件等
  - 目录结构: `chatwoot-develop_storage_data/_data/*`

### 3. 源代码
**目录**: `/data/sufe/chatwoot-develop/`
- 已修改的企业版源码
- 企业功能解锁脚本
- Docker 配置文件

---

## 遇到的问题和坑

### 🚨 坑 #1: Docker Compose 使用了官方镜像

**问题描述**:
初始的 `docker-compose.production.yaml` 配置使用了官方的 `chatwoot/chatwoot:latest` 镜像：

```yaml
# ❌ 错误配置
services:
  base: &base
    image: chatwoot/chatwoot:latest
```

**问题后果**:
- 官方镜像没有企业功能解锁修改
- 启动后企业功能不可用
- `ChatwootApp.enterprise?` 返回 false

**解决方案**:
修改 docker-compose 配置为本地构建：

```yaml
# ✅ 正确配置
services:
  base: &base
    build:
      context: .
      dockerfile: docker/Dockerfile
      args:
        RAILS_ENV: production
        BUNDLE_WITHOUT: "development:test"
    image: chatwoot-enterprise:local
    env_file: .env
    volumes:
      - storage_data:/app/storage
    networks:
      - 1panel-network
```

**构建命令**:
```bash
docker compose -f docker-compose.production.yaml build --no-cache
```

---

### 🚨 坑 #2: 数据库 pgvector 扩展未安装

**问题描述**:
Captain AI 功能的 `captain_assistant_responses` 表需要 pgvector 扩展来存储向量嵌入数据，但 1Panel 的 PostgreSQL 容器默认没有安装。

**错误信息**:
```
PG::UndefinedTable: ERROR: relation "captain_assistant_responses" does not exist
```

尝试运行迁移时报错:
```
ActiveRecord::StatementInvalid: PG::UndefinedObject: ERROR: type "vector" does not exist
```

**解决方案**:

1. **在 PostgreSQL 容器中编译安装 pgvector**:

```bash
# 安装编译依赖
docker exec 1Panel-postgresql-GKlm apk add --no-cache \
  llvm clang gcc make git postgresql-dev

# 编译 pgvector
docker exec 1Panel-postgresql-GKlm sh -c "
  cd /tmp && \
  git clone --branch v0.5.1 https://github.com/pgvector/pgvector.git && \
  cd pgvector && \
  make
"

# 手动安装（如果 make install 失败）
docker exec 1Panel-postgresql-GKlm sh -c "
  cd /tmp/pgvector && \
  cp vector.so /usr/local/lib/postgresql/ && \
  cp sql/vector--0.5.1.sql /usr/local/share/postgresql/extension/ && \
  cp vector.control /usr/local/share/postgresql/extension/
"
```

2. **在数据库中启用扩展**:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

3. **运行数据库迁移**:

```bash
docker compose exec rails bundle exec rails db:migrate
```

**关键点**:
- pgvector 扩展必须在运行 Captain 相关迁移之前安装
- 编译时可能遇到 clang-19 不存在的错误，安装 clang20 即可
- 手动安装时确保文件权限正确

---

### 🚨 坑 #3: 表结构与模型定义不匹配

**问题描述**:
运行迁移后，表结构缺少某些列，导致 Rails 模型报错：

```
RuntimeError: Undeclared attribute type for enum 'status' in Captain::AssistantResponse
```

**缺少的列**:

| 表名 | 缺少的列 |
|------|---------|
| `captain_assistant_responses` | `status`, `documentable_type`, `documentable_id` |
| `captain_assistants` | `config`, `response_guidelines`, `guardrails` |
| `captain_documents` | `status`, `metadata` |

**原因分析**:
- 迁移虽然标记为已运行（up），但实际表不存在时迁移被跳过
- 需要手动运行或手动添加缺少的列

**解决方案**:

```sql
-- captain_assistant_responses
ALTER TABLE captain_assistant_responses
  ADD COLUMN IF NOT EXISTS status integer DEFAULT 1 NOT NULL,
  ADD COLUMN IF NOT EXISTS documentable_type varchar;

ALTER TABLE captain_assistant_responses
  RENAME COLUMN document_id TO documentable_id;

CREATE INDEX IF NOT EXISTS index_captain_assistant_responses_on_status
  ON captain_assistant_responses(status);

CREATE INDEX IF NOT EXISTS idx_cap_asst_resp_on_documentable
  ON captain_assistant_responses(documentable_id, documentable_type);

-- captain_assistants
ALTER TABLE captain_assistants
  ADD COLUMN IF NOT EXISTS config jsonb DEFAULT '{}' NOT NULL,
  ADD COLUMN IF NOT EXISTS response_guidelines jsonb DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS guardrails jsonb DEFAULT '[]';

-- captain_documents
ALTER TABLE captain_documents
  ADD COLUMN IF NOT EXISTS status integer DEFAULT 0 NOT NULL,
  ADD COLUMN IF NOT EXISTS metadata jsonb DEFAULT '{}';

CREATE INDEX IF NOT EXISTS index_captain_documents_on_status
  ON captain_documents(status);
```

---

### 🚨 坑 #4: 存储文件路径混淆

**问题描述**:
最初认为存储文件在项目目录 `/opt/chatwoot-develop/storage/`，但实际不存在。

**原因**:
Docker Compose 使用的是 **Named Volume**（命名卷），而不是 Bind Mount（目录映射）：

```yaml
# Named Volume (当前配置)
volumes:
  - storage_data:/app/storage

# 如果是 Bind Mount 应该这样:
volumes:
  - ./storage:/app/storage
```

**实际存储位置**:

| 位置 | 路径 |
|------|------|
| 容器内 | `/app/storage/` |
| 宿主机物理位置 | `/var/lib/docker/volumes/chatwoot-develop_storage_data/_data` |
| Docker Volume 名称 | `chatwoot-develop_storage_data` |

**恢复方法**:
```bash
# 解压备份
unzip /data/sufe/chatwoot-develop/chatwoot-develop_storage_data.zip -d /tmp/storage_restore

# 直接复制到 Docker volume
sudo cp -a /tmp/storage_restore/chatwoot-develop_storage_data/_data/* \
  /var/lib/docker/volumes/chatwoot-develop_storage_data/_data/
```

---

### 🚨 坑 #5: 企业功能配置丢失

**问题描述**:
恢复数据库后，企业功能虽然在代码层面解锁，但数据库中的配置需要重新设置。

**需要的配置**:
1. `installation_configs` 表中的定价计划
2. 每个 Account 的 `custom_attributes` 中的计划信息
3. Account 的 feature flags

**解决方案**:
运行企业解锁脚本：

```bash
docker compose exec rails bundle exec rails runner /app/unlock_enterprise.rb
```

脚本会自动：
- 设置 `INSTALLATION_PRICING_PLAN` 为 `enterprise`
- 设置 `INSTALLATION_PRICING_PLAN_QUANTITY` 为 `100000`
- 为所有账户设置 `plan_name` 和 `subscribed_quantity`
- 启用所有高级功能 (disable_branding, audit_logs, sla, captain_integration 等)

---

## 完整恢复步骤

### 前置准备

1. **确保 Docker 和 Docker Compose 已安装**
2. **确保 1Panel 的 PostgreSQL 和 Redis 容器正常运行**
3. **备份文件准备好**

### 步骤 1: 准备项目文件

```bash
cd /data/sufe/chatwoot-develop

# 检查 docker-compose 配置
cat docker-compose.production.yaml
```

确保配置使用本地构建：
```yaml
services:
  base: &base
    build:
      context: .
      dockerfile: docker/Dockerfile
```

### 步骤 2: 构建 Docker 镜像

```bash
# 停止现有容器
docker compose -f docker-compose.production.yaml down

# 构建新镜像（约需 10-15 分钟）
docker compose -f docker-compose.production.yaml build --no-cache
```

**预期输出**:
```
 chatwoot-enterprise:local  Built
```

### 步骤 3: 安装 pgvector 扩展

```bash
# 1. 安装编译依赖
docker exec 1Panel-postgresql-GKlm apk add --no-cache \
  llvm clang gcc make git postgresql-dev

# 2. 编译 pgvector
docker exec 1Panel-postgresql-GKlm sh -c "
  cd /tmp && \
  git clone --branch v0.5.1 https://github.com/pgvector/pgvector.git && \
  cd pgvector && \
  make
"

# 3. 手动安装扩展文件
docker exec 1Panel-postgresql-GKlm sh -c "
  cd /tmp/pgvector && \
  cp vector.so /usr/local/lib/postgresql/ && \
  cp sql/vector--0.5.1.sql /usr/local/share/postgresql/extension/ && \
  cp vector.control /usr/local/share/postgresql/extension/
"

# 4. 在数据库中启用扩展
docker exec 1Panel-postgresql-GKlm psql -U chatwoot_production \
  -d chatwoot_production -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

**验证**:
```bash
docker exec 1Panel-postgresql-GKlm psql -U chatwoot_production \
  -d chatwoot_production -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';"
```

应该看到:
```
 extname | extversion
---------+------------
 vector  | 0.5.1
```

### 步骤 4: 恢复数据库备份

```bash
# 1. 复制备份文件到 PostgreSQL 容器
docker cp /opt/1panel/apps/postgresql/postgresql/chatwoot_production_202512041522594fpch.sql \
  1Panel-postgresql-GKlm:/tmp/backup.sql

# 2. 停止 Rails 和 Sidekiq 服务
docker compose -f docker-compose.production.yaml stop rails sidekiq

# 3. 清空所有数据表（保留 schema_migrations）
docker exec 1Panel-postgresql-GKlm psql -U chatwoot_production -d chatwoot_production << 'EOF'
DO $$
DECLARE
  r RECORD;
  stmt TEXT;
BEGIN
  FOR r IN (
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'public'
    AND tablename NOT IN ('schema_migrations', 'ar_internal_metadata')
    ORDER BY tablename
  ) LOOP
    stmt := 'TRUNCATE TABLE ' || quote_ident(r.tablename) || ' RESTART IDENTITY CASCADE';
    EXECUTE stmt;
  END LOOP;
END $$;
EOF

# 4. 恢复所有数据
docker exec 1Panel-postgresql-GKlm pg_restore -U chatwoot_production \
  -d chatwoot_production --data-only --disable-triggers /tmp/backup.sql
```

**验证数据恢复**:
```bash
docker exec 1Panel-postgresql-GKlm psql -U chatwoot_production -d chatwoot_production -c "
SELECT
  (SELECT COUNT(*) FROM messages) as messages,
  (SELECT COUNT(*) FROM contacts) as contacts,
  (SELECT COUNT(*) FROM conversations) as conversations,
  (SELECT COUNT(*) FROM captain_assistant_responses) as captain_responses;
"
```

### 步骤 5: 修复表结构

```bash
docker exec 1Panel-postgresql-GKlm psql -U chatwoot_production -d chatwoot_production << 'EOF'
-- captain_assistant_responses
ALTER TABLE captain_assistant_responses
  ADD COLUMN IF NOT EXISTS status integer DEFAULT 1 NOT NULL,
  ADD COLUMN IF NOT EXISTS documentable_type varchar;

ALTER TABLE captain_assistant_responses
  RENAME COLUMN document_id TO documentable_id;

CREATE INDEX IF NOT EXISTS index_captain_assistant_responses_on_status
  ON captain_assistant_responses(status);

CREATE INDEX IF NOT EXISTS idx_cap_asst_resp_on_documentable
  ON captain_assistant_responses(documentable_id, documentable_type);

-- captain_assistants
ALTER TABLE captain_assistants
  ADD COLUMN IF NOT EXISTS config jsonb DEFAULT '{}' NOT NULL,
  ADD COLUMN IF NOT EXISTS response_guidelines jsonb DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS guardrails jsonb DEFAULT '[]';

-- captain_documents
ALTER TABLE captain_documents
  ADD COLUMN IF NOT EXISTS status integer DEFAULT 0 NOT NULL,
  ADD COLUMN IF NOT EXISTS metadata jsonb DEFAULT '{}';

CREATE INDEX IF NOT EXISTS index_captain_documents_on_status
  ON captain_documents(status);
EOF
```

### 步骤 6: 恢复存储文件

```bash
# 1. 解压备份
mkdir -p /tmp/storage_restore
unzip /data/sufe/chatwoot-develop/chatwoot-develop_storage_data.zip \
  -d /tmp/storage_restore

# 2. 复制到 Docker volume
sudo cp -a /tmp/storage_restore/chatwoot-develop_storage_data/_data/* \
  /var/lib/docker/volumes/chatwoot-develop_storage_data/_data/

# 3. 清理临时文件
rm -rf /tmp/storage_restore
```

**验证存储文件**:
```bash
# 检查文件数量
sudo find /var/lib/docker/volumes/chatwoot-develop_storage_data/_data/ -type f | wc -l

# 从容器内验证
docker compose -f docker-compose.production.yaml exec rails find /app/storage -type f | wc -l
```

### 步骤 7: 启动服务并应用企业配置

```bash
# 1. 启动服务
docker compose -f docker-compose.production.yaml start rails sidekiq

# 2. 等待服务启动（约 10 秒）
sleep 10

# 3. 运行企业解锁脚本
docker compose -f docker-compose.production.yaml exec rails \
  bundle exec rails runner /app/unlock_enterprise.rb

# 4. 重启服务使配置生效
docker compose -f docker-compose.production.yaml restart rails sidekiq
```

---

## 验证和测试

### 1. 检查服务状态

```bash
# 查看容器状态
docker compose -f docker-compose.production.yaml ps

# 查看 Rails 日志
docker compose -f docker-compose.production.yaml logs rails --tail=50

# 检查数据库连接
docker compose -f docker-compose.production.yaml exec rails \
  bundle exec rails runner "puts ActiveRecord::Base.connection.active?"
```

### 2. 验证数据完整性

```bash
docker exec 1Panel-postgresql-GKlm psql -U chatwoot_production -d chatwoot_production -c "
SELECT
  relname as table_name,
  n_live_tup as row_count
FROM pg_stat_user_tables
WHERE schemaname='public' AND n_live_tup > 0
ORDER BY n_live_tup DESC
LIMIT 20;
"
```

**预期结果**:
```
       table_name        | row_count
------------------------+-----------
 messages               |      3082
 contacts               |      2460
 captain_assistant_resp |       199
 ...
```

### 3. 测试 Captain AI 功能

```bash
# 检查 Captain 表
docker exec 1Panel-postgresql-GKlm psql -U chatwoot_production -d chatwoot_production -c "
SELECT
  (SELECT COUNT(*) FROM captain_assistants) as assistants,
  (SELECT COUNT(*) FROM captain_documents) as documents,
  (SELECT COUNT(*) FROM captain_assistant_responses) as responses;
"
```

### 4. 测试文件访问

访问任意一张已上传的图片，检查是否能正常显示，不应该出现 404 错误。

### 5. 验证企业功能

```bash
# 检查企业配置
docker exec 1Panel-postgresql-GKlm psql -U chatwoot_production -d chatwoot_production -c "
SELECT name, serialized_value
FROM installation_configs
WHERE name IN ('INSTALLATION_PRICING_PLAN', 'INSTALLATION_PRICING_PLAN_QUANTITY');
"
```

**预期输出**:
```
            name             | serialized_value
-----------------------------+------------------
 INSTALLATION_PRICING_PLAN   | "enterprise"
 INSTALLATION_PRICING_PLAN_Q | 100000
```

---

## 关键配置说明

### 1. 企业功能解锁机制

修改 `lib/chatwoot_app.rb` 中的两个方法：

```ruby
def self.enterprise?
  # Always return true to enable all enterprise features
  true
end

def self.chatwoot_cloud?
  # Always return true to enable all cloud-only features in self-hosted enterprise
  true
end
```

**影响范围**:
- `enterprise?`: 启用所有企业版功能
- `chatwoot_cloud?`: 启用云版专属功能（如某些高级 API）

### 2. Docker 网络配置

```yaml
networks:
  1panel-network:
    external: true
```

**说明**:
- 使用 1Panel 创建的外部网络 `1panel-network`
- 允许 Chatwoot 容器与 1Panel 管理的 PostgreSQL 和 Redis 通信
- 网络名称必须精确匹配

### 3. 存储卷配置

```yaml
volumes:
  storage_data:
```

**说明**:
- 使用 Docker 管理的命名卷
- 物理路径: `/var/lib/docker/volumes/chatwoot-develop_storage_data/_data`
- 容器内路径: `/app/storage/`
- 持久化所有上传的文件和附件

### 4. 环境变量关键配置

```env
# 数据库连接
POSTGRES_HOST=1Panel-postgresql-GKlm
POSTGRES_DATABASE=chatwoot_production
POSTGRES_USERNAME=chatwoot_production
POSTGRES_PASSWORD=aSTn6WEBZBEZr8Py

# Redis 连接
REDIS_URL=redis://:redis_xWkbpN@1Panel-redis-z3FT:6379
REDIS_PASSWORD=redis_xWkbpN

# 前端 URL
FRONTEND_URL=https://chatbot.sufe.pro

# 存储
ACTIVE_STORAGE_SERVICE=local
```

---

## 恢复结果总结

### ✅ 已恢复的数据

#### 数据库 (85 个配置表，40 个有数据)
- **核心业务数据**:
  - 3,082 条消息
  - 2,460 个联系人
  - 112 个会话
  - 775 个报告事件
  - 545 条备注
  - 486 条审计日志

- **Captain AI 数据**:
  - 199 个助手响应（常见问题）
  - 1 个助手配置
  - 9 个文档

- **Copilot AI 数据**:
  - 62 条消息
  - 12 个对话线程

- **文件元数据**:
  - 157 个 ActiveStorage blobs
  - 157 个附件关联
  - 11 个变体记录

#### 存储文件
- **文件数量**: 164 个文件
- **总大小**: 64 MB
- **类型**: 用户头像、聊天图片、文件附件等

#### 企业配置
- **定价计划**: enterprise
- **许可数量**: 100,000
- **启用功能**: 11 个高级功能
  - disable_branding (去品牌)
  - audit_logs (审计日志)
  - sla (SLA 管理)
  - help_center_embedding_search (帮助中心向量搜索)
  - captain_integration (Captain AI)
  - captain_integration_v2 (Captain AI v2)
  - custom_roles (自定义角色)
  - saml (SAML 单点登录)
  - advanced_search (高级搜索)
  - advanced_search_indexing (高级搜索索引)
  - companies (公司管理)

### ⚠️ 注意事项

1. **PostgreSQL 版本**: 确保使用 PostgreSQL 17.x
2. **pgvector 扩展**: 必须安装 v0.5.1 或更高版本
3. **网络配置**: 必须使用 1Panel 的外部网络
4. **镜像构建**: 必须本地构建，不能使用官方镜像
5. **企业脚本**: 数据库恢复后必须运行企业解锁脚本

---

## 故障排查

### 问题: 容器无法连接数据库

**检查**:
```bash
# 1. 检查网络
docker network inspect 1panel-network

# 2. 测试数据库连接
docker run --rm --network 1panel-network postgres:17-alpine \
  psql -h 1Panel-postgresql-GKlm -U chatwoot_production -d chatwoot_production -c "SELECT 1;"
```

### 问题: Captain API 返回 500 错误

**检查**:
```bash
# 1. 检查 pgvector 扩展
docker exec 1Panel-postgresql-GKlm psql -U chatwoot_production \
  -d chatwoot_production -c "\dx vector"

# 2. 检查表结构
docker exec 1Panel-postgresql-GKlm psql -U chatwoot_production \
  -d chatwoot_production -c "\d captain_assistant_responses"

# 3. 检查日志
docker compose -f docker-compose.production.yaml logs rails | grep -i captain
```

### 问题: 文件 404 错误

**检查**:
```bash
# 1. 检查存储卷
docker volume inspect chatwoot-develop_storage_data

# 2. 检查容器内文件
docker compose -f docker-compose.production.yaml exec rails ls -la /app/storage/

# 3. 检查物理文件
sudo ls -la /var/lib/docker/volumes/chatwoot-develop_storage_data/_data/
```

---

## 备份建议

### 定期备份

#### 数据库备份（每日）
```bash
docker exec 1Panel-postgresql-GKlm pg_dump -U chatwoot_production \
  -d chatwoot_production -Fc > "chatwoot_backup_$(date +%Y%m%d).sql"
```

#### 存储文件备份（每周）
```bash
sudo tar -czf "storage_backup_$(date +%Y%m%d).tar.gz" \
  /var/lib/docker/volumes/chatwoot-develop_storage_data/_data/
```

#### Docker Volume 备份
```bash
docker run --rm \
  -v chatwoot-develop_storage_data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/storage_volume_backup.tar.gz /data
```

### 备份验证

定期验证备份可恢复性：
```bash
# 1. 测试数据库备份
docker exec 1Panel-postgresql-GKlm pg_restore -l backup.sql

# 2. 测试存储备份
tar -tzf storage_backup.tar.gz | head
```

---

## 参考资源

- [Chatwoot 官方文档](https://www.chatwoot.com/docs)
- [pgvector GitHub](https://github.com/pgvector/pgvector)
- [Docker Compose 文档](https://docs.docker.com/compose/)
- [PostgreSQL 备份和恢复](https://www.postgresql.org/docs/current/backup.html)

---

**文档版本**: 1.0
**最后更新**: 2025-12-04
**维护者**: Claude Code Assistant
