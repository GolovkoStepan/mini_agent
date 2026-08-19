# frozen_string_literal: true

require "json"
require "did_you_mean"

module MiniAgent
  # Постоянные настройки из файла ~/.mini_agent/settings.json.
  #
  # Отдельным классом, а не методом Config: у того задача — свести опции,
  # окружение и умолчания в одно значение, здесь же начинается файловая
  # система. Тем же порогом из Config в своё время выделился Paths.
  #
  # Читает файл CLI, а не Config: у CLI уже есть и флаги (--settings,
  # --no-settings), и обработка ConfigError. Config получает готовое —
  # благодаря этому его тесты не начинают читать диск разработчика,
  # а умолчанием остаётся NONE.
  class Settings
    PATH = "~/.mini_agent/settings.json"

    def initialize(values = {}, path: nil)
      @values = values
      @path = path
    end

    attr_reader :values, :path

    # Файла не было вовсе. Не nil, потому что спрашивают у него values и path,
    # и проверка на nil расползлась бы по всем местам, где настройки читают.
    NONE = new.freeze

    class << self
      # Файл настроек этого запуска по флагам CLI. Здесь, а не в CLI: вопрос
      # «какой файл читать» целиком про настройки, а у CLI от него оставалась
      # бы одна проверка на противоречие.
      #
      # Оба флага сразу — отказ, а не угадывание: указания противоречат друг
      # другу и ни одно не точнее другого (прецедент --policy asl — падать
      # громко там, где выбор был бы выдуман).
      #
      # Спрашивается key?, а не значение: OptionParser считает «--no-»
      # отрицанием и отдаёт в блок false, поэтому ложь в options и есть признак
      # того, что флаг набран. Проверка на истинность пропускала бы его всегда —
      # поймано живой проверкой сразу после того, как тесты были зелёными.
      def from_options(options)
        disabled = options.key?(:no_settings)
        raise ConfigError, Messages::SETTINGS_CONFLICT if options[:settings] && disabled

        load(options[:settings], enabled: !disabled)
      end

      # enabled: false — это --no-settings: файл не читается даже названный.
      # Нужно оценочным задачам, где личные настройки молча участвовали бы
      # в измерениях, не показываясь в отчёте.
      def load(path = nil, enabled: true)
        return NONE unless enabled

        named = Paths.expand(path)
        full = named || Paths.expand(PATH)
        return new(read(full), path: full) if File.file?(full)

        # Отсутствие умолчательного файла — обычное дело, а вот названный
        # и отсутствующий означает работу с чужими настройками при уверенности
        # в своих. Тот же случай, что --policy asl: молчать нельзя.
        raise ConfigError, format(Messages::SETTINGS_NOT_FOUND, path: full) if named

        NONE
      end

      private

      def read(full)
        parsed = JSON.parse(File.read(full))
        raise ConfigError, format(Messages::SETTINGS_NOT_OBJECT, path: full) unless parsed.is_a?(Hash)

        parsed.to_h { |key, value| [check(key, full), value] }
      rescue JSON::ParserError => e
        raise ConfigError, format(Messages::SETTINGS_BROKEN, path: full, message: e.message)
      rescue SystemCallError, IOError => e
        raise ConfigError, format(Messages::SETTINGS_UNREADABLE, path: full, message: e.message)
      end

      # Белый список — ключи ENV_KEYS, а не DEFAULTS: у параметров сэмплинга
      # умолчаний нет вовсе, а они и есть повод заводить файл. Третьей схемы
      # имён после ключей настроек и переменных окружения быть не должно,
      # поэтому список берётся из существующей таблицы, а не пишется заново.
      # Действия CLI (interactive, list_models, help) в неё не входят и в файле
      # не принимаются: это не настройки.
      #
      # Неизвестный ключ роняет запуск, а не игнорируется молча: файл пишут
      # один раз и потом не перечитывают, а «max_token» без s выглядит рабочим
      # ровно до того дня, когда понадобится.
      def check(key, full)
        name = key.to_s
        known = Config::ENV_KEYS.keys
        symbol = name.to_sym
        return symbol if known.include?(symbol)

        raise ConfigError, format(Messages::SETTINGS_UNKNOWN_KEY, key: name, path: full, hint: hint(name, known))
      end

      # Подсказка ближайшего ключа. Перечислять все двадцать семь в сообщении
      # бесполезно — их и так видно в README, — а вот «возможно, max_tokens»
      # отвечает ровно на тот вопрос, который возник.
      def hint(name, known)
        near = DidYouMean::SpellChecker.new(dictionary: known.map(&:to_s)).correct(name).first
        near ? format(Messages::SETTINGS_DID_YOU_MEAN, key: near) : ""
      end
    end
  end
end
