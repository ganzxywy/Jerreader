import CryptoKit
import Foundation

protocol BackendTranslationHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionBackendTranslationHTTPClient: BackendTranslationHTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ServiceError.temporarilyUnavailable
        }
        return (data, response)
    }
}

struct BackendTranslationService: TranslationService, ContextExplanationService {
    static let providerIdentifier = "ai-backend-proxy"
    static let explanationRequestTimeout: TimeInterval = 60

    let configuration: BackendTranslationConfiguration
    private let client: any BackendTranslationHTTPClient

    init(
        configuration: BackendTranslationConfiguration,
        client: any BackendTranslationHTTPClient = URLSessionBackendTranslationHTTPClient()
    ) {
        self.configuration = configuration
        self.client = client
    }

    var providerVersion: String {
        Self.providerVersion(for: configuration)
    }

    static func providerVersion(for configuration: BackendTranslationConfiguration) -> String {
        let value = [
            configuration.endpoint.absoluteString,
            configuration.model ?? "default",
            configuration.translationPromptTemplate,
            configuration.grammarAnalysisPromptTemplate,
            // 关掉思考后的译文和开着思考时不是同一个结果，缓存身份要跟着变，
            // 否则切换开关会读到旧结果。Android 侧的 `cacheNamespace` 同样处理。
            String(configuration.disableDeepThinking),
            "jerreader-proxy-v1",
        ].joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func translate(
        text: String,
        sourceLanguage: LanguageCode?,
        targetLanguage: LanguageCode
    ) async throws -> TranslationResult {
        try await translate(
            text: text,
            context: nil,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    func translate(
        text: String,
        context: String?,
        sourceLanguage: LanguageCode?,
        targetLanguage: LanguageCode
    ) async throws -> TranslationResult {
        let sourceText = TranslationCacheStore.normalizedText(text)
        let normalizedContext = context.map(TranslationCacheStore.normalizedText)
            .flatMap { value in
                value.isEmpty || value == sourceText ? nil : value
            }
        guard !sourceText.isEmpty else { throw ServiceError.emptyText }
        guard sourceText.count <= 2_000 else { throw ServiceError.textTooLong }
        guard let sourceLanguage,
              LanguageCode.allCases.contains(sourceLanguage),
              LanguageCode.allCases.contains(targetLanguage),
              sourceLanguage != targetLanguage
        else {
            throw ServiceError.unsupportedLanguage
        }
        guard configuration.endpoint.scheme?.lowercased() == "https",
              configuration.endpoint.host?.isEmpty == false
        else {
            throw ServiceError.invalidConfiguration
        }

        let body = RequestBody(
            text: sourceText,
            context: normalizedContext,
            sourceLanguage: sourceLanguage.rawValue,
            targetLanguage: targetLanguage.rawValue,
            model: configuration.model,
            prompt: AIPromptTemplateDefaults.rendered(
                configuration.translationPromptTemplate,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            ),
            // 代理自己决定怎么让上游关掉思考：能力在服务端，App 只能把意图说清楚。
            // 老代理不认识这个字段，会按未知字段忽略。
            disableThinking: configuration.disableDeepThinking ? true : nil
        )
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "X-Jerreader-Translation-Protocol")
        for (field, value) in configuration.disableDeepThinkingHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue(
            TranslationCacheStore.cacheKey(
                text: sourceText,
                contextText: normalizedContext,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                providerIdentifier: Self.providerIdentifier,
                providerVersion: providerVersion
            ),
            forHTTPHeaderField: "X-Jerreader-Idempotency-Key"
        )
        if let token = configuration.accessToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.temporarilyUnavailable
        }

        switch response.statusCode {
        case 200 ..< 300:
            break
        case 401, 403:
            throw ServiceError.authenticationFailed
        case 400, 404, 405, 415, 422:
            throw ServiceError.invalidConfiguration
        default:
            throw ServiceError.temporarilyUnavailable
        }

        let payload: ResponseBody
        do {
            payload = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw ServiceError.resultNotFound
        }
        guard let translatedText = TranslationOutputPolicy.displayText(
            payload.translatedText ?? payload.translation ?? ""
        ) else {
            throw ServiceError.resultNotFound
        }

        return TranslationResult(
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            providerIdentifier: Self.providerIdentifier,
            providerVersion: providerVersion,
            isFromCache: false
        )
    }

    func explain(
        _ explanationRequest: ContextExplanationRequest
    ) async throws -> ContextExplanationResult {
        let explanationRequest = ContextExplanationInputPolicy.prepared(
            explanationRequest
        )
        let focusedText = explanationRequest.focusedText
        let context = explanationRequest.contextText
        guard !focusedText.isEmpty else { throw ServiceError.emptyText }
        guard focusedText.count <= 2_000 else { throw ServiceError.textTooLong }
        guard configuration.endpoint.scheme?.lowercased() == "https",
              configuration.endpoint.host?.isEmpty == false
        else {
            throw ServiceError.invalidConfiguration
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        // Grammar analysis is intentionally allowed more time than a normal
        // translation. Reasoning-capable models commonly need longer than the
        // old 30–35 second window, which made an otherwise healthy request look
        // like a permanent failure in the explanation sheet.
        request.timeoutInterval = Self.explanationRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "X-Jerreader-Translation-Protocol")
        // GPT 与 Claude 没有可写的关闭字段，读者在直接 API 页打开开关时至少要
        // 有这个请求头，代理或网关才能据此决定上游要不要开思考。
        for (field, value) in configuration.disableDeepThinkingHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let token = configuration.accessToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            ExplanationRequestBody(
                task: "explain",
                analysisMode: "grammar",
                text: focusedText,
                context: context,
                sourceLanguage: explanationRequest.sourceLanguage?.rawValue,
                responseLanguage: explanationRequest.responseLanguage.rawValue,
                model: configuration.model,
                prompt: AIPromptTemplateDefaults.rendered(
                    configuration.grammarAnalysisPromptTemplate,
                    sourceLanguage: explanationRequest.sourceLanguage,
                    responseLanguage: explanationRequest.responseLanguage,
                    fallback: AIPromptTemplateDefaults.grammarAnalysis
                ),
                disableThinking: configuration.disableDeepThinking ? true : nil
            )
        )

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.temporarilyUnavailable
        }

