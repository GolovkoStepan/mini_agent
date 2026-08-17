# frozen_string_literal: true

require "json"

module MiniAgent
  # Из чего складывается контекст, уходящий модели.
  #
  # Меряет ЗНАКИ, а не токены, и это не приблизительность от лени. Своего
  # токенизатора в проекте нет, словарь у каждой модели свой, а пересчёт
  # знаков в токены коэффициентом отвергнут сознательно: на русском тексте
  # и на коде он разный, ошибка легко в полтора-два раза, — и при этом
  # такая оценка выглядит ровно так же уверенно, как измерение. Знаки
  # считаются точно и проверяемо; единственное честное число о токенах
  # присылает сервер в usage, и оно показывается отдельной строкой как есть.
  #
  # Ничего не печатает и никуда не ходит: чистая функция от истории.
  class ContextReport
    # Порядок здесь — порядок вывода: сверху то, что задано до диалога,
    # снизу то, что накопилось по ходу работы. На этом же делении держится
    # различение fixed/compactable — см. ниже.
    CATEGORIES = %i[system project tasks answers tools].freeze

    def initialize(conversation, usage: nil, config: nil)
      @sizes = Hash.new(0)
      @messages = conversation.size
      @usage = usage
      @config = config
      measure(conversation)
    end

    # Знаки по категориям: только непустые и в порядке CATEGORIES.
    # Строка «результаты команд: 0» в диалоге без единой команды —
    # это шум, а не сведения.
    def sizes
      CATEGORIES.filter_map { |name| [name, @sizes[name]] if @sizes[name].positive? }.to_h
    end

    attr_reader :messages

    def total = @sizes.values.sum

    def empty? = total.zero?

    # Доля категории в процентах. Округление до целого: сотые доли процента
    # ничего не решают, а строку удлиняют.
    def share(category)
      return 0 if empty?

      (@sizes[category] * 100.0 / total).round
    end

    # Что переживёт /compact: системный промпт и описание проекта
    # пересобираются заново из History и сворачиванию не поддаются.
    def fixed = @sizes[:system] + @sizes[:project]

    # Что /compact способен свернуть: сам диалог.
    def compactable = @sizes[:tasks] + @sizes[:answers] + @sizes[:tools]

    # Место занято описанием проекта — /compact не поможет, лечится только
    # правкой файла.
    #
    # Спрашивается именно про описание, а не про всё несворачиваемое
    # (`fixed > compactable`), и это разница не косметическая: системный
    # промпт занимает под тысячу знаков, поэтому сразу ПОСЛЕ успешного
    # сворачивания он почти всегда перевешивает короткое резюме. Признак
    # по fixed срабатывал бы почти на каждом /compact — предупреждение
    # превратилось бы в шум, который перестают читать. Поймано тестом
    # «на обычном диалоге не предупреждает».
    #
    # Промпт к тому же постоянен и пользователю не подвластен: сообщать
    # о нём нечего. Описание проекта задаётся файлом и бывает любого
    # размера — известен живой случай, когда большой AGENTS.md делал
    # сессию неработоспособной, и /clear не помогал по той же причине.
    def project_dominates? = @sizes[:project] * 2 > total

    # Реальный размер промпта в токенах — по данным сервера, а не наш счёт.
    # nil, если запросов ещё не было или сервер usage не присылает: это
    # разные вещи с нулём, и показывать их одинаково нельзя.
    #
    # Ноль после /clear — тот же случай: счётчик забыл прошлый промпт, а
    # нового ещё не было. «Последний промпт — 0 токенов» выглядело бы как
    # ответ сервера, хотя это отсутствие ответа (замечено живой проверкой
    # сразу после починки самого сброса).
    def tokens
      return nil if @usage.nil? || @usage.empty?

      context = @usage.context
      context.positive? ? context : nil
    end

    # Заполнение контекстного окна — единственная строка отчёта, где знаки
    # не при чём: и размер окна, и промпт меряются в токенах, а пересчёт
    # одного в другое здесь отвергнут по той же причине, что и везде.
    #
    # Отдаётся всегда, даже когда мерить нечем: Window сам знает, что он
    # ничего не знает, и решение «показывать или нет» принимает UI. Возвращать
    # отсюда nil значило бы развести проверку на два места.
    def window
      Window.new(
        size: @config&.context_window,
        prompt_tokens: tokens,
        max_tokens: @config&.max_tokens.to_i
      )
    end

    private

    def measure(conversation)
      conversation.to_a.each { |message| @sizes[category(message)] += size(message) }
      split_project(conversation.project_context_size)
    end

    # Описание проекта живёт внутри системного сообщения (второе system-
    # сообщение ломает шаблоны чата ряда моделей), поэтому в общем подсчёте
    # оно попадает в :system, а здесь отделяется.
    #
    # Размер берётся у Conversation, а не вычисляется разбором готового
    # промпта по образцу разметки: это был бы второй EXIT_CODE_PATTERN —
    # пара «формат и его разбор», которая молча расходится при первой же
    # правке формата.
    def split_project(project_size)
      return if project_size.zero?

      @sizes[:project] = project_size
      @sizes[:system] = [@sizes[:system] - project_size, 0].max
    end

    def category(message)
      case message[:role]
      when "system" then :system
      when "user" then :tasks
      when "assistant" then :answers
      else :tools
      end
    end

    # tool_calls считаются вместе с сообщением: в теле запроса они едут
    # рядом с content и место занимают наравне с ним.
    def size(message)
      length = message[:content].to_s.length
      calls = message[:tool_calls]
      length += JSON.generate(calls).length if calls && !calls.empty?
      length
    end
  end
end
