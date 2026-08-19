# frozen_string_literal: true

module Evals
  # Итог одного прогона: задача × набор × попытка.
  #
  # УСПЕХ ОПРЕДЕЛЯЕТСЯ ПРОВЕРКАМИ, А НЕ КОДОМ ВОЗВРАТА. Код 4 (ходы кончились)
  # при пройденных проверках означает, что работа сделана, хоть и впритык, —
  # объявить это провалом значило бы наказать за медлительность там, где
  # меряется правильность. Обратное тоже бывает: код 0 при непройденных
  # проверках — это ровно то фантазёрство, ради которого всё затевалось,
  # модель отрапортовала о сделанном и вышла успешно. Код печатается рядом
  # отдельной колонкой: он диагностика, а не приговор.
  class Result
    attr_reader :task, :preset, :attempt, :seed, :exit_code, :failed_check, :journal, :seconds, :error

    def initialize(task:, preset:, attempt:, seed:, exit_code:, journal:, seconds:, failed_check: nil, error: nil)
      @task = task
      @preset = preset
      @attempt = attempt
      @seed = seed
      @exit_code = exit_code
      @failed_check = failed_check
      @journal = journal
      @seconds = seconds
      @error = error
    end

    def ok? = @failed_check.nil? && @error.nil?

    # Почему не получилось — одной строкой для таблицы. Провалившаяся проверка
    # называется дословно: «не сделал» без указания, что именно не сошлось,
    # заставляет открывать каталог прогона руками на каждой строке отчёта.
    def reason
      return nil if ok?

      @error || @failed_check
    end

    def to_h
      { task: @task, preset: @preset, attempt: @attempt, seed: @seed, ok: ok?,
        exit_code: @exit_code, reason: reason, seconds: @seconds.round(1) }.merge(@journal.to_h)
    end
  end
end