        switch response.statusCode {
        case 200 ..< 300:
            break
        case 401, 403:
            throw ServiceError.authenticationFailed
        case 400, 404, 405, 415, 422:
            throw ServiceError.invalidConfiguration
        default:
            throw ServiceError.temporarilyUnavailable
        }

        let payload: ExplanationResponseBody
        do {
            payload = try JSONDecoder().decode(ExplanationResponseBody.self, from: data)
        } catch {
            throw ServiceError.resultNotFound
        }
        guard let explanation = TranslationOutputPolicy.displayText(
            payload.explanation
                ?? payload.answer
                ?? payload.translatedText
                ?? payload.translation
                ?? ""
        ) else {
            throw ServiceError.resultNotFound
        }
        return ContextExplanationResult(
            explanation: explanation,
            providerIdentifier: Self.providerIdentifier,
            providerVersion: providerVersion
        )
    }

    private struct RequestBody: Encodable {
        let text: String
        let context: String?
        let sourceLanguage: String
        let targetLanguage: String
        let model: String?
        let prompt: String?
        let disableThinking: Bool?
    }

    private struct ResponseBody: Decodable {
        let translatedText: String?
        let translation: String?
    }

    private struct ExplanationRequestBody: Encodable {
        let task: String
        let analysisMode: String
        let text: String
        let context: String?
        let sourceLanguage: String?
        let responseLanguage: String
        let model: String?
        let prompt: String?
        let disableThinking: Bool?

        init(
            task: String,
            analysisMode: String,
            text: String,
            context: String?,
            sourceLanguage: String?,
            responseLanguage: String,
            model: String?,
            prompt: String?,
            disableThinking: Bool? = nil
        ) {
            self.task = task
            self.analysisMode = analysisMode
            self.text = text
            self.context = context
            self.sourceLanguage = sourceLanguage
            self.responseLanguage = responseLanguage
            self.model = model
            self.prompt = prompt
            self.disableThinking = disableThinking
        }
    }

    private struct ExplanationResponseBody: Decodable {
        let explanation: String?
        let answer: String?
        let translatedText: String?
        let translation: String?
    }
}

struct DirectAITranslationService: TranslationService, ContextExplanationService {
    static let explanationRequestTimeout: TimeInterval = 60

    let configuration: DirectAITranslationConfiguration
    private let client: any BackendTranslationHTTPClient

    init(
        configuration: DirectAITranslationConfiguration,
        client: any BackendTranslationHTTPClient = URLSessionBackendTranslationHTTPClient()
    ) {
        self.configuration = configuration
        self.client = client
    }

    var providerIdentifier: String {
        Self.providerIdentifier(for: configuration.provider)
    }

    var providerVersion: String {
        Self.providerVersion(for: configuration)
    }

    static func providerIdentifier(for provider: DirectAIProviderChoice) -> String {
        "direct-ai-\(provider.rawValue)"
    }

