# frozen_string_literal: true

module Evals
  # Отчёт по матрице прогонов: таблица успехов, расход по успешным прогонам
  # и вердикт «стало лучше / хуже / не повлияло».
  #
  # Вердикт выносится с оговоркой, а не как факт. Доля успехов на пяти-десяти
  # прогонах — величина шумная, и разница «11 из 15 против 9 из 15» от шума
  # неотличима. Поэтому разница сравнивается с оценкой собственного разброса,
  # и «не повлияло» — самый частый честный ответ на маленькой матрице.
  # Отчёт, объявляющий победителя по трём прогонам, хуже отсутствия отчёта:
  # он выглядит измерением.
  class Report
    # Во сколько разбросов должна укладываться разница, чтобы считаться шумом.
    # Два — обычная граница «на глаз» для нормального приближения; точнее
    # здесь не нужно, потому что само приближение на таких числах грубое.
    MARGIN = 2.0

    VERDICTS = { better: "лучше", worse: "хуже", same: "не повлияло",
                 unknown: "мало наблюдений" }.freeze

    def initialize(results, presets:, tasks:)
      @results = results
      @presets = presets
      @tasks = tasks
    end

    def baseline = @presets.first

    def to_s
      [successes_table, spend_table, verdict_block].join("\n\n")
    end

    # Вердикт набора относительно исходного. :unknown означает «прогонов мало»,
    # а не «разницы нет»: это разные ответы, и сливать их нельзя — первый
    # лечится числом прогонов, второй означает, что настройка не работает.
    def verdict(preset)
      base = runs(baseline)
      other = runs(preset)
      return :unknown if [base.size, other.size].min < MIN_OBSERVATIONS

      difference = share(other) - share(base)
      return :same if difference.abs <= MARGIN * spread(base, other)

      difference.positive? ? :better : :worse
    end

    private

    def runs(preset) = @results.select { |result| result.preset == preset }

    def cell(preset, task)
      set = runs(preset).select { |result| result.task == task }
      "#{set.count(&:ok?)}/#{set.size}"
    end

    def successes_table
      header = ["задача", *@presets]
      rows = @tasks.map { |task| [task, *@presets.map { |preset| cell(preset, task) }] }
      totals = ["итого", *@presets.map { |preset| "#{runs(preset).count(&:ok?)}/#{runs(preset).size}" }]
      "Успешных прогонов\n\n#{render([header, *rows, totals])}"
    end

    # Средние считаются ТОЛЬКО по успешным прогонам, и это не мелочь.
    # Провал обычно короче успеха: агент сдался, упёрся в ошибку, вышел
    # с кодом 3 на втором ходу. Смешав их, набор с большим числом провалов
    # выглядит самым экономным — то есть таблица расхода противоречила бы
    # таблице успехов ровно там, где на неё смотрят.
    def spend_table
      header = %w[набор ходов сгенерировано повторов рассуждений секунд]
      rows = @presets.map do |preset|
        set = runs(preset).select(&:ok?)
        [preset, *spend_row(set)]
      end
      "Расход на успешный прогон (среднее)\n\n#{render([header, *rows])}"
    end

    def spend_row(set)
      return ["—"] * 5 if set.empty?

      [average(set) { |result| result.journal.turns },
       average(set) { |result| result.journal.generated_tokens },
       average(set) { |result| result.journal.repeats },
       average(set) { |result| result.journal.reasoning_chars },
       average(set, &:seconds)]
    end

    def average(set)
      values = set.map { |result| yield(result).to_f }
      format("%.1f", values.sum / values.size)
    end

    def verdict_block
      lines = (@presets - [baseline]).map do |preset|
        "#{preset}: #{VERDICTS.fetch(verdict(preset))} " \
          "(#{runs(preset).count(&:ok?)}/#{runs(preset).size} против " \
          "#{runs(baseline).count(&:ok?)}/#{runs(baseline).size})"
      end
      lines << "сравнивать не с чем: набор один" if lines.empty?
      "Вердикт относительно набора «#{baseline}»\n\n#{lines.join("\n")}"
    end

    def share(set) = set.empty? ? 0.0 : set.count(&:ok?).to_f / set.size

    def spread(base, other) = Math.sqrt(variance(base) + variance(other))

    # Разброс доли по нормальному приближению, со сглаживанием (+1 успех,
    # +1 промах). Без сглаживания набор, прошедший все прогоны до одного,
    # даёт нулевой разброс, и любой перевес над ним объявляется несомненным
    # — на пяти прогонах это заведомая неправда. Приём известен как поправка
    # Агрести — Коулла; здесь он нужен ровно ради этого края.
    def variance(set)
      size = set.size + 2
      value = (set.count(&:ok?) + 1).to_f / size
      value * (1 - value) / size
    end

    def render(rows)
      widths = rows.transpose.map { |column| column.map(&:to_s).map(&:length).max }
      rows.map { |row| row.each_with_index.map { |cell, i| cell.to_s.ljust(widths[i]) }.join("  ").rstrip }
          .join("\n")
    end
  end
end
