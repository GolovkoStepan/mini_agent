# frozen_string_literal: true

RSpec.describe MiniAgent::LLMClient do
  let(:base_url) { "http://llm.test/v1" }
  let(:endpoint) { "#{base_url}/chat/completions" }
  # retry_delay: 0 — тесты не должны спать между попытками.
  let(:config) do
    MiniAgent::Config.new({ base_url: base_url, api_key: "secret", model: "test-model", retry_delay: 0 }, env: {})
  end

  subject(:client) { described_class.new(config: config) }

  def chat_response(content: "готово", tool_calls: nil)
    message = { "role" => "assistant", "content" => content }
    message["tool_calls"] = tool_calls if tool_calls
    { "choices" => [{ "message" => message }] }.to_json
  end

  let(:messages) { [{ role: "user", content: "привет" }] }

  describe "успешный ответ" do
    it "возвращает текст и пустой список вызовов" do
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response)

      content, tool_calls = client.chat(messages)

      expect(content).to eq("готово")
      expect(tool_calls).to eq([])
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

    it "не падает на невалидных байтах в теле ошибки" do
      stub_request(:post, endpoint).to_return(status: 400, body: "bad \xFF\xFE byte".dup.force_encoding(Encoding::BINARY))

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /400/)
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
