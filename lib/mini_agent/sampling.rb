# frozen_string_literal: true

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
