# 本机部署验证

2026-11-23，Windows 工作区 `D:\elabftw`，WSL2 Ubuntu-24.04。

## 版本与依据

| 项目 | 核对结果 |
| --- | --- |
| fork 源码 | `master`，`89b47daed65ec40f1f4d68a9f751c5cd710b01fa` |
| eLabFTW 运行版本 | `261123-d8a796a`，PHP 8.4.28 |
| eLabFTW 镜像 | `elabftw/elabimg@sha256:582c5c48cbcef3c4c2d8ecbc22950aedd9131ce031f5eb98b368557a34ae7a88` |
| MySQL 运行版本与镜像 | 8.4.13，`mysql@sha256:72c368d898861f3b3a07af0e6d690400f44f048799ed46822783d9224cc2c86d` |
| 运行工具 | Bubblewrap 0.9.0，Ubuntu 包 `0.9.0-1ubuntu0.3`，crane 0.22.1 |

镜像由上游 nightly 构建从 `d8a796af095c9d9815f16ada066d0e35cd86e121` 生成。用 Git 比对到 fork 提交，唯一差异是 [API 文档的 Go 客户端链接](../../documentation/docs/usage/api.md)。镜像中的 `bin/init`、`src/Elabftw/Db.php`、`src/Commands/Install.php`、`web/login.php` 和 `web/register.php` 与 fork 对应文件逐字节一致。[fork 提交](https://github.com/dlam12138/elabftw/commit/89b47daed65ec40f1f4d68a9f751c5cd710b01fa) · [上游构建记录](https://github.com/elabftw/elabftw/actions/runs/45149886816)

部署核对了 [镜像构建文件](../elabimg/Dockerfile)、[Compose 示例](../elabimg/docker-compose.yml-EXAMPLE)、[启动入口](../elabimg/entrypoint/docker-entrypoint.sh)、[首次初始化](../../src/Commands/Install.php) 和 [默认品牌资源](../../src/Enums/Branding.php)。工作区入口、启停文档和实际证据按固定版本的 Agent-Native Delivery 技能整理。[技能说明](https://github.com/dlam12138/agent-native-delivery/blob/c184d4eea94c7a36ccfad83b060b02e82494a029/skills/agent-native-delivery/SKILL.md)

## 实际检查

| 检查 | 结果 |
| --- | --- |
| `bash -n` 与 PowerShell `ParseFile` | 启动入口均通过语法检查。 |
| PowerShell `Start`、`Status`、`Stop` | 启动就绪、运行状态和停止状态均验证。MySQL 日志记录正常关停。 |
| Windows HTTPS | 使用本机证书校验连接。`/healthcheck` 返回 204。`/healthcheck.php` 返回 200 和 `ok`，覆盖 nginx、PHP-FPM 和 MySQL 查询。 |
| 登录、注册和样式 | 两个页面及 `/assets/main.min.css` 返回 200。登录页有密码表单。Edge 执行注册页脚本后，实际出现注册表单和邮箱、密码字段。 |
| 网络绑定 | WSL `ss -ltn` 核对网页和 MySQL 分别监听 `127.0.0.1:8080` 与 `127.0.0.1:13306`。PHP-FPM 改用容器内 Unix socket。 |
| 数据初始化与重启 | 首次安装生成 104 张表和 1 个默认团队。停止并重启后，MySQL 实例标识、表数、默认团队和配置数据一致。启动日志记录 `Automatic initialization false`。 |
| 文件权限 | 运行目录和密钥目录为 `0700`，数据库凭据、应用加密密钥与 TLS 私钥为 `0600`。 |

Lody tester 对首次运行执行了独立的 Windows HTTPS 和回环检查。Lody reviewer 检查了空库识别、配置生成和关闭流程。改动后重新验证了 Windows 访问和数据库重启。当前启停入口见 [本地部署说明](README.md)。

## 使用范围

本次验证覆盖这台电脑的启动、页面与数据库连通性、浏览器注册表单渲染及现有数据库重启。首个系统管理员由使用者注册。真实实验数据、附件写入与备份恢复需要在投入使用前单独验收。

当前使用上游 nightly。上游发布清单步骤成功，后续漏洞扫描步骤以 137 退出。服务面向本机回环使用。[构建与扫描记录](https://github.com/elabftw/elabftw/actions/runs/45149886816)
