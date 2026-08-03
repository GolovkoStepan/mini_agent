# frozen_string_literal: true

RSpec.describe MiniAgent::LLMClient do
  let(:base_url) { "http://llm.test/v1" }
  let(:endpoint) { "#{base_url}/chat/completions" }
  # retry_delay: 0 — тесты не должны спать между попытками.
  # stream: false — здесь проверяется разбор обычного ответа; потоковый режим
  # включён по умолчанию и разбирается иначе, поэтому у него свой раздел ниже.
  let(:config) do
    MiniAgent::Config.new(
      { base_url: base_url, api_key: "secret", model: "test-model", retry_delay: 0, stream: false }, env: {}
    )
  end

  subject(:client) { described_class.new(config: config) }

  def chat_response(content: "готово", tool_calls: nil, usage: nil, finish_reason: nil)
    message = { "role" => "assistant", "content" => content }
    message["tool_calls"] = tool_calls if tool_calls
    choice = { "message" => message }
    choice["finish_reason"] = finish_reason if finish_reason
    body = { "choices" => [choice] }
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

    # finish_reason лежит в choices рядом с message, а не внутри него.
    # Без него обрезанный ответ неотличим от полного.
    it "отдаёт finish_reason четвёртым элементом" do
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response(finish_reason: "length"))

      *, finish_reason = client.chat(messages)

      expect(finish_reason).to eq("length")
    end

    # Поле необязательное — его отсутствие не должно выглядеть как обрыв.
    it "отдаёт nil, когда сервер не прислал finish_reason" do
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response)

      *, finish_reason = client.chat(messages)

      expect(finish_reason).to be_nil
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

    # to_timeout в webmock поднимает Net::OpenTimeout, а не ReadTimeout —
    # это таймаут ОТКРЫТИЯ соединения, и он повторяется. Про ожидание
    # ответа — отдельный блок ниже, там поведение противоположное.
    it "повторяет запрос при таймауте соединения" do
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
      config = MiniAgent::Config.new({ base_url: base_url, retry_delay: 2, stream: false }, env: {})
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
      config = MiniAgent::Config.new({ base_url: base_url, retry_delay: 2, stream: false }, env: {})
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
      config = MiniAgent::Config.new({ base_url: base_url, retry_delay: 2, stream: false }, env: {})
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
      config = MiniAgent::Config.new({ base_url: base_url, retry_delay: 2, stream: false }, env: {})
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

  # Модель считает и не успевает — не то же самое, что сбой связи.
  # Живой случай на квантованной 27B: обычный вопрос занял 176 секунд
  # при потолке в 120, и агент сообщил об этом «сетевой ошибкой».
  describe "ожидание ответа исчерпано" do
    before { stub_request(:post, endpoint).to_raise(Net::ReadTimeout) }

    # Ждать ещё дважды по столько же — значит молчать втрое дольше ради
    # того же исхода. При лимите 600 с это полчаса вместо ответа.
    it "не повторяет запрос" do
      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError)

      expect(a_request(:post, endpoint)).to have_been_made.once
    end

    # Сырой «Net::ReadTimeout with #<TCPSocket:(closed)>» выглядит как
    # обрыв сети и посылает проверять сеть вместо того, чтобы поднять лимит.
    it "называет причину и способ вместо сырой ошибки сокета" do
      expect { client.chat(messages) }
        .to raise_error(MiniAgent::LLMError, /не ответила за 600 с.*--llm-timeout/m)
    end

    it "показывает настроенный лимит, а не умолчание" do
      slow = MiniAgent::Config.new({ base_url: base_url, llm_timeout: 42 }, env: {})

      expect { described_class.new(config: slow).chat(messages) }
        .to raise_error(MiniAgent::LLMError, /за 42 с/)
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

  describe "потоковый режим" do
    # Умолчание: stream включён, и его отсутствие в этом конфиге намеренно.
    let(:config) do
      MiniAgent::Config.new({ base_url: base_url, api_key: "secret", model: "test-model", retry_delay: 0 }, env: {})
    end

    def sse(*events)
      "#{events.map { |event| "data: #{event.to_json}\n\n" }.join}data: [DONE]\n\n"
    end

    def delta(content: nil, finish_reason: nil, tool_calls: nil)
      body = {}
      body["content"] = content if content
      body["tool_calls"] = tool_calls if tool_calls
      { "choices" => [{ "index" => 0, "delta" => body, "finish_reason" => finish_reason }] }
    end

    it "просит поток и расход токенов вместе с ним" do
      stub_request(:post, endpoint).to_return(status: 200, body: sse(delta(content: "x", finish_reason: "stop")))

      client.chat(messages)

      expect(a_request(:post, endpoint).with(
               body: hash_including("stream" => true, "stream_options" => { "include_usage" => true })
             )).to have_been_made
    end

    it "собирает текст из дельт" do
      stub_request(:post, endpoint).to_return(
        status: 200, body: sse(delta(content: "при"), delta(content: "вет", finish_reason: "stop"))
      )

      content, tool_calls, _usage, finish_reason = client.chat(messages)

      expect(content).to eq("привет")
      expect(tool_calls).to eq([])
      expect(finish_reason).to eq("stop")
    end

    # usage приходит отдельным куском с пустым choices — без include_usage
    # его в потоке нет вовсе, и /usage показывал бы нули.
    it "берёт usage из завершающего куска" do
      body = sse(delta(content: "готово", finish_reason: "stop"),
                 { "choices" => [], "usage" => { "prompt_tokens" => 16, "completion_tokens" => 4 } })
      stub_request(:post, endpoint).to_return(status: 200, body: body)

      _content, _tool_calls, usage = client.chat(messages)

      expect(usage).to include("prompt_tokens" => 16, "completion_tokens" => 4)
    end

    it "склеивает вызов инструмента из кусков аргументов" do
      body = sse(
        delta(tool_calls: [{ "index" => 0, "id" => "call_1", "type" => "function",
                             "function" => { "name" => "bash", "arguments" => "" } }]),
        delta(tool_calls: [{ "index" => 0, "function" => { "arguments" => "{\"command\":" } }]),
        delta(tool_calls: [{ "index" => 0, "function" => { "arguments" => "\"ls\"}" } }], finish_reason: "tool_calls")
      )
      stub_request(:post, endpoint).to_return(status: 200, body: body)

      _content, tool_calls = client.chat(messages)

      expect(tool_calls.first["function"]).to eq("name" => "bash", "arguments" => "{\"command\":\"ls\"}")
    end

    # Ошибки разбираются одинаково в обоих режимах: тело у них обычный JSON,
    # а не поток, и ErrorResponse ждёт именно строку.
    it "не повторяет запрос при HTTP 400" do
      stub_request(:post, endpoint).to_return(status: 400, body: { "error" => "плохой запрос" }.to_json)

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /плохой запрос/)
      expect(a_request(:post, endpoint)).to have_been_made.once
    end

    it "повторяет запрос после HTTP 500" do
      stub_request(:post, endpoint)
        .to_return(status: 500, body: "boom").then
        .to_return(status: 200, body: sse(delta(content: "со второй", finish_reason: "stop")))

      content, = client.chat(messages)

      expect(content).to eq("со второй")
    end

    # Сервер, не умеющий stream, отвечает 200 с пустым телом. Без отдельной
    # ветки это выглядело бы как «модель промолчала» — и агент вышел бы
    # с кодом 0, ничего не сделав.
    it "не принимает пустой поток за пустой ответ модели" do
      stub_request(:post, endpoint).to_return(status: 200, body: "")

      expect { client.chat(messages) }.to raise_error(MiniAgent::LLMError, /--no-stream/)
    end

    it "повторяет запрос после пустого потока" do
      stub_request(:post, endpoint)
        .to_return(status: 200, body: "").then
        .to_return(status: 200, body: sse(delta(content: "получилось", finish_reason: "stop")))

      content, = client.chat(messages)

      expect(content).to eq("получилось")
    end

    # Ответ из одних вызовов инструментов текста не содержит вовсе — это
    # штатный случай, а не пустой поток.
    it "не считает пустым поток с одним лишь вызовом инструмента" do
      body = sse(delta(tool_calls: [{ "index" => 0, "id" => "call_1", "type" => "function",
                                      "function" => { "name" => "bash", "arguments" => "{}" } }],
                       finish_reason: "tool_calls"))
      stub_request(:post, endpoint).to_return(status: 200, body: body)

      content, tool_calls = client.chat(messages)

      expect(content).to eq("")
      expect(tool_calls.size).to eq(1)
    end

    it "отдаёт куски текста в UI по мере поступления" do
      ui = spy("UI")
      allow(ui).to receive(:with_spinner) { |&block| block.call }
      streaming = described_class.new(config: config, ui: ui)
      stub_request(:post, endpoint).to_return(
        status: 200, body: sse(delta(content: "раз"), delta(content: " два", finish_reason: "stop"))
      )

      streaming.chat(messages)

      expect(ui).to have_received(:stream_chunk).with("раз")
      expect(ui).to have_received(:stream_chunk).with(" два")
    end

    # Резюме для /compact замещает историю, а не адресовано человеку: при
    # стриминге оно вываливалось в терминал целиком, и следом шёл отчёт
    # «сворачивать было нечего». Найдено живой проверкой.
    it "не печатает служебный ответ" do
      ui = spy("UI")
      allow(ui).to receive(:with_spinner) { |&block| block.call }
      streaming = described_class.new(config: config, ui: ui)
      stub_request(:post, endpoint).to_return(status: 200, body: sse(delta(content: "резюме",
                                                                           finish_reason: "stop")))

      content, = streaming.chat(messages, visible: false)

      expect(content).to eq("резюме")
      expect(ui).not_to have_received(:stream_chunk)
    end

    it "не просит поток, когда он отключён" do
      plain = described_class.new(
        config: MiniAgent::Config.new({ base_url: base_url, model: "m", stream: false }, env: {})
      )
      stub_request(:post, endpoint).to_return(status: 200, body: chat_response)

      plain.chat(messages)

      expect(a_request(:post, endpoint).with { |req| !JSON.parse(req.body).key?("stream") }).to have_been_made
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
