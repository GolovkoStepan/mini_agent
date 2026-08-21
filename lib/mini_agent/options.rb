# frozen_string_literal: true

require "optparse"

module MiniAgent
  # Таблица флагов и разбор командной строки.
  #
  # Отделено от CLI девятым срабатыванием Metrics/ClassLength — и, как все
  # восемь раз до этого, порог указал верно: здесь описание внешнего
  # интерфейса (какие флаги бывают, как пишется значение, какой можно
  # повторять), а у CLI — что делать с разобранным и с каким кодом выйти.
  # Растут они от разных причин: первое от новых настроек, второе от новых
  # исходов запуска.
  class Options
    # Описание флагов таблицей: [ключ настроек, *аргументы OptionParser#on].
    # Значение флага кладётся в values под указанным ключом.
    FLAGS = [
      [:interactive, "-i", "--interactive", Messages::OPT_INTERACTIVE],
      [:max_turns, "--max-turns N", Integer, Messages::OPT_MAX_TURNS],
      [:max_tokens, "--max-tokens N", Integer, Messages::OPT_MAX_TOKENS],
      [:context_window, "--context-window N", Integer, Messages::OPT_CONTEXT_WINDOW],
      [:llm_timeout, "--llm-timeout N", Float, Messages::OPT_LLM_TIMEOUT],
      [:retry_count, "--retry-count N", Integer, Messages::OPT_RETRY_COUNT],
      [:retry_delay, "--retry-delay N", Float, Messages::OPT_RETRY_DELAY],
      [:base_url, "--base-url URL", Messages::OPT_BASE_URL],
      [:model, "--model NAME", Messages::OPT_MODEL],
      [:stream, "--[no-]stream", Messages::OPT_STREAM],
      [:auto_compact, "--[no-]auto-compact", Messages::OPT_AUTO_COMPACT],
      # Без типа Float намеренно: разбор и проверку диапазона делает Config,
      # и «--compact-at abc» обязано падать одним и тем же ConfigError
      # независимо от того, пришло значение флагом или из AUTO_COMPACT_AT.
      [:compact_at, "--compact-at N", Messages::OPT_COMPACT_AT],
      [:markdown, "--[no-]markdown", Messages::OPT_MARKDOWN],
      # Параметры сэмплинга. Умолчаний у них нет: не задано — не отправляем,
      # решает пресет сервера (см. Sampling).
      [:temperature, "--temperature N", Float, Messages::OPT_TEMPERATURE],
      [:top_p, "--top-p N", Float, Messages::OPT_TOP_P],
      [:top_k, "--top-k N", Integer, Messages::OPT_TOP_K],
      [:min_p, "--min-p N", Float, Messages::OPT_MIN_P],
      [:repeat_penalty, "--repeat-penalty N", Float, Messages::OPT_REPEAT_PENALTY],
      [:presence_penalty, "--presence-penalty N", Float, Messages::OPT_PRESENCE_PENALTY],
      [:frequency_penalty, "--frequency-penalty N", Float, Messages::OPT_FREQUENCY_PENALTY],
      [:seed, "--seed N", Integer, Messages::OPT_SEED],
      # Та же восьмёрка одной строкой. Без типа намеренно: разбор пар и
      # проверку ключей делает Sampling, и «--sampling temperatur=0.3»
      # обязано падать до запроса, а не уезжать на сервер молча.
      [:sampling, "--sampling PAIRS", Messages::OPT_SAMPLING],
      [:policy, "--policy NAME", Messages::OPT_POLICY],
      [:plan, "--plan", Messages::OPT_PLAN],
      [:allow_unsafe, "--[no-]allow-unsafe", Messages::OPT_ALLOW_UNSAFE],
      [:list_models, "--list-models", Messages::OPT_LIST_MODELS],
      [:cwd, "--cwd DIR", Messages::OPT_CWD],
      [:log, "--log FILE", Messages::OPT_LOG],
      # Два отдельных флага, а не --[no-]settings: у первого есть аргумент,
      # у второго его быть не может.
      [:settings, "--settings FILE", Messages::OPT_SETTINGS],
      [:no_settings, "--no-settings", Messages::OPT_NO_SETTINGS],
      [:help, "-h", "--help", Messages::OPT_HELP],
      [:version, "-v", "--version", Messages::OPT_VERSION]
    ].freeze

    # Флаги, которые можно повторять: значение копится списком.
    ACCUMULATED = %i[sampling].freeze

    attr_reader :values, :parser

    # Разбор отделён от сборки парсера намеренно: справку надо напечатать и
    # тогда, когда разбор провалился, — то есть объект парсера обязан
    # существовать до первой ошибки.
    def initialize
      @values = {}
      @parser = build_parser
    end

    # Возвращает то, что осталось после флагов, — задачу.
    def parse(argv)
      @parser.parse(argv.dup)
    end

    private

    def build_parser
      OptionParser.new do |opts|
        opts.banner = Messages::BANNER

        FLAGS.each do |key, *definition|
          opts.on(*definition) { |value| store(key, value) }
        end
      end
    end

    # Повторяемый флаг копит значения списком, обычный — хранит последнее.
    # Затирание здесь было бы молчаливым: «--sampling top_k=50 --sampling
    # temperature=0.3» выглядит как два указания, а действовало бы одно.
    def store(key, value)
      return @values[key] = value unless ACCUMULATED.include?(key)

      (@values[key] ||= []) << value
    end
  end
end
