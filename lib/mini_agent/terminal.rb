# frozen_string_literal: true

require "io/console"

module MiniAgent
  # Ширина терминала.
  #
  # Выделено из Spinner, когда за той же величиной пришёл рендерер разметки:
  # два способа узнать одно число разошлись бы при первой правке, а
  # разъехавшаяся ширина видна не как ошибка, а как криво сверстанный вывод.
  #
  # Спрашивается при каждом обращении, а не запоминается: окно терминала
  # меняют посреди работы, и запомненное даёт либо перенос строки, либо
  # пустое место справа.
  module Terminal
    # Ширина, когда узнать её не вышло: вывод перенаправлен, ioctl
    # не отвечает, окна нет вовсе.
    DEFAULT_WIDTH = 80

    def self.width
      columns = IO.console&.winsize&.last.to_i
      columns.positive? ? columns : DEFAULT_WIDTH
    rescue StandardError
      DEFAULT_WIDTH
    end
  end
end
