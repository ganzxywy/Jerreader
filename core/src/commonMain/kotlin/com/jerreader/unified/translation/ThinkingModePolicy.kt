package com.jerreader.unified.translation

/**
 * 「关闭深度思考」在请求里到底写什么。
 *
 * 深度思考（思维链）默认是开启的：模型先输出一大段推理再给译文。翻译是一句
 * 话直译的活，这段推理既拖慢首字延迟，又按输出 token 计费，读者往往只想关掉
 * 它。但**没有统一参数**：`enable_thinking` 是 Qwen 系模板变量，DeepSeek 用
 * `thinking.type`，Gemini 用 `thinkingConfig.thinkingBudget`，名字和层级都不
 * 一样，所以这里按服务商分别描述。
 *
 * 两个约束：
 * - 只写各服务商**文档里真实存在**的字段。未知字段对宽松服务端无害，对严格的
 *   服务端就是一个 400，而用户是拿自己的 Key 在付费调用。
 * - GPT 与 Claude 刻意不写。OpenAI Responses 的 `reasoning.effort` 与
 *   Anthropic Messages 的 `reasoning.effort` 都同时承担「思考强度」的含义，
 *   拿它们当关闭开关会连非推理模型一起打挂；这两个服务商只带请求头标记。
 */
sealed class ThinkingModeParameter {
    /** `"enable_thinking": false`，Qwen 系 `chat_template_kwargs` 的顶层写法。 */
    data object EnableThinkingFalse : ThinkingModeParameter()

    /**
     * `"chat_template_kwargs": {"enable_thinking": false}`。
     *
     * vLLM / SGLang 与部分兼容网关要求模板变量嵌在 `chat_template_kwargs`
     * 里，顶层那份会被忽略。两个都发，认识其中一个的服务端就能生效，不认识
     * 的按未知字段忽略。
     */
    data object ChatTemplateKwargsEnableThinkingFalse : ThinkingModeParameter()

    /** `"thinking": {"type": "disabled"}`。 */
    data object ThinkingTypeDisabled : ThinkingModeParameter()

    /** `"reasoning_effort": "none"`，与 [ThinkingTypeDisabled] 一起用于 DeepSeek。 */
    data object ReasoningEffortNone : ThinkingModeParameter()

    /** `"generationConfig": {"thinkingConfig": {"thinkingBudget": 0}}`，Gemini。 */
    data object GeminiThinkingBudgetZero : ThinkingModeParameter()
}

/**
 * 本服务商关掉思考要写进请求体的参数；空集表示该服务商没有可靠的关闭方式。
 *
 * 新增服务商时照抄这里的判断顺序，不要为了「顺手也关掉 GPT」往
 * [DirectAIProtocol.OPENAI_RESPONSES] 里加 `reasoning`：`gpt-5.2` 这类模型
 * 一旦带上 `reasoning` 字段就必须回传 `reasoning` 项，翻译这种单轮请求不需要
 * 冒这个险。
 */
fun DirectAIProvider.thinkingDisabledParameters(): List<ThinkingModeParameter> = when (this) {
    DirectAIProvider.DEEPSEEK -> listOf(
        ThinkingModeParameter.ThinkingTypeDisabled,
        ThinkingModeParameter.ReasoningEffortNone
    )

    DirectAIProvider.KIMI -> listOf(ThinkingModeParameter.EnableThinkingFalse)

    DirectAIProvider.OPENAI_COMPATIBLE -> listOf(
        ThinkingModeParameter.EnableThinkingFalse,
        ThinkingModeParameter.ChatTemplateKwargsEnableThinkingFalse
    )

    DirectAIProvider.GEMINI -> listOf(ThinkingModeParameter.GeminiThinkingBudgetZero)

    // 见类注释：GPT 与 Claude 只带请求头标记。
    DirectAIProvider.OPENAI, DirectAIProvider.ANTHROPIC -> emptyList()
}

/**
 * 关掉思考后，该服务商是否还有可写的请求体参数。
 *
 * 设置页用它决定要不要展示开关：对 GPT / Claude 而言开关打开也只会多一个请求
 * 头，把「可写但没作用」的选项摆出来比不摆更坏。
 */
fun DirectAIProvider.canDisableThinkingInRequestBody(): Boolean =
    thinkingDisabledParameters().isNotEmpty()

/**
 * 请求头上的显式指令。
 *
 * 直接调官方 API 时这些头会被忽略（服务商不认未知请求头），但自建代理、网关
 * 和企业中转常按请求头决定上游要不要开思考，所以两个字段都带：一个是布尔语义
 * 的 `X-Enable-Thinking: false`，一个是把原始指令原样透传的
 * `X-Jerreader-Disable-Thinking: 1`。
 *
 * `disableDeepThinking` 为 false 时返回空表，请求与加这个功能之前逐字节相同。
 */
fun disabledThinkingRequestHeaders(disableDeepThinking: Boolean): Map<String, String> =
    if (disableDeepThinking) {
        mapOf(
            DISABLE_THINKING_HEADER to "false",
            DISABLE_THINKING_PASSTHROUGH_HEADER to "1"
        )
    } else {
        emptyMap()
    }

/** 布尔语义的开关，网关最常见读法。 */
const val DISABLE_THINKING_HEADER: String = "X-Enable-Thinking"

/**
 * 原样指令的透传头：自建代理可以在不改请求体的情况下据此让上游关掉思考，
 * 开关打开时代理请求体里还会多一个 `disableThinking` 字段（见 README 的
 * 「关闭深度思考」一节）。
 */
const val DISABLE_THINKING_PASSTHROUGH_HEADER: String = "X-Jerreader-Disable-Thinking"
