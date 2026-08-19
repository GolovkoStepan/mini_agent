# frozen_string_literal: true

require "json"

module Evals
  # Одна оценочная задача: что дать агенту и как проверить, что он справился.
  #
  # Проверки — команды shell, обязанные вернуть 0. Не сравнение с эталонным
  # ответом: тот же результат достигается разным кодом, и сверка текстов
  # ловила бы стиль вместо работы. Проверка состояния файлов отвечает ровно
  # на нужный вопрос — сделано или нет.
  #
  # Ответ модели проверять тоже можно, но редко: он лежит в ../answer.txt
  # относительно рабочего каталога проверок. Путь литеральный, без подстановки
  # переменных в текст проверки: подстановка завела бы очередную пару «формат
  # и его разбор», которая расходится при первой правке. Ответ вынесен НАД
  # рабочим каталогом, чтобы не попадать под проверки вида «сколько файлов
  # в каталоге».
  class Task
    # Обязательные и допустимые поля. Опечатка в имени поля обязана ронять
    # разбор, а не молча пропадать: задача с "check" вместо "checks" прошла
    # бы все прогоны успешно, ничего не проверив, — то есть отчёт был бы
    # не пустым, а ложным.
    REQUIRED = %w[name prompt checks].freeze
    ALLOWED = (REQUIRED + %w[setup max_turns about agent_flags]).freeze

    # Умолчание ходов: задачи держатся мелкими намеренно (см. evals/README.md),
    # а упор в лимит — это и есть сигнал «модель топчется на месте».
    DEFAULT_MAX_TURNS = 8

    # Условия, в которых задача измеряется, задаются ею самой (`agent_flags`),
    # а не строкой запуска. Условие в ARGS действует на всю матрицу, то есть
    # задача, требующая `--policy ask`, в обычном `make evals` мерила бы не то,
    # ради чего заведена. Набор при этом сильнее: его флаги идут последними
    # и перебивают задачу, иначе задача с `--temperature` молча ломала бы
    # сравнение наборов между собой (см. Runner#command).
    attr_reader :name, :prompt, :setup, :checks, :max_turns, :about, :agent_flags

    def self.load_all(dir, names: nil)
      files = Dir.glob(File.join(dir, "*.json"))
      tasks = files.map { |path| from_file(path) }
      return tasks unless names

      select(tasks, names)
    end

    def self.from_file(path)
      new(JSON.parse(File.read(path)), source: path)
    rescue JSON::ParserError => e
      raise ArgumentError, "#{path}: не разбирается как JSON — #{e.message}"
    end

    def self.select(tasks, names)
      known = tasks.to_h { |task| [task.name, task] }
      names.map do |name|
        known.fetch(name) { raise ArgumentError, "неизвестная задача: #{name}" }
      end
    end

    def initialize(data, source: nil)
      @source = source
      validate(data)
      @name = data.fetch("name")
      @prompt = data.fetch("prompt")
      @checks = Array(data.fetch("checks"))
      @setup = Array(data["setup"])
      @max_turns = data["max_turns"] || DEFAULT_MAX_TURNS
      @about = data["about"]
      @agent_flags = Array(data["agent_flags"])
    end

    private

    def validate(data)
      missing = REQUIRED.reject { |key| data[key] }
      raise ArgumentError, "#{where}: нет обязательных полей: #{missing.join(", ")}" unless missing.empty?

      unknown = data.keys - ALLOWED
      raise ArgumentError, "#{where}: неизвестные поля: #{unknown.join(", ")}" unless unknown.empty?
    end

    def where = @source || "задача"
  end
end
