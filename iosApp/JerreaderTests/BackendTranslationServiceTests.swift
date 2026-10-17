import Foundation
import XCTest
@testable import JerreaderUnified

final class BackendTranslationServiceTests: XCTestCase {
    func testSuccessfulRequestUsesProxyContractAndBearerToken() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://translate.example.test/v1/selection"))
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"translatedText":"夜色很安静。"}"#.data(using: .utf8)!
        )
        let service = BackendTranslationService(
            configuration: BackendTranslationConfiguration(
                endpoint: endpoint,
                model: "translation-model",
                accessToken: "local-proxy-token"
            ),
            client: client
        )

        let result = try await service.translate(
            text: "  The night was quiet.  ",
            context: "The lamps were already lit. The night was quiet. Nobody spoke.",
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let capturedRequest = await client.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-proxy-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Jerreader-Translation-Protocol"), "1")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Jerreader-Idempotency-Key"),
            TranslationCacheStore.cacheKey(
                text: "The night was quiet.",
                contextText: "The lamps were already lit. The night was quiet. Nobody spoke.",
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese,
                providerIdentifier: BackendTranslationService.providerIdentifier,
                providerVersion: service.providerVersion
            )
        )
        XCTAssertEqual(body["text"] as? String, "The night was quiet.")
        XCTAssertEqual(
            body["context"] as? String,
            "The lamps were already lit. The night was quiet. Nobody spoke."
        )
        XCTAssertEqual(body["sourceLanguage"] as? String, LanguageCode.english.rawValue)
        XCTAssertEqual(body["targetLanguage"] as? String, LanguageCode.simplifiedChinese.rawValue)
        XCTAssertEqual(body["model"] as? String, "translation-model")
        XCTAssertTrue((body["prompt"] as? String)?.contains("英语") == true)
        XCTAssertTrue((body["prompt"] as? String)?.contains("简体中文") == true)
        XCTAssertEqual(result.translatedText, "夜色很安静。")
        XCTAssertEqual(result.providerIdentifier, BackendTranslationService.providerIdentifier)
        XCTAssertFalse(result.isFromCache)
    }

    func testAlternativeTranslationResponseFieldIsAccepted() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://translate.example.test/translate"))
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"translation":"A quiet evening."}"#.data(using: .utf8)!
        )
        let service = BackendTranslationService(
            configuration: BackendTranslationConfiguration(
                endpoint: endpoint,
                model: nil,
                accessToken: nil
            ),
            client: client
        )

        let result = try await service.translate(
            text: "静かな夜でした。",
            sourceLanguage: .japanese,
            targetLanguage: .english
        )

        XCTAssertEqual(result.translatedText, "A quiet evening.")
    }

    func testAuthenticationAndConfigurationStatusCodesAreTyped() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://translate.example.test/translate"))

        for statusCode in [401, 403] {
            let service = BackendTranslationService(
                configuration: .init(endpoint: endpoint, model: nil, accessToken: nil),
                client: BackendHTTPClientStub(statusCode: statusCode, body: Data())
            )
            await assertServiceError(.authenticationFailed) {
                try await service.translate(
                    text: "Translate me.",
                    sourceLanguage: .english,
                    targetLanguage: .japanese
                )
            }
        }

        for statusCode in [400, 404, 422] {
            let service = BackendTranslationService(
                configuration: .init(endpoint: endpoint, model: nil, accessToken: nil),
                client: BackendHTTPClientStub(statusCode: statusCode, body: Data())
            )
            await assertServiceError(.invalidConfiguration) {
                try await service.translate(
                    text: "Translate me.",
                    sourceLanguage: .english,
                    targetLanguage: .japanese
                )
            }
        }
    }

    func testInsecureEndpointAndSameLanguageAreRejectedBeforeNetwork() async throws {
        let insecureEndpoint = try XCTUnwrap(URL(string: "http://translate.example.test/translate"))
        let client = BackendHTTPClientStub(statusCode: 200, body: Data())
        let service = BackendTranslationService(
            configuration: .init(endpoint: insecureEndpoint, model: nil, accessToken: nil),
            client: client
        )

        await assertServiceError(.invalidConfiguration) {
            try await service.translate(
                text: "Translate me.",
                sourceLanguage: .english,
                targetLanguage: .japanese
            )
        }
        let requestAfterInsecureEndpoint = await client.lastRequest()
        XCTAssertNil(requestAfterInsecureEndpoint)

        let secureService = BackendTranslationService(
            configuration: .init(
                endpoint: URL(string: "https://translate.example.test/translate")!,
                model: nil,
                accessToken: nil
            ),
            client: client
        )
        await assertServiceError(.unsupportedLanguage) {
            try await secureService.translate(
                text: "同じ言語",
                sourceLanguage: .japanese,
                targetLanguage: .japanese
            )
        }
        let requestAfterSameLanguage = await client.lastRequest()
        XCTAssertNil(requestAfterSameLanguage)
    }

    func testOpenAIDirectPresetUsesResponsesContract() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses"))
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"output_text":"夜晚很安静。","output":[]}"#.data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: .init(
                provider: .openAI,
                endpoint: endpoint,
                model: "gpt-test",
                apiKey: "openai-test-key"
            ),
            client: client
        )

        let result = try await service.translate(
            text: "The night was quiet.",
            context: "The lamps were lit. The night was quiet.",
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let capturedRequest = await client.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer openai-test-key"
        )
        XCTAssertEqual(body["model"] as? String, "gpt-test")
        XCTAssertTrue((body["instructions"] as? String)?.contains("只输出译文") == true)
        XCTAssertTrue((body["input"] as? String)?.contains("The night was quiet.") == true)
        XCTAssertEqual(result.translatedText, "夜晚很安静。")
        XCTAssertEqual(result.providerIdentifier, "direct-ai-openAI")
    }

    func testDeepSeekDirectPresetUsesChatCompletionsContract() async throws {
        let endpoint = try XCTUnwrap(
            URL(string: "https://api.deepseek.com/chat/completions")
        )
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"choices":[{"message":{"content":"你好。"}}]}"#.data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: .init(
                provider: .deepSeek,
                endpoint: endpoint,
                model: "deepseek-test",
                apiKey: "deepseek-test-key"
            ),
            client: client
        )

        let result = try await service.translate(
            text: "Hello.",
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let capturedRequest = await client.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(body["model"] as? String, "deepseek-test")
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        // 「关闭深度思考」默认关闭，请求体里不该多出任何思考参数。
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["enable_thinking"])
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Enable-Thinking"))
        XCTAssertEqual(result.translatedText, "你好。")
    }

    func testDisablingDeepThinkingKeepsTheOldRequestWhenItIsOff() async throws {
        let endpoint = try XCTUnwrap(
            URL(string: "https://api.deepseek.com/chat/completions")
        )
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"choices":[{"message":{"content":"你好。"}}]}"#.data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: .init(
                provider: .deepSeek,
                endpoint: endpoint,
                model: "deepseek-test",
                apiKey: "deepseek-test-key",
                disableDeepThinking: false
            ),
            client: client
        )

        _ = try await service.translate(
            text: "Hello.",
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let request = try XCTUnwrap(await client.lastRequest())
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )

        XCTAssertEqual(
            Set(body.keys),
            ["model", "messages", "stream"],
            "开关关闭时请求体必须与加这个功能之前逐字段相同"
        )
        XCTAssertNotNil(body["stream"])
        XCTAssertTrue(request.allHTTPHeaderFields?.isEmpty == false)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Enable-Thinking"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Jerreader-Disable-Thinking"))
    }

    func testDisablingDeepThinkingUsesTheDeepSeekThinkingField() async throws {
        let endpoint = try XCTUnwrap(
            URL(string: "https://api.deepseek.com/chat/completions")
        )
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"choices":[{"message":{"content":"你好。"}}]}"#.data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: .init(
                provider: .deepSeek,
                endpoint: endpoint,
                model: "deepseek-test",
                apiKey: "deepseek-test-key",
                disableDeepThinking: true
            ),
            client: client
        )

        _ = try await service.translate(
            text: "Hello.",
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let request = try XCTUnwrap(await client.lastRequest())
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])

        XCTAssertEqual(thinking["type"] as? String, "disabled")
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Enable-Thinking"), "false")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Jerreader-Disable-Thinking"),
            "1"
        )
    }

    func testDisablingDeepThinkingCoversBothCompatibleServiceSpellings() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://gateway.example.test/v1/chat/completions"))
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"choices":[{"message":{"content":"你好。"}}]}"#.data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: .init(
                provider: .openAICompatible,
                endpoint: endpoint,
                model: "local-model",
                apiKey: "local-key",
                disableDeepThinking: true
            ),
            client: client
        )

        _ = try await service.translate(
            text: "Hello.",
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let request = try XCTUnwrap(await client.lastRequest())
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
        let templateKwargs = try XCTUnwrap(
            body["chat_template_kwargs"] as? [String: Any]
        )

        XCTAssertEqual((body["enable_thinking"] as? NSNumber)?.boolValue, false)
        XCTAssertEqual(
            (templateKwargs["enable_thinking"] as? NSNumber)?.boolValue,
            false
        )
    }

    func testDisablingDeepThinkingUsesAZeroGeminiThinkingBudget() async throws {
        let endpoint = try XCTUnwrap(
            URL(string: "https://generativelanguage.googleapis.com/v1beta")
        )
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"candidates":[{"content":{"parts":[{"text":"你好。"}]}}]}"#
                .data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: .init(
                provider: .gemini,
                endpoint: endpoint,
                model: "gemini-test",
                apiKey: "gemini-key",
                disableDeepThinking: true
            ),
            client: client
        )

        _ = try await service.translate(
            text: "Hello.",
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let request = try XCTUnwrap(await client.lastRequest())
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
        let generationConfig = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        let thinkingConfig = try XCTUnwrap(
            generationConfig["thinkingConfig"] as? [String: Any]
        )

        XCTAssertEqual(thinkingConfig["thinkingBudget"] as? Int, 0)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Enable-Thinking"), "false")
    }

    func testGptKeepsItsBodyAndOnlyGainsTheThinkingHeader() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses"))
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"output_text":"夜晚很安静。","output":[]}"#.data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: .init(
                provider: .openAI,
                endpoint: endpoint,
                model: "gpt-test",
                apiKey: "openai-test-key",
                disableDeepThinking: true
            ),
            client: client
        )

        _ = try await service.translate(
            text: "The night was quiet.",
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let request = try XCTUnwrap(await client.lastRequest())
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )

        // Responses 的 reasoning 字段同时表达思考强度，用它当关闭开关会把非推理
        // 模型一起打挂，所以这里只能多一个请求头。
        XCTAssertEqual(Set(body.keys), ["model", "instructions", "input"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Enable-Thinking"), "false")
    }

    func testProxyCarriesTheDisableThinkingIntent() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://translate.example.test/translate"))
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"translatedText":"夜晚很安静。"}"#.data(using: .utf8)!
        )
        let service = BackendTranslationService(
            configuration: BackendTranslationConfiguration(
                endpoint: endpoint,
                model: "translation-model",
                accessToken: nil,
                disableDeepThinking: true
            ),
            client: client
        )

        _ = try await service.translate(
            text: "The night was quiet.",
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let request = try XCTUnwrap(await client.lastRequest())
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )

        XCTAssertEqual(body["disableThinking"] as? NSNumber, true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Enable-Thinking"), "false")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Jerreader-Disable-Thinking"),
            "1"
        )
    }

    func testKimiDirectPresetUsesOfficialChatCompletionsContract() async throws {
        let endpoint = try XCTUnwrap(
            URL(string: "https://api.moonshot.cn/v1/chat/completions")
        )
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"choices":[{"message":{"content":"月光很安静。"}}]}"#.data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: .init(
                provider: .kimi,
                endpoint: endpoint,
                model: "kimi-k2.6",
                apiKey: "kimi-test-key"
            ),
            client: client
        )

        let result = try await service.translate(
            text: "The moonlight was quiet.",
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let capturedRequest = await client.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer kimi-test-key")
        XCTAssertEqual(body["model"] as? String, "kimi-k2.6")
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(result.translatedText, "月光很安静。")
        XCTAssertEqual(result.providerIdentifier, "direct-ai-kimi")
    }

    func testGeminiDirectPresetBuildsModelURLAndKeyHeader() async throws {
        let baseURL = try XCTUnwrap(
            URL(string: "https://generativelanguage.googleapis.com/v1beta")
        )
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"candidates":[{"content":{"parts":[{"text":"你好。"}]}}]}"#.data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: .init(
                provider: .gemini,
                endpoint: baseURL,
                model: "gemini-test",
                apiKey: "gemini-test-key"
            ),
            client: client
        )

        let result = try await service.translate(
            text: "Hello.",
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let capturedRequest = await client.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-goog-api-key"),
            "gemini-test-key"
        )
        XCTAssertNotNil(body["systemInstruction"])
        XCTAssertNotNil(body["contents"])
        XCTAssertEqual(result.translatedText, "你好。")
    }

    func testAnthropicDirectPresetUsesMessagesHeadersAndResponse() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.anthropic.com/v1/messages"))
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"content":[{"type":"text","text":"你好。"}]}"#.data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: .init(
                provider: .anthropic,
                endpoint: endpoint,
                model: "claude-test",
                apiKey: "claude-test-key"
            ),
            client: client
        )

        let result = try await service.translate(
            text: "Hello.",
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let capturedRequest = await client.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "claude-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(body["model"] as? String, "claude-test")
        XCTAssertEqual(body["max_tokens"] as? Int, 1_200)
        XCTAssertEqual(result.translatedText, "你好。")
    }

    func testBackendContextExplanationUsesExplicitTaskAndLimitedContext() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://translate.example.test/v1/selection"))
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"explanation":"这里的 light 表示重量轻，而不是光线。"}"#.data(using: .utf8)!
        )
        let service = BackendTranslationService(
            configuration: .init(
                endpoint: endpoint,
                model: "explanation-model",
                accessToken: "proxy-token"
            ),
            client: client
        )

        let result = try await service.explain(
            ContextExplanationRequest(
                focusedText: "It was light.",
                contextText: "She lifted the box. It was light.",
                sourceLanguage: .english,
                responseLanguage: .simplifiedChinese
            )
        )
        let capturedRequest = await client.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )

        XCTAssertEqual(body["task"] as? String, "explain")
        XCTAssertEqual(body["analysisMode"] as? String, "grammar")
        XCTAssertEqual(body["text"] as? String, "It was light.")
        XCTAssertEqual(body["context"] as? String, "She lifted the box. It was light.")
        XCTAssertEqual(body["responseLanguage"] as? String, "zh-Hans")
        XCTAssertTrue((body["prompt"] as? String)?.contains("句子主干") == true)
        XCTAssertEqual(
            request.timeoutInterval,
            BackendTranslationService.explanationRequestTimeout
        )
        XCTAssertEqual(result.explanation, "这里的 light 表示重量轻，而不是光线。")
        XCTAssertEqual(result.providerIdentifier, BackendTranslationService.providerIdentifier)
    }

    func testOpenAIContextExplanationReusesConfiguredProviderContract() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses"))
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"output_text":"light 在这里是形容重量轻。","output":[]}"#.data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: .init(
                provider: .openAI,
                endpoint: endpoint,
                model: "gpt-test",
                apiKey: "openai-test-key"
            ),
            client: client
        )

        let result = try await service.explain(
            ContextExplanationRequest(
                focusedText: "It was light.",
                contextText: "She lifted the box. It was light.",
                sourceLanguage: .english,
                responseLanguage: .simplifiedChinese
            )
        )
        let capturedRequest = await client.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )

        XCTAssertEqual(body["model"] as? String, "gpt-test")
        XCTAssertTrue((body["instructions"] as? String)?.contains("精确的语言教师") == true)
        XCTAssertTrue((body["instructions"] as? String)?.contains("句子主干") == true)
        XCTAssertTrue((body["input"] as? String)?.contains("SELECTED TEXT:\nIt was light.") == true)
        XCTAssertTrue((body["input"] as? String)?.contains("READING CONTEXT:") == true)
        XCTAssertEqual(
            request.timeoutInterval,
            DirectAITranslationService.explanationRequestTimeout
        )
        XCTAssertEqual(result.explanation, "light 在这里是形容重量轻。")
        XCTAssertEqual(result.providerIdentifier, "direct-ai-openAI")
    }

    func testOpenAIContextExplanationAcceptsReasoningItemBeforeMessage() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses"))
        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"""
            {
              "output": [
                {"id":"reasoning-1","type":"reasoning","summary":[]},
                {
                  "id":"message-1",
                  "type":"message",
                  "content":[
                    {"type":"output_text","text":"这是主系表结构。","annotations":[]}
                  ]
                }
              ]
            }
            """#.data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: .init(
                provider: .openAI,
                endpoint: endpoint,
                model: "reasoning-model",
                apiKey: "openai-test-key"
            ),
            client: client
        )

        let result = try await service.explain(
            ContextExplanationRequest(
                focusedText: "It was light.",
                contextText: nil,
                sourceLanguage: .english,
                responseLanguage: .simplifiedChinese
            )
        )

        XCTAssertEqual(result.explanation, "这是主系表结构。")
    }

    func testDirectProviderVersionDoesNotDependOnSecret() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses"))
        let first = DirectAITranslationConfiguration(
            provider: .openAI,
            endpoint: endpoint,
            model: "gpt-test",
            apiKey: "first-secret"
        )
        let second = DirectAITranslationConfiguration(
            provider: .openAI,
            endpoint: endpoint,
            model: "gpt-test",
            apiKey: "second-secret"
        )

        XCTAssertEqual(
            DirectAITranslationService.providerVersion(for: first),
            DirectAITranslationService.providerVersion(for: second)
        )
    }

    func testDeepThinkingSwitchChangesTheCacheIdentity() throws {
        let endpoint = try XCTUnwrap(
            URL(string: "https://api.deepseek.com/chat/completions")
        )
        let thinkingOn = DirectAITranslationConfiguration(
            provider: .deepSeek,
            endpoint: endpoint,
            model: "deepseek-test",
            apiKey: "local-secret"
        )
        let thinkingOff = DirectAITranslationConfiguration(
            provider: .deepSeek,
            endpoint: endpoint,
            model: "deepseek-test",
            apiKey: "local-secret",
            disableDeepThinking: true
        )

        // 开关改变的是请求语义（也改变译文），缓存身份必须跟着变，否则切换后
        // 会读到按另一种模式翻译出来的旧结果。Android 的 cacheNamespace 同样处理。
        XCTAssertNotEqual(
            DirectAITranslationService.providerVersion(for: thinkingOn),
            DirectAITranslationService.providerVersion(for: thinkingOff)
        )

        let proxyOn = BackendTranslationConfiguration(
            endpoint: try XCTUnwrap(URL(string: "https://translate.example.test/translate")),
            model: "translation-model",
            accessToken: nil
        )
        let proxyOff = BackendTranslationConfiguration(
            endpoint: try XCTUnwrap(URL(string: "https://translate.example.test/translate")),
            model: "translation-model",
            accessToken: nil,
            disableDeepThinking: true
        )
        XCTAssertNotEqual(
            BackendTranslationService.providerVersion(for: proxyOn),
            BackendTranslationService.providerVersion(for: proxyOff)
        )
    }

    func testCustomPromptChangesProviderVersionAndRenderedInstruction() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses"))
        let baseline = DirectAITranslationConfiguration(
            provider: .openAI,
            endpoint: endpoint,
            model: "gpt-test",
            apiKey: "local-secret"
        )
        let customized = DirectAITranslationConfiguration(
            provider: .openAI,
            endpoint: endpoint,
            model: "gpt-test",
            apiKey: "local-secret",
            translationPromptTemplate:
                "CUSTOM {source_language} TO {target_language}",
            grammarAnalysisPromptTemplate:
                AIPromptTemplateDefaults.grammarAnalysis
        )
        XCTAssertNotEqual(
            DirectAITranslationService.providerVersion(for: baseline),
            DirectAITranslationService.providerVersion(for: customized)
        )

        let client = BackendHTTPClientStub(
            statusCode: 200,
            body: #"{"output_text":"こんにちは","output":[]}"#.data(using: .utf8)!
        )
        let service = DirectAITranslationService(
            configuration: customized,
            client: client
        )
        _ = try await service.translate(
            text: "Hello",
            sourceLanguage: .english,
            targetLanguage: .japanese
        )
        let capturedRequest = await client.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(request.httpBody)
            ) as? [String: Any]
        )
        XCTAssertEqual(body["instructions"] as? String, "CUSTOM 英语 TO 日语")
    }

    private func assertServiceError(
        _ expected: ServiceError,
        operation: () async throws -> TranslationResult
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? ServiceError, expected)
        }
    }
}

private actor BackendHTTPClientStub: BackendTranslationHTTPClient {
    private let statusCode: Int
    private let body: Data
    private var capturedRequest: URLRequest?

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }

    func lastRequest() -> URLRequest? {
        capturedRequest
    }
}
