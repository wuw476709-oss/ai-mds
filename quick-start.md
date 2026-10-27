# 快速开始指南

## 🚀 一键同步

配置 SSH 后，直接运行：

```bash
cd "/Users/kivan/Documents/Obsidian Vault/git-sync"
./sync-to-git.sh
```

## 📋 快速检查

```bash
# 查看状态
cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && git status

# 查看最近提交
cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && git log --oneline -5
```

## 🎯 工作流程

1. **编辑**: 在 Obsidian 的 `git-sync` 文件夹中编辑 Markdown 文件
2. **同步**: 运行 `sync-to-git.sh` 脚本
3. **推送**: 脚本自动推送到 GitHub

## ⚙️ 配置快捷命令

```bash
# 添加到 .zshrc
cat >> ~/.zshrc << 'EOF'
alias obsidian-sync='cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && ./sync-to-git.sh'
alias obsidian-status='cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && git status'
alias obsidian-log='cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && git log --oneline -5'
EOF

# 重新加载
source ~/.zshrc
```

## 📁 文件结构

```
git-sync/
├── sync-to-git.sh     # 同步脚本
├── README.md          # 详细说明
├── SETUP.md           # 配置指南
├── setup-complete.md        # 配置摘要
└── *.md              # 你的 Markdown 文件
```

## 🔧 首次使用

1. 配置 GitHub SSH 密钥（见 SETUP.md）
2. 测试连接：`ssh -T git@github.com`
3. 推送初始提交：`git push -u origin main`
4. 开始同步你的文件！

## 💡 提示

- 脚本只同步 `.md` 文件
- 每次同步都会创建新的提交
- 查看配置详情请阅读 `SETUP.md`