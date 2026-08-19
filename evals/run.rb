#!/usr/bin/env ruby
# frozen_string_literal: true

# Прогон оценочных задач: матрица «задача × набор × попытка».
#
#   ruby evals/run.rb --runs 3
#   ruby evals/run.rb --tasks empty-grep --presets server,tuned --dry-run
#
# Флаги после `--` уходят агенту как есть (--model, --base-url, --context-window).

require "optparse"
require "json"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"), File.join(ROOT, "evals", "lib"))

require "evals"

options = { runs: 3, seed: Evals::Runner::DEFAULT_SEED, timeout: Evals::Runner::DEFAULT_TIMEOUT,
            out: File.join(ROOT, "evals", "results") }

parser = OptionParser.new do |opts|
  opts.banner = "Использование: ruby evals/run.rb [опции] [-- флаги агента]"
  opts.on("--tasks LIST", Array, "задачи через запятую (по умолчанию все)") { |v| options[:tasks] = v }
  opts.on("--presets LIST", Array, "наборы через запятую (по умолчанию все)") { |v| options[:presets] = v }
  opts.on("--runs N", Integer, "прогонов на задачу и набор") { |v| options[:runs] = v }
  opts.on("--seed N", Integer, "базовое зерно; попытка i получает seed + i") { |v| options[:seed] = v }
  opts.on("--no-seed", "не задавать зерно вовсе") { options[:seed] = nil }
  opts.on("--timeout N", Integer, "потолок секунд на прогон") { |v| options[:timeout] = v }
  opts.on("--out DIR", "куда складывать каталоги прогонов") { |v| options[:out] = v }
  opts.on("--dry-run", "показать команды и выйти") { options[:dry_run] = true }
end

extra = parser.parse(ARGV)

tasks = Evals::Task.load_all(File.join(ROOT, "evals", "tasks"), names: options[:tasks])
presets = Evals::Preset.load_all(File.join(ROOT, "evals", "presets"), names: options[:presets])
runner = Evals::Runner.new(root: ROOT, out_dir: options[:out], seed: options[:seed],
                           timeout: options[:timeout], extra: extra)

# Показать команды и выйти. Матрица идёт часами, и убедиться, что модель,
# адрес и флаги те самые, дешевле до запуска, чем после.
if options[:dry_run]
  tasks.each do |task|
    presets.each { |preset| puts runner.command(task, preset, "<каталог-прогона>", options[:seed]) }
  end
  exit 0
end

total = tasks.size * presets.size * options[:runs]
results = []

# Порядок обхода: задача → попытка → набор. Набор во внутреннем цикле
# намеренно: матрица идёт часами, и прерванный посреди прогон должен
# оставлять СРАВНИМЫЙ остаток — одну и ту же задачу на всех наборах с одним
# зерном. При обратном порядке прерывание оставляло бы полностью померенный
# первый набор и ничего для второго, то есть отчёт, в котором нечего
# сравнивать.
begin
  tasks.each do |task|
    options[:runs].times do |attempt|
      presets.each do |preset|
        result = runner.call(task, preset, attempt)
        results << result
        puts format("[%<n>d/%<total>d] %<task>s · %<preset>s · попытка %<attempt>d → %<mark>s, " \
                    "ходов %<turns>d, %<seconds>d с",
                    n: results.size, total: total, task: task.name, preset: preset.name,
                    attempt: attempt, mark: result.ok? ? "ок" : "провал: #{result.reason}",
                    turns: result.journal.turns, seconds: result.seconds)
      end
    end
  end
rescue Interrupt
  # Прерванная матрица — не потерянная: отчёт по тому, что успели, полезнее
  # молчания, а прогоны стоили часов.
  puts "\nПрервано, отчёт по #{results.size} прогонам из #{total}."
end

puts "\n#{Evals::Report.new(results, presets: presets.map(&:name), tasks: tasks.map(&:name))}"

FileUtils.mkdir_p(options[:out])
raw = File.join(options[:out], "results.json")
File.write(raw, JSON.pretty_generate(results.map(&:to_h)))
puts "\nСырые данные: #{raw}"
