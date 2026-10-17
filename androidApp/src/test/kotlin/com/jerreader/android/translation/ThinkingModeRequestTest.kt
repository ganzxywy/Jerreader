package com.jerreader.android.translation

import com.jerreader.unified.domain.LanguageCode
import com.jerreader.unified.translation.DirectAIProtocol
import com.jerreader.unified.translation.DirectAIProvider
import com.jerreader.unified.translation.DISABLE_THINKING_HEADER
import com.jerreader.unified.translation.DISABLE_THINKING_PASSTHROUGH_HEADER
import com.jerreader.unified.translation.TranslationPreferences
import com.jerreader.unified.translation.TranslationProviderMode
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「关闭深度思考」在请求里的最终形态。
 *
 * 这些断言只跑在 JVM 上：请求体由 `org.json` 构造，而 `androidApp` 的单元测试
 * 类路径上有真正的 `org.json` 实现（见 `build.gradle.kts`），所以不需要模拟器
 * 就能验证 App 到底发了什么。
 */
class ThinkingModeRequestTest {

    private fun prepare(configuration: TranslationServiceConfiguration): TranslationPreparedRequest =
        TranslationRequestBuilder.prepare(
            configuration = configuration,
            text = "The night was quiet.",
            source = LanguageCode.ENGLISH,
            target = LanguageCode.CHINESE_SIMPLIFIED,
            prompt = "只输出译文。",
            operation = "translate"
        )

    private fun body(request: TranslationPreparedRequest): JSONObject = JSONObject(request.body)

    /**
     * 请求地址跟着服务商自己的协议走，不额外给一个开关：测试想验证的是
     * 「哪个服务商写哪个字段」，地址只是为了让 Gemini 与 Responses 的 URL 拼得出来。
     */
    private fun directApi(
        provider: DirectAIProvider,
        disableDeepThinking: Boolean
    ): TranslationServiceConfiguration = TranslationServiceConfiguration(
        preferences = TranslationPreferences(
            providerMode = TranslationProviderMode.DIRECT_API,
            directProvider = provider,
            disableDeepThinking = disableDeepThinking
        ),
        endpoint = if (provider.protocol == DirectAIProtocol.OPENAI_CHAT_COMPLETIONS) {
            "https://api.example.test/v1/chat/completions"
        } else {
            "https://api.example.test/v1"
        },
        model = "test-model",
        credential = "test-key"
    )

    @Test
    fun `the switch off leaves the request byte for byte as it was`() {
        val request = prepare(
            directApi(DirectAIProvider.DEEPSEEK, disableDeepThinking = false)
        )
        val body = body(request)

        assertEquals("test-model", body.getString("model"))
        assertEquals(0.2, body.getDouble("temperature"), 0.0)
        assertFalse(body.has("thinking"))
        assertFalse(body.has("reasoning_effort"))
        assertFalse(body.has("enable_thinking"))
        assertFalse(request.headers.containsKey(DISABLE_THINKING_HEADER))
        assertFalse(request.headers.containsKey(DISABLE_THINKING_PASSTHROUGH_HEADER))
    }

    @Test
    fun `deepseek gets the documented thinking switch and drops temperature`() {
        val request = prepare(
            directApi(DirectAIProvider.DEEPSEEK, disableDeepThinking = true)
        )
        val body = body(request)

        assertEquals("disabled", body.getJSONObject("thinking").getString("type"))
        assertEquals("none", body.getString("reasoning_effort"))
        // DeepSeek 的思考模式不吃 temperature；关掉思考后它也不再参与控制随机性。
        assertFalse(body.has("temperature"))
        assertEquals("false", request.headers[DISABLE_THINKING_HEADER])
        assertEquals("1", request.headers[DISABLE_THINKING_PASSTHROUGH_HEADER])
    }

    @Test
    fun `a compatible service gets both spellings of the template flag`() {
        val request = prepare(
            directApi(DirectAIProvider.OPENAI_COMPATIBLE, disableDeepThinking = true)
        )
        val body = body(request)

        assertFalse(body.getBoolean("enable_thinking"))
        assertFalse(
            body.getJSONObject("chat_template_kwargs").getBoolean("enable_thinking")
        )
        // 其他服务商仍然保留采样温度。
        assertEquals(0.2, body.getDouble("temperature"), 0.0)
    }

    @Test
    fun `kimi gets the single top level template flag`() {
        val request = prepare(
            directApi(DirectAIProvider.KIMI, disableDeepThinking = true)
        )
        val body = body(request)

        assertFalse(body.getBoolean("enable_thinking"))
        // Kimi 的文档只认模板变量本身，不认 chat_template_kwargs 那一层。
        assertFalse(body.has("chat_template_kwargs"))
        assertFalse(body.has("thinking"))
    }

    @Test
    fun `gemini budget goes into generationConfig`() {
        val request = prepare(
            directApi(DirectAIProvider.GEMINI, disableDeepThinking = true)
        )
        val body = body(request)

        assertEquals(
            0,
            body.getJSONObject("generationConfig")
                .getJSONObject("thinkingConfig")
                .getInt("thinkingBudget")
        )
    }

    @Test
    fun `gpt keeps its request body and only gains the header`() {
        val request = prepare(
            directApi(DirectAIProvider.OPENAI, disableDeepThinking = true)
        )
        val body = body(request)

        assertFalse(body.has("reasoning_effort"))
        assertFalse(body.has("thinking"))
        assertEquals("只输出译文。", body.getString("instructions"))
        assertEquals("false", request.headers[DISABLE_THINKING_HEADER])
    }

    @Test
    fun `the proxy contract carries the intent instead of a provider parameter`() {
        val configuration = TranslationServiceConfiguration(
            preferences = TranslationPreferences(
                providerMode = TranslationProviderMode.BACKEND_PROXY,
                disableDeepThinking = true
            ),
            endpoint = "https://proxy.example.test/translate",
            model = "proxy-model",
            credential = "proxy-token"
        )

        val body = body(prepare(configuration))

        assertTrue(body.getBoolean("disableThinking"))
        assertEquals("proxy-model", body.getString("model"))
        // 代理自己决定怎么关，App 不猜上游是哪家。
        assertFalse(body.has("thinking"))
        assertFalse(body.has("enable_thinking"))
    }

    @Test
    fun `a proxy request without the switch is unchanged`() {
        val configuration = TranslationServiceConfiguration(
            preferences = TranslationPreferences(
                providerMode = TranslationProviderMode.BACKEND_PROXY,
                disableDeepThinking = false
            ),
            endpoint = "https://proxy.example.test/translate",
            model = "",
            credential = null
        )

        val request = prepare(configuration)

        assertFalse(body(request).has("disableThinking"))
        assertFalse(body(request).has("model"))
        assertNull(request.headers["Authorization"])
        assertFalse(request.headers.containsKey(DISABLE_THINKING_HEADER))
    }
}
