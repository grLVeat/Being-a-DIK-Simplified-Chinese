# 来源与授权范围

本仓库维护《Being a DIK》Steam 0.8.3、第 1—2 季的简体中文修订、安装工具及打包材料。安装补丁需要玩家自己的游戏；仓库不包含可独立运行的游戏。

基础汉化来自 [Vetoyi / CN_Patch.Being_A_DIK](https://github.com/Vetoyi/CN_Patch.Being_A_DIK) 的 [CN_Ver0.09](https://github.com/Vetoyi/CN_Patch.Being_A_DIK/releases/tag/CN_Ver0.09)。上游注明火鸟字幕组、ACG、Vetoyi 等翻译来源，并声明仅供交流学习、不得商用。请保留来源说明，不销售本补丁，不冒称游戏或基础汉化的原创作者。

离线发行包中的 `cache/BAD_CN_0.09.rar` 是上游发布文件的完整副本，仅改了文件名。它用于避免原链接失效，并不改变原有译文、字体、图片、音乐及其他资源的权利归属和使用条件。该文件不存放在 Git 源码仓库中；打包离线版时由维护者提供并核对 SHA-256。

本次译文修订基于游戏和既有译文，底层作品与第三方内容的权利属于各自权利人。转发、修改和纠错时请保留这些来源。上游没有覆盖全部资源的统一开源许可证，本仓库也不为游戏、上游补丁、译文数据、字体、图片和音乐授予统一开源许可。

本次新增安装器、运行时脚本与打包脚本的代码许可见 [CODE-LICENSE.txt](CODE-LICENSE.txt)，仅覆盖其中明确列出的文件。发行包保留其已有代码许可说明。

`tools/unrar/UnRAR.exe` 为 Alexander Roshal 的免费解压工具，来源为 [RARLAB](https://www.rarlab.com/rar_add.htm)。其完整许可位于 [UnRAR-license.txt](tools/unrar/UnRAR-license.txt)。此工具不适用本仓库的 MIT 代码许可。

打包脚本只校验和组合本地文件，不下载上游内容，也不重新执行游戏验证。发行包中的验证 JSON 记录的是 2026-10-03 已完成的安装器与运行时验证，范围和限制以对应报告为准；它们不代表全部剧情分支都已通关测试。
