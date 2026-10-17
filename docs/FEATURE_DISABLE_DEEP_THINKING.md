# 关闭深度思考：改动清单与验证

> 目的：AI 翻译与句子结构分析不再无条件等待模型的思维链。设置页新增「关闭深度思考」，
> 打开后按服务商下发的字段要求服务端跳过思考；默认关闭，行为与服务商默认一致。

## 1. 开关在哪里

「设置 → 翻译与 AI → 提示词与 AI 行为 → 关闭深度思考」。仅在能真正关掉的服务上显示：

| 当前服务 | 是否显示 | 原因 |
| --- | --- | --- |
| Android 本机翻译 / Apple 系统翻译 | 否 | 没有思考环节 |
| 直接 API：DeepSeek、Kimi、Gemini、其他兼容服务 | 是 | 这些服务商文档里有真实的关闭字段 |
| 直接 API：GPT、Claude | 否 | Responses / Messages 的 `reasoning` 同时表达思考强度，拿它当关闭开关会连非推理模型一起影响；只带请求头不足以让读者看到效果 |
| AI 代理 | 是 | 怎么关由代理自己决定，App 只表达意图 |

## 2. 请求里到底发了什么

| 服务商 | 请求体 | 请求头 |
| --- | --- | --- |
| DeepSeek | `thinking: {"type": "disabled"}`、`reasoning_effort: "none"`；**不再发送 `temperature`**（思考模式下本就不生效） | `X-Enable-Thinking: false`、`X-Jerreader-Disable-Thinking: 1` |
| Kimi | `enable_thinking: false` | 同上 |
| 其他兼容服务 | `enable_thinking: false` 与 `chat_template_kwargs: {"enable_thinking": false}` | 同上 |
| Gemini | `generationConfig.thinkingConfig.thinkingBudget: 0` | 同上 |
| GPT、Claude | 无（请求体与之前逐字节相同） | 同上 |
| AI 代理 | 新增可选字段 `disableThinking: true` | 同上 |

开关关闭时，请求头为空集、请求体不写任何思考字段，也就是与加这个功能之前完全一致。

## 3. 改了哪些文件

### 共用核心 `core/`

- `commonMain/.../translation/ThinkingModePolicy.kt`（**新增**）：`ThinkingModeParameter` 与三个查询函数
  （`thinkingDisabledParameters()`、`canDisableThinkingInRequestBody()`、`disabledThinkingRequestHeaders()`），
  以及两个请求头常量。这里是「哪个服务商写哪个字段」的唯一出处。
- `commonMain/.../translation/TranslationModels.kt`：`TranslationPreferences` 新增 `disableDeepThinking = false`。
- `commonTest/.../translation/ThinkingModePolicyTest.kt`（**新增**）：策略与默认值的 8 个用例。

### Android

- `translation/AndroidTranslationSettingsStore.kt`：`updateDisableDeepThinking`、持久化键
  `translation.disableDeepThinking`、载入、备份恢复，并把开关纳入 `cacheNamespace`（切换后重取译文）。
- `translation/ConfiguredTranslationService.kt`：请求构造从类的私有方法抽成同文件的
  `internal object TranslationRequestBuilder`（返回 `TranslationPreparedRequest`），使请求体可以在 JVM 单测里
  直接验证而无需 `Context`；请求头与请求体按上表下发。
- `ui/SettingsScreen.kt`：`TranslationSettingsActions.updateDisableDeepThinking`、开关行、说明文案、
  `disableDeepThinkingIsAvailable()` 可见性判断。
- `MainActivity.kt`：接线。
- `backup/LibraryBackupService.kt`：备份写出 `translation.disableDeepThinking`。
- `test/.../translation/ThinkingModeRequestTest.kt`（**新增**）：8 个用例，逐字段断言请求体与请求头。

### iOS

- `Core/Models/TranslationPreferences.swift`：两个配置结构新增 `disableDeepThinking`（默认 `false`）。
- `Data/Services/TranslationSettingsStore.swift`：`@Published var disableDeepThinking`、存储键、
  备份键、初始化与 `reloadNonSensitivePreferences()` 恢复、两处配置构造。
- `Data/Services/BackendTranslationService.swift`：请求头与请求体按上表下发；`providerVersion(for:)`
  纳入该开关（否则切换开关会命中旧缓存）；代理请求体新增 `disableThinking`。
- `App/AppSettingsView.swift`：开关、说明文案、可见性判断。
- `Features/Learning/TranslateToolView.swift`：独立翻译页透传该开关。
- `JerreaderTests/BackendTranslationServiceTests.swift`：新增 7 个用例（含缓存身份）。

### 文档

- `README.md`：新增「关闭深度思考」小节（含服务商对照表与代理字段说明）。
- `docs/PARITY.md`：新增 1.16 节，记录两端字段一一对应与可见性规则一致。
- `docs/RELEASE_NOTES_1.5.1.md`：新增「翻译与 AI」小节。

## 4. 验证

本机只做了只读静态核验（没有 Android SDK、Xcode 与 Gradle 缓存，跑不了双端构建）：

```bash
# 本机已做的等价静态检查：请求体/请求头策略、双端字段一致性、备份与缓存读写、花括号配平
# 交由读者在有完整工具链的机器上执行：
./gradlew :core:testAndroidHostTest :androidApp:testDebugUnitTest
scripts/safe_xcodebuild.sh build   # 或直接跑 JerreaderTests
```

如果本机装不下 Android SDK，可以把这一步搬到 GitHub：

1. 把仓库（含新增的 `.github/workflows/android-apk.yml`）推到 GitHub；
2. 打开 Actions → **Android APK** → Run workflow；
3. 运行结束后在该次运行的 Artifacts 里下载 `Jerreader-<版本>-<构建号>-ci`，里面就是已签名的 APK。

工作流会先跑 `:core:testAndroidHostTest :androidApp:testDebugUnitTest`，再出包，所以它同时起到了
「这次改动是否编译通过、测试是否通过」的验证作用。签名用 Actions 缓存固定下来的 debug key：
同一工作流前后构建的包可以互相覆盖安装，但它与作者官方 Release APK 的签名不同，二者之间
必须先卸载再装（本地书库会随卸载丢失，先做一次备份）。

测试覆盖点：

- 开关关闭时请求体逐字段不变、请求头不含新头（两端各一个用例）。
- DeepSeek / Kimi / 兼容服务 / Gemini / GPT / 代理各自的字段（两端对称）。
- iOS `providerVersion` 随开关变化；Android `cacheNamespace` 随开关变化。
- 备份写出与恢复都不丢这个偏好。

## 5. 已知边界

- 关闭思考会改变译文，属于读者自己的取舍；因此默认关闭，不替读者决定。
- 若某个兼容网关对未知字段直接报错，关掉本开关即可恢复（设置页文案已说明）。
- GPT 与 Claude 只带请求头：官方接口会忽略它，自建代理或网关可以据此决定上游行为。
