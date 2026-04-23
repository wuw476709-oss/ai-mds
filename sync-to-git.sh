#!/bin/bash

# Obsidian to Git Sync Script
# 将 Obsidian git-sync 文件夹中的 Markdown 文件同步到 GitHub 仓库

OBSIDIAN_GIT_DIR="/Users/kivan/Documents/Obsidian Vault/git-sync"
REMOTE_REPO="origin"
MAIN_BRANCH="main"

# 检查目录是否存在
if [ ! -d "$OBSIDIAN_GIT_DIR" ]; then
    echo "错误: Obsidian Git 目录不存在: $OBSIDIAN_GIT_DIR"
    exit 1
fi

# 进入 Git 目录
cd "$OBSIDIAN_GIT_DIR" || exit 1

# 检查是否有更改
if [ -z "$(git status --porcelain)" ]; then
    echo "没有需要同步的更改"
    exit 0
fi

echo "检测到以下更改："
git status --short
echo ""

# 添加所有 Markdown 文件
echo "添加 Markdown 文件..."
git add "*.md"
git add "*.MD"

# 检查是否有需要提交的文件
if [ -z "$(git diff --cached --name-only)" ]; then
    echo "没有 Markdown 文件需要提交"
    exit 0
fi

# 获取提交信息
COMMIT_MSG="Update $(date '+%Y-%m-%d %H:%M:%S')"

echo "准备提交更改..."
echo "提交信息: $COMMIT_MSG"
git commit -m "$COMMIT_MSG"

# 推送到远程仓库
echo "推送到远程仓库..."
git push -u origin main

echo "同步完成！"
