# frozen_string_literal: true

require "json"

module Evals
  # Набор параметров сэмплинга, с которым гоняется вся матрица задач.
  #
  # Имена полей — те же, что у MiniAgent::Sampling, и список допустимых берётся
  # оттуда же, а не переписывается сюда. Своя копия списка разошлась бы с
  # настоящей при первом же новом параметре, и опечатка в наборе уехала бы
  # в командную строку агента, где обвалила бы КАЖДЫЙ прогон одинаково —
  # то есть выглядела бы как «набор плохой», а не как «в файле опечатка».
  #
  # ЗЕРНО СЮДА НЕ КЛАДЁТСЯ, и это не упущение. Сравнение наборов имеет смысл
  # только попарно: набор A и набор B обязаны получить одну и ту же
  # последовательность зёрен, иначе к разнице настроек примешивается разница
  # случайности. Значит зерно принадлежит прогону целиком (Runner), а не
  # отдельному набору, — и ключ "seed" в файле набора отвергается с
  # объяснением, а не игнорируется молча.
  class Preset
    ALLOWED = (MiniAgent::Sampling::KEYS.keys.map(&:to_s) - ["seed"] + ["about"]).freeze

    attr_reader :name, :sampling, :about

    def self.load_all(dir, names: nil)
      presets = Dir.glob(File.join(dir, "*.json")).map { |path| from_file(path) }
      return presets unless names

      known = presets.to_h { |preset| [preset.name, preset] }
      names.map { |name| known.fetch(name) { raise ArgumentError, "неизвестный набор: #{name}" } }
    end

    def self.from_file(path)
      new(File.basename(path, ".json"), JSON.parse(File.read(path)), source: path)
    rescue JSON::ParserError => e
      raise ArgumentError, "#{path}: не разбирается как JSON — #{e.message}"
    end

    def initialize(name, data, source: nil)
      @name = name
      @source = source
      validate(data)
      @about = data["about"]
      @sampling = data.except("about")
    end

    # Флаги командной строки агента. Пустой набор — это осмысленный набор:
    # он означает «ничего не шлём, решает пресет сервера», то есть тот самый
    # исходный уровень, относительно которого меряются остальные.
    def flags
      @sampling.sort.flat_map { |key, value| ["--#{key.tr("_", "-")}", value.to_s] }
    end

    def to_h = { name: @name, sampling: @sampling }

    private

    def validate(data)
      raise ArgumentError, "#{where}: зерно задаётся прогоном (--seed), а не набором" if data.key?("seed")

      unknown = data.keys - ALLOWED
      raise ArgumentError, "#{where}: неизвестные параметры: #{unknown.join(", ")}" unless unknown.empty?
    end

    def where = @source || @name
  end
end
