---
description: 手动合并上游 Chatwoot 最新代码并保持企业版功能解锁
---

# 合并上游 Chatwoot 代码

// turbo-all

以下步骤用于手动将上游 chatwoot/chatwoot 仓库的最新代码合并到本地 develop 分支，同时保持企业版功能解锁。

## 前置条件

确保 upstream remote 已配置：
```bash
git remote add upstream https://github.com/chatwoot/chatwoot.git 2>/dev/null || true
```

## 步骤

1. 获取上游最新代码：
```bash
git fetch upstream
```

2. 查看上游新提交（确认有需要合并的内容）：
```bash
git log HEAD..upstream/master --oneline
```

3. 切换到 develop 分支：
```bash
git checkout develop
```

4. 合并上游 master：
```bash
git merge upstream/master --no-edit
```

5. 如果有冲突，解决冲突后运行：
```bash
git add -A
git commit --no-edit
```

6. 运行企业版解锁补丁脚本，确保企业特性被正确重新应用：
```bash
./scripts/patch_enterprise.sh
```

7. 检查补丁是否正确应用：
```bash
grep -A 2 "def self.enterprise?" lib/chatwoot_app.rb
grep -A 2 "def self.pricing_plan" lib/chatwoot_hub.rb
grep -B 2 "premium: true" config/features.yml | grep "enabled:"
```

8. 如果补丁脚本修改了文件，提交补丁变更：
```bash
git add -A
UPSTREAM_VERSION=$(cat VERSION_CW 2>/dev/null || echo "unknown")
git diff --cached --quiet || git commit -m "feat: sync upstream v${UPSTREAM_VERSION} and re-apply enterprise patches"
```

9. 推送到远程：
```bash
git push origin develop
```

## 注意事项

- **不要修改** `.github/workflows/build_docker.yml`（Docker 构建工作流）
- **不要修改** `.github/workflows/sync_upstream.yml`（自动同步工作流）
- 如果合并冲突涉及 `chatwoot_app.rb`/`chatwoot_hub.rb`/`features.yml`，优先采用上游代码（`--theirs`），然后运行 `patch_enterprise.sh` 重新应用企业版补丁
- 合并后建议运行 `bundle exec rails runner unlock_enterprise.rb` 更新数据库中的企业版配置
