package com.jerreader.unified.translation

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ThinkingModePolicyTest {

    @Test
    fun `deep thinking stays on until the reader asks for it`() {
        // 这个开关的价值在于读者主动省钱省时间，所以默认必须与服务商一致，
        // 否则旧版本升级上来的行为会悄悄变掉。
        assertFalse(TranslationPreferences().disableDeepThinking)
    }

    @Test
    fun `deepseek disables thinking through the documented thinking field`() {
        assertEquals(
            listOf(
                ThinkingModeParameter.ThinkingTypeDisabled,
                ThinkingModeParameter.ReasoningEffortNone
            ),
            DirectAIProvider.DEEPSEEK.thinkingDisabledParameters()
        )
    }

    @Test
    fun `openai compatible services get both spellings of enable thinking`() {
        // 顶层 `enable_thinking` 是 Qwen 系模板变量最常见的写法，
        // `chat_template_kwargs` 是 vLLM / SGLang 与部分网关要求的写法。
        val parameters = DirectAIProvider.OPENAI_COMPATIBLE.thinkingDisabledParameters()
        assertTrue(parameters.contains(ThinkingModeParameter.EnableThinkingFalse))
        assertTrue(parameters.contains(ThinkingModeParameter.ChatTemplateKwargsEnableThinkingFalse))
    }

    @Test
    fun `gemini uses a zero thinking budget`() {
        assertEquals(
            listOf(ThinkingModeParameter.GeminiThinkingBudgetZero),
            DirectAIProvider.GEMINI.thinkingDisabledParameters()
        )
    }

    @Test
    fun `gpt and claude get no body parameter at all`() {
        // Responses 与 Messages 的 reasoning 字段同时表达思考强度，用它当关闭
        // 开关会把非推理模型一起打挂，所以这里只能留空、只用请求头。
        assertTrue(DirectAIProvider.OPENAI.thinkingDisabledParameters().isEmpty())
        assertTrue(DirectAIProvider.ANTHROPIC.thinkingDisabledParameters().isEmpty())
        assertFalse(DirectAIProvider.OPENAI.canDisableThinkingInRequestBody())
        assertFalse(DirectAIProvider.ANTHROPIC.canDisableThinkingInRequestBody())
    }

    @Test
    fun `providers without a documented switch stay out of the settings screen`() {
        // 设置页按这个判断展示开关，所以「能不能关」必须与服务商一一对应。
        assertTrue(DirectAIProvider.DEEPSEEK.canDisableThinkingInRequestBody())
        assertTrue(DirectAIProvider.KIMI.canDisableThinkingInRequestBody())
        assertTrue(DirectAIProvider.OPENAI_COMPATIBLE.canDisableThinkingInRequestBody())
        assertTrue(DirectAIProvider.GEMINI.canDisableThinkingInRequestBody())
    }

    @Test
    fun `an untouched request carries no thinking header`() {
        // 开关关闭时请求必须与加这个功能之前逐字节相同，自建代理才不会被新头影响。
        assertTrue(disabledThinkingRequestHeaders(disableDeepThinking = false).isEmpty())
    }

    @Test
    fun `turning the switch on adds the boolean header and the passthrough marker`() {
        val headers = disabledThinkingRequestHeaders(disableDeepThinking = true)
        assertEquals("false", headers[DISABLE_THINKING_HEADER])
        assertEquals("1", headers[DISABLE_THINKING_PASSTHROUGH_HEADER])
        assertEquals(2, headers.size)
    }
}
