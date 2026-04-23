#!/bin/bash

# Obsidian to Git Sync Script
# 将 Obsidian git-sync 文件夹中的 Markdown 文件同步到 GitHub 仓库

OBSIDIAN_GIT_DIR="/Users/kivan/Documents/Obsidian Vault/git-sync"
REMOTE_REPO="origin"
MAIN_BRANCH="main"

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Obsidian Git Sync ===${NC}"
echo ""

# 检查目录是否存在
if [ ! -d "$OBSIDIAN_GIT_DIR" ]; then
    echo -e "${RED}错误: Obsidian Git 目录不存在: $OBSIDIAN_GIT_DIR${NC}"
    exit 1
fi

# 进入 Git 目录
cd "$OBSIDIAN_GIT_DIR" || exit 1

# 检查是否有更改
if [ -z "$(git status --porcelain)" ]; then
    echo -e "${YELLOW}没有需要同步的更改${NC}"
    echo ""
    echo "当前仓库状态："
    git status
    exit 0
fi

echo -e "${YELLOW}检测到以下更改：${NC}"
git status --short
echo ""

# 添加所有 Markdown 文件
echo -e "${GREEN}添加 Markdown 文件...${NC}"
git add "*.md" 2>/dev/null || true
git add "*.MD" 2>/dev/null || true

# 检查是否有需要提交的文件
if [ -z "$(git diff --cached --name-only)" ]; then
    echo -e "${YELLOW}没有 Markdown 文件需要提交${NC}"
    exit 0
fi

# 获取提交信息
COMMIT_MSG="Update $(date '+%Y-%m-%d %H:%M:%S')"

echo -e "${GREEN}准备提交更改...${NC}"
echo "提交信息: $COMMIT_MSG"
git commit -m "$COMMIT_MSG"

# 推送到远程仓库
echo -e "${GREEN}推送到远程仓库...${NC}"
if git push -u origin main; then
    echo ""
    echo -e "${GREEN}=== 同步完成！ ===${NC}"
    echo ""
    echo "查看仓库: https://github.com/wuw476709-oss/ai-mds"
else
    echo ""
    echo -e "${RED}推送失败，请检查网络连接和 GitHub 认证配置${NC}"
    echo ""
    echo "查看 SETUP.md 获取详细的配置指南"
    exit 1
fi
