# Obsidian Git 快捷命令

## 可用命令

在配置完快捷命令后，你可以在任何地方运行以下命令：

### 同步文件到 GitHub
```bash
obsidian-sync
```

### 查看 Git 状态
```bash
obsidian-status
```

### 查看最近提交
```bash
obsidian-log
```

## 配置快捷命令

运行以下命令来添加快捷命令到你的 shell 配置：

```bash
cat >> ~/.zshrc << 'EOF'

# Obsidian Git 同步快捷命令
alias obsidian-sync='cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && ./sync-to-git.sh'
alias obsidian-status='cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && git status'
alias obsidian-log='cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && git log --oneline -10'
alias obsidian-push='cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && git push'
EOF
```

然后重新加载配置：

```bash
source ~/.zshrc
```

## 使用示例

### 1. 同步文件
```bash
# 在 Obsidian 中编辑文件后
obsidian-sync
```

### 2. 检查状态
```bash
# 查看是否有未提交的更改
obsidian-status
```

### 3. 查看历史
```bash
# 查看最近的提交记录
obsidian-log
```

### 4. 手动推送
```bash
# 如果需要手动推送
obsidian-push
```

## 工作流程

1. 在 Obsidian 中编辑 `git-sync` 文件夹下的文件
2. 运行 `obsidian-sync` 自动提交并推送
3. 完成！

## 注意事项

- 快捷命令只适用于 Git Bash 配置为 zsh 的情况
- 如果使用 bash，请将命令添加到 `~/.bash_profile`
- 确保网络连接正常