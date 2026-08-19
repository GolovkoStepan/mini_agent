# frozen_string_literal: true

require "json"

module Evals
  # Что происходило внутри прогона — по журналу агента (--log, JSONL).
  #
  # Журнал берётся потому, что это единственный источник, который видит ход
  # работы, а не только её итог. Код возврата отвечает «получилось или нет»,
  # а вопрос из MY_THINKS.md — про то, как именно портится работа: сколько
  # ходов ушло, сколько токенов сгенерировано впустую, повторялись ли вызовы.
  class Journal
    # Пустой журнал — не ошибка разбора. Агент мог упасть до открытия файла
    # (неверный --cwd, сервер не отвечает), и прогон при этом честно
    # провалился. Отдельным исключением это выглядело бы как поломка
    # измерителя вместо поломки прогона.
    def self.read(path)
      return new([]) unless path && File.exist?(path)

      new(File.readlines(path, chomp: true))
    end

    def initialize(lines)
      # Битая последняя строка — норма, а не порча: журнал пишется по
      # сообщению, и убитый посреди записи процесс оставляет обрывок.
      # Пропускаем её молча, остальные записи от этого не страдают.
      @records = lines.filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    # Ходов модели: по одному ответу на запрос. Именно это число упирается
    # в --max-turns, поэтому оно же говорит, топталась модель или работала.
    def turns = messages("assistant").size

    def tool_calls = calls.size

    # Повторов подряд — тем же дословным сравнением, что и в
    # ToolCallRunner#count_repeat. Определение обязано совпадать: расхождение
    # дало бы отчёт, где повторов нет, а агент их считает и обрывает задачу.
    def repeats
      calls.each_cons(2).count { |before, after| before == after }
    end

    # Контекст на последнем запросе — то самое число, что упирается в окно.
    # Сумма prompt_tokens смысла не имеет: история уходит модели целиком
    # на каждом ходу (см. Usage в CLAUDE.md).
    def context_tokens = usages.filter_map { |usage| usage["prompt_tokens"] }.last

    def generated_tokens = usages.sum { |usage| usage["completion_tokens"].to_i }

    # Знаки, а не токены: reasoning_content приходит текстом, и токенов
    # отдельно по нему сервер не сообщает. Мерить нечем точнее, а порядок
    # величины — ровно то, ради чего число здесь: зацикливание рассуждений
    # видно по нему сразу.
    def reasoning_chars
      @records.select { |record| record["type"] == "reasoning" }.sum { |record| record["content"].to_s.length }
    end

    def compacts = count_type("compact")
    def rollbacks = count_type("rollback")

    def to_h
      { turns: turns, tool_calls: tool_calls, repeats: repeats, context_tokens: context_tokens,
        generated_tokens: generated_tokens, reasoning_chars: reasoning_chars,
        compacts: compacts, rollbacks: rollbacks }
    end

    private

    def count_type(type) = @records.count { |record| record["type"] == type }

    def messages(role)
      @records.select { |record| record["type"] == "message" && record["role"] == role }
    end

    # Вызовы инструментов по порядку: имя и аргументы как есть. Строкой, а не
    # разобранным JSON, — сравниваются они на равенство, и лишний разбор
    # добавил бы способ разойтись с агентом на форматировании.
    def calls
      @calls ||= messages("assistant").flat_map { |message| Array(message["tool_calls"]) }
                                      .map { |call| (call["function"] || {}).values_at("name", "arguments") }
    end

    def usages = @records.filter_map { |record| record["usage"] }
  end
end
