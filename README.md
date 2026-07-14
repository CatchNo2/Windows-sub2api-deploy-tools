# Sub2API Windows Auto Installer (Newbie-Friendly)

> **Say goodbye to tedious manual deployment - install Sub2API with one click!**
> This tool automatically sets up WSL2 + Docker + Sub2API for you, and won't leave you stuck on "can't find the project".

---

## 📚 Documentation

- [中文文档](README_CN.md)

---

## ⚠️ Step Zero (most important): get the Sub2API source code first

**Read this before you do anything else!**

This installer **only sets up the environment and deploys** — it does **not magically produce the Sub2API source code**.
You need to have the Sub2API project (which must contain a `deploy` folder) somewhere on your machine first.

> In short: **this repo (the auto-install script) is the "installer", while Sub2API is the "program to install". You need both.**

### Option A: let the script download it for you (easiest)

Just run the script. When prompted `Clone Sub2API project now?`, type `Y` and it will
automatically clone the source to `C:\Users\YourName\Git\sub2api`.

### Option B: clone it yourself (recommended, more predictable)

Use Git to pull the project anywhere (the folder name can be anything — `sub2api`, `sub2api-main`, etc.):

```powershell
# Recommended location (the script finds this first)
git clone https://github.com/Wei-Shaw/sub2api.git %USERPROFILE%\Git\sub2api

# Or put it on another drive — totally fine
git clone https://github.com/Wei-Shaw/sub2api.git D:\mycode\sub2api
```

> No Git? Grab it from https://git-scm.com/download/win (next-next-next install).
> No Git knowledge? You can also click `Code -> Download ZIP` on GitHub, unzip, and rename the folder — same result.

**How to confirm it's correct?** Open the folder and check there's a `deploy` directory containing
`docker-compose.local.yml` and `.env.example`.

---

## Install in 3 steps

### Step 1: open PowerShell as Administrator

- Start menu → type `PowerShell` → right-click "Windows PowerShell" → **Run as administrator**
- Click "Yes" on the UAC prompt if it appears

### Step 2: go to the script's directory

Place this repo (the one with `auto-install.ps1`) somewhere you know, e.g. `E:\Git\sub2api-installer`,
then `cd` into it in the admin PowerShell:

```powershell
cd E:\Git\sub2api-installer
```

### Step 3: run the script

```powershell
.\auto-install.ps1
```

Then **just follow the on-screen prompts**. Most steps are fully automatic; only a few need your input
(creating the Ubuntu user, clicking to enable WSL integration in Docker). Those are always shown inside
a clear `━━` box with step-by-step instructions.

---

## How does the script find the Sub2API project? (heavily improved, no longer rigid)

The old version only searched 6 hard-coded paths and required the folder to be named exactly `sub2api` — **very rigid**.
The new version is much smarter:

1. **You pass `-ProjectPath`** → uses your path directly (it even searches inside it recursively).
2. **Parent / same directory of the script** → auto-detected (handy when you drop the script into the sub2api project).
3. **Common locations** (e.g. `~/Git/sub2api`, `D:\Git\sub2api`) → quick hit.
4. **Recursive search** of your code roots (`Git`, `Desktop`, `Documents`, `source`, `projects`, …) —
   **any folder name works**, as long as it contains `deploy/docker-compose.local.yml`.
5. **Whole-drive scan** for folders whose name contains `sub2api`.
6. **Multiple matches?** It lists them and lets you pick (Enter = first one).
7. **Nothing found?** It asks whether to **auto git-clone** it (see Step Zero above).

> So in practice you rarely need to specify a path manually anymore.

---

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-ProjectPath` | Sub2API project path | Auto-detect (see above) |
| `-ServerPort` | Web port | 8787 |
| `-AdminPassword` | Admin password (auto-generated if empty) | Auto-generated |
| `-InstallCodex` | Also install Codex CLI | No |
| `-Reset` | Reset install progress, start over | No |
| `-SkipAdminCheck` | Skip admin privilege check (debug) | No |

```powershell
# Custom port and password
.\auto-install.ps1 -ServerPort 8080 -AdminPassword "MyPass123"

# Manually point at the project (fallback if auto-detect ever fails)
.\auto-install.ps1 -ProjectPath "D:\mycode\sub2api"

# Reset and reinstall
.\auto-install.ps1 -Reset
```

---

## The few steps that need your hands

Out of 10 steps, only a handful need you — each shows a clear yellow prompt:

| Step | What you do |
|------|-------------|
| 1 Install WSL2 | May need a **reboot**; just re-run the script after (resume supported) |
| 2 Init Ubuntu | First launch needs a user (suggested username `admin`, password e.g. `123456`) |
| 4 Install Docker | Download the installer yourself, or answer `y` to use winget |
| 5 Configure Docker | Docker Desktop → Settings → Resources → WSL Integration → toggle Ubuntu → Apply |

Everything else (env setup, key generation, pulling images, starting containers, fetching password) is automatic.

---

## After installation

### Admin panel

```
http://localhost:8787
```

- Admin email: `admin@sub2api.local`
- Admin password: shown in the install log, or look it up later (FAQ below)

### Common commands (inside Ubuntu, enter with `wsl -d Ubuntu`)

```bash
cd ~/sub2api-deploy
docker compose -f docker-compose.local.yml ps
docker compose -f docker-compose.local.yml logs -f sub2api
docker compose -f docker-compose.local.yml down
docker compose -f docker-compose.local.yml up -d
docker compose -f docker-compose.local.yml restart
```

---

## FAQ

### Q: Install interrupted / PC rebooted?
Just re-run `.\auto-install.ps1`. Finished steps are skipped and it resumes.

### Q: "Cannot find Sub2API project directory"?
The script didn't locate the source. Choose `Y` to auto-clone, or go back to **Step Zero** above and clone manually, then use `-ProjectPath`.

### Q: Start completely over?
```powershell
.\auto-install.ps1 -Reset
```

### Q: Network issues (clone / image pull failed)?
The script already configures China Docker mirror acceleration. If it still fails: use a proxy / VPN, or download the Docker installer manually. For clone failures, run `git clone` with a proxy.

### Q: Where is the auto-generated admin password?
```bash
wsl -d Ubuntu bash -c 'cd ~/sub2api-deploy && docker compose -f docker-compose.local.yml logs sub2api | grep -i password'
```

---

## System Requirements

- Windows 10 version 2004 or later (Build 19041+)
- CPU with hardware virtualization enabled (VT-x / AMD-V, enabled in BIOS)
- At least 4GB available memory
- Administrator privileges

---

## Related Links

- [Sub2API Project](https://github.com/Wei-Shaw/sub2api)
- [中文文档](README_CN.md)
