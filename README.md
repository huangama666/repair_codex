# Codex 代理配置助手

当 Codex 反复显示“正在重连 1/5…5/5”，而电脑上已经运行 Clash、Clash Verge、v2rayN 等代理软件时，可以用这个工具检查本机代理端口，并将代理设置写入 Codex 的 `.env`。

工具提供 Windows 和 macOS 原生界面，支持检测、预览、自动备份和恢复。它只处理本地代理配置；网络、账号、服务状态等其他原因引起的重连，仍需另行排查，不能保证所有重连问题都能解决。

## 下载

打开 [repair_codex 仓库](https://github.com/huangama666/repair_codex)，点击绿色 **Code → Download ZIP**，下载后完整解压。

也可以使用 Git：

```sh
git clone https://github.com/huangama666/repair_codex.git
cd repair_codex
```

请保留同一目录内的四个程序文件：

- `Start-Windows.cmd` 和 `CodexProxy.ps1`：Windows 入口和核心脚本。
- `Start-macOS.command` 和 `CodexProxyMac.pl`：macOS 入口和核心脚本。

运行时不需要安装 Python、Node 或第三方依赖。Windows 使用系统自带的 Windows PowerShell 和 WinForms；macOS 使用系统自带的 zsh、Perl 和 AppleScript。

## 双击使用

先启动代理软件，确认它已开启 **HTTP 或混合（mixed）代理端口**。只有 SOCKS 端口时不能直接使用。

### Windows

1. 双击 `Start-Windows.cmd`。
2. 点击“检测本机代理”，选择通过检测的端口；也可以手填代理软件显示的 HTTP / mixed 端口。
3. 点击“预览配置”，核对目标文件和端口。
4. 点击“确认写入预览配置”，在确认框中同意后才会写入。

### macOS

1. 双击 `Start-macOS.command`。
2. 选择“检测并配置代理”。
3. 选择通过检测的端口，或选择“手动输入端口”。
4. 查看配置预览，点击“确认”后写入。

如果双击未能启动，在终端进入解压目录后运行：

```sh
zsh ./Start-macOS.command
```

默认流程都会先展示配置并等待确认。检测、预览和取消不会修改 Codex 配置，也不会创建配置备份。

## 一条命令自动配置

先在命令行进入包含启动器的目录。以下命令会自动选择第一个通过检测的端口，展示配置、备份并写入：

Windows（PowerShell 或 CMD）：

```powershell
.\Start-Windows.cmd -Action apply -Yes
```

macOS（终端）：

```sh
zsh ./Start-macOS.command --cli --yes
```

`-Yes` / `--yes` 表示明确授权本次跳过交互确认。希望看完预览再决定，去掉这个参数即可。发现多个可用端口时，自动配置使用第一个；需要其他端口，请在界面选择或手动指定。

## 只检测、只预览、指定端口

下面的 `7897` 是示例，请换成代理软件实际显示的 HTTP / mixed 端口。

Windows：

```powershell
# 只检测
.\Start-Windows.cmd -Action detect

# 只预览
.\Start-Windows.cmd -Action preview -Port 7897

# 指定端口，预览后等待确认
.\Start-Windows.cmd -Action apply -Port 7897
```

macOS：

```sh
# 只检测
zsh ./Start-macOS.command --detect

# 只预览
zsh ./Start-macOS.command --preview --port 7897

# 指定端口，预览后等待确认
zsh ./Start-macOS.command --apply --port 7897
```

检测会检查常见端口，以及可查询到的代理进程监听端口。工具连接 `127.0.0.1`，发送不含凭据的 `CONNECT chatgpt.com:443` 请求；只有收到 HTTP 200 才会将端口视为可用。需要认证的代理、SOCKS-only 端口和仅 TCP 开放的服务不会被自动采用。

未检测到可用端口时，先查看代理软件是否启动、HTTP / mixed 端口是否开启。不要随意猜一个端口写入。

## 恢复上次修改

Windows 界面点击“恢复最近一次配置”；macOS 菜单选择“恢复上次修改”。也可以运行：

Windows：

```powershell
.\Start-Windows.cmd -Action restore
```

macOS：

```sh
zsh ./Start-macOS.command --restore
```

恢复前会显示目标文件并等待确认。需要跳过这次确认时，再加 `-Yes` / `--yes`。

- 原先有 `.env`：恢复该次修改前的完整原文件，按原始字节还原。
- 原先没有 `.env`：删除本工具创建的 `.env`，恢复为原先不存在的状态。
- 配置后又被其他程序或你自己修改过：停止恢复，保留后续改动，并提示查看备份手动合并。

每次恢复撤销最近一次尚未恢复的有效修改，可以连续运行逐次撤销。重复应用完全相同的配置不会增加备份。

## 配置位置和修改范围

默认目标文件：

- Windows：`%USERPROFILE%\.codex\.env`
- macOS：`~/.codex/.env`

如果设置了环境变量 `CODEX_HOME`，使用该目录中的 `.env`。也可以在命令中传入 `-ConfigHome "目录"`（Windows）或 `--config-home "目录"`（macOS），其优先级高于 `CODEX_HOME`。配置和恢复时应使用同一个目录。

工具只管理以下三个变量，端口会替换为所选值：

```dotenv
HTTP_PROXY=http://127.0.0.1:7897
HTTPS_PROXY=http://127.0.0.1:7897
NO_PROXY=localhost,127.0.0.1,::1
```

同名变量的大小写变体和 `export` 写法会被合并，其他配置和已有注释会保留。工具不会修改系统代理、代理软件设置、注册表、shell 启动文件、Codex 的 `config.toml` 或账号信息，也不会自动退出应用。

## 备份和保护

备份保存在所用配置目录的 `proxy-helper-backups/日期-随机值/` 中。原文件存在时保存 `original.env`；`manifest.json` 记录原文件是否存在、修改前后校验值及恢复状态。请保留整个备份目录。

写入前会复核 `.env` 是否与预览时一致。发现预览后发生变化、存在其他写入操作、路径是符号链接/重解析点，或备份校验失败时，工具会停止相关操作。

如果提示存在 `proxy-helper.lock`，先确认没有另一个助手进程仍在运行。只有确认是异常退出留下的旧锁后，才删除配置目录中的该锁目录并重试；不要删除备份目录。

Windows 启动器的 `-ExecutionPolicy Bypass` 只作用于本次 PowerShell 子进程，不会永久修改执行策略。组织策略仍可能阻止运行，不需要为此关闭系统安全保护。

## 配置后怎么验证

1. 等待正在进行的任务结束。
2. 完全退出 Codex 所在应用。macOS 可用 `⌘Q`；Windows 请确保应用进程退出，不能只关闭可能驻留后台的窗口。
3. 重新打开应用，新建任务并发送消息，观察是否仍然重连。

“HTTP CONNECT 检测通过”只说明这次代理隧道请求被接受；“配置已写入”只说明本地文件修改成功。应用是否读取配置、登录和模型请求是否正常，以及持续连接是否恢复，都需要重启后实测。

## 兼容性与验证范围

目标平台为 Windows 10/11（Windows PowerShell 5.1）和 macOS。验证记录日期为 **2026-10-16**：

- **Windows 核心 23 项通过**：在 macOS 26.4.1 上，通过 Microsoft 官方 PowerShell 7.6.6 便携运行时执行。
- **macOS 核心 13 项通过**：在 macOS 26.4.1 上，使用系统 zsh 和 Perl 执行。
- **跨平台恢复 5 项通过**：覆盖双方写入后由另一方恢复、原文件不存在、UTF-8 BOM / CRLF，以及 Windows UTF-16 备份恢复。

合计 **41 项核心与跨平台测试通过**。测试使用隔离目录和模拟代理，没有改动真实 Codex `.env`。macOS 原生菜单可以启动，5 段 AppleScript 通过编译检查，尚未完成完整截图验收。

**尚未在 Windows 真机验证**：Windows PowerShell 5.1、WinForms 窗口交互、Windows ACL 和监听进程查询。PowerShell 7.6.6 上的核心测试通过，不等于这些 Windows 行为已经验收。

文件格式方面：

- Windows 保留 UTF-8 BOM、UTF-16 BOM 和原换行；遇到带引号的多行值或未闭合引号时拒绝编辑，保留原文件。UTF-32、无 BOM UTF-16 等含 NUL 的不支持格式也会拒绝编辑。
- macOS 保留 UTF-8 BOM、CRLF / LF / CR 换行和带引号的多行值；拒绝编辑包含 NUL 的文件，包括 UTF-16。**恢复按原字节进行，仍可恢复兼容清单格式的 Windows UTF-16 备份。**
- 两个平台使用相同的备份清单格式，恢复前会核对原始备份的校验值。

更具体的已测场景见仓库中的 `VERIFICATION.txt`。

## 复跑测试

以下依赖仅供开发测试，运行工具本身不需要 Python 或额外的 PowerShell 运行时。

Windows 核心测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Windows.ps1
```

macOS 核心测试（需要 Python 3）：

```sh
python3 -m unittest discover -s tests -p test_mac.py -v
```

macOS 上安装了 PowerShell 7 且 `pwsh` 在 PATH 中时，还可运行 Windows 核心与互通测试：

```sh
pwsh -NoLogo -NoProfile -File tests/Test-Windows.ps1
python3 -m unittest discover -s tests -p test_cross.py -v
```

也可用 `CODEX_TEST_PWSH` 指向用于测试的 `pwsh` 可执行文件。缺少运行条件时，互通测试会明确标为跳过；不会自动安装依赖。测试使用临时目录，不要把个人 `.env` 或备份上传到仓库。

## 配置方式参考

OpenAI 在桌面应用与 IDE 的 Bedrock 配置说明中，提到使用 `.codex/.env` 提供环境变量，并在修改后重启。该说明针对 Bedrock 变量，并不保证所有版本的所有请求都使用本工具写入的 HTTP(S) 代理变量。

- [桌面应用与 IDE 的 .env 说明](https://learn.chatgpt.com/docs/amazon-bedrock#desktop-app-and-ide-extension)
- [CODEX_HOME 与环境变量](https://learn.chatgpt.com/docs/config-file/environment-variables#core-locations)

项目沿用仓库中的 [MIT 许可证](LICENSE)。
