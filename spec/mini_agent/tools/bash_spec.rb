# frozen_string_literal: true

RSpec.describe MiniAgent::Tools::Bash do
  let(:runner) { MiniAgent::ProcessRunner.new(timeout: 5) }
  let(:guard) { MiniAgent::CommandGuard.new(prompt: MiniAgent::Prompt::AutoApprove.new) }

  subject(:tool) { described_class.new(guard: guard, runner: runner) }

  it "объявляет имя и схему для модели" do
    expect(tool.name).to eq("bash")
    expect(tool.schema.dig("function", "name")).to eq("bash")
    expect(tool.schema.dig("function", "parameters", "required")).to eq(["command"])
  end

  it "возвращает вывод команды с кодом выхода" do
    result = tool.call({ "command" => "echo привет" })

    expect(result).to include("Код выхода: 0")
    expect(result).to include("привет")
  end

  it "добавляет секцию STDERR при выводе в поток ошибок" do
    result = tool.call({ "command" => "echo беда >&2" })

    expect(result).to include("STDERR:")
    expect(result).to include("беда")
  end

  it "не добавляет секцию STDERR, когда поток ошибок пуст" do
    expect(tool.call({ "command" => "echo ok" })).not_to include("STDERR:")
  end

  it "сообщает о пустой команде вместо запуска пустого shell" do
    expect(tool.call({ "command" => "   " })).to eq(MiniAgent::Messages::EMPTY_COMMAND)
  end

  it "сообщает об отсутствующем аргументе command" do
    expect(tool.call({})).to eq(MiniAgent::Messages::EMPTY_COMMAND)
  end

  context "когда guard запрещает команду" do
    let(:guard) { MiniAgent::CommandGuard.new(prompt: MiniAgent::Prompt::AutoDeny.new) }

    it "возвращает сообщение об отмене" do
      expect(tool.call({ "command" => "rm -rf /tmp/x" })).to eq(MiniAgent::Messages::CANCELLED)
    end

    it "не запускает runner" do
      spy_runner = instance_spy(MiniAgent::ProcessRunner)
      described_class.new(guard: guard, runner: spy_runner).call({ "command" => "rm -rf /" })

      expect(spy_runner).not_to have_received(:call)
    end
  end

  # Два отказа объясняются модели по-разному, и это не украшение: «пробуй
  # иначе» после отказа режима гонит её подбирать обход, которого нет.
  context "когда идёт планирование" do
    let(:guard) do
      MiniAgent::CommandGuard.new(prompt: MiniAgent::Prompt::AutoApprove.new,
                                  plan_mode: MiniAgent::PlanMode.new(enabled: true))
    end

    it "возвращает отказ режима, а не отмену пользователем" do
      result = tool.call({ "command" => "touch new.rb" })

      expect(result).to eq(MiniAgent::Messages::PLAN_REFUSED)
      expect(result).to include("Идёт планирование")
    end

    it "выполняет читающую команду как обычно" do
      expect(tool.call({ "command" => "echo привет" })).to include("привет")
    end
  end

  # Таймаут — это результат, который модель должна увидеть,
  # а не исключение, роняющее цикл агента.
  it "превращает таймаут в текстовый результат" do
    slow = MiniAgent::ProcessRunner.new(timeout: 0.2, poll_interval: 0.02)
    result = described_class.new(guard: guard, runner: slow).call({ "command" => "sleep 5" })

    expect(result).to include("превышено время ожидания")
  end

  it "превращает неожиданную ошибку в текстовый результат" do
    broken = instance_double(MiniAgent::ProcessRunner)
    allow(broken).to receive(:call).and_raise(Errno::ENOENT, "bash")

    result = described_class.new(guard: guard, runner: broken).call({ "command" => "ls" })

    expect(result).to include("Ошибка выполнения")
  end
end
