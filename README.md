# 本项目完全由Codex编写

# 本地 Galaxy 生信分析平台

这个项目用 Galaxy 官方社区 Docker 镜像部署本地 Galaxy，并在镜像构建阶段通过 Tool Shed 安装常用生信工具。Windows 用户双击 `Start-Galaxy.exe` 即可打开启动器；只要电脑已经安装 Docker Desktop/Engine，就可以一键构建、启动并打开 Galaxy 登录页。

## 已实现

- 使用 `quay.io/bgruening/galaxy:26.0` 作为基础镜像，并用官方 `install-tools` 方式扩展工具。
- 用 Docker Compose 启动 Galaxy，Web 端口默认是 `http://localhost:8080`。
- `/export` 挂载到命名卷 `local-usegalaxy_galaxy-export`，退出 Docker 或重启电脑后状态保留。
- 提供 Windows GUI 应用程序启动器：检查 Docker、可选执行 `docker login`、首次构建镜像、后续直接启动容器、等待 Galaxy 就绪、打开登录页并自动关闭启动器。
- 启动器、工具管理和日志窗口都不再依赖可见命令提示符窗口。
- 提供工具管理界面：从 Galaxy Tool Shed 搜索官方工具仓库，勾选后通过 Galaxy 官方 API 增量安装，取消勾选后增量卸载。
- `tools.selected.json` 保存当前选择，`tool_list.yml` 由 `scripts/Update-ToolList.ps1` 从 Galaxy Tool Shed 拉取最新可安装 revision 生成。

## 默认登录信息

- 地址：`http://localhost:8080`
- 账号：`admin@example.org`
- 密码：`password`

首次部署后建议在 Galaxy 页面内修改管理员密码，或先编辑 `.env` 里的 `GALAXY_ADMIN_PASSWORD` 再首次启动。

## 一键启动

Windows：

```powershell
双击 Start-Galaxy.exe
```

macOS/Linux：

```bash
bash start-galaxy.sh
```

如果修改了启动器外壳源码，可重新生成 Windows 应用程序：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Launcher.ps1
```

第一次启动会拉取基础镜像、安装 Tool Shed 工具和 Conda 依赖，可能需要较长时间和较大磁盘空间。后续启动会复用已构建镜像和持久化数据。

`quay.io/bgruening/galaxy:26.0` 是公开镜像，通常不需要 Docker Registry 登录。启动器里的 `Docker login` 只在你的网络或镜像源策略要求登录时使用；登录成功后启动器会自动关闭。

## 自助添加或移除工具

双击 `Start-Galaxy.exe` 后点击 `Tools`：

- 在搜索框输入工具名，例如 `kraken2` 或 `seqsero2`。
- 点击 `Search Tool Shed`，界面会从 Galaxy Tool Shed 拉取匹配的官方仓库列表。
- 勾选要加入 Galaxy 的工具；取消勾选已选工具，会从运行中的 Galaxy 卸载。
- 点击 `Save selection` 只保存选择并重写 `tool_list.yml`。
- 点击 `Save and apply` 会保存选择、启动容器，并通过 Galaxy API 只安装新增工具、只卸载取消勾选的工具。

注意：首次镜像不存在时仍会构建一次，并按 `tool_list.yml` 安装当前选择的工具。之后工具选择变更不需要重建镜像，已安装且仍被勾选的工具不会重新下载安装；只有新增工具及其依赖会下载，取消勾选的工具会通过 Galaxy API 卸载。

## 停止与保留状态

在启动器里点 `Stop`，或执行：

```powershell
docker compose stop
```

这样只会停止容器，数据、用户、历史记录、工具配置都会留在 Docker volume 中。不要执行下面这些命令，除非你明确想清空状态：

```powershell
docker compose down -v
docker volume rm local-usegalaxy_galaxy-export
```

## 已安装工具

核心工具覆盖：

- FastQC、fastp
- SPAdes
- BWA
- Samtools 常用 wrapper：view、sort、fastx、merge、fixmate、markdup、collate、depth、coverage、mpileup、flagstat、stats、idxstats
- iVar wrapper：trim、consensus、variants、filtervariants、removereads、getmasked
- NCBI BLAST+
- MAFFT
- Snippy
- Gubbins
- Kraken2
- SeqSero2

如需刷新到当前 Tool Shed 最新可安装 revision：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Update-ToolList.ps1
```

刷新 revision 不会强制重装已安装工具。需要安装新勾选工具时，在启动器中点击 `Tools`，再点击 `Save and apply`。

## 常用配置

首次启动会从 `.env.example` 自动复制出 `.env`。常改项：

```dotenv
GALAXY_BASE_IMAGE=quay.io/bgruening/galaxy:26.0
GALAXY_PORT=8080
GALAXY_ADMIN_EMAIL=admin@example.org
GALAXY_ADMIN_PASSWORD=password
GALAXY_ADMIN_API_KEY=local-usegalaxy-admin-key
```

如果 8080 端口被占用，修改 `GALAXY_PORT` 后重新启动即可。

## 自检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-Project.ps1
```

如果当前机器没有 Docker，自检会跳过 Docker 构建，只检查项目文件和 PowerShell 语法。

## 官方依据

- Galaxy Docker 镜像与用法：https://bgruening.github.io/docker-galaxy/
- 官方扩展镜像和 `install-tools` 方法：https://bgruening.github.io/docker-galaxy/extending-the-docker-image.html
- Galaxy Tool Shed：https://toolshed.g2.bx.psu.edu/

