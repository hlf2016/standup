# Standup

原生 SwiftUI macOS 启动项管理器。

## 预览

```sh
swift run
```

## 打包为 macOS App

```sh
./package.sh
open dist/Standup.app
```

`package.sh` 会进行 Release 编译、生成 `.app` bundle，并做本机 ad-hoc 签名。该签名用于本机运行，不等于 Developer ID 公证分发。

macOS 的登录项（包括新式后台任务）由系统设置管理。Standup 提供“macOS 登录项”快捷入口；系统没有公开通用 API 枚举其他应用注册的所有登录项，因此这部分不会伪造一个不完整列表。Standup 自身的登录启动由 `SMAppService.mainApp` 管理。