    static func providerVersion(for configuration: DirectAITranslationConfiguration) -> String {
        let value = [
            configuration.provider.rawValue,
            configuration.endpoint.absoluteString,
            configuration.model,
            configuration.translationPromptTemplate,
            configuration.grammarAnalysisPromptTemplate,
            // 同 `BackendTranslationService.providerVersion`：开关影响请求语义，
            // 也就必须影响缓存身份。
            String(configuration.disableDeepThinking),
            "jerreader-direct-api-v1",
        ].joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func translate(
        text: String,
        sourceLanguage: LanguageCode?,
        targetLanguage: LanguageCode
    ) async throws -> TranslationResult {
        try await translate(
            text: text,
            context: nil,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    func translate(
        text: String,
        context: String?,
        sourceLanguage: LanguageCode?,
        targetLanguage: LanguageCode
    ) async throws -> TranslationResult {
        let sourceText = TranslationCacheStore.normalizedText(text)
        let normalizedContext = context.map(TranslationCacheStore.normalizedText)
            .flatMap { value in
                value.isEmpty || value == sourceText ? nil : value
            }
        guard !sourceText.isEmpty else { throw ServiceError.emptyText }
        guard sourceText.count <= 2_000 else { throw ServiceError.textTooLong }
        guard let sourceLanguage,
              LanguageCode.allCases.contains(sourceLanguage),
              LanguageCode.allCases.contains(targetLanguage),
              sourceLanguage != targetLanguage
        else {
            throw ServiceError.unsupportedLanguage
        }
        guard configuration.endpoint.scheme?.lowercased() == "https",
              configuration.endpoint.host?.isEmpty == false,
              !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ServiceError.invalidConfiguration
        }

        let prompt = TranslationPrompt(
            sourceText: sourceText,
            context: normalizedContext,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            template: configuration.translationPromptTemplate
        )
        let request = try makeRequest(
            systemInstruction: prompt.systemInstruction,
            userContent: prompt.userContent
        )
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.temporarilyUnavailable
        }

        switch response.statusCode {
        case 200 ..< 300:
            break
        case 401, 403:
            throw ServiceError.authenticationFailed
        case 400, 404, 405, 415, 422:
            throw ServiceError.invalidConfiguration
        default:
            throw ServiceError.temporarilyUnavailable
        }

        guard let translatedText = TranslationOutputPolicy.displayText(
            try decodedText(from: data)
        ) else {
            throw ServiceError.resultNotFound
        }

        return TranslationResult(
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            providerIdentifier: providerIdentifier,
            providerVersion: providerVersion,
            isFromCache: false
        )
    }

    func explain(
        _ explanationRequest: ContextExplanationRequest
    ) async throws -> ContextExplanationResult {
        let explanationRequest = ContextExplanationInputPolicy.prepared(
            explanationRequest
        )
        let focusedText = explanationRequest.focusedText
        let context = explanationRequest.contextText
        guard !focusedText.isEmpty else { throw ServiceError.emptyText }
        guard focusedText.count <= 2_000 else { throw ServiceError.textTooLong }
        guard configuration.endpoint.scheme?.lowercased() == "https",
              configuration.endpoint.host?.isEmpty == false,
              !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ServiceError.invalidConfiguration
        }

        let systemInstruction = AIPromptTemplateDefaults.rendered(
            configuration.grammarAnalysisPromptTemplate,
            sourceLanguage: explanationRequest.sourceLanguage,
            responseLanguage: explanationRequest.responseLanguage,
            fallback: AIPromptTemplateDefaults.grammarAnalysis
        )
        let userContent: String
        if let context {
            userContent = """
            SELECTED TEXT:
            \(focusedText)

            READING CONTEXT:
            \(context)
            """
        } else {
            userContent = "SELECTED TEXT:\n\(focusedText)"
        }
        let request = try makeRequest(
            systemInstruction: systemInstruction,
            userContent: userContent,
            timeoutInterval: Self.explanationRequestTimeout
        )

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.temporarilyUnavailable
        }

        switch response.statusCode {
        case 200 ..< 300:
            break
        case 401, 403:
            throw ServiceError.authenticationFailed
        case 400, 404, 405, 415, 422:
            throw ServiceError.invalidConfiguration
        default:
            throw ServiceError.temporarilyUnavailable
        }

