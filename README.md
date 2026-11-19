# Syncthing → 懒猫微服

为懒猫官方商店的 `cloud.lazycat.app.syncthing1` 自动构建更新。工作流每天北京时间 12:41 检查 `syncthing/syncthing` 的稳定 Git 标签，使用对应的官方 GHCR 镜像和 GitHub Release 更新说明。发现可更新版本后，由 `wcaqrl/lazycat-action@v1` 转存镜像、构建 LPK、记录发布状态、提交审核并上传版本化 `.lpk` 到 GitHub Release。

## 配置和运行

1. 在本仓库配置 Actions Secret `LZC_API_TOKEN`。对应的懒猫开发者账号需要是 `cloud.lazycat.app.syncthing1` 的开发者或协作者。
2. 在 Actions 打开 **Update Syncthing for LazyCat**，选择 **Run workflow**。保留 `dry-run` 勾选时仅检查版本。准备正式送审时取消勾选。
3. 推送到 `main` 触发只读检查。定时任务按当前工作流配置自动处理更新。审核拒绝后修复问题，再手动使用 `retry-rejected`。

## 升级兼容性

- 原商店 LPK 是 `2.0.11`，包内实际运行的是 Syncthing `2.0.10`。`package.yml` 使用商店版本作为比较基线。
- LPK v2 要求懒猫系统 1.5.0 或以上。适配器沿用原包的 `linux/amd64` 镜像架构、`syncthing` 子域名和多实例部署。现用字段为 `multi_instance: true`。
- 原有 `/lzcapp/var/conf:/var/syncthing` 挂载继续存放配置、索引、设备证书和同步文件。有效 UID/GID 仍为 `0:1000`，以便读取旧实例已有的文件。
- 管理界面通过微服登录保护的 HTTP 入口打开。旧实例自行配置的 Syncthing GUI 密码保留。TCP `22000` 仅用于 Syncthing 设备之间的同步，手动配置对端时使用启动器分配给当前实例的域名。
- 正式打包脚本使用固定摘要的官方公开 `2.0.10` 镜像建立升级测试数据。该镜像与旧包镜像的文件层和运行设置一致，测试沿用旧包的环境变量。随后用所选候选镜像接管同一测试卷，检查设备 ID、配置、文件、索引和管理页。测试容器不联网，也不访问用户目录。

本地可用 `bash scripts/test-upgrade.sh <带摘要的官方候选镜像>` 重现升级检查。正式打包时，脚本从 Manifest 的镜像来源注释读取候选镜像。

参考 [懒猫 LPK v2 规范](https://developer.lazycat.cloud/spec/lpk-format.html)、[多实例](https://developer.lazycat.cloud/advanced-multi-instance.html) 和 [Syncthing 官方容器文档](https://github.com/syncthing/syncthing/blob/main/README-Docker.md)。
