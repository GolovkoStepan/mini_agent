# frozen_string_literal: true

RSpec.describe Evals::Report do
  def journal(turns: 3, generated: 100)
    records = Array.new(turns) do
      JSON.generate({ "type" => "message", "role" => "assistant",
                      "usage" => { "completion_tokens" => generated / turns } })
    end
    Evals::Journal.new(records)
  end

  def result(preset:, task: "a", passed: true, turns: 3, seconds: 10.0)
    Evals::Result.new(task: task, preset: preset, attempt: 0, seed: 1,
                      exit_code: passed ? 0 : 3, failed_check: passed ? nil : "test -f a → код 1",
                      journal: journal(turns: turns), seconds: seconds)
  end

  def many(preset:, passed:, total:, task: "a")
    Array.new(total) { |i| result(preset: preset, task: task, passed: i < passed) }
  end

  def report(results, presets: %w[server tuned], tasks: %w[a])
    described_class.new(results, presets: presets, tasks: tasks)
  end

  it "показывает долю успехов по задачам и итог" do
    results = many(preset: "server", passed: 1, total: 2) + many(preset: "tuned", passed: 2, total: 2)

    expect(report(results).to_s).to include("1/2", "2/2", "итого")
  end

  # Провал обычно короче успеха: агент сдался на втором ходу. Смешав их,
  # набор с большим числом провалов выглядел бы самым экономным — то есть
  # таблица расхода противоречила бы таблице успехов.
  it "считает расход только по успешным прогонам" do
    results = [result(preset: "server", passed: true, turns: 8, seconds: 80.0),
               result(preset: "server", passed: false, turns: 1, seconds: 2.0)]

    expect(report(results, presets: %w[server]).to_s).to include("8.0", "80.0")
  end

  it "не даёт вердикта, пока прогонов мало" do
    results = many(preset: "server", passed: 0, total: 3) + many(preset: "tuned", passed: 3, total: 3)

    expect(report(results).verdict("tuned")).to eq(:unknown)
    expect(report(results).to_s).to include("мало наблюдений")
  end

  it "называет явное улучшение улучшением" do
    results = many(preset: "server", passed: 2, total: 10) + many(preset: "tuned", passed: 9, total: 10)

    expect(report(results).verdict("tuned")).to eq(:better)
  end

  it "называет явное ухудшение ухудшением" do
    results = many(preset: "server", passed: 9, total: 10) + many(preset: "tuned", passed: 2, total: 10)

    expect(report(results).verdict("tuned")).to eq(:worse)
  end

  # Разница «8 из 10 против 6 из 10» от шума неотличима, и отчёт, объявляющий
  # по ней победителя, хуже отсутствия отчёта: он выглядит измерением.
  it "называет небольшой перевес шумом" do
    results = many(preset: "server", passed: 6, total: 10) + many(preset: "tuned", passed: 8, total: 10)

    expect(report(results).verdict("tuned")).to eq(:same)
  end

  # Без сглаживания разброса набор, прошедший все прогоны, даёт нулевой
  # разброс, и перевес в один прогон объявляется несомненным.
  it "не объявляет победителя по одному прогону разницы" do
    results = many(preset: "server", passed: 5, total: 6) + many(preset: "tuned", passed: 6, total: 6)

    expect(report(results).verdict("tuned")).to eq(:same)
  end

  it "сравнивает с первым набором и говорит об этом" do
    results = many(preset: "server", passed: 1, total: 2) + many(preset: "tuned", passed: 2, total: 2)

    expect(report(results).to_s).to include("относительно набора «server»")
  end

  it "сообщает, что сравнивать не с чем, когда набор один" do
    expect(report(many(preset: "server", passed: 1, total: 2), presets: %w[server]).to_s)
      .to include("сравнивать не с чем")
  end
end