        guard let explanation = TranslationOutputPolicy.displayText(
            try decodedText(from: data)
        ) else {
            throw ServiceError.resultNotFound
        }
        return ContextExplanationResult(
            explanation: explanation,
            providerIdentifier: providerIdentifier,
            providerVersion: providerVersion
        )
    }

    private func makeRequest(
        systemInstruction: String,
        userContent: String,
        timeoutInterval: TimeInterval = 30
    ) throws -> URLRequest {
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in configuration.disableDeepThinkingHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        switch configuration.provider {
        case .openAI:
            request.setValue(
                "Bearer \(configuration.apiKey)",
                forHTTPHeaderField: "Authorization"
            )
            request.httpBody = try JSONEncoder().encode(
                OpenAIResponsesRequest(
                    model: configuration.model,
                    instructions: systemInstruction,
                    input: userContent
                )
            )

        case .kimi, .deepSeek, .openAICompatible:
            request.setValue(
                "Bearer \(configuration.apiKey)",
                forHTTPHeaderField: "Authorization"
            )
            request.httpBody = try JSONEncoder().encode(
                configuration.chatCompletionsRequest(
                    systemInstruction: systemInstruction,
                    userContent: userContent
                )
            )

        case .gemini:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = try JSONEncoder().encode(
                GeminiRequest(
                    systemInstruction: .init(
                        parts: [.init(text: systemInstruction)]
                    ),
                    contents: [
                        .init(role: "user", parts: [.init(text: userContent)])
                    ],
                    generationConfig: configuration.geminiGenerationConfig
                )
            )

        case .anthropic:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONEncoder().encode(
                AnthropicRequest(
                    model: configuration.model,
                    maxTokens: 1_200,
                    system: systemInstruction,
                    messages: [
                        .init(role: "user", content: userContent)
                    ]
                )
            )
        }
        return request
    }

    private var requestURL: URL {
        guard configuration.provider == .gemini else {
            return configuration.endpoint
        }
        return configuration.endpoint
            .appendingPathComponent("models")
            .appendingPathComponent("\(configuration.model):generateContent")
    }

    private func decodedText(from data: Data) throws -> String {
        do {
            switch configuration.provider {
            case .openAI:
                let response = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
                if let outputText = response.outputText?.nilIfBlank {
                    return outputText
                }
                return (response.output ?? [])
                    // Responses from reasoning-capable models can contain a
                    // reasoning item without `content` before the final
                    // message. Requiring content on every item caused the
                    // entire otherwise valid response to fail decoding.
                    .flatMap { $0.content ?? [] }
                    .compactMap(\.text)
                    .joined()

            case .kimi, .deepSeek, .openAICompatible:
                let response = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
                return response.choices.first?.message.content ?? ""

            case .gemini:
                let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
                return (response.candidates ?? [])
                    .flatMap { $0.content?.parts ?? [] }
                    .compactMap(\.text)
                    .joined()

            case .anthropic:
                let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
                return response.content.compactMap(\.text).joined()
            }
        } catch {
            throw ServiceError.resultNotFound
        }
    }

    private struct TranslationPrompt {
        let systemInstruction: String
        let userContent: String

        init(
            sourceText: String,
            context: String?,
            sourceLanguage: LanguageCode,
            targetLanguage: LanguageCode,
            template: String
        ) {
            systemInstruction = AIPromptTemplateDefaults.rendered(
                template,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            if let context {
                userContent = """
                SOURCE:
                \(sourceText)

                CONTEXT:
                \(context)
                """
            } else {
                userContent = "SOURCE:\n\(sourceText)"
            }
        }
    }

    private struct OpenAIResponsesRequest: Encodable {
        let model: String
        let instructions: String
        let input: String
    }

    private struct OpenAIResponsesResponse: Decodable {
        let outputText: String?
        let output: [OutputItem]?

        enum CodingKeys: String, CodingKey {
            case outputText = "output_text"
            case output
        }

        struct OutputItem: Decodable {
            let content: [Content]?
        }

        struct Content: Decodable {
            let text: String?
        }
    }

    private struct ChatCompletionsResponse: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let message: Message
        }

        struct Message: Decodable {
            let content: String?
        }
    }

    private struct GeminiRequest: Encodable {
        let systemInstruction: Content
        let contents: [Content]
        let generationConfig: DirectAITranslationServiceGenerationConfig?

        struct Content: Encodable {
            let role: String?
            let parts: [Part]

            init(role: String? = nil, parts: [Part]) {
                self.role = role
                self.parts = parts
            }
        }

        struct Part: Encodable {
            let text: String
        }
    }

    private struct GeminiResponse: Decodable {
        let candidates: [Candidate]?

        struct Candidate: Decodable {
            let content: Content?
        }

        struct Content: Decodable {
            let parts: [Part]?
        }

        struct Part: Decodable {
            let text: String?
        }
    }

    private struct AnthropicRequest: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    private struct AnthropicResponse: Decodable {
        let content: [Content]

        struct Content: Decodable {
            let text: String?
        }
    }
}

