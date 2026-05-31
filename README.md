# 本项目完全由Codex编写

# 本地 Galaxy 生信分析平台

这个项目用 Galaxy 官方社区 Docker 镜像部署本地 Galaxy，并在镜像构建阶段通过 Tool Shed 安装常用生信工具。Windows 用户双击 `Start-Galaxy.exe` 即可打开启动器；只要电脑已经安装 Docker Desktop/Engine，就可以一键构建、启动并打开 Galaxy 登录页。

## 已实现

- 使用 `quay.io/bgruening/galaxy:26.0` 作为基础镜像，并用官方 `install-tools` 方式扩展工具。
- 用 Docker Compose 启动 Galaxy，Web 端口默认是 `http://localhost:8080`。
- `/export` 挂载到命名卷 `local-usegalaxy_galaxy-export`，退出 Docker 或重启电脑后状态保留。
- 提供 Windows GUI 应用程序启动器：检查 Docker、首次构建镜像、后续直接启动容器、等待 Galaxy 就绪、打开登录页并自动关闭启动器。
- 启动器、工具管理和日志窗口都不再依赖可见命令提示符窗口。
- 启动器会显示当前 Galaxy 容器状态，例如 `running`、`exited`、`starting`，Docker Compose 的正常状态进度不会再弹成错误。
- 提供工具管理界面：从 Galaxy Tool Shed 搜索官方工具仓库，勾选并点击 `Apply changes` 后通过 Galaxy 官方 API 增量安装，取消勾选后增量卸载。
- 提供 `Clear data` 清理功能：删除并 purge Galaxy 历史记录、数据集、输出文件，清理 Docker volume 里的实际数据文件和任务临时目录，并取消仍在运行的任务；不删除已安装工具。
- 提供 `Compact disk` 压缩功能：清理数据后可停止 Galaxy、关闭 Docker Desktop/WSL，并压缩 Docker Desktop 的 VHDX 虚拟磁盘，把已释放空间尽量还给 Windows；不删除镜像、容器、卷、Galaxy 数据或已安装工具。
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

如果启动器检测不到 Docker，会询问是否打开 Docker Desktop 下载页：https://www.docker.com/get-started/

## 自助添加或移除工具

双击 `Start-Galaxy.exe` 后点击 `Tools`：

- 在搜索框输入工具名，例如 `kraken2` 或 `seqsero2`。
- 点击 `Search Tool Shed`，界面会从 Galaxy Tool Shed 拉取匹配的官方仓库列表。
- 勾选要加入 Galaxy 的工具；取消勾选已选工具，会从运行中的 Galaxy 卸载。
- 点击 `Apply changes` 会保存选择、启动容器，并通过 Galaxy API 只安装新增工具、只卸载取消勾选的工具。

注意：首次镜像不存在时仍会构建一次，并按 `tool_list.yml` 安装当前选择的工具。之后工具选择变更不需要重建镜像，已安装且仍被勾选的工具不会重新下载安装；只有新增工具及其依赖会下载，取消勾选的工具会通过 Galaxy API 卸载。

## 清理任务和文件

启动器中点击 `Clear data` 会先二次确认，然后通过 Galaxy API 清理历史记录、数据集、输出文件，并取消仍在排队或运行的任务。随后它会进入容器清理 `/export/galaxy/database/files`、`/export/galaxy/database/job_working_directory`、`/export/galaxy/database/tmp` 和 `/export/galaxy/database/object_store_cache` 里的实际文件。这个功能不会调用 Tool Shed 仓库删除接口，也不会删除 `/export/galaxy/database/shed_tools`，因此已安装工具会保留。

本项目的数据保存在 Docker named volume `local-usegalaxy_galaxy-export` 中，容器内路径是 `/export`。Docker 报告的卷挂载点通常是 `/var/lib/docker/volumes/local-usegalaxy_galaxy-export/_data`；在 Windows Docker Desktop 上它位于 Docker 的 Linux/WSL 虚拟磁盘中，而不是项目目录。清理后空间会先在 Docker 卷内释放并可被 Docker 复用；如果 Windows 资源管理器里的可用空间没有立刻变多，通常是 Docker Desktop 的虚拟磁盘还没有压缩。

Docker Desktop 的虚拟磁盘不能在 Galaxy 运行清理时同步压缩：清理历史需要容器运行，而压缩 `docker_data.vhdx` 或 `ext4.vhdx` 需要停止 Docker Desktop/WSL。需要把 C 盘可用空间真正还给 Windows 时，先点击 `Clear data`，再点击 `Compact disk`。压缩过程可能请求管理员权限，会停止当前机器上的 Docker Desktop/WSL；它只压缩虚拟磁盘文件，不删除 Docker 镜像、容器、卷、Galaxy 数据或已安装工具。压缩完成后 Docker 会保持停止状态，下次点击 `Start and open login` 会按原状态继续启动容器。

也可以先用 dry run 预览：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Clear-GalaxyData.ps1 -DryRun
```

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

刷新 revision 不会强制重装已安装工具。需要安装新勾选工具时，在启动器中点击 `Tools`，再点击 `Apply changes`。

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
