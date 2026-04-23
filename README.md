# Obsidian Git Sync 文件夹

这个文件夹用于存放需要同步到 GitHub 的 Markdown 文件。

## 仓库信息

- GitHub 仓库: https://github.com/wuw476709-oss/ai-mds.git
- 同步脚本: `./sync-to-git.sh`

## 使用方法

### 1. 在 Obsidian 中编辑文件

- 在 Obsidian 中编辑这个文件夹下的 Markdown 文件
- 保存文件后，文件会自动保存到本地

### 2. 同步到 GitHub

运行同步脚本：

```bash
cd "/Users/kivan/Documents/Obsidian Vault/git-sync"
./sync-to-git.sh
```

或者直接运行：

```bash
/Users/kivan/Documents/Obsidian Vault/git-sync/sync-to-git.sh
```

### 3. 脚本功能

- 自动检测 Markdown 文件的更改
- 添加所有 `.md` 文件到 Git
- 创建带时间戳的提交信息
- 推送到 GitHub 仓库

## 注意事项

- 脚本只会同步 Markdown 文件（`.md` 和 `.MD` 扩展名）
- 如果没有更改，脚本会自动退出
- 确保你有 GitHub 仓库的推送权限

## 手动 Git 操作

如果需要更精细的 Git 操作，可以手动使用：

```bash
# 查看状态
git status

# 添加特定文件
git add 文件名.md

# 提交更改
git commit -m "你的提交信息"

# 推送到 GitHub
git push origin main
```

## 快捷命令

可以将以下命令添加到你的 `.zshrc` 或 `.bash_profile` 中：

```bash
alias obsidian-git-sync='cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && ./sync-to-git.sh'
```

这样你就可以在任何地方运行 `obsidian-git-sync` 来同步文件。