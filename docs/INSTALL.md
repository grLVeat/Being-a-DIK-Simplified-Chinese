# 安装、校验与卸载

## 适用范围

- Windows 64 位。
- Steam 版 Being a DIK **0.8.3**，已安装第 1 季及第 2 季 DLC（EP1—8）。
- 安装器核对游戏脚本资源指纹。第三季、其他版本及修改过目标资源包的版本不适用。

补丁不包含可独立运行的游戏。安装前退出游戏；不要在游戏运行期间安装或卸载。

## 下载与安装

1. 在[发布页](https://github.com/grLVeat/Being-a-DIK-Simplified-Chinese/releases/latest)下载 `BeingADIK_CN_0.8.3_S1-S2_20261003_OFFLINE.zip`。GitHub 自动生成的 `Source code` 压缩包不用于安装。
2. 将整个 ZIP 解压到一个新文件夹。不要直接在压缩包预览窗口中运行脚本，也不要只复制单个 `.cmd`。
3. 保留离线包的 `cache`、`payload`、`tools` 和其他随包文件；不必手动解开 `cache/BAD_CN_0.09.rar` 的两层压缩。
4. 双击 `安装汉化.cmd`（英文文件名为 `install.cmd`）。安装器会尝试查找 Steam 游戏。
5. 若需要手动指定，选择同时包含 `BeingADIK.exe`、`game` 和 `renpy` 的目录。例如：

   ```text
   X:\SteamLibrary\steamapps\common\Being a DIK\Being a DIK Seasons 1 and 2
   ```

6. 安装完成后照常从 Steam 启动游戏。双击 `检查安装.cmd`（`check.cmd`）可核对已安装文件。

完整离线版使用随包 RAR，缺失或损坏时会停止，**不会静默联网下载**。若目标游戏已装有完整且匹配的 CN0.09 基础汉化，可直接应用修订。

在线版 `BeingADIK_CN_0.8.3_S1-S2_20261003.zip` 的使用步骤相同，但需要基础汉化时通常会从原项目下载约 287 MB。原链接失效时改用完整离线版。汉化安装工具的离线能力不改变 Steam 或游戏自身的联网要求。

## 校验下载

发布页的 `.sha256` 文件记录整个 ZIP 的 SHA-256。可在 PowerShell 中执行以下命令，再与对应校验文件比较：

```powershell
Get-FileHash -LiteralPath "X:\Downloads\BeingADIK_CN_0.8.3_S1-S2_20261003_OFFLINE.zip" -Algorithm SHA256
```

2026.10.03 版校验值：

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `BeingADIK_CN_0.8.3_S1-S2_20261003_OFFLINE.zip` | 288458480 | `35c869228dd2b6bdbcbbf060aafdecd34a96d7a8bb2e1fc591a69e72aeba6672` |
| `BeingADIK_CN_0.8.3_S1-S2_20261003.zip` | 1643646 | `cd78d7edbef7ed1ed825734dc2616daae55e669ebca8f0007989f88c4855247d` |

安装器还会检查基础 RAR、目标游戏资源及修订文件。SHA-256 用于比对文件是否一致，不是数字签名。

## 备份、卸载与重装

安装器将需要覆盖的文件保存到游戏目录的 `.badik-cn-community`。**请保留该目录**，不要把它与补丁一起发给其他人。

退出游戏，双击 `卸载汉化.cmd`（`uninstall.cmd`），即可恢复安装前状态：安装前是英文便恢复英文；安装前已有旧汉化便恢复旧汉化。备份及冲突副本会保留。安装后被其他工具或手动修改过的文件，会先保存到 `.badik-cn-community/conflicts/` 下再恢复。

同版完整安装可重复执行。若安装后的文件又发生变化，重装会停止，按提示先卸载再安装。遇到中断、文件占用或备份损坏时，请保留 `.badik-cn-community` 与提示信息，参考[常见问题](FAQ.md)；不要靠删除备份绕过检查。

安装器不修改或转换玩家存档。旧存档中已记录的历史内容不保证全部回溯改写。游戏升级前建议先卸载补丁，并重新确认新版本兼容性。

## 手动指定目录

在完整解压后的补丁目录打开 PowerShell：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\installer.ps1 -Action Install -GamePath "X:\SteamLibrary\steamapps\common\Being a DIK\Being a DIK Seasons 1 and 2"
```

将 `Install` 改为 `Check` 或 `Uninstall` 可检查或卸载。`-ArchivePath "X:\Archives\BAD_CN_0.09.rar"` 可指定同版原始基础 RAR；不必先解压或重命名。自动化可加 `-NonInteractive`，缺少必要信息或失败时会以非零状态码退出。
