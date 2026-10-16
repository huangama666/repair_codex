# Codex 代理配置助手

为 Windows 和 macOS 检测本地 HTTP / 混合代理，预览并备份 Codex `.env` 配置，支持恢复上次修改。

**[查看完整使用说明：read.md](read.md)**

下载整个仓库并解压后：

- Windows 双击 `Start-Windows.cmd`。
- macOS 双击 `Start-macOS.command`，或在终端运行 `zsh ./Start-macOS.command`。

工具提供简单原生界面，也可用命令行自动配置。无需安装 Python 或 Node；测试代码的运行环境另见 [read.md](read.md)。

只维护 Codex 的 `.env` 和备份，不修改系统代理或其他软件设置。写入后请完全退出并重新打开 Codex，再验证重连是否消失。

已通过 41 项核心与互通测试。Windows 图形界面、Windows PowerShell 5.1、Windows ACL 和监听进程查询尚需 Windows 真机验证；检测通过不保证解决所有重连问题。

[测试记录](VERIFICATION.txt) · [MIT 许可证](LICENSE)
