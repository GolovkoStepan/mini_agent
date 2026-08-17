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
      expect(agent).not_to be_failed
    end
  end

  # Найдено живой проверкой: qwen3.6 отдаёт размышления отдельным полем
  # reasoning_content, но тратит на них общий с ответом бюджет max_tokens.
  # Выбрав его, модель возвращает пустой content — и агент рапортовал
  # «пустой ответ» с кодом возврата 0, уводя от настоящей причины.
  describe "обрыв по лимиту генерации" do
    it "на пустом ответе называет причину, а не «пустой ответ»" do
      allow(client).to receive(:chat).and_return(["", [], nil, "length"])

      agent.run("задача")

      expect(out.string).to include("оборван на лимите", "max_tokens: 16384")
      expect(out.string).not_to include("пустой ответ")
    end

    # Задача не выполнена — код возврата обязан это показать.
    it "помечает задачу провалившейся" do
      allow(client).to receive(:chat).and_return(["", [], nil, "length"])

      agent.run("задача")

      expect(agent).to be_failed
    end

    # Текст есть — его надо показать и сохранить, но предупредив о неполноте.
    it "на непустом ответе предупреждает, но ответ сохраняет" do
      allow(client).to receive(:chat).and_return(["начало отв", [], nil, "length"])

      conversation = agent.run("задача")

      expect(out.string).to include("● начало отв", "может быть неполным")
      expect(conversation.last).to eq({ role: "assistant", content: "начало отв" })
      expect(agent).not_to be_failed
    end

    # Обрезанные аргументы дошли бы до parse_arguments как «битый JSON
    # от модели» — диагноз, уводящий от настоящей причины.
    it "на обрыве посреди вызова инструмента называет лимит" do
      allow(client).to receive(:chat)
        .and_return(["думаю", [tool_call], nil, "length"], ["готово", []])

      agent.run("задача")

      expect(out.string).to include("Вызов инструмента оборван")
    end

    # Обычное завершение не должно попадать под предупреждение.
    it "молчит при finish_reason stop" do
      allow(client).to receive(:chat).and_return(["всё готово", [], nil, "stop"])

      agent.run("задача")

      expect(out.string).not_to include("оборван")
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

  describe "прерывание по Ctrl+C" do
    # Interrupt не StandardError, поэтому rescue внутри цикла его не ловят
    # и он доходит до обработчика вокруг всего хода.
    it "прерывает задачу, а не роняет агента" do
      allow(client).to receive(:chat).and_raise(Interrupt)

      conversation = nil
      expect { conversation = agent.run("задача") }.not_to raise_error
      expect(out.string).to include("Прервано")
    end

    it "сохраняет историю: диалог можно продолжить" do
      allow(client).to receive(:chat).and_raise(Interrupt)

      conversation = agent.run("задача")

      expect(conversation.to_a.map { |m| m[:role] }).to eq(%w[system user])
    end

    # Прерывается задача целиком, а не один запрос: первый ход прошёл
    # нормально, на втором пришёл Ctrl+C — третьего быть не должно,
    # хотя max_turns это позволяет.
    it "не идёт на следующий ход после прерывания" do
      responses = [["работаю", [tool_call]]]
      allow(client).to receive(:chat) do
        raise Interrupt if responses.empty?

        responses.shift
      end

      agent.run("задача")

      expect(client).to have_received(:chat).twice
    end

    it "прерывание во время команды не роняет агента" do
      angry = Class.new do
        def name = "angry"
        def schema = {}
        def call(_arguments) = raise(Interrupt)
      end.new
      call = { "id" => "c1", "function" => { "name" => "angry", "arguments" => "{}" } }
      allow(client).to receive(:chat).and_return(["сейчас", [call]])

      agent = described_class.new(
        config: config, client: client, tools: MiniAgent::ToolRegistry.new([angry]), ui: ui
      )

      expect { agent.run("задача") }.not_to raise_error
      expect(out.string).to include("Прервано")
    end
  end

  describe "ошибки связи" do
    before { allow(client).to receive(:chat).and_raise(MiniAgent::LLMError, "сеть недоступна") }

    it "возвращает историю, а не бросает исключение" do
      conversation = nil
      expect { conversation = agent.run("задача") }.not_to raise_error
      expect(conversation).to be_a(MiniAgent::Conversation)
      expect(out.string).to include("Ошибка связи с LLM")
    end

    # Задача не сделана, и это должно быть видно снаружи: по этому признаку
    # CLI возвращает код 3 вместо нуля.
    it "помечает задачу как проваленную" do
      agent.run("задача")

      expect(agent).to be_failed
    end

    # Неотвеченное user-сообщение валит и следующий запрос: при упоре
    # в контекстное окно вся сессия оставалась мёртвой до /clear.
    it "снимает с истории сообщения неудачного хода" do
      conversation = agent.run("задача")

      expect(conversation.to_a.map { |m| m[:role] }).to eq(["system"])
      expect(out.string).to include("снят с истории")
    end

    it "не трогает то, что было в истории до задачи" do
      history = agent.new_conversation
      history.user("прошлая задача")
      history.assistant("прошлый ответ")

      agent.run("новая задача", conversation: history)

      expect(history.to_a.map { |m| m[:role] }).to eq(%w[system user assistant])
    end

    # Следующая задача в той же сессии должна уходить уже без мусора,
    # иначе откат бесполезен.
    it "позволяет продолжить работу в той же истории" do
      history = agent.new_conversation
      agent.run("упавшая задача", conversation: history)

      allow(client).to receive(:chat).and_return(["готово", []])
      agent.run("следующая задача", conversation: history)

      expect(agent).not_to be_failed
      expect(history.to_a.map { |m| m[:role] }).to eq(%w[system user assistant])
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

  describe "учёт токенов" do
    def tokens(prompt, completion)
      { "prompt_tokens" => prompt, "completion_tokens" => completion }
    end

    it "копит расход по ходам" do
      allow(client).to receive(:chat).and_return(["ответ", [], tokens(13, 5)])

      agent.run("задача")

      expect(agent.usage.to_h).to include(sent: 13, generated: 5, requests: 1)
    end

    # Промпт растёт от хода к ходу — история уходит целиком заново. Складывать
    # его нельзя: осмысленно последнее значение, текущий размер контекста.
    it "берёт контекст из последнего запроса, а не из суммы" do
      call = { "id" => "call_1", "function" => { "name" => "echo", "arguments" => "{}" } }
      allow(client).to receive(:chat).and_return(
        ["", [call], tokens(13, 5)],
        ["готово", [], tokens(57, 7)]
      )

      agent.run("задача")

      expect(agent.usage.context).to eq(57)
      expect(agent.usage.generated).to eq(12)
    end

    # Токены провалившегося хода уже уплачены серверу: откат снимает сообщения,
    # но не расход — иначе счётчик показывал бы не то, что было на самом деле.
    it "не сбрасывает расход при откате неудачного хода" do
      responses = [-> { ["ответ", [], tokens(13, 5)] }, -> { raise MiniAgent::LLMError, "сбой" }]
      allow(client).to receive(:chat) { responses.shift.call }
      history = agent.new_conversation

      agent.run("первая", conversation: history)
      agent.run("вторая", conversation: history)

      expect(agent.usage.to_h).to include(sent: 13, generated: 5, requests: 1)
    end

    it "переживает ответ без usage" do
      allow(client).to receive(:chat).and_return(["ответ", []])

      expect { agent.run("задача") }.not_to raise_error
      expect(agent.usage).to be_empty
    end
  end

  describe "#init" do
    # History собрана на старте и о созданном посреди сессии файле не знает.
    # Без этой строчки описание не подхватилось бы до перезапуска, причём
    # молча — ровно та ошибка, ради которой History и заводилась.
    it "кладёт новое описание в историю для следующей сборки" do
      Dir.mktmpdir do |dir|
        history = MiniAgent::History.new
        agent = described_class.new(
          config: MiniAgent::Config.new({ cwd: dir }, env: {}),
          client: client, tools: tools, ui: ui, history: history,
          prompt: MiniAgent::Prompt::AutoApprove.new
        )
        allow(client).to receive(:chat) do
          File.write(File.join(dir, "AGENTS.md"), "Тесты: make spec")
          ["записал", []]
        end

        agent.init(agent.new_conversation)

        expect(history.project_context).to include("make spec")
        expect(agent.new_conversation.to_a.first[:content]).to include("make spec")
      end
    end

    # Текущий диалог остаётся как был: применить описание к нему значило бы
    # его выбросить — скрытый /clear там, где о нём не просили.
    it "не переписывает текущую историю" do
      Dir.mktmpdir do |dir|
        agent = described_class.new(
          config: MiniAgent::Config.new({ cwd: dir }, env: {}),
          client: client, tools: tools, ui: ui,
          prompt: MiniAgent::Prompt::AutoApprove.new
        )
        allow(client).to receive(:chat) do
          File.write(File.join(dir, "AGENTS.md"), "описание")
          ["записал", []]
        end
        conversation = agent.new_conversation

        expect(agent.init(conversation)).to be(conversation)
        expect(conversation.to_a.first[:content]).not_to include("описание")
      end
    end
  end
end
