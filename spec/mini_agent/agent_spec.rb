# frozen_string_literal: true

RSpec.describe MiniAgent::Agent do
  let(:out) { StringIO.new }
  let(:ui) { MiniAgent::UI.new(out: out, tty: false) }
  let(:config) { MiniAgent::Config.new({ max_turns: 3 }, env: {}) }
  let(:client) { instance_double(MiniAgent::LLMClient) }

  # Инструмент-заглушка: без процессов, полностью предсказуемый.
  let(:echo_tool) do
    Class.new do
      attr_reader :calls

      def initialize = @calls = []
      def name = "echo"
      def schema = { "type" => "function", "function" => { "name" => "echo" } }

      def call(arguments)
        @calls << arguments
        "результат: #{arguments["text"]}"
      end
    end.new
  end

  let(:tools) { MiniAgent::ToolRegistry.new([echo_tool]) }

  subject(:agent) { described_class.new(config: config, client: client, tools: tools, ui: ui) }

  def tool_call(text: "привет", id: "call_1")
    {
      "id" => id,
      "function" => { "name" => "echo", "arguments" => { "text" => text }.to_json }
    }
  end

  describe "завершение работы" do
    it "останавливается, когда модель ответила без вызовов инструментов" do
      allow(client).to receive(:chat).and_return(["всё готово", []])

      conversation = agent.run("задача")

      expect(client).to have_received(:chat).once
      expect(conversation.last).to eq({ role: "assistant", content: "всё готово" })
      expect(out.string).to include("● всё готово")
    end

    it "сообщает о пустом ответе без вызовов инструментов" do
      allow(client).to receive(:chat).and_return(["", []])

      agent.run("задача")

      expect(out.string).to include("пустой ответ")
    end
  end

  describe "выполнение инструментов" do
    it "выполняет вызов и продолжает цикл" do
      allow(client).to receive(:chat)
        .and_return(["сейчас посмотрю", [tool_call(text: "мир")]], ["готово", []])

      conversation = agent.run("задача")

      expect(echo_tool.calls).to eq([{ "text" => "мир" }])
      expect(client).to have_received(:chat).twice

      roles = conversation.to_a.map { |m| m[:role] }
      expect(roles).to eq(%w[system user assistant tool assistant])
    end

    it "связывает ответ инструмента с идентификатором вызова" do
      allow(client).to receive(:chat).and_return(["", [tool_call(id: "call_xyz")]], ["готово", []])

      conversation = agent.run("задача")
      tool_message = conversation.to_a.find { |m| m[:role] == "tool" }

      expect(tool_message[:tool_call_id]).to eq("call_xyz")
    end

    it "выполняет несколько вызовов за один ход" do
      calls = [tool_call(text: "раз", id: "c1"), tool_call(text: "два", id: "c2")]
      allow(client).to receive(:chat).and_return(["", calls], ["готово", []])

      agent.run("задача")

      expect(echo_tool.calls).to eq([{ "text" => "раз" }, { "text" => "два" }])
    end

    it "передаёт модели сообщение об ошибке при неизвестном инструменте" do
      bad = { "id" => "c1", "function" => { "name" => "magic", "arguments" => "{}" } }
      allow(client).to receive(:chat).and_return(["", [bad]], ["готово", []])

      conversation = agent.run("задача")
      tool_message = conversation.to_a.find { |m| m[:role] == "tool" }

      expect(tool_message[:content]).to include("неизвестный инструмент")
    end

    # Битый JSON не должен ронять цикл: модель получает сообщение об ошибке
    # и может исправиться на следующем ходу.
    it "не роняет цикл при некорректном JSON в аргументах" do
      broken = { "id" => "c1", "function" => { "name" => "echo", "arguments" => "{не json" } }
      allow(client).to receive(:chat).and_return(["", [broken]], ["готово", []])

      conversation = agent.run("задача")
      tool_message = conversation.to_a.find { |m| m[:role] == "tool" }

      expect(tool_message[:content]).to include("Ошибка разбора аргументов")
      expect(echo_tool.calls).to be_empty
    end
  end

  describe "ограничение вывода инструмента" do
    let(:long_tool) do
      Class.new do
        def name = "long"
        def schema = {}
        def call(_arguments) = "x" * 25_000
      end.new
    end

    let(:tools) { MiniAgent::ToolRegistry.new([long_tool]) }

    # Два независимых бюджета: модель получает усечённый текст ради контекста,
    # пользователь видит вывод целиком (с отдельным усечением для читаемости).
    it "обрезает результат, уходящий в модель" do
      call = { "id" => "c1", "function" => { "name" => "long", "arguments" => "{}" } }
      allow(client).to receive(:chat).and_return(["", [call]], ["готово", []])

      conversation = agent.run("задача")
      tool_message = conversation.to_a.find { |m| m[:role] == "tool" }

      expect(tool_message[:content].length)
        .to eq(described_class::MAX_TOOL_OUTPUT + MiniAgent::Messages::TRUNCATED_SUFFIX.length)
      expect(tool_message[:content]).to end_with("(truncated)")
    end

    it "не трогает короткий результат" do
      allow(client).to receive(:chat).and_return(["", [tool_call(text: "коротко")]], ["готово", []])

      conversation = described_class.new(
        config: config, client: client, tools: MiniAgent::ToolRegistry.new([echo_tool]), ui: ui
      ).run("задача")
      tool_message = conversation.to_a.find { |m| m[:role] == "tool" }

      expect(tool_message[:content]).to eq("результат: коротко")
    end
  end

  describe "лимит ходов" do
    it "останавливается и запрашивает итог" do
      allow(client).to receive(:chat).and_return(["работаю", [tool_call]])

      conversation = agent.run("задача")

      # 3 хода + 1 суммирующий вызов
      expect(client).to have_received(:chat).exactly(4).times
      expect(out.string).to include("Достигнуто максимальное число ходов")
      expect(conversation.to_a).to include(hash_including(content: MiniAgent::Messages::STOP_MAX_TURNS))
    end

    # Шаблоны чата Qwen и ряда других моделей принимают system только первым
    # сообщением и отвечают HTTP 400 на system в середине истории.
    it "просит итог ролью user, а не system" do
      allow(client).to receive(:chat).and_return(["работаю", [tool_call]])

      conversation = agent.run("задача")
      stop_message = conversation.to_a.find { |m| m[:content] == MiniAgent::Messages::STOP_MAX_TURNS }

      expect(stop_message[:role]).to eq("user")
      expect(conversation.to_a.drop(1)).to all(satisfy { |m| m[:role] != "system" })
    end

    # Иначе модель вернёт вызов инструмента, применить который уже негде.
    it "запрещает вызовы инструментов в суммирующем запросе" do
      allow(client).to receive(:chat).and_return(["работаю", [tool_call]])

      agent.run("задача")

      expect(client).to have_received(:chat).with(anything, hash_including(tool_choice: "none")).once
    end
  end

  describe "ошибки связи" do
    it "возвращает историю, а не бросает исключение" do
      allow(client).to receive(:chat).and_raise(MiniAgent::LLMError, "сеть недоступна")

      conversation = nil
      expect { conversation = agent.run("задача") }.not_to raise_error
      expect(conversation.to_a.map { |m| m[:role] }).to eq(%w[system user])
      expect(out.string).to include("Ошибка связи с LLM")
    end
  end

  describe "#run с существующей историей" do
    it "продолжает переданный диалог" do
      allow(client).to receive(:chat).and_return(["ответ", []])
      conversation = MiniAgent::Conversation.new
      conversation.user("первый вопрос")
      conversation.assistant("первый ответ")

      result = agent.run("второй вопрос", conversation: conversation)

      expect(result.to_a.map { |m| m[:role] }).to eq(%w[system user assistant user assistant])
    end
  end
end
