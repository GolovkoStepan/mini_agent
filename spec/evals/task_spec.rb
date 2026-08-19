# frozen_string_literal: true

RSpec.describe Evals::Task do
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  def write(name, data)
    File.write(File.join(dir, "#{name}.json"), JSON.generate(data))
  end

  let(:minimal) { { "name" => "a", "prompt" => "сделай", "checks" => ["test -f a"] } }

  it "читает поля задачи" do
    task = described_class.new(minimal.merge("setup" => ["mkdir x"], "max_turns" => 3))

    expect([task.name, task.prompt, task.setup, task.checks, task.max_turns])
      .to eq(["a", "сделай", ["mkdir x"], ["test -f a"], 3])
  end

  it "подставляет умолчание ходов и пустую подготовку" do
    task = described_class.new(minimal)

    expect([task.max_turns, task.setup, task.agent_flags]).to eq([described_class::DEFAULT_MAX_TURNS, [], []])
  end

  # Условие, в котором задача измеряется, принадлежит ей самой: то же условие
  # в ARGS действовало бы на всю матрицу.
  it "читает флаги агента" do
    task = described_class.new(minimal.merge("agent_flags" => ["--policy", "ask"]))

    expect(task.agent_flags).to eq(["--policy", "ask"])
  end

  # Задача без проверок прошла бы каждый прогон успешно, ничего не проверив:
  # отчёт был бы не пустым, а ложным.
  it "требует обязательные поля" do
    expect { described_class.new({ "name" => "a" }) }
      .to raise_error(ArgumentError, /prompt, checks/)
  end

  # Та же причина: "check" вместо "checks" — это молча не работающая задача.
  it "отвергает неизвестное поле, а не пропускает его" do
    expect { described_class.new(minimal.merge("check" => ["test -f a"])) }
      .to raise_error(ArgumentError, /неизвестные поля: check/)
  end

  it "читает каталог задач по алфавиту" do
    write("b", minimal.merge("name" => "b"))
    write("a", minimal)

    expect(described_class.load_all(dir).map(&:name)).to eq(%w[a b])
  end

  it "отбирает названные задачи в указанном порядке" do
    write("a", minimal)
    write("b", minimal.merge("name" => "b"))

    expect(described_class.load_all(dir, names: %w[b a]).map(&:name)).to eq(%w[b a])
  end

  # Опечатка в имени задачи означала бы прогон не того, что заказывали, —
  # причём отчёт выглядел бы нормальным, просто с меньшим числом строк.
  it "падает на неизвестном имени задачи" do
    write("a", minimal)

    expect { described_class.load_all(dir, names: %w[нет]) }
      .to raise_error(ArgumentError, /неизвестная задача: нет/)
  end

  it "называет файл, который не разобрался" do
    File.write(File.join(dir, "broken.json"), "{не json")

    expect { described_class.load_all(dir) }.to raise_error(ArgumentError, /broken\.json/)
  end
end
