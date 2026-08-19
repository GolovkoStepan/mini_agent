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

  # Замечено живьём: модель пять раз подряд выдала один и тот же вызов
  # и один и тот же пустой результат. При политике deny вопросов не задаётся,
  # так что заметить это можно было только глазами, а стоил каждый холостой
  # ход настоящего запроса и места в окне.
  describe "повтор вызова" do
    def run(arguments, id: "call_1")
      runner.call(conversation, { "id" => id, "function" => { "name" => "echo", "arguments" => arguments } })
    end

    let(:args) { { "text" => "раз" }.to_json }

    it "второй раз подряд не выполняет команду и возвращает прежний результат" do
      run(args)
      status = run(args)

      expect(status).to eq(:ok)
      expect(echo_tool.calls.length).to eq(1)
      expect(conversation.to_a.last[:content]).to include("результат: раз")
    end

    # Приписка стоит перед результатом: длинный вывод отодвинул бы её в хвост,
    # а короткого «уже выполнялось» модели мало — на нём она рапортует
    # о сделанном (те же грабли, что у Messages::Tool::CANCELLED).
    it "объясняет модели, что команда не выполнялась" do
      run(args)
      run(args)

      content = conversation.to_a.last[:content]
      expect(content).to include("НЕ выполнялась")
      expect(content.index("НЕ выполнялась")).to be < content.index("результат: раз")
    end

    it "третий раз подряд обрывает задачу" do
      run(args)
      run(args)
      status = run(args)

      expect(status).to eq(:loop)
      expect(echo_tool.calls.length).to eq(1)
    end

    # Модель ждёт ответа на каждый tool_call_id: брошенный без ответа вызов
    # оставил бы в истории дыру, от которой валится следующий запрос.
    it "и на обрыве отвечает на вызов" do
      3.times { run(args, id: "call_7") }

      message = conversation.to_a.last
      expect(message[:role]).to eq("tool")
      expect(message[:tool_call_id]).to eq("call_7")
    end

    it "не считает повтором вызов с другими аргументами" do
      run({ "text" => "раз" }.to_json)
      run({ "text" => "два" }.to_json)

      expect(echo_tool.calls.length).to eq(2)
    end

    # Считаются только подряд идущие вызовы: чередование A, B, A здесь
    # не ловится, и это осознанно — окна не заводим, пока такое чередование
    # не встретится живьём.
    it "сбрасывает счёт на другом вызове между одинаковыми" do
      run({ "text" => "раз" }.to_json)
      run({ "text" => "два" }.to_json)
      run({ "text" => "раз" }.to_json)

      expect(echo_tool.calls.length).to eq(3)
    end

    # Счёт относится к задаче, а не к сессии: объект один на агента, и без
    # сброса первая команда новой задачи, совпавшая с последней командой
    # прошлой, получила бы чужой результат вместо выполнения.
    it "начинает счёт заново после reset" do
      run(args)
      runner.reset
      run(args)

      expect(echo_tool.calls.length).to eq(2)
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

    # Одно число не бывает верным и при окне 8192, и при 50176: там вывод
    # команды съедает половину окна, здесь до потолка далеко. Доля считает
    # от окна ровно так же, как WINDOW_SHARE и ProjectContext::SHARE.
    it "считает предел долей окна, когда размер известен" do
      config = MiniAgent::Config.new({ context_window: 8192 }, env: {})
      runner = described_class.new(tools: tools, ui: ui, config: config)
      runner.call(conversation, { "id" => "1", "function" => { "name" => "long", "arguments" => "{}" } })

      # 8192 × 0.125 × 2,5 знака на токен — 2560.
      expect(conversation.to_a.last[:content].length)
        .to eq(2560 + MiniAgent::Messages::TRUNCATED_SUFFIX.length)
    end

    # Потолок остаётся потолком: на большом окне доля даёт десятки тысяч
    # знаков, то есть один вывод команды вытеснил бы весь диалог.
    it "не превышает потолка на большом окне" do
      config = MiniAgent::Config.new({ context_window: 262_144 }, env: {})
      runner = described_class.new(tools: tools, ui: ui, config: config)
      runner.call(conversation, { "id" => "1", "function" => { "name" => "long", "arguments" => "{}" } })

      expect(conversation.to_a.last[:content].length)
        .to eq(described_class::MAX_TOOL_OUTPUT + MiniAgent::Messages::TRUNCATED_SUFFIX.length)
    end
  end
end