// MARK: - 关闭深度思考
//
// 深度思考（思维链）默认开启：模型先输出一大段推理再给译文。翻译是一句话直译
// 的活，这段推理只是拖慢首字延迟并按输出 token 计费，所以设置页给了一个开关。
//
// 没有统一参数：`enable_thinking` 是 Qwen 系模板变量，DeepSeek 用
// `thinking.type`，Gemini 用 `thinkingConfig.thinkingBudget`，而 GPT 与 Claude
// 的 `reasoning` 字段同时表达「思考强度」，拿它当关闭开关会连非推理模型一起打
// 挂，所以这两个服务商只带请求头。与 Kotlin 侧的 `ThinkingModePolicy` 一一对应。

private let disableThinkingHeader = "X-Enable-Thinking"
private let disableThinkingPassthroughHeader = "X-Jerreader-Disable-Thinking"

/// Chat Completions 的请求体。声明在文件层而不是服务内部，是因为下面几个
/// `extension` 要自己拼这个请求体；文件层的 private 让它既可见又不出这个文件。
private struct DirectAITranslationServiceChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool
    // 「关闭深度思考」用到的可选字段。Swift 的 JSONEncoder 会省略 nil，
    // 所以开关关闭时请求体与加这个功能之前完全一致。
    let enableThinking: Bool?
    let chatTemplateKwargs: [String: Bool]?
    let thinking: ThinkingSwitch?
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case enableThinking = "enable_thinking"
        case chatTemplateKwargs = "chat_template_kwargs"
        case thinking
        case reasoningEffort = "reasoning_effort"
    }

    struct ThinkingSwitch: Encodable {
        let type: String
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

/// Gemini 的 `generationConfig`，只在关闭深度思考时出现。
private struct DirectAITranslationServiceGenerationConfig: Encodable {
    let thinkingConfig: ThinkingConfig

    struct ThinkingConfig: Encodable {
        /// 0 表示不分配思考预算，也就是关掉深度思考。
        let thinkingBudget: Int
    }
}

extension BackendTranslationConfiguration {
    /// 开关关闭时为空表，请求与加这个功能之前逐字节相同。
    var disableDeepThinkingHeaders: [String: String] {
        disableDeepThinking
            ? [disableThinkingHeader: "false", disableThinkingPassthroughHeader: "1"]
            : [:]
    }
}

/// 收窄成 `private`：这两个成员在签名里用到文件级 private 的请求体类型，Swift
/// 不允许声明比签名里的类型更可见。使用点都在本文件内。
private extension DirectAITranslationConfiguration {
    /// 开关关闭时为空表，请求与加这个功能之前逐字节相同。
    var disableDeepThinkingHeaders: [String: String] {
        disableDeepThinking
            ? [disableThinkingHeader: "false", disableThinkingPassthroughHeader: "1"]
            : [:]
    }

    /// Chat Completions 的请求体。开关关闭时不写任何思考参数。
    func chatCompletionsRequest(
        systemInstruction: String,
        userContent: String
    ) -> DirectAITranslationServiceChatRequest {
        DirectAITranslationServiceChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemInstruction),
                .init(role: "user", content: userContent),
            ],
            stream: false,
            enableThinking: disableDeepThinking && provider.wantsEnableThinkingFalse
                ? false
                : nil,
            chatTemplateKwargs: disableDeepThinking
                && provider.wantsChatTemplateKwargs
                ? ["enable_thinking": false]
                : nil,
            thinking: disableDeepThinking && provider == .deepSeek
                ? .init(type: "disabled")
                : nil,
            reasoningEffort: disableDeepThinking && provider == .deepSeek
                ? "none"
                : nil
        )
    }

    /// Gemini 的 `thinkingBudget: 0`；其他服务商没有这一项。
    var geminiGenerationConfig: DirectAITranslationServiceGenerationConfig? {
        guard disableDeepThinking, provider == .gemini else { return nil }
        return .init(thinkingConfig: .init(thinkingBudget: 0))
    }
}

private extension DirectAIProviderChoice {
    /// 顶层 `enable_thinking` 是 Qwen 系模板变量最常见的写法。
    var wantsEnableThinkingFalse: Bool {
        self == .kimi || self == .openAICompatible
    }

    /// vLLM / SGLang 与部分兼容网关要求模板变量嵌在 `chat_template_kwargs` 里，
    /// 顶层那份会被忽略。两个都发，认识其中一个的服务端就能生效。
    var wantsChatTemplateKwargs: Bool {
        self == .openAICompatible
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
