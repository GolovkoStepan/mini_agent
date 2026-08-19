# frozen_string_literal: true

require "fileutils"
require "rbconfig"

module Evals
  # Один прогон: задача × набор × попытка.
  #
  # Каждый прогон получает свой каталог с чистой копией фикстуры. Общий
  # каталог на несколько попыток означал бы, что вторая попытка начинается
  # с результатов первой, — и задача «создай файл» проходила бы, даже если
  # агент на второй попытке не сделал ничего.
  class Runner
    # Потолок на прогон. Число большое намеренно: на локальной сети в
    # ~6 токенов/с одна мелкая задача идёт минутами, и таймаут здесь —
    # страховка от зависшего прогона, а не мерило скорости. Без него
    # многочасовая матрица встаёт на первом же зависании и не доходит
    # до отчёта вовсе.
    DEFAULT_TIMEOUT = 900

    # Базовое зерно. Попытка i получает seed + i: одно и то же зерно на все
    # попытки сделало бы их копиями друг друга, а разные наборы обязаны
    # получить ОДНУ И ТУ ЖЕ последовательность зёрен — тогда сравнение
    # попарное и разница случайности из него уходит.
    DEFAULT_SEED = 1

    # Подготовка и проверки — свои команды, и ждать их столько же, сколько
    # модель, незачем: они локальные и мгновенные, а зависшая проверка
    # молча съедала бы четверть часа на каждом прогоне.
    HELPER_TIMEOUT = 60

    # Что можно оставить в командной строке как есть. `[[:alnum:]]`, а не
    # `\w`: тот в Ruby ограничен ASCII, и русское слово закавычивалось бы
    # целиком без всякой на то причины (те же грабли, что в
    # SlashCommands::PATTERN).
    SAFE = %r{\A[[:alnum:]_\-.,:+/@=]+\z}

    def initialize(root:, out_dir:, seed: DEFAULT_SEED, timeout: DEFAULT_TIMEOUT, extra: [])
      @root = root
      @out_dir = out_dir
      @seed = seed
      @timeout = timeout
      @extra = extra
    end

    def call(task, preset, attempt)
      dir = make_dir(task, preset, attempt)
      seed = @seed && (@seed + attempt)
      started = clock
      facts = perform(task, preset, dir, seed)

      Result.new(task: task.name, preset: preset.name, attempt: attempt, seed: seed,
                 exit_code: facts[:exit_code], error: facts[:error], failed_check: facts[:failed_check],
                 journal: Journal.read(File.join(dir, "log.jsonl")), seconds: clock - started)
    end

    # Команда запуска — наружу ради отчёта и разбора вручную: повторить
    # провалившийся прогон копированием строки должно быть можно, не
    # восстанавливая её по флагам из головы.
    def command(task, preset, dir, seed)
      parts = [RbConfig.ruby, "-Ilib", "exe/mini_agent",
               "--cwd", File.join(dir, "work"),
               "--log", File.join(dir, "log.jsonl"),
               "--max-turns", task.max_turns.to_s]
      parts += preset.flags
      parts += ["--seed", seed.to_s] if seed
      parts += @extra
      # Двойное тире перед задачей: без него задача, начинающаяся с дефиса,
      # разбиралась бы как флаг.
      (parts + ["--", task.prompt]).map { |part| quote(part) }.join(" ")
    end

    private

    # Своё закавычивание вместо Shellwords.join: тот экранирует всё, что вне
    # ASCII, обратной косой — русская задача превращается в «\с\д\е\л\а\й».
    # Для bash это верно, но команду заводили ради того, чтобы провалившийся
    # прогон можно было повторить копированием строки, а такую строку сперва
    # надо расшифровать. Одинарные кавычки дают то же самое читаемо.
    def quote(part)
      return part if part.match?(SAFE)

      "'#{part.gsub("'", "'\\\\''")}'"
    end

    # Провалившаяся подготовка — это сломанная задача, а не проигравшая
    # модель, и проверки после неё не запускаются: они прошли бы или упали
    # по причинам, к работе агента отношения не имеющим.
    def perform(task, preset, dir, seed)
      work = File.join(dir, "work")
      error = run_all(task.setup, cwd: work)
      return { error: "подготовка: #{error}" } if error

      agent = shell(command(task, preset, dir, seed), cwd: @root, timeout: @timeout)
      # Ответ модели пишется ДО проверок: задача вправе его проверить
      # (../answer.txt относительно рабочего каталога).
      File.write(File.join(dir, "answer.txt"), agent.stdout)
      File.write(File.join(dir, "stderr.txt"), agent.stderr)
      { exit_code: agent.exit_code, failed_check: run_all(task.checks, cwd: work) }
    rescue MiniAgent::TimeoutError => e
      { error: e.message }
    end

    # Первая же провалившаяся команда прекращает череду и называется целиком:
    # «не сошлось» без указания, что именно, заставляет открывать каталог
    # прогона руками на каждой строке отчёта.
    def run_all(commands, cwd:)
      runner = MiniAgent::ProcessRunner.new(timeout: HELPER_TIMEOUT, cwd: cwd)
      commands.each do |command|
        result = runner.call(command)
        return "#{command} → код #{result.exit_code}" unless result.success?
      end
      nil
    end

    def shell(command, cwd:, timeout:)
      MiniAgent::ProcessRunner.new(timeout: timeout, cwd: cwd).call(command)
    end

    # Каталог прошлого прогона сносится, а не дополняется. Оставленный файл
    # прошлой попытки прошёл бы проверки этой, ничего не делая, — то есть
    # отчёт показал бы успех там, где агент не работал вовсе.
    def make_dir(task, preset, attempt)
      dir = File.join(@out_dir, preset.name, task.name, attempt.to_s)
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(File.join(dir, "work"))
      dir
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
