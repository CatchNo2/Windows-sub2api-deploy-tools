# Sub2API Windows 自动安装程序（新手友好版）

> **告别繁琐的手动部署，一键完成 Sub2API 安装！**
> 本工具自动帮你装好 WSL2 + Docker + 部署 Sub2API，全程不用担心"找不到项目"的问题。

---

## ⚠️ 最重要的第一步：先拿到 Sub2API 项目源码

**请务必先读完这一段再动手！**

这个安装脚本**只负责"装环境 + 部署"**，它自己**不会凭空变出 Sub2API 的源代码**。
你需要先把 Sub2API 项目（里面必须包含 `deploy` 文件夹）放到你的电脑上，脚本才能部署它。

> 简单说：**这个项目（auto-install 脚本）是"安装工"，而 Sub2API 才是"要安装的程序"。两样都要有。**

### 方式一：让脚本帮你自动下载（最省事，推荐新手）

直接运行脚本，当提示 `是否现在自动克隆 Sub2API 项目...` 时输入 `Y` 回车即可，
脚本会自动把源码下载到 `C:\Users\你的用户名\Git\sub2api`。

### 方式二：自己手动下载（更可控，推荐）

用 Git 把项目拉到任意位置（名字随便起，比如 `sub2api`、`sub2api-main` 都行）：

```powershell
# 推荐放这里（脚本会优先找到它）
git clone https://github.com/Wei-Shaw/sub2api.git %USERPROFILE%\Git\sub2api

# 或者放别的盘也完全没问题
git clone https://github.com/Wei-Shaw/sub2api.git D:\我的代码\sub2api
```

> 没有 Git？去 https://git-scm.com/download/win 装一个，一路下一步即可。
> 不会用 Git 也没关系，也可以直接在 GitHub 页面点 `Code -> Download ZIP`，
> 解压后把文件夹重命名一下即可，效果一样。

**怎么判断下载对了？** 进去看一眼，应该有 `deploy` 这个文件夹，里面要有 `docker-compose.local.yml` 和 `.env.example` 两个文件。

---

## 三步完成安装

### 第 1 步：以管理员身份打开 PowerShell

- 点击开始菜单 → 输入 `PowerShell` → 右键「Windows PowerShell」→ **以管理员身份运行**
- 如果弹出"是否允许更改此设备"，点"是"

### 第 2 步：进入脚本所在目录

把本仓库（就是带 `auto-install.ps1` 的这个文件夹）放到一个你知道的位置，比如 `E:\Git\sub2api-installer`。
然后在管理员 PowerShell 里 `cd` 进去：

```powershell
cd E:\Git\sub2api-installer
```

### 第 3 步：运行脚本

```powershell
.\auto-install.ps1
```

然后**跟着屏幕提示走就行**。大部分步骤全自动，只有少数几步需要你动一下（比如创建 Ubuntu 用户、在 Docker 里点一下开启 WSL 集成），脚本都会用 `━━` 框把操作写得清清楚楚。

---

## 脚本怎么找到 Sub2API 项目的？（已大幅优化，不再死板）

老版本只能在 6 个固定路径、且文件夹必须精确叫 `sub2api` 时才能找到，**非常死板**。
新版本聪明多了：

1. **你用 `-ProjectPath` 指定** → 直接用你给的路径（里面还能嵌套，它会自动往里找）。
2. **放在脚本的上级目录 / 同级目录** → 自动识别（适合把脚本丢进 sub2api 项目里运行）。
3. **常见位置**（如 `~/Git/sub2api`、`D:\Git\sub2api` 等）→ 快速命中。
4. **递归搜索**你的代码目录（`Git`、`Desktop`、`Documents`、`source`、`projects` 等），
   **文件夹叫什么名字都行**，只要里面有 `deploy/docker-compose.local.yml` 就能找到。
5. **全盘扫描**所有磁盘根目录下名字含 `sub2api` 的文件夹。
6. **找到多个？** 会列出清单让你选一个（直接回车默认选第一个）。
7. **一个都找不到？** 会问你要不要**自动 git clone** 下来（见上方第一步）。

