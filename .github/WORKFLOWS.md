# Python 3.8 构建

本分支保留版本号 `12.3.0`，包含针对 Python 3.8 的修复。

在 GitHub 仓库的 **Actions → Build Python 3.8 wheels → Run workflow** 中选择分支并运行。
向 `main`、`codex/**` 分支推送代码，或向 `main` 提交 PR 时，也会自动运行。
工作流只构建、测试并上传 Actions artifacts，不创建 Releases，也不上传 PyPI。

## 构建产物

| Actions artifact | 目标系统 | Python | 架构 |
| --- | --- | --- | --- |
| `pyav-12.3.0-cp38-windows-x64` | Windows 7 SP1、Windows 10 | CPython 3.8，64 位 | x64 |
| `pyav-12.3.0-cp38-linux-x86_64` | Ubuntu、麒麟、统信 UOS，glibc ≥ 2.17 | CPython 3.8，64 位 | x86_64 |
| `pyav-12.3.0-cp38-linux-aarch64` | Ubuntu、麒麟、统信 UOS，glibc ≥ 2.17 | CPython 3.8，64 位 | ARM64 |

FFmpeg 6.1.1 及需要随包分发的动态库会打包进 wheel，目标设备无需单独安装 FFmpeg。
Linux 使用 manylinux2014 容器构建，并通过 auditwheel 校验 glibc 2.17 基线。
ARM64 在 QEMU 下构建和执行测试。龙芯、申威、32 位系统不在此构建范围内。

## Windows 7 要求与验证范围

Windows 使用 CPython 3.8.10、MSVC 14.29，并将扩展的最低系统版本设为 Windows 7。
Windows 7 设备需要 SP1、Python 3.8 所需的系统补丁（包括 KB2533623、KB2999226），
以及支持 Windows 7 的 Visual C++ 2015–2019 x64 运行库，例如 14.29。

GitHub 托管的 Windows runner 运行 Windows Server 2022，不能直接测试 Windows 7/10。
工作流会测试安装后的 wheel，并检查扩展和全部打包 DLL 的 PE 系统版本与已知不兼容接口。
这个检查只能筛查已知问题；使用前仍应在实际 Windows 7/10 设备上验收。
Ubuntu、麒麟、统信也需要按实际发行版验收；manylinux 测试不等同于在这些系统上逐一测试。

## 下载与安装

运行成功后，在该次 Actions 页面的 **Artifacts** 下载对应架构的 ZIP 并解压。
Windows 示例：

```powershell
python -m pip install --force-reinstall --no-index .\av-12.3.0-cp38-cp38-win_amd64.whl
python -c "import av; print(av.__version__); print(av.library_versions)"
```

Linux 使用相应的 `manylinux` wheel 文件路径执行同样的安装命令。
由于版本号与官方 `12.3.0` 相同，必须明确指定下载的 wheel，并使用 `--force-reinstall`，
否则已安装的官方同版本可能不会被替换。
Artifacts 保留 30 天；需要长期保存时请下载到本地。
