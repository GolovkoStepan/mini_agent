# frozen_string_literal: true

RSpec.describe MiniAgent::ContextReport do
  # Системный промпт задаётся коротким явно: иначе каждое ожидание про доли
  # зависело бы от длины настоящего SYSTEM_PROMPT и ломалось при его правке.
  def conversation(project_context: nil)
    MiniAgent::Conversation.new(system_prompt: "промпт", project_context: project_context)
  end

  describe "разбивка по категориям" do
    it "разносит сообщения по ролям" do
      talk = conversation
      talk.user("задача")
      talk.assistant("ответ")
      talk.tool("call_1", "вывод команды")

      sizes = described_class.new(talk).sizes

      expect(sizes[:system]).to eq("промпт".length)
      expect(sizes[:tasks]).to eq("задача".length)
      expect(sizes[:answers]).to eq("ответ".length)
      expect(sizes[:tools]).to eq("вывод команды".length)
    end

    # Категория с нулём — это шум: «результаты команд: 0» в диалоге без
    # единой команды ничего не сообщает, а строку занимает.
    it "не показывает пустые категории" do
      talk = conversation
      talk.user("задача")

      expect(described_class.new(talk).sizes.keys).to eq(%i[system tasks])
    end

    it "сохраняет порядок категорий независимо от порядка сообщений" do
      talk = conversation
      talk.tool("call_1", "вывод")
      talk.assistant("ответ")
      talk.user("задача")

      expect(described_class.new(talk).sizes.keys).to eq(%i[system tasks answers tools])
    end

    # tool_calls едут в теле запроса рядом с content и место занимают
    # наравне с ним: считать только content значило бы занижать ответы
    # модели ровно там, где она вызывает команды.
    it "считает tool_calls вместе с сообщением" do
      talk = conversation
      calls = [{ "id" => "call_1", "function" => { "name" => "bash", "arguments" => '{"command":"ls"}' } }]
      talk.assistant("сейчас посмотрю", tool_calls: calls)

      expect(described_class.new(talk).sizes[:answers]).to be > "сейчас посмотрю".length
    end

    it "считает общий размер и число сообщений" do
      talk = conversation
      talk.user("задача")
      talk.assistant("ответ")

      report = described_class.new(talk)

      expect(report.total).to eq("промпт".length + "задача".length + "ответ".length)
      expect(report.messages).to eq(3)
    end
  end

  describe "описание проекта" do
    # Описание живёт внутри системного сообщения (второе system-сообщение
    # ломает шаблоны чата ряда моделей), но показывать их одной строкой
    # нельзя: это ровно та категория, ради которой команду и зовут.
    it "отделяется от системного промпта" do
      talk = conversation(project_context: "тесты: make spec")

      sizes = described_class.new(talk).sizes

      expect(sizes[:project]).to be > "тесты: make spec".length
      expect(sizes[:system]).to eq("промпт".length)
    end

    it "не появляется, когда описания нет" do
      expect(described_class.new(conversation).sizes).not_to have_key(:project)
    end

    it "не искажает общий размер" do
      talk = conversation(project_context: "тесты: make spec")

      report = described_class.new(talk)

      expect(report.total).to eq(talk.last[:content].length)
    end
  end

  describe "доли" do
    it "считает процент от общего размера" do
      talk = MiniAgent::Conversation.new(system_prompt: "a" * 25)
      talk.user("b" * 75)

      report = described_class.new(talk)

      expect(report.share(:system)).to eq(25)
      expect(report.share(:tasks)).to eq(75)
    end

    it "на пустой истории не делит на ноль" do
      report = described_class.new(MiniAgent::Conversation.new(system_prompt: nil))

      expect(report).to be_empty
      expect(report.share(:system)).to eq(0)
    end
  end

  # Главное, ради чего описание проекта считается отдельно. Известен живой
  # случай: AGENTS.md на мегабайт обрезается до 20 КБ, это ~10 000 токенов
  # при окне 8192, и сессия мертва — причём /clear не спасает, потому что
  # описание попадает и в новую историю. /compact не спасёт по той же
  # причине, и сказать об этом надо до того, как пользователь его позовёт.
  describe "что переживёт /compact" do
    it "относит промпт и описание проекта к несворачиваемому" do
      talk = conversation(project_context: "описание " * 100)
      talk.user("задача")

      report = described_class.new(talk)

      expect(report.fixed).to eq(report.sizes[:system] + report.sizes[:project])
      expect(report.compactable).to eq("задача".length)
    end

    it "замечает, что место занято описанием проекта" do
      talk = conversation(project_context: "описание " * 100)
      talk.user("задача")

      expect(described_class.new(talk)).to be_project_dominates
    end

    it "на обычном диалоге молчит" do
      talk = conversation
      talk.user("задача " * 50)
      talk.assistant("ответ " * 50)

      expect(described_class.new(talk)).not_to be_project_dominates
    end

    # Спрашивается про описание проекта, а не про всё несворачиваемое.
    # Настоящий SYSTEM_PROMPT — больше килознака, и сразу после успешного
    # сворачивания он перевешивает короткое резюме: признак по `fixed`
    # срабатывал бы почти всегда, и предупреждение стало бы шумом.
    # Ровно этот случай и поймал первый прогон тестов Compactor.
    it "не срабатывает от одного лишь системного промпта" do
      talk = MiniAgent::Conversation.new
      talk.user("резюме предыдущего диалога")

      report = described_class.new(talk)

      expect(report.fixed).to be > report.compactable, "промпт должен перевешивать — иначе тест ничего не проверяет"
      expect(report).not_to be_project_dominates
    end
  end

  describe "токены" do
    let(:talk) do
      conversation.tap { |c| c.user("задача") }
    end

    it "берёт последний промпт из данных сервера" do
      usage = MiniAgent::Usage.new
      usage.add({ "prompt_tokens" => 13, "completion_tokens" => 5 })
      usage.add({ "prompt_tokens" => 57, "completion_tokens" => 7 })

      expect(described_class.new(talk, usage: usage).tokens).to eq(57)
    end

    # Ноль означал бы «промпт пустой», а на деле его просто нечем измерить.
    # Это разные вещи, и показывать их одинаково нельзя.
    it "молчит, когда запросов ещё не было" do
      expect(described_class.new(talk, usage: MiniAgent::Usage.new).tokens).to be_nil
    end

    it "молчит, когда счётчик не передан" do
      expect(described_class.new(talk).tokens).to be_nil
    end

    # После /clear счётчик забывает прошлый промпт, а нового ещё не было:
    # запросы в сессии уже шли, но к этой истории они не относятся.
    # «Последний промпт — 0 токенов» читалось бы как ответ сервера, хотя
    # это его отсутствие. Замечено живой проверкой сразу после починки
    # самого сброса — тот дефект чинился, а этот им же и создавался.
    it "молчит, когда история начата заново" do
      usage = MiniAgent::Usage.new
      usage.add({ "prompt_tokens" => 508, "completion_tokens" => 5 })
      usage.reset_context

      expect(described_class.new(talk, usage: usage).tokens).to be_nil
    end
  end

  describe "контекстное окно" do
    let(:talk) { conversation.tap { |c| c.user("задача") } }

    def usage(prompt)
      MiniAgent::Usage.new.tap { |u| u.add({ "prompt_tokens" => prompt, "completion_tokens" => 5 }) }
    end

    def settings(window:, max_tokens: 1000)
      MiniAgent::Config.new({ context_window: window, max_tokens: max_tokens }, env: {})
    end

    it "собирает окно из настроек и данных сервера" do
      window = described_class.new(talk, usage: usage(2000), config: settings(window: 8192)).window

      expect(window.size).to eq(8192)
      expect(window.occupied).to eq(3000)
    end

    # Отчёт отдаёт окно всегда — незнающее, если знать неоткуда. Решение
    # «показывать или нет» принимает UI, и разводить эту проверку на два
    # места незачем.
    it "отдаёт незнающее окно без настроек" do
      expect(described_class.new(talk).window).not_to be_known
    end

    it "отдаёт незнающее окно, когда размер не задан" do
      expect(described_class.new(talk, usage: usage(2000), config: settings(window: nil)).window).not_to be_known
    end

    # Размер известен, а промпта нет: сервер не прислал usage.
    it "знает размер, но мерить не может без usage" do
      window = described_class.new(talk, config: settings(window: 8192)).window

      expect(window).to be_known
      expect(window).not_to be_measurable
    end
  end
end