> 所以现在基本不用手动指定路径了，除非你想精确控制用哪个项目。

---

## 常用参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-ProjectPath` | 手动指定 Sub2API 项目路径 | 自动查找（见上） |
| `-ServerPort` | Web 管理后台端口 | 8787 |
| `-AdminPassword` | 管理员密码（不设则自动生成） | 自动生成 |
| `-InstallCodex` | 额外安装 Codex CLI（非必须） | 否 |
| `-Reset` | 重置安装进度，从头再来 | 否 |
| `-SkipAdminCheck` | 跳过管理员权限检查（调试用） | 否 |

```powershell
# 自定义端口和密码
.\auto-install.ps1 -ServerPort 8080 -AdminPassword "MyPass123"

# 手动指定项目路径（万一无敌自动找不到时用）
.\auto-install.ps1 -ProjectPath "D:\我的代码\sub2api"

# 重置后重装
.\auto-install.ps1 -Reset
```

---

## 安装过程中那些"需要你动手"的节点

脚本总共 10 步，真正需要你操作的只有少数几处，都会有醒目的黄色提示：

| 步骤 | 你要做什么 |
|------|------------|
| 1 安装 WSL2 | 装完可能要**重启电脑**，重启后重跑脚本即可（支持断点续传） |
| 2 初始化 Ubuntu | 第一次进 Ubuntu 要建个用户（教程里建议用户名用 `admin`，密码随便设如 `123456`） |
| 4 安装 Docker | 要么自己下安装包，要么脚本里回答 `y` 用 winget 装 |
| 5 配置 Docker | 打开 Docker Desktop → Settings → Resources → WSL Integration → 打开 Ubuntu 开关 → Apply |

其它步骤（装环境、生成密钥、拉镜像、起容器、拿密码）全部自动完成。

---

## 装好之后

### 打开管理后台

```
http://localhost:8787
```

- 管理员邮箱：`admin@sub2api.local`
- 管理员密码：看安装结束时的日志输出；或之后手动查（见下方 FAQ）

### 常用命令（在 Ubuntu 里执行，进 Ubuntu 用 `wsl -d Ubuntu`）

```bash
cd ~/sub2api-deploy
docker compose -f docker-compose.local.yml ps              # 看状态
docker compose -f docker-compose.local.yml logs -f sub2api # 看日志
docker compose -f docker-compose.local.yml down            # 停止
docker compose -f docker-compose.local.yml up -d           # 启动
docker compose -f docker-compose.local.yml restart         # 重启
```

---

## 常见问题

### Q：安装到一半断了 / 电脑重启了怎么办？
直接重新运行 `.\auto-install.ps1`。做过的步骤会自动跳过，从断点继续。

### Q：提示"无法找到 Sub2API 项目目录"？
说明脚本没找到源码。按提示选 `Y` 让它自动克隆，或回到本文最上方**第一步**手动 clone 后用 `-ProjectPath` 指定。

### Q：我想完全重来？
```powershell
.\auto-install.ps1 -Reset
```

### Q：网络不好，拉镜像/克隆失败？
脚本已自动配好国内 Docker 镜像加速。若仍失败：开代理 / VPN，或手动下载 Docker 安装包。
克隆项目失败时也可自行用代理执行 `git clone`。

### Q：怎么看自动生成的管理员密码？
```bash
wsl -d Ubuntu bash -c 'cd ~/sub2api-deploy && docker compose -f docker-compose.local.yml logs sub2api | grep -i password'
```

### Q：实在不会？把文档丢给 Agent，它会解答你的疑问。

---

## 系统要求

- Windows 10 版本 2004 及以上（内部版本 19041+）
- CPU 支持并开启硬件虚拟化（VT-x / AMD-V，需在 BIOS 里打开）
- 至少 4GB 可用内存
- 管理员权限

---

## 相关链接

- [Sub2API 项目主页](https://github.com/Wei-Shaw/sub2api)
- [English Documentation](README.md)
