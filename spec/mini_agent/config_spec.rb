# frozen_string_literal: true

RSpec.describe MiniAgent::Config do
  describe "приоритет источников" do
    it "берёт значение по умолчанию, когда нет ни опций, ни ENV" do
      config = described_class.new({}, env: {})

      expect(config.model).to eq("qwen/qwen3.6-35b-a3b")
      expect(config.max_turns).to eq(10)
    end

    it "предпочитает ENV значению по умолчанию" do
      config = described_class.new({}, env: { "LLM_MODEL" => "llama3" })

      expect(config.model).to eq("llama3")
    end

    it "предпочитает опции переменным окружения" do
      config = described_class.new({ model: "from-cli" }, env: { "LLM_MODEL" => "from-env" })

      expect(config.model).to eq("from-cli")
    end

    # В исходном скрипте base_url/api_key/model читались только из ENV
    # и молча игнорировали переданные опции.
    it "учитывает опции для base_url, api_key и model" do
      config = described_class.new(
        { base_url: "http://cli:9/v1", api_key: "cli-key", model: "cli-model" },
        env: { "LLM_BASE_URL" => "http://env:1/v1", "LLM_API_KEY" => "env", "LLM_MODEL" => "env" }
      )

      expect(config.base_url).to eq("http://cli:9/v1")
      expect(config.api_key).to eq("cli-key")
      expect(config.model).to eq("cli-model")
    end

    it "игнорирует пустую переменную окружения" do
      config = described_class.new({}, env: { "LLM_MODEL" => "" })

      expect(config.model).to eq("qwen/qwen3.6-35b-a3b")
    end
  end

  describe "#allow_unsafe?" do
    it "по умолчанию выключен" do
      expect(described_class.new({}, env: {}).allow_unsafe?).to be(false)
    end

    it "включается через ALLOW_UNSAFE=true" do
      expect(described_class.new({}, env: { "ALLOW_UNSAFE" => "true" }).allow_unsafe?).to be(true)
    end

    it "не реагирует на произвольное значение ALLOW_UNSAFE" do
      expect(described_class.new({}, env: { "ALLOW_UNSAFE" => "maybe" }).allow_unsafe?).to be(false)
    end

    # Баг исходника: options[:allow_unsafe] || ENV[...] терял явное false,
    # поэтому --no-allow-unsafe не мог перебить переменную окружения.
    it "позволяет флагу --no-allow-unsafe перебить ALLOW_UNSAFE=true" do
      config = described_class.new({ allow_unsafe: false }, env: { "ALLOW_UNSAFE" => "true" })

      expect(config.allow_unsafe?).to be(false)
    end
  end

  describe "#chat_uri" do
    it "собирает адрес эндпоинта из base_url" do
      config = described_class.new({ base_url: "http://localhost:1234/v1" }, env: {})

      expect(config.chat_uri.to_s).to eq("http://localhost:1234/v1/chat/completions")
    end

    it "не удваивает слеш при завершающем слеше в base_url" do
      config = described_class.new({ base_url: "http://localhost:1234/v1/" }, env: {})

      expect(config.chat_uri.to_s).to eq("http://localhost:1234/v1/chat/completions")
    end

    it "определяет ssl по схеме адреса" do
      expect(described_class.new({ base_url: "https://api.example.com/v1" }, env: {}).use_ssl?).to be(true)
      expect(described_class.new({ base_url: "http://api.example.com/v1" }, env: {}).use_ssl?).to be(false)
    end
  end

  describe "приведение типов" do
    it "приводит числовые значения из ENV к числам" do
      config = described_class.new({}, env: { "MAX_TURNS" => "42", "MAX_TOKENS" => "8192" })

      expect(config.max_turns).to eq(42)
      expect(config.max_tokens).to eq(8192)
    end
  end

  # Ожидание ответа модели и таймаут команд bash — разные вещи, и держать
  # на них одно число значит, что правка ради медленной модели молча
  # продлит и зависшую команду.
  describe "ожидание ответа модели" do
    it "по умолчанию 600 секунд" do
      expect(described_class.new({}, env: {}).llm_timeout).to eq(600)
    end

    it "читается из опции и из ENV" do
      expect(described_class.new({ llm_timeout: 30 }, env: {}).llm_timeout).to eq(30)
      expect(described_class.new({}, env: { "LLM_TIMEOUT" => "45" }).llm_timeout).to eq(45)
    end

    it "не путается с таймаутом команд" do
      config = described_class.new({ llm_timeout: 300 }, env: { "COMMAND_TIMEOUT" => "10" })

      expect(config.llm_timeout).to eq(300)
      expect(config.timeout).to eq(10)
    end
  end

  describe "контекстное окно" do
    it "по умолчанию неизвестно" do
      expect(described_class.new({}, env: {}).context_window).to be_nil
    end

    it "читается из опции и из ENV" do
      expect(described_class.new({ context_window: 65_536 }, env: {}).context_window).to eq(65_536)
      expect(described_class.new({}, env: { "CONTEXT_WINDOW" => "8192" }).context_window).to eq(8192)
    end

    # Ноль и мусор означают то же, что и отсутствие значения. Превратить их
    # в 0 значило бы сделать «неизвестно» неотличимым от «окно нулевого
    # размера», и всё, что считает доли от окна, делило бы на ноль.
    it "не принимает ноль и мусор за размер" do
      expect(described_class.new({ context_window: 0 }, env: {}).context_window).to be_nil
      expect(described_class.new({}, env: { "CONTEXT_WINDOW" => "мусор" }).context_window).to be_nil
    end

    # Записываемо: значение приходит от сервера уже после создания настроек.
    it "принимает узнанное у сервера значение" do
      config = described_class.new({}, env: {})
      config.context_window = 8192

      expect(config.context_window).to eq(8192)
    end
  end

  describe "рабочий каталог" do
    around do |example|
      Dir.mktmpdir { |dir| example.run(@dir = dir) }
    end

    it "по умолчанию не задан" do
      expect(described_class.new({}, env: {}).cwd).to be_nil
    end

    it "разворачивает относительный путь в абсолютный" do
      config = described_class.new({ cwd: @dir }, env: {})

      expect(config.cwd).to eq(File.expand_path(@dir))
    end

    it "читается из AGENT_CWD" do
      config = described_class.new({}, env: { "AGENT_CWD" => @dir })

      expect(config.cwd).to eq(File.expand_path(@dir))
    end

    # Иначе опечатка в пути всплывёт посреди работы невнятной ошибкой Open3,
    # уже после запроса к модели.
    it "падает сразу, если каталога нет" do
      expect { described_class.new({ cwd: "/нет/такого/каталога" }, env: {}) }
        .to raise_error(MiniAgent::ConfigError, /Рабочий каталог не найден/)
    end

    it "падает, если путь ведёт на файл" do
      path = File.join(@dir, "файл.txt")
      File.write(path, "не каталог")

      expect { described_class.new({ cwd: path }, env: {}) }.to raise_error(MiniAgent::ConfigError)
    end

    it "пустое значение равносильно отсутствию" do
      expect(described_class.new({}, env: { "AGENT_CWD" => "" }).cwd).to be_nil
    end
  end

  describe "журнал" do
    around do |example|
      Dir.mktmpdir { |dir| example.run(@dir = dir) }
    end

    # В журнал уходят и задачи, и содержимое всего, что агент прочитал.
    # Включать такое молча нельзя.
    it "по умолчанию выключен" do
      expect(described_class.new({}, env: {}).log).to be_nil
    end

    it "разворачивает путь в абсолютный" do
      config = described_class.new({ log: File.join(@dir, "session.jsonl") }, env: {})

      expect(config.log).to eq(File.join(File.expand_path(@dir), "session.jsonl"))
    end

    it "читается из AGENT_LOG" do
      config = described_class.new({}, env: { "AGENT_LOG" => File.join(@dir, "s.jsonl") })

      expect(config.log).to end_with("s.jsonl")
    end

    # Файла ещё нет — это норма, а вот каталога быть обязан.
    it "не требует существования самого файла" do
      expect { described_class.new({ log: File.join(@dir, "нового.jsonl") }, env: {}) }.not_to raise_error
    end

    it "падает сразу, если каталога нет" do
      expect { described_class.new({ log: "/нет/такого/каталога/s.jsonl" }, env: {}) }
        .to raise_error(MiniAgent::ConfigError, /Каталог для журнала не найден/)
    end

    it "пустое значение равносильно отсутствию" do
      expect(described_class.new({}, env: { "AGENT_LOG" => "" }).log).to be_nil
    end
  end
end
