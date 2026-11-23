# Windows 本地部署

这台电脑上的 eLabFTW 使用 WSL2 Ubuntu-24.04 和普通用户 Bubblewrap。网页入口是 [https://127.0.0.1:8080](https://127.0.0.1:8080/)。首次使用时，打开 [注册页](https://127.0.0.1:8080/register.php) 创建系统管理员。浏览器会显示自签证书提示，可以在本地检查时用运行目录中的 `tls/cert.pem` 验证连接。

## 启停

在仓库根目录的 PowerShell 中运行。

```powershell
powershell.exe -NoProfile -File .\containers\local\elabftw.ps1 -Action Start
powershell.exe -NoProfile -File .\containers\local\elabftw.ps1 -Action Status
powershell.exe -NoProfile -File .\containers\local\elabftw.ps1 -Action Stop
```

`Start` 在后台保留一个 WSL 客户端，并等待 HTTPS 和数据库健康检查通过。Windows 重启后可再次执行 `Start`。正常停止通过 MySQL 的管理连接关闭数据库。

## 数据和诊断

WSL 的运行目录默认为 `~/.local/share/elabftw-local`。配置了 `XDG_DATA_HOME` 的会话使用对应目录下的 `elabftw-local`。

| 路径 | 内容 |
| --- | --- |
| `mysql/` | MySQL 数据目录 |
| `uploads/`、`exports/` | 附件和导出文件 |
| `secrets/`、`tls/` | 数据库凭据、应用加密密钥和本地 HTTPS 证书 |
| `logs/` | `service.log`、`web.log`、`mysql.log` |
| `images/`、`tools/` | 解包后的镜像和 Bubblewrap |

网页和 MySQL 分别绑定 WSL 的 `127.0.0.1:8080` 和 `127.0.0.1:13306`。nginx 通过容器内 Unix socket 访问 PHP-FPM。可以访问 [Web 健康检查](https://127.0.0.1:8080/healthcheck) 和 [数据库健康检查](https://127.0.0.1:8080/healthcheck.php)。启动时只对空库安装表结构。遇到与固定镜像不匹配的表结构或缺少初始数据的数据库，脚本会保留数据并停止。结构升级需要单独安排。

需要做冷备份时，先用 `Stop` 正常关停，再一起备份 `mysql/`、`uploads/`、`exports/`、`secrets/` 和 `tls/`。恢复到新实例后，应另外验证登录、记录和附件。具体已验证项目见 [验证记录](VERIFICATION.md)。

## 重新准备镜像

现有实例的运行文件已就绪。以下步骤用于准备新的 WSL 运行目录。应用和数据库镜像均固定到 `linux/amd64` 平台摘要。

在 Windows PowerShell 中下载并校验 crane，再导出镜像。

```powershell
$stage = Join-Path $env:TEMP ('elabftw-oci-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$archive = 'go-containerregistry_Windows_x86_64.tar.gz'
gh release download v0.22.1 --repo google/go-containerregistry --pattern $archive --dir $stage
if ($LASTEXITCODE -ne 0) { throw 'crane download failed' }
$tarball = Join-Path $stage $archive
$expected = '0e073ea8192c3b8442ec8aaf44d53c1050a09084669fae3a6ceb0f2026cf8b21'
if ((Get-FileHash $tarball -Algorithm SHA256).Hash -ne $expected) { throw 'crane archive checksum mismatch' }
tar.exe -xzf $tarball -C $stage crane.exe
if ($LASTEXITCODE -ne 0) { throw 'crane extraction failed' }
$crane = Join-Path $stage 'crane.exe'
& $crane export --platform linux/amd64 'index.docker.io/elabftw/elabimg@sha256:582c5c48cbcef3c4c2d8ecbc22950aedd9131ce031f5eb98b368557a34ae7a88' (Join-Path $stage 'elabftw.tar')
if ($LASTEXITCODE -ne 0) { throw 'eLabFTW export failed' }
& $crane export --platform linux/amd64 'index.docker.io/library/mysql@sha256:72c368d898861f3b3a07af0e6d690400f44f048799ed46822783d9224cc2c86d' (Join-Path $stage 'mysql.tar')
if ($LASTEXITCODE -ne 0) { throw 'MySQL export failed' }
$stage
```

在 Ubuntu-24.04 中将 `stage` 换成上一步输出的 Windows 目录，再准备普通用户运行文件。以下命令需要 WSL 用户命名空间以及可写的 Linux 文件系统。

```bash
(
set -e
umask 077
stage="$(wslpath -u 'C:\path\to\elabftw-oci-directory')"
runtime="${XDG_DATA_HOME:-$HOME/.local/share}/elabftw-local"
for existing in tools/bwrap images/elabftw images/mysql; do
    test ! -e "$runtime/$existing" || { printf 'Already exists %s\n' "$runtime/$existing"; exit 1; }
done
mkdir -p "$runtime"/{tools,images}
toolstage="$(mktemp -d "$runtime/tools/bubblewrap.XXXXXXXX")"
(
    cd "$toolstage"
    apt-get download bubblewrap
    dpkg-deb -x ./*.deb extracted
)
ln -s "$toolstage/extracted/usr/bin/bwrap" "$runtime/tools/bwrap"
for image in elabftw mysql; do
    dest="$(mktemp -d "$runtime/images/.$image.XXXXXXXX")"
    tar --extract --no-same-owner --no-same-permissions --delay-directory-restore \
        --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' \
        --file "$stage/$image.tar" --directory "$dest"
    mv -T --no-clobber "$dest" "$runtime/images/$image"
done
)
```

版本依据见 [crane 发布记录](https://github.com/google/go-containerregistry/releases/tag/v0.22.1)、[上游 nightly 构建](https://github.com/elabftw/elabftw/actions/runs/45149886816) 和 [eLabFTW 首次安装说明](../../documentation/docs/install/installation/4-start.md)。
