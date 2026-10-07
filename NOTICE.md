# 第三方素材与致谢

本仓库的**代码**采用 MIT 许可（见 [LICENSE](LICENSE)）。但下面的**桌宠形象素材**不是本仓库作者的原创作品，
**不适用 MIT 许可**，版权与使用条款归各自原作者所有。

---

## 1. 桌宠形象素材：`assets/pets/`

| 目录 | 名称 | 来源 |
|---|---|---|
| `assets/pets/ikkun/` | ikkun | petdex 素材生态（来源站点：`codex-pet.org`） |
| `assets/pets/haiyue-classic/` | 海月·幻海映月 | petdex 素材生态（来源站点：`codex-pet.org`） |

- 素材形态：`pet.json` + `spritesheet.png` / `spritesheet.webp`，8 列 × 9 行，每格 192×208。
- 本仓库附带这两个素材，**仅为了让你 clone 下来就能直接看到效果**，方便开箱即用。
- **版权归原作者所有。** 如果你要再分发、商用或二次创作，请自行确认原作者的授权条款，
  并遵守来源站点的使用规定。
- 如果你是想用的素材原作者，且不希望它出现在本仓库：开一个 Issue，我会立即移除相关文件。

> 同样规格的其它素材可以直接放进 `%USERPROFILE%\.petdex\pets\<slug>\` 使用，不需要改代码。
> 详见 README 的「装形象素材」一节。

---

## 2. 规格与灵感来源

桌面桌宠的**行为规格**（9 个标准动作、单击挥手、双击跳跃、16 向待机视线、8×9 精灵图布局等）
对齐 **Codex 桌面宠物 / petdex** 的公开规格。本仓库的代码是独立实现（PowerShell + WPF），
没有复制上述项目的源代码。

---

## 3. 运行环境

- **DeepSeek Harness（DSH）**：`plugin/` 目录是面向 DSH 的插件，`desktop/` 能读取 DSH 的会话状态。
  DSH 及其相关包归其各自作者所有，本仓库不包含、也不分发它们。
- 桌宠本身**不依赖** DSH 即可运行。

---

## 4. 本仓库作者原创部分

- `desktop/kun-pet-desktop.ps1` —— 桌面桌宠本体（WPF 渲染、状态机、素材加载、气泡、托盘、审批面板等）
- `plugin/index.js`、`plugin/client.js` —— DSH 插件（host 状态机 / 端点 / 审批应答；网页端小宠渲染）
- `install.ps1`、`uninstall.ps1`、`plugin/toggle-gui-pet.ps1` 等脚本
- `docs/` 下的文档

以上均为 MIT 许可。
