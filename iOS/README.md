# 拾页 Apple 平台开发版

共享 Xcode 工程 `Shiye.xcodeproj` 包含 `ShiyePhone` 和 `ShiyeMac` 两个 Scheme。版本 1.0，构建号 2026111404。iPhone 要求 iOS 17+，Mac 要求 macOS 13+。

两端共享网页界面及 Core Data / CloudKit 资料库。分组、网站、图文笔记和文件按记录同步，删除使用墓碑标记，离线编辑按显示基线合并。需要设备登录同一 Apple 账户并开启 iCloud。同步到达时间受网络、CloudKit 推送和系统后台调度影响。

Bundle ID 为 `com.shangweiqiu.shiye`，CloudKit 容器为 `iCloud.com.shangweiqiu.shiye`。通过 Xcode 自动签名构建。模拟器默认关闭云同步，可用环境变量 `SHIYE_SIMULATOR_CLOUD_ENABLED=1` 开启。

已通过两端开发签名构建和本机资料库回归测试，iPhone 17 Pro Max 已安装并启动。已在 iPhone 17 Pro Max 与 Mac 开发版验证双向新增及标题、评级修改自动同步。删除和离线冲突恢复尚待实机验证。旧 Mac 应用数据通过已有加密备份导入新应用，导入时保留本机独有记录。旧 iOS 原型的 `shiye-ios.json` 尚无自动迁移。

CloudKit 生产架构及 Apple 默认角色权限已获用户明确授权并完成部署。iOS 与 macOS 的 1.0（2026111403）已归档并成功上传 App Store Connect，商店名称为“拾页 · 收藏与笔记”。内部 TestFlight 测试与正式上架分别推进，商店资料、隐私申报和审核仍待完成。

大文件改为 8 MiB 二进制分块，网页使用 1 MiB 桥接分片，日常快照仅传文件元数据。新 `.shiye` 加密备份流式读写，继续支持旧 `.json` 备份导入。新格式需要本次新版读取。测试范围见 [大文件测试报告](../AppStore/TESTING-20261114.md)。
