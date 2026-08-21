# frozen_string_literal: true

require "tmpdir"

RSpec.describe MiniAgent::Planner do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:out) { StringIO.new }
  let(:ui) { MiniAgent::UI.new(out: out, tty: false) }
  let(:plan_mode) { MiniAgent::PlanMode.new(enabled: true) }
  let(:conversation) { MiniAgent::History.new.build }
  # Свой каталог на каждый пример: иначе спека писала бы планы в настоящий
  # ~/.mini_agent/plans разработчика.
  let(:store) { MiniAgent::PlanStore.new(dir: @dir) }

  # Агент-заглушка: планирование идёт обычным циклом ходов, и подменять надо
  # именно его. answers задаёт, чем кончится каждая задача, tasks собирает то,
  # что уходило модели. conversations — то, В КАКОЙ истории каждая задача шла:
  # одобрение плана обязано начать новую, и проверить это можно только так.
  let(:agent) do
    Class.new do
      attr_reader :tasks, :answer, :conversations, :transcript

      def initialize(*answers)
        @answers = answers
        @tasks = []
        @conversations = []
      end

      def run(task, conversation: nil)
        @tasks << task
        @conversations << conversation
        @answer = @answers.shift
        conversation
      end

      # То же, что History#build у настоящего агента: новая история взамен
      # прежней. Здесь достаточно любого другого объекта.
      def new_conversation = MiniAgent::History.new.build
    end
  end

  def planner(agent_double, prompt: MiniAgent::Prompt::AutoDeny.new)
    described_class.new(agent: agent_double, plan_mode: plan_mode, ui: ui, prompt: prompt, store: store)
  end

  describe "план получен" do
    it "запоминает план и спрашивает, выполнять ли его" do
      prompt = instance_spy(MiniAgent::Prompt, ask: "n")
      planner(agent.new("1. Прочитать. 2. Написать."), prompt: prompt).call("как добавить X?", conversation)

      expect(plan_mode.plan).to eq("1. Прочитать. 2. Написать.")
      expect(prompt).to have_received(:ask).with(/Выполнять этот план/)
    end

    # Отказ оставляет режим включённым: план уточняют следующей задачей,
    # и выключить его на «нет» значило бы отправить агента менять файлы
    # ровно там, где человек только что сказал «не надо».
    it "при отказе остаётся в планировании" do
      result = planner(agent.new("план")).call("как добавить X?", conversation)

      expect(plan_mode.on?).to be(true)
      expect(out.string).to include("Остаёмся в планировании")
      expect(result).to be(conversation)
    end
  end

  describe "план одобрен" do
    def approved(agent_double)
      planner(agent_double, prompt: MiniAgent::Prompt::AutoApprove.new).call("как добавить X?", conversation)
    end

    # Режим обязан выключиться до запуска: иначе первая же команда из
    # только что одобренного плана была бы отвергнута им самим.
    it "выключает режим планирования" do
      approved(agent.new("план", "сделано"))

      expect(plan_mode.on?).to be(false)
      expect(out.string).to include("План принят")
    end

    # План повторяется целиком, хотя он есть в истории выше: между
    # планированием и одобрением мог пройти /compact.
    it "передаёт модели одобренный план текстом" do
      runner = agent.new("1. Прочитать. 2. Написать.", "сделано")
      approved(runner)

      expect(runner.tasks.length).to eq(2)
      expect(runner.tasks.last).to include("1. Прочитать. 2. Написать.", "approved")
    end

    # План и есть резюме исследования: десятки выводов ls и cat, на которых
    # он построен, дальше только занимают окно. Проверяется тождество
    # объекта — тот же признак, по которому Compactor отличает «свернули»
    # от «ничего не менялось».
    it "выполняет план в новой истории, а не в истории исследования" do
      runner = agent.new("план", "сделано")
      approved(runner)

      expect(runner.conversations.first).to be(conversation)
      expect(runner.conversations.last).not_to be(conversation)
      expect(out.string).to include("Контекст исследования сброшен")
    end

    # Сброс без отметки в журнале выглядел бы так, будто модель посреди
    # работы забыла всё изученное. Записывается ПЕРЕД сборкой новой истории,
    # иначе отметка оказалась бы внутри неё — тот же порядок, что у compact.
    it "отмечает сброс в журнале" do
      log = instance_spy(MiniAgent::Transcript)
      runner = agent.new("план", "сделано")
      allow(runner).to receive(:transcript).and_return(log)

      approved(runner)

      expect(log).to have_received(:plan).with(before: conversation.size, path: a_string_including(@dir))
    end
  end

  # Третий ответ на вопрос «выполнять?»: план почти всегда верен на три
  # четверти, и без правки остаётся либо принять его целиком, либо отвергнуть
  # и переписывать задачу словами.
  describe "правка плана" do
    # Ответы кончаются раньше, чем цикл: nil от gets — обрыв ввода, то есть
    # отказ. Без этого «e» крутило бы вопрос вечно.
    def answering(*answers)
      MiniAgent::Prompt.new(input: StringIO.new(answers.join("\n")), output: StringIO.new)
    end

    def planner_with(editor, prompt)
      described_class.new(agent: agent.new("1. Прочитать."), plan_mode: plan_mode, ui: ui,
                          prompt: prompt, store: store, editor: editor)
    end

    # Файл — источник истины: человек мог поправить знак, а мог переписать всё.
    it "берёт план из файла после правки" do
      editor = instance_spy(MiniAgent::PlanEditor, call: "1. Прочитать. 2. Проверить.")
      planner_with(editor, answering("e", "n")).call("как добавить X?", conversation)

      expect(plan_mode.plan).to eq("1. Прочитать. 2. Проверить.")
      expect(out.string).to include("План перечитан из файла")
    end

    # Открыть план в редакторе — не то же самое, что одобрить его: «поправил,
    # глянул, передумал» обязано остаться возможным.
    it "спрашивает заново, а не считает правку согласием" do
      editor = instance_spy(MiniAgent::PlanEditor, call: "исправленный план")
      prompt = answering("e", "y")
      runner = agent.new("1. Прочитать.", "сделано")
      described_class.new(agent: runner, plan_mode: plan_mode, ui: ui, prompt: prompt,
                          store: store, editor: editor).call("как добавить X?", conversation)

      expect(runner.tasks.last).to include("исправленный план")
    end

    it "передаёт редактору путь сохранённого файла" do
      editor = instance_spy(MiniAgent::PlanEditor, call: nil)
      planner_with(editor, answering("e", "n")).call("как добавить X?", conversation)

      expect(editor).to have_received(:call).with(a_string_including(@dir))
    end

    # Правка не удалась (не задан EDITOR, файл не записался) — план прежний,
    # вопрос прежний. Терять из-за этого составленный план незачем.
    it "оставляет прежний план, когда править не вышло" do
      editor = instance_spy(MiniAgent::PlanEditor, call: nil)
      planner_with(editor, answering("e", "n")).call("как добавить X?", conversation)

      expect(plan_mode.plan).to eq("1. Прочитать.")
      expect(out.string).not_to include("План перечитан")
    end

    # Очистить буфер, чтобы передумать, — то же соглашение, что у git commit.
    it "считает опустевший файл отказом" do
      editor = instance_spy(MiniAgent::PlanEditor, call: "   \n")
      result = planner_with(editor, answering("e", "y")).call("как добавить X?", conversation)

      expect(out.string).to include("считаю это отказом", "Остаёмся в планировании")
      expect(result).to be(conversation)
    end

    it "не зовёт редактор, когда план одобрили сразу" do
      editor = instance_spy(MiniAgent::PlanEditor)
      planner_with(editor, answering("y")).call("как добавить X?", conversation)

      expect(editor).not_to have_received(:call)
    end
  end

  describe "план в файле" do
    # Файл пишется ДО вопроса: «нет» означает «не выполнять», а не
    # «выбросить». Уточняют план как раз после отказа, и сравнить его
    # с предыдущим можно только по файлу.
    it "сохраняет план даже при отказе выполнять" do
      planner(agent.new("1. Прочитать.")).call("как добавить X?", conversation)

      saved = Dir.children(@dir)
      expect(saved.length).to eq(1)
      expect(File.read(File.join(@dir, saved.first))).to include("1. Прочитать.")
      expect(out.string).to include("План сохранён")
    end

    # Незаписанный файл сессию не рушит: план уже составлен, и терять из-за
    # прав на каталог целую работу незачем.
    it "предупреждает и продолжает, когда файл не записался" do
      broken = MiniAgent::PlanStore.new(dir: File.join(@dir, "нет", "ещё"))
      allow(broken).to receive(:save).and_return(nil)
      allow(broken).to receive(:error).and_return("Permission denied")
      described_class.new(agent: agent.new("план"), plan_mode: plan_mode, ui: ui,
                          prompt: MiniAgent::Prompt::AutoDeny.new, store: broken)
                     .call("как добавить X?", conversation)

      expect(out.string).to include("Не удалось сохранить план", "Permission denied")
      expect(plan_mode.plan).to eq("план")
    end
  end

  # Разовый запуск (--plan): план сохраняется и печатается, вопроса нет
  # и выполнения нет. Спрашивать некого — интерактивного режима здесь нет.
  describe "без подтверждения" do
    it "сохраняет план и ничего не выполняет" do
      prompt = instance_spy(MiniAgent::Prompt)
      runner = agent.new("план")
      described_class.new(agent: runner, plan_mode: plan_mode, ui: ui, prompt: prompt, store: store)
                     .call("как добавить X?", nil, confirm: false)

      expect(prompt).not_to have_received(:ask)
      expect(runner.tasks.length).to eq(1)
      expect(Dir.children(@dir).length).to eq(1)
      expect(out.string).to include("План сохранён", "План не выполнялся")
    end
  end

  describe "плана нет" do
    # Задачу прервали, запрос провалился или кончились ходы. Вопрос
    # «выполнять?» без плана перед ним предлагал бы выполнить неизвестно что.
    it "не спрашивает, когда ответа не было" do
      prompt = instance_spy(MiniAgent::Prompt)
      planner(agent.new(nil), prompt: prompt).call("как добавить X?", conversation)

      expect(prompt).not_to have_received(:ask)
      expect(out.string).to include("Плана нет")
    end

    it "не спрашивает про пустой ответ" do
      prompt = instance_spy(MiniAgent::Prompt)
      planner(agent.new("   \n"), prompt: prompt).call("как добавить X?", conversation)

      expect(prompt).not_to have_received(:ask)
      expect(plan_mode.plan).to be_nil
    end
  end
end
