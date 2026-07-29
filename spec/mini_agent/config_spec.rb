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
end
