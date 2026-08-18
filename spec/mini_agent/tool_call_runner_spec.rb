# frozen_string_literal: true

RSpec.describe MiniAgent::ToolCallRunner do
  let(:out) { StringIO.new }
  let(:ui) { MiniAgent::UI.new(out: out, tty: false) }

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
  let(:conversation) { MiniAgent::History.new.build }

  subject(:runner) { described_class.new(tools: tools, ui: ui) }

  def call_with(arguments, name: "echo", id: "call_1")
    runner.call(conversation, { "id" => id, "function" => { "name" => name, "arguments" => arguments } })
    conversation.to_a.last
  end

  describe "обычный вызов" do
    it "выполняет инструмент и кладёт результат в историю" do
      message = call_with({ "text" => "привет" }.to_json)

      expect(echo_tool.calls).to eq([{ "text" => "привет" }])
      expect(message[:role]).to eq("tool")
      expect(message[:content]).to eq("результат: привет")
    end

    # Модель ждёт ответа на каждый tool_call_id: сообщение без него уходит
    # в следующий запрос дырой, и сервер отвечает отказом.
    it "связывает ответ с идентификатором вызова" do
      message = call_with("{}", id: "call_42")

      expect(message[:tool_call_id]).to eq("call_42")
    end

    it "пустые аргументы считает пустым объектом, а не ошибкой" do
      call_with("")

      expect(echo_tool.calls).to eq([{}])
    end
  end

  # Битый JSON — не повод ронять цикл: модель узнаёт о нём ответом
  # инструмента и может исправиться на следующем ходу.
  describe "негодные аргументы" do
    it "сообщает модели об ошибке разбора, а не бросает исключение" do
      message = call_with("{не json")

      expect(message[:role]).to eq("tool")
      expect(message[:content]).to include("Ошибка")
      expect(echo_tool.calls).to be_empty
    end

    it "отвергает JSON, который разобрался не в объект" do
      message = call_with("[1, 2, 3]")

      expect(message[:content]).to include("ожидался объект")
      expect(echo_tool.calls).to be_empty
    end
  end

  describe "усечение результата" do
    let(:long_tool) do
      Class.new do
        def name = "long"
        def schema = {}
        def call(_arguments) = "x" * 25_000
      end.new
    end

    let(:tools) { MiniAgent::ToolRegistry.new([long_tool]) }

    # Бюджет модели, а не пользователя: на экран вывод уходит целиком
    # (со своим усечением для читаемости — UI::PREVIEW_LINES).
    it "режет то, что уходит в модель" do
      message = call_with("{}", name: "long")

      expect(message[:content].length)
        .to eq(described_class::MAX_TOOL_OUTPUT + MiniAgent::Messages::TRUNCATED_SUFFIX.length)
    end
  end
end
