# eLabFTW 工作区

本工作区包含 eLabFTW fork 源码和一套 Windows / WSL2 本地部署入口。

- 改动前先用 `git fetch` 获取目标远端分支的最新提交，比较本地与远端分支，并核对拟改文件的远端版本。远端有新改动时，先同步并处理冲突，保留已有工作。
- 改动完成并通过验证后，及时提交本次任务相关文件，推送到对应远端分支，并确认远端已收到提交。
- 本机启停、镜像准备和数据位置见 [本地部署说明](containers/local/README.md)。已执行的检查和版本依据见 [验证记录](containers/local/VERIFICATION.md)。
- 应用源码入口为 [web/](web/) 和 [src/](src/)。开发和测试入口见 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [开发环境文档](documentation/docs/contributing/installation.md)。容器运行契约见 [官方镜像目录](containers/elabimg/)。
- 本地部署脚本位于 [containers/local/](containers/local/)。数据库、上传、导出、密钥和运行日志均位于 WSL 用户的运行目录。交付记录只引用脱敏后的结果。
- 变更部署入口后，核对镜像摘要、回环监听、HTTPS、数据库健康和原数据目录重启。执行涉及数据库迁移、删除或覆盖的操作前，核对当前授权和备份。
