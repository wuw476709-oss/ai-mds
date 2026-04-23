# Obsidian Git 同步配置指南

## 配置完成状态

✅ Obsidian Vault 路径: `/Users/kivan/Documents/Obsidian Vault`
✅ 同步文件夹: `/Users/kivan/Documents/Obsidian Vault/git-sync`
✅ Git 仓库已初始化
✅ 同步脚本已创建
✅ 示例文件已创建

## 下一步操作：配置 GitHub SSH 认证

由于当前没有配置 SSH 密钥，需要先设置 GitHub 认证。

### 方案一：配置 SSH 密钥（推荐）

1. 生成 SSH 密钥：
```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```

2. 启动 ssh-agent：
```bash
eval "$(ssh-agent -s)"
```

3. 添加 SSH 密钥：
```bash
ssh-add ~/.ssh/id_ed25519
```

4. 复制公钥内容：
```bash
cat ~/.ssh/id_ed25519.pub
```

5. 在 GitHub 添加 SSH 密钥：
   - 访问 https://github.com/settings/keys
   - 点击 "New SSH key"
   - 粘贴公钥内容
   - 保存

6. 测试连接：
```bash
ssh -T git@github.com
```

### 方案二：使用 Personal Access Token

1. 访问 https://github.com/settings/tokens
2. 生成新的 Personal Access Token
3. 选择 repo 权限
4. 复制生成的 token

5. 在 Git 中使用 token：
```bash
cd "/Users/kivan/Documents/Obsidian Vault/git-sync"
git remote set-url origin https://YOUR_TOKEN@github.com/wuw476709-oss/ai-mds.git
```

## 同步文件夹结构

```
/Users/kivan/Documents/Obsidian Vault/git-sync/
├── .git/                    # Git 仓库配置
├── README.md               # 使用说明
├── sync-to-git.sh          # 同步脚本
└── 测试文件.md             # 示例文件
```

## 使用方法

### 基本使用

1. 在 Obsidian 中编辑文件：
   - 在 `git-sync` 文件夹中编辑 Markdown 文件
   - 或创建新的 Markdown 文件

2. 运行同步脚本：
```bash
cd "/Users/kivan/Documents/Obsidian Vault/git-sync"
./sync-to-git.sh
```

3. 推送到 GitHub：
   - 脚本会自动执行 git add, commit, push
   - 所有更改会被推送到 GitHub 仓库

### 手动 Git 操作

如果需要更精细的控制：

```bash
cd "/Users/kivan/Documents/Obsidian Vault/git-sync"

# 查看状态
git status

# 添加特定文件
git add 文件名.md

# 提交更改
git commit -m "你的提交信息"

# 推送到 GitHub
git push origin main
```

## 脚本功能说明

`sync-to-git.sh` 脚本会自动：

1. 检查文件更改
2. 添加所有 Markdown 文件（`.md`, `.MD`）
3. 创建带时间戳的提交信息
4. 推送到 GitHub 仓库

## 快捷命令

将以下内容添加到 `~/.zshrc` 或 `~/.bash_profile`：

```bash
# Obsidian Git 同步快捷命令
alias obsidian-git-sync='cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && ./sync-to-git.sh'
alias obsidian-git-status='cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && git status'
alias obsidian-git-log='cd "/Users/kivan/Documents/Obsidian Vault/git-sync" && git log --oneline -10'
```

重新加载配置：
```bash
source ~/.zshrc
# 或
source ~/.bash_profile
```

## 测试同步

配置完成后，测试同步：

1. 创建或修改一个 Markdown 文件
2. 运行同步脚本
3. 检查 GitHub 仓库 https://github.com/wuw476709-oss/ai-mds

## 注意事项

- 脚本只同步 Markdown 文件
- 确保你有 GitHub 仓库的推送权限
- 首次使用需要配置 GitHub 认证
- 每次同步都会创建新的提交

## 故障排查

### 推送失败

如果 `git push` 失败，检查：

1. GitHub 认证是否配置正确
2. 是否有仓库的推送权限
3. 网络连接是否正常

### 同步脚本无法运行

检查脚本权限：
```bash
chmod +x "/Users/kivan/Documents/Obsidian Vault/git-sync/sync-to-git.sh"
```

## 联系支持

如有问题，请检查：
- GitHub 仓库权限
- SSH 密钥配置
- 网络连接状态