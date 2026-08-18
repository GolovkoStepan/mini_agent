# frozen_string_literal: true

RSpec.describe MiniAgent::Planner do
  let(:out) { StringIO.new }
  let(:ui) { MiniAgent::UI.new(out: out, tty: false) }
  let(:plan_mode) { MiniAgent::PlanMode.new(enabled: true) }
  let(:conversation) { MiniAgent::History.new.build }

  # Агент-заглушка: планирование идёт обычным циклом ходов, и подменять надо
  # именно его. answers задаёт, чем кончится каждая задача, tasks собирает то,
  # что уходило модели.
  let(:agent) do
    Class.new do
      attr_reader :tasks, :answer

      def initialize(*answers)
        @answers = answers
        @tasks = []
      end

      def run(task, conversation: nil)
        @tasks << task
        @answer = @answers.shift
        conversation
      end
    end
  end

  def planner(agent_double, prompt: MiniAgent::Prompt::AutoDeny.new)
    described_class.new(agent: agent_double, plan_mode: plan_mode, ui: ui, prompt: prompt)
  end

  describe "план получен" do
    it "запоминает план и спрашивает, выполнять ли его" do
      prompt = instance_spy(MiniAgent::Prompt, confirm?: false)
      planner(agent.new("1. Прочитать. 2. Написать."), prompt: prompt).call("как добавить X?", conversation)

      expect(plan_mode.plan).to eq("1. Прочитать. 2. Написать.")
      expect(prompt).to have_received(:confirm?).with(/Выполнять этот план/)
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
  end

  describe "плана нет" do
    # Задачу прервали, запрос провалился или кончились ходы. Вопрос
    # «выполнять?» без плана перед ним предлагал бы выполнить неизвестно что.
    it "не спрашивает, когда ответа не было" do
      prompt = instance_spy(MiniAgent::Prompt)
      planner(agent.new(nil), prompt: prompt).call("как добавить X?", conversation)

      expect(prompt).not_to have_received(:confirm?)
      expect(out.string).to include("Плана нет")
    end

    it "не спрашивает про пустой ответ" do
      prompt = instance_spy(MiniAgent::Prompt)
      planner(agent.new("   \n"), prompt: prompt).call("как добавить X?", conversation)

      expect(prompt).not_to have_received(:confirm?)
      expect(plan_mode.plan).to be_nil
    end
  end
end
