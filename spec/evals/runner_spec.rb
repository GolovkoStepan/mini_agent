# frozen_string_literal: true

RSpec.describe Evals::Runner do
  let(:out) { Dir.mktmpdir }
  let(:root) { File.expand_path("../..", __dir__) }

  after { FileUtils.remove_entry(out) }

  def task(checks: ["true"], setup: [], name: "a", prompt: "сделай")
    Evals::Task.new({ "name" => name, "prompt" => prompt, "checks" => checks,
                      "setup" => setup, "max_turns" => 4 })
  end

  def preset(sampling = {})
    Evals::Preset.new("tuned", sampling)
  end

  # Агент запускается по-настоящему, но с --version: он разбирает все флаги
  # и выходит, не открывая соединения. Иначе спека либо ходила бы в сеть,
  # либо проверяла подделку вместо настоящей командной строки.
  def runner(**options)
    described_class.new(root: root, out_dir: out, extra: ["--version"], **options)
  end

  describe "#command" do
    it "собирает командную строку из набора, задачи и каталога прогона" do
      line = runner.command(task, preset({ "temperature" => 0.3 }), "/тмп/п", 7)

      expect(line).to include("exe/mini_agent", "--cwd /тмп/п/work", "--log /тмп/п/log.jsonl",
                              "--max-turns 4", "--temperature 0.3", "--seed 7", "-- сделай")
    end

    it "не передаёт зерно, когда его отключили" do
      expect(runner(seed: nil).command(task, preset, "/тмп/п", nil)).not_to include("--seed")
    end
  end

  # Одно зерно на все попытки сделало бы их копиями друг друга, а разные
  # наборы обязаны получить одну и ту же последовательность — иначе к разнице
  # настроек примешивается разница случайности.
  it "сдвигает зерно на номер попытки" do
    seeds = Array.new(3) { |i| runner(seed: 10).call(task, preset, i).seed }

    expect(seeds).to eq([10, 11, 12])
  end

  it "считает прогон успешным, когда все проверки вернули ноль" do
    result = runner.call(task(setup: ["touch готово"], checks: ["test -f готово"]), preset, 0)

    expect([result.ok?, result.reason]).to eq([true, nil])
  end

  # «Не сошлось» без указания, что именно, заставляет лезть в каталог прогона
  # руками на каждой строке отчёта.
  it "называет провалившуюся проверку целиком" do
    result = runner.call(task(checks: ["true", "test -f нет"]), preset, 0)

    expect(result.reason).to eq("test -f нет → код 1")
  end

  # Сломанная фикстура — это не проигравшая модель, и проверки после неё
  # прошли бы или упали по причинам, к работе агента отношения не имеющим.
  it "не запускает агента, когда подготовка провалилась" do
    result = runner.call(task(setup: ["false"], checks: ["test -f нет"]), preset, 0)

    expect(result.reason).to start_with("подготовка: false → код 1")
    expect(File.exist?(File.join(out, "tuned", "a", "0", "answer.txt"))).to be(false)
  end

  it "сохраняет ответ агента рядом с рабочим каталогом" do
    runner.call(task, preset, 0)

    expect(File.read(File.join(out, "tuned", "a", "0", "answer.txt"))).to include(MiniAgent::VERSION)
  end

  # Оставленный файл прошлой попытки прошёл бы проверки этой, ничего не делая:
  # отчёт показал бы успех там, где агент не работал вовсе.
  it "сносит каталог прошлого прогона, а не дополняет его" do
    stale = File.join(out, "tuned", "a", "0", "work", "готово")
    FileUtils.mkdir_p(File.dirname(stale))
    File.write(stale, "с прошлой попытки")

    expect(runner.call(task(checks: ["test -f готово"]), preset, 0).ok?).to be(false)
  end
end
