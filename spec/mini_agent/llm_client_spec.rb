# frozen_string_literal: true

RSpec.describe MiniAgent::LLMClient do
  let(:base_url) { "http://llm.test/v1" }
  let(:endpoint) { "#{base_url}/chat/completions" }
  # retry_delay: 0 — тесты не должны спать между попытками.
  let(:config) do
    MiniAgent::Config.new({ base_url: base_url, api_key: "secret", model: "test-model", retry_delay: 0 }, env: {})
  end

  subject(:client) { described_class.new(config: config) }

  def chat_response(content: "готово", tool_calls: nil, usage: nil)
    message = { "role" => "assistant", "content" => content }
    message["tool_calls"] = tool_calls if tool_calls
    body = { "choices" => [{ "message" => message }] }
    body["usage"] = usage if usage
    body.to_json
  end

  let(:messages) { [{ role: "user", content: "привет" }] }

  describe "успешный ответ" do
    it "возвращает текст и пустой список вызовов" do
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response)

      content, tool_calls = client.chat(messages)

      expect(content).to eq("готово")
      expect(tool_calls).to eq([])
    end

    # Расход токенов сервер кладёт рядом с choices, а не внутрь сообщения.
    # Клиент отдаёт его как есть: считать — забота Usage.
    it "отдаёт usage третьим элементом" do
      tokens = { "prompt_tokens" => 13, "completion_tokens" => 5, "total_tokens" => 18 }
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response(usage: tokens))

      _content, _tool_calls, usage = client.chat(messages)

      expect(usage).to include("prompt_tokens" => 13, "completion_tokens" => 5)
    end

    # Спецификация usage не требует: ответ без него — обычное дело,
    # а не повод для ошибки.
    it "не ломается, когда сервер не прислал usage" do
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response)

      content, _tool_calls, usage = client.chat(messages)

      expect(content).to eq("готово")
      expect(usage).to be_nil
    end

    it "возвращает вызовы инструментов" do
      calls = [{ "id" => "call_1", "function" => { "name" => "bash", "arguments" => "{}" } }]
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response(content: nil, tool_calls: calls))

      content, tool_calls = client.chat(messages)

      expect(content).to eq("")
      expect(tool_calls).to eq(calls)
    end

    it "передаёт модель, токены и авторизацию" do
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response)

      client.chat(messages)

      expect(a_request(:post, endpoint).with(
               headers: { "Authorization" => "Bearer secret", "Content-Type" => "application/json" },
               body: hash_including("model" => "test-model", "max_tokens" => 4096)
             )).to have_been_made
    end

    it "передаёт схемы инструментов, когда они есть" do
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response)

      client.chat(messages, tools: [MiniAgent::Tools::Bash::SCHEMA])

      expect(a_request(:post, endpoint).with(body: hash_including("tool_choice" => "auto"))).to have_been_made
    end

    # Иначе на финальном суммирующем запросе модель может вернуть
    # очередной tool_call, который уже некуда применить.
    it "умеет запрещать вызовы инструментов" do
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response)

      client.chat(messages, tools: [MiniAgent::Tools::Bash::SCHEMA], tool_choice: "none")

      expect(a_request(:post, endpoint).with(body: hash_including("tool_choice" => "none"))).to have_been_made
    end

    it "не передаёт tools, когда инструментов нет" do
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response)

      client.chat(messages)

      expect(a_request(:post, endpoint).with { |req| !JSON.parse(req.body).key?("tools") }).to have_been_made
    end
  end

  describe "повторные попытки" do
    it "повторяет запрос после HTTP 500 и возвращает успешный ответ" do
      stub_request(:post, endpoint)
        .to_return(status: 500, body: "boom").then
        .to_return(status: 200, body: chat_response(content: "со второй попытки"))

      content, = client.chat(messages)

      expect(content).to eq("со второй попытки")
      expect(a_request(:post, endpoint)).to have_been_made.twice
    end

    it "повторяет запрос при отказе соединения" do
      stub_request(:post, endpoint)
        .to_raise(Errno::ECONNREFUSED).then
        .to_return(status: 200, body: chat_response)

      expect(client.chat(messages).first).to eq("готово")
    end

    it "повторяет запрос при таймауте чтения" do
      stub_request(:post, endpoint)
        .to_timeout.then
        .to_return(status: 200, body: chat_response)

      expect(client.chat(messages).first).to eq("готово")
    end

    it "бросает LLMError, исчерпав попытки" do
      stub_request(:post, endpoint).to_return(status: 503, body: "unavailable")

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /503/)
      expect(a_request(:post, endpoint)).to have_been_made.times(3)
    end

    # Net::HTTP отдаёт тело как ASCII-8BIT, если сервер не прислал charset.
    # Без перекодировки склейка с русским текстом сообщения роняет клиент
    # Encoding::CompatibilityError вместо того, чтобы показать ошибку сервера.
    it "показывает ошибку сервера с русским текстом в теле" do
      body = '{"error":"Сообщение system должно быть первым"}'.dup.force_encoding(Encoding::BINARY)
      stub_request(:post, endpoint).to_return(status: 400, body: body)

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /должно быть первым/)
    end

    # Ошибка запроса не станет успехом на второй попытке: повтор только
    # платит retry_delay за тот же самый ответ.
    it "не повторяет запрос при HTTP 400" do
      stub_request(:post, endpoint).to_return(status: 400, body: "bad request")

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /400/)
      expect(a_request(:post, endpoint)).to have_been_made.once
    end

    it "не повторяет запрос при HTTP 401" do
      stub_request(:post, endpoint).to_return(status: 401, body: "unauthorized")

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /401/)
      expect(a_request(:post, endpoint)).to have_been_made.once
    end

    it "не повторяет запрос при HTTP 404" do
      stub_request(:post, endpoint).to_return(status: 404, body: "model not found")

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /404/)
      expect(a_request(:post, endpoint)).to have_been_made.once
    end

    # 429 — исключение среди 4xx: сервер занят, а не запрос плох.
    it "повторяет запрос при HTTP 429" do
      stub_request(:post, endpoint)
        .to_return(status: 429, body: "slow down").then
        .to_return(status: 200, body: chat_response)

      expect(client.chat(messages).first).to eq("готово")
      expect(a_request(:post, endpoint)).to have_been_made.twice
    end

    # Сообщение об ошибке достаём из error.message: сырой JSON в консоли
    # читать невозможно, а именно это поле сервер заполняет осмысленно.
    it "показывает текст из поля error.message" do
      body = { error: { message: "Модель qwen не загружена", type: "invalid_request_error" } }.to_json
      stub_request(:post, endpoint).to_return(status: 400, body: body)

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /Модель qwen не загружена/)
    end

    it "не падает на невалидных байтах в теле ошибки" do
      stub_request(:post, endpoint).to_return(status: 400, body: "bad \xFF\xFE byte".dup.force_encoding(Encoding::BINARY))

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /400/)
    end

    # Сервер знает, когда освободится, а настроенная задержка — только догадка.
    it "ждёт время из заголовка Retry-After вместо настроенной задержки" do
      slept = []
      config = MiniAgent::Config.new({ base_url: base_url, retry_delay: 2 }, env: {})
      client = described_class.new(config: config, sleeper: ->(seconds) { slept << seconds })
      stub_request(:post, endpoint)
        .to_return(status: 429, headers: { "Retry-After" => "5" }).then
        .to_return(status: 200, body: chat_response)

      client.chat(messages)

      expect(slept).to eq([5.0])
    end

    # Иначе задержка от давнего 429 тянулась бы через все следующие повторы.
    it "не переносит Retry-After на последующие попытки" do
      slept = []
      config = MiniAgent::Config.new({ base_url: base_url, retry_delay: 2 }, env: {})
      client = described_class.new(config: config, sleeper: ->(seconds) { slept << seconds })
      stub_request(:post, endpoint)
        .to_return(status: 429, headers: { "Retry-After" => "5" }).then
        .to_return(status: 500).then
        .to_return(status: 200, body: chat_response)

      client.chat(messages)

      expect(slept).to eq([5.0, 2.0])
    end

    # Сервер вправе попросить и час, но агент интерактивный: молчаливое
    # ожидание неотличимо от зависания.
    it "ограничивает Retry-After потолком" do
      slept = []
      config = MiniAgent::Config.new({ base_url: base_url, retry_delay: 2 }, env: {})
      client = described_class.new(config: config, sleeper: ->(seconds) { slept << seconds })
      stub_request(:post, endpoint)
        .to_return(status: 429, headers: { "Retry-After" => "3600" }).then
        .to_return(status: 200, body: chat_response)

      client.chat(messages)

      expect(slept).to eq([MiniAgent::ErrorResponse::MAX_RETRY_AFTER.to_f])
    end

    # HTTP-дата в Retry-After спецификацией допустима, но локальные серверы
    # её не шлют — разбирать её значило бы тянуть зависимость от времени.
    it "игнорирует Retry-After в формате даты" do
      slept = []
      config = MiniAgent::Config.new({ base_url: base_url, retry_delay: 2 }, env: {})
      client = described_class.new(config: config, sleeper: ->(seconds) { slept << seconds })
      stub_request(:post, endpoint)
        .to_return(status: 429, headers: { "Retry-After" => "Wed, 21 Oct 2026 07:28:00 GMT" }).then
        .to_return(status: 200, body: chat_response)

      client.chat(messages)

      expect(slept).to eq([2.0])
    end

    it "уважает настроенное число попыток" do
      config = MiniAgent::Config.new({ base_url: base_url, retry_count: 5, retry_delay: 0 }, env: {})
      stub_request(:post, endpoint).to_return(status: 500)

      expect { described_class.new(config: config).chat(messages) }.to raise_error(MiniAgent::LLMError)
      expect(a_request(:post, endpoint)).to have_been_made.times(5)
    end

    # Объект Net::HTTP::Post нельзя переиспользовать между попытками:
    # запрос должен создаваться заново, а тело — оставаться корректным.
    it "отправляет корректное тело на повторной попытке" do
      stub_request(:post, endpoint)
        .to_return(status: 500).then
        .to_return(status: 200, body: chat_response)

      client.chat(messages)

      expect(a_request(:post, endpoint).with(body: hash_including("model" => "test-model")))
        .to have_been_made.twice
    end
  end

  describe "некорректные ответы" do
    it "повторяет и падает при пустом choices" do
      stub_request(:post, endpoint).to_return(status: 200, body: { "choices" => [] }.to_json)

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /choices/)
    end

    it "повторяет и падает при отсутствующем message" do
      stub_request(:post, endpoint).to_return(status: 200, body: { "choices" => [{}] }.to_json)

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /message/)
    end

    it "повторяет и падает при некорректном JSON" do
      stub_request(:post, endpoint).to_return(status: 200, body: "не json")

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /JSON/)
    end

    it "восстанавливается, если некорректным был только первый ответ" do
      stub_request(:post, endpoint)
        .to_return(status: 200, body: "не json").then
        .to_return(status: 200, body: chat_response)

      expect(client.chat(messages).first).to eq("готово")
    end
  end

  describe "#models" do
    let(:models_endpoint) { "#{base_url}/models" }

    it "возвращает отсортированные имена моделей" do
      body = { "data" => [{ "id" => "qwen" }, { "id" => "deepseek" }] }.to_json
      stub_request(:get, models_endpoint).to_return(status: 200, body: body)

      expect(client.models).to eq(%w[deepseek qwen])
    end

    it "возвращает пустой список, когда моделей нет" do
      stub_request(:get, models_endpoint).to_return(status: 200, body: { "data" => [] }.to_json)

      expect(client.models).to eq([])
    end

    it "пропускает записи без id" do
      body = { "data" => [{ "id" => "qwen" }, { "object" => "model" }] }.to_json
      stub_request(:get, models_endpoint).to_return(status: 200, body: body)

      expect(client.models).to eq(["qwen"])
    end

    it "передаёт авторизацию" do
      stub_request(:get, models_endpoint).to_return(status: 200, body: { "data" => [] }.to_json)

      client.models

      expect(a_request(:get, models_endpoint).with(headers: { "Authorization" => "Bearer secret" }))
        .to have_been_made
    end

    # Разовая справочная команда: человек смотрит в терминал, и молча ждать
    # несколько секунд перед показом ошибки хуже, чем показать её сразу.
    it "не повторяет запрос при ошибке" do
      stub_request(:get, models_endpoint).to_return(status: 500, body: "boom")

      expect { client.models }.to raise_error(MiniAgent::LLMError, /500/)
      expect(a_request(:get, models_endpoint)).to have_been_made.once
    end

    it "бросает LLMError на некорректном JSON" do
      stub_request(:get, models_endpoint).to_return(status: 200, body: "не json")

      expect { client.models }.to raise_error(MiniAgent::LLMError, /JSON/)
    end

    it "бросает LLMError, когда поле data не список" do
      stub_request(:get, models_endpoint).to_return(status: 200, body: { "data" => "qwen" }.to_json)

      expect { client.models }.to raise_error(MiniAgent::LLMError, /data/)
    end

    # LM Studio на неверный путь отвечает 200 с полем error в теле.
    it "показывает ошибку из тела, пришедшую с кодом 200" do
      body = { "error" => "Unexpected endpoint or method." }.to_json
      stub_request(:get, models_endpoint).to_return(status: 200, body: body)

      expect { client.models }.to raise_error(MiniAgent::LLMError, /Unexpected endpoint/)
    end
  end

  describe "#start" do
    it "выполняет блок и закрывает соединение" do
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response)

      result = client.start { |c| c.chat(messages).first }

      expect(result).to eq("готово")
    end
  end

  # В исходном скрипте вызов без предварительного start_http падал
  # с NoMethodError на nil.
  it "работает без явного вызова start" do
    stub_request(:post, endpoint).to_return(status: 200, body: chat_response)

    expect { client.chat(messages) }.not_to raise_error
  end
end
