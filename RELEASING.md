# FolderBeacon 站外发布

发布产物统一放在项目的 `dist/<版本>-<构建号>/` 中；`dist/` 已加入 `.gitignore`。每个版本目录包含 DMG、Apple 公证结果和 SHA-256 校验文件。打包暂存目录是 `dist/.release.*`，脚本结束后会清理。桌面无需参与打包。

## 一次性准备

1. 在 Xcode 中配置本项目的 Apple Developer 团队与 Developer ID Application 签名。脚本需要本机钥匙串中有团队 `AKDDZQLVBL` 的证书和对应私钥。
2. 保存公证凭据到钥匙串（只需一次）：

   ```zsh
   xcrun notarytool store-credentials FolderBeaconNotary
   ```

   按终端提示输入 Apple 账号与 App 专用密码，或 App Store Connect API key。不要把密钥或密码放进仓库。
3. Sparkle 更新签名私钥已经保存在本机钥匙串，账户名为 `com.yanlongchen.folderbeacon`；公钥在 `Config/Info.plist`。换电脑发布前必须安全迁移私钥，不要把私钥加入仓库。可用 `dist/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account com.yanlongchen.folderbeacon -p` 核对公钥。

## 配置更新地址

确定 Cloudflare 域名后，填写 `scripts/UpdateFeed.plist`：

- `feedURL`：Pages 或 R2 上固定的 HTTPS `appcast.xml` 地址，例如 `https://example.com/appcast.xml`。
- `downloadURLPrefix`：DMG 所在目录的 HTTPS 地址，以 `/` 结尾，例如 `https://downloads.example.com/releases/`。

这些只是格式示例，不能直接用于发布。域名未定时保持两个值为空；发布脚本会拒绝从源码构建一个无法检查更新的正式版本。

## 每次升级

1. 在 Xcode 更新 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，完成版本测试。
2. 在项目根目录运行：

   ```zsh
   ./scripts/release.sh
   ```

   脚本依次执行 Release 归档、Developer ID 导出、签名检查、生成含 `FolderBeacon.app` 与 `Applications` 快捷方式的 DMG、DMG 签名、公证、附加票据、生成 Sparkle 签名的 `appcast.xml` 和校验。

3. 先把 `dist/FolderBeacon-<版本>-<构建号>/` 中的 `.dmg` 上传到 `downloadURLPrefix` 对应的路径，确认公开 URL 可下载；再把 `appcast.xml` 上传到 `feedURL` 对应的固定地址。先发 DMG，后更新 feed，可避免用户收到更新提示时遇到 404。
4. 在另一台 Mac 下载、打开 DMG，测试拖动安装和首次启动；再用已安装的旧版测试菜单栏的“检查更新…”。Sparkle 默认在第二次启动时询问是否允许自动检查更新，此后通常每 24 小时检查一次。

如果已从 Xcode Organizer 导出公证 App，可跳过重新归档：

```zsh
./scripts/release.sh --app "/完整路径/FolderBeacon.app"
```

这个模式依然会对新 DMG 单独签名、公证。如果更新地址已配置，导出的 App 必须使用相同的更新地址，脚本才会生成 appcast。若钥匙串中有多个同团队 Developer ID 证书，可加 `--identity "Developer ID Application: 名称 (AKDDZQLVBL)"` 指定。

脚本不会覆盖已有版本目录。若发布失败，查看终端错误；公证被拒时脚本会请求 Apple 的详细日志。`dist/` 是本地构建产物，建议将最终 DMG 和校验值上传到 GitHub Releases 或其他正式下载渠道留档。

已经安装的旧版 App 没有 Sparkle，无法收到更新提醒。首次包含 Sparkle 的版本需要用户手动安装；后续版本才能通过 App 内更新。
