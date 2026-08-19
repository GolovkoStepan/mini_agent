# frozen_string_literal: true

require "json"

RSpec.describe MiniAgent::ChatPayload do
  def body(options = {}, **payload_args)
    config = MiniAgent::Config.new(options, env: {})
    messages = [{ role: "user", content: "привет" }]
    JSON.parse(described_class.new(config: config, messages: messages, **payload_args).to_json)
  end

  describe "обязательные поля" do
    it "кладёт модель, сообщения и лимит генерации" do
      result = body

      expect(result["model"]).to eq("qwen/qwen3.6-35b-a3b")
      expect(result["messages"]).to eq([{ "role" => "user", "content" => "привет" }])
      expect(result["max_tokens"]).to eq(16_384)
    end
  end

  describe "параметры сэмплинга" do
    # Ради этого примера класс и обзавёлся спекой. Прежняя константа
    # TEMPERATURE = 0.1 уходила в каждый запрос и молча перебивала пресет,
    # загруженный на сервере: выставленная там температура не применялась
    # никогда, а заметить это по поведению агента было нельзя.
    it "не шлёт температуру, когда её не задавали" do
      expect(body).not_to have_key("temperature")
    end

    it "не шлёт ни одного параметра сэмплинга по умолчанию" do
      keys = MiniAgent::Sampling::KEYS.keys.map(&:to_s)

      expect(body.keys).not_to include(*keys)
    end

    it "шлёт заданное человеком" do
      result = body({ temperature: 0.3, top_k: 50, repeat_penalty: 1.12 })

      expect(result).to include("temperature" => 0.3, "top_k" => 50, "repeat_penalty" => 1.12)
    end

    it "шлёт зерно генератора" do
      expect(body({ seed: 42 })).to include("seed" => 42)
    end
  end

  describe "потоковый режим" do
    # Без include_usage сервер не присылает usage в потоке вовсе, и /usage
    # с /context показывали бы нули — не ошибку, а правдоподобные числа.
    it "просит usage вместе с потоком" do
      result = body({ stream: true })

      expect(result["stream"]).to be(true)
      expect(result["stream_options"]).to eq({ "include_usage" => true })
    end

    it "не упоминает поток, когда он выключен" do
      result = body({ stream: false })

      expect(result).not_to have_key("stream")
      expect(result).not_to have_key("stream_options")
    end
  end

  describe "инструменты" do
    let(:tools) { [{ type: "function", function: { name: "bash" } }] }

    it "не упоминает инструменты, когда их нет" do
      expect(body).not_to have_key("tools")
      expect(body).not_to have_key("tool_choice")
    end

    it "кладёт инструменты вместе со способом выбора" do
      result = body({}, tools: tools)

      expect(result["tools"].first["function"]["name"]).to eq("bash")
      expect(result["tool_choice"]).to eq("auto")
    end

    # "none" нужен суммирующему запросу: иначе модель вернёт очередной вызов,
    # применить который уже негде, и он потеряется молча.
    it "передаёт запрет на вызовы" do
      expect(body({}, tools: tools, tool_choice: "none")["tool_choice"]).to eq("none")
    end
  end
end
