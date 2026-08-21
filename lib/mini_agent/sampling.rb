# frozen_string_literal: true

require "did_you_mean"

module MiniAgent
  # Параметры сэмплинга, уходящие в тело запроса к /chat/completions.
  #
  # ГЛАВНОЕ ПРАВИЛО: чего человек не задал, того в теле запроса НЕТ ВОВСЕ.
  # Отсутствие поля — единственный способ сказать «решает сервер». Поле с
  # умолчанием этого не выражает: параметр в теле перебивает пресет,
  # загруженный на стороне сервера, и делает это молча.
  #
  # Заведено по живому дефекту, а не из общих соображений. ChatPayload
  # зашивал temperature = 0.1 и клал её в КАЖДЫЙ запрос, включая служебные
  # (/compact, /init, суммирующий ход). Выставленная в LM Studio температура
  # 0.3 не применялась ни разу — и, что хуже, само зацикливание рассуждений,
  # ради которого пресет настраивали, могло быть следствием этих 0.1:
  # низкая температура на рассуждающей модели — известная причина
  # вырожденного повтора.
  #
  # ИМЕНА ПОЛЕЙ 1:1 С ПРОВОДОМ, БЕЗ ПЕРЕВОДА. repeat_penalty (llama.cpp,
  # LM Studio) и frequency_penalty (OpenAI) — РАЗНЫЕ величины, а не синонимы:
  # первый делит логиты и нейтрален в 1.0, второй вычитает и нейтрален в 0.
  # Значение 1.12, поставленное в поле frequency_penalty, означало бы почти
  # максимальный штраф там, где просили слабый. vLLM зовёт то же третьим
  # именем (repetition_penalty). Своя таблица переводов стала бы четвёртым
  # источником истины и разошлась бы с каждым из трёх; вместо неё — три
  # независимые ручки и строка в README о том, какой сервер что понимает.
  class Sampling
    # Ключ → как разбирать значение. Ключей нет в Config::DEFAULTS намеренно:
    # умолчания у них живут на сервере, а не здесь.
    KEYS = {
      temperature: :float,
      top_p: :float,
      top_k: :integer,
      min_p: :float,
      repeat_penalty: :float,
      presence_penalty: :float,
      frequency_penalty: :float,
      seed: :integer
    }.freeze

    # Разделители пар внутри одного --sampling: запятая и пробел. Дробная
    # часть при этом пишется через точку — «temperature=0,3» разрежется
    # на «temperature=0» и «3», и второй обломок упрётся в требование
    # «ключ=значение». Ошибка громкая, поэтому запятая-разделитель
    # допустима; про точку сказано прямо в тексте отказа.
    SEPARATOR = /[,\s]+/

    class << self
      # Общая форма --sampling key=value, разложенная по отдельным ключам
      # options.
      #
      # Возвращается НОВЫЙ хеш опций, а не свой источник значений, и это
      # главное решение здесь: дальше по коду разницы между «--temperature
      # 0.3» и «--sampling temperature=0.3» быть не должно. Свой источник
      # означал бы, что Lookup#given? видит одно число в двух местах, —
      # а от этого признака зависят и max_tokens, и спор policy с
      # allow_unsafe (см. Lookup).
      #
      # ПРОВЕРКА КЛЮЧЕЙ ПО СПИСКУ — условие, при котором общая форма вообще
      # заводится, а не украшение. Опечатка «temperatur=0.3» в пересылаемом
      # как есть виде уходит на сервер и молча игнорируется: флаг выглядит
      # рабочим, а действует пресет сервера. Именованный флаг ловит такое
      # разбором аргументов, и общая форма обязана ловить не хуже — иначе
      # она меняет восемь строк справки на молчаливую подмену настроек.
      def expand(options)
        pairs = Array(options[:sampling])
        return options if pairs.empty?

        seen = []
        fragments(pairs).each_with_object(options.dup) do |fragment, result|
          key, value = pair(fragment)
          check(key, seen, options)
          seen << key
          result[key] = value
        end
      end

      private

      def fragments(pairs)
        pairs.flat_map { |text| text.to_s.split(SEPARATOR) }.reject(&:empty?)
      end

      # split("=", 2): значение может содержать что угодно, ключ — нет.
      def pair(fragment)
        name, value = fragment.split("=", 2)
        raise ConfigError, format(Messages::SAMPLING_PAIR_EXPECTED, fragment: fragment) if value.nil?

        [known(name), value]
      end

      def known(name)
        key = name.strip.to_sym
        return key if KEYS.key?(key)

        raise ConfigError, format(Messages::SAMPLING_UNKNOWN_KEY, key: name,
                                                                  known: KEYS.keys.join(", "), hint: hint(name))
      end

      # Дважды заданный параметр — отказ, а не «побеждает последний».
      # Указания противоречат друг другу, и ни одно не точнее другого:
      # тот же выбор, что у --settings вместе с --no-settings. Случая два,
      # и сообщения тоже два — «повторено в --sampling» и «спорит с
      # отдельным флагом» лечатся по-разному.
      def check(key, seen, options)
        raise ConfigError, format(Messages::SAMPLING_REPEATED, name: key) if seen.include?(key)
        raise ConfigError, format(Messages::SAMPLING_CONFLICT, name: key) if options.key?(key)
      end

      # Подсказка ближайшего ключа — та же, что у неизвестной настройки
      # в файле, и тем же способом. Восемь известных имён при этом
      # перечисляются целиком: их мало, в отличие от двадцати семи настроек.
      def hint(name)
        near = DidYouMean::SpellChecker.new(dictionary: KEYS.keys.map(&:to_s)).correct(name.strip).first
        near ? format(Messages::DID_YOU_MEAN, key: near) : ""
      end
    end

    def initialize(config)
      @config = config
    end

    def to_h
      KEYS.each_with_object({}) do |(key, type), result|
        value = @config.given(key)
        result[key] = number(key, type, value) unless value.nil?
      end
    end

    private

    # Float()/Integer(), а не to_f/to_i: «LLM_TEMPERATURE=abc» обязано ронять
    # запуск, а не превращаться в правдоподобный 0.0. Тот же выбор, что у
    # неизвестной политики (--policy asl): опечатка в значении, определяющем
    # поведение модели, не должна работать молча.
    #
    # Диапазоны НЕ проверяются. Границы у каждого сервера свои (top_k = 0
    # где-то означает «выключено», где-то ошибку), и своя таблица пределов
    # устарела бы первой. Неприемлемое значение сервер отвергнет сам —
    # HTTP 400 разберёт и покажет ErrorResponse.
    def number(key, type, value)
      type == :integer ? Integer(value) : Float(value)
    rescue ArgumentError, TypeError
      raise ConfigError, format(Messages::INVALID_SAMPLING, name: key, value: value)
    end
  end
end
