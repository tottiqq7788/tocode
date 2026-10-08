# Mac 端工作约定

本目录是 Tocode 的 macOS 菜单栏应用，独立 git 仓库。治理不在本仓。

## 权威入口

- 治理清单：`../governance/architecture/governance.json`
- 语义地图：`../governance/architecture/traceability/semantic-map.json`
- 架构合同：`../governance/architecture/contracts/`
- 工作包：`../governance/architecture/work-packages/`
- 证据：`../governance/architecture/evidence/`

## 开发前准入

任何可能改变业务语义、权限、生命周期、数据归属、跨模块写入、Agent 上下文或持久化执行的任务，都必须声明以下结论之一：

1. 不影响 L0；
2. 修改已有 L0；
3. 新增 L0。

影响 L0 时，必须先有已批准工作包，再改代码。

## 实现协议

- 只修改任务信封与工作包声明的范围；
- 发现实际影响超出声明时，立即停止扩展并重新准入；
- 不得绕过统一授权、状态迁移、权威写入和审计边界；
- 历史提交中的 `app/` 路径保持原样，新路径写成 `mac_app/`。

## 常用命令

```text
./scripts/test.sh
./scripts/build.sh
python3 ../governance/architecture/tools/audit_project.py --target ../governance
```
