# frozen_string_literal: true

RSpec.describe Evals::Preset do
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  it "собирает флаги агента из параметров" do
    preset = described_class.new("tuned", { "temperature" => 0.3, "repeat_penalty" => 1.12 })

    expect(preset.flags).to eq(["--repeat-penalty", "1.12", "--temperature", "0.3"])
  end

  # Пустой набор — это набор «решает сервер», а не отсутствие набора:
  # именно он служит исходным уровнем сравнения.
  it "даёт пустой список флагов на наборе без параметров" do
    expect(described_class.new("server", { "about" => "пресет сервера" }).flags).to eq([])
  end

  # Список допустимых берётся из MiniAgent::Sampling: своя копия разошлась бы
  # с настоящей при первом же новом параметре.
  it "принимает все параметры сэмплинга агента, кроме зерна" do
    expect(described_class::ALLOWED).to include("temperature", "top_k", "min_p")
    expect(described_class::ALLOWED).not_to include("seed")
  end

  # Опечатка уехала бы в командную строку агента и обвалила бы КАЖДЫЙ прогон
  # одинаково — то есть выглядела бы как «набор плохой», а не как опечатка.
  it "отвергает неизвестный параметр" do
    expect { described_class.new("x", { "temperatur" => 0.3 }) }
      .to raise_error(ArgumentError, /неизвестные параметры: temperatur/)
  end

  # Зерно принадлежит прогону: наборы обязаны получить одну и ту же
  # последовательность зёрен, иначе сравнение перестаёт быть попарным.
  it "объясняет, почему зерно здесь не задаётся" do
    expect { described_class.new("x", { "seed" => 7 }) }
      .to raise_error(ArgumentError, /--seed/)
  end

  it "берёт имя набора из имени файла" do
    File.write(File.join(dir, "tuned.json"), JSON.generate({ "temperature" => 0.2 }))

    expect(described_class.load_all(dir).map(&:name)).to eq(["tuned"])
  end

  it "падает на неизвестном имени набора" do
    File.write(File.join(dir, "tuned.json"), "{}")

    expect { described_class.load_all(dir, names: %w[нет]) }
      .to raise_error(ArgumentError, /неизвестный набор: нет/)
  end
end
