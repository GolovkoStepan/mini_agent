# frozen_string_literal: true

module MiniAgent
  # Анимация ожидания в отдельном потоке.
  #
  # Выделена из UI по тому же признаку, что и ContextView: у остального UI
  # нет состояния — маркер, отступ, цвет и печать. Здесь же живут поток,
  # признак остановки и две строки состояния, а с приходом стриминга
  # добавилась досрочная остановка. Это уже не печать, а управление
  # фоновой работой, и порог Metrics/ClassLength указал на это пятый раз.
  #
  # Вне TTY поток не создаётся вообще: в логах и в тестах анимация не нужна,
  # а лишний поток — источник недетерминированности.
  class Spinner
    FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
    INTERVAL = 0.1

    # Меньше этого места под бегущую строку не отводим. Обрывок в несколько
    # знаков не читается вовсе, а строку удлиняет.
    MIN_TICKER = 24

    TICKER_SEPARATOR = "│ "

    # Строка состояния (например, «ход 2/10»): ставится один раз на ход
    # и живёт до конца запроса.
    attr_writer :status

    # Ход самой генерации («размышления: 240 знаков»). Отдельно от status:
    # меняется десятки раз в секунду и гаснет вместе со спиннером.
    attr_writer :progress

    # Бегущая строка: сам текст размышлений, хвостом. Отдельно от progress
    # потому, что у них разная судьба при нехватке места — счётчик короткий
    # и показывается всегда, а бегущая строка занимает весь остаток ширины
    # и на узком терминале пропадает целиком.
    attr_writer :ticker

    def initialize(ui:, enabled: true, interval: INTERVAL, width: nil)
      @ui = ui
      @enabled = enabled
      @interval = interval
      @width = width
      @thread = nil
      @stop = false
      @status = nil
      @progress = nil
      @ticker = nil
    end

    def around
      return yield unless @enabled

      start
      begin
        yield
      ensure
        stop
      end
    end

    # Погасить досрочно, не дожидаясь конца блока. Нужен стримингу: там текст
    # начинает печататься посреди запроса, а спиннер рисует себя в ту же
    # строку. Идемпотентен — around зовёт его же в ensure.
    def stop
      return unless @thread

      @stop = true
      @thread.join
      @thread = nil
      @progress = nil
      @ticker = nil
      @ui.print("\r\e[K")
    end

    private

    def start
      @stop = false
      @thread = spawn
    end

    # Строка чистится перед каждой отрисовкой (\e[K), потому что при стриминге
    # текст меняет длину: «240 знаков» короче «1240 знаков», и без очистки
    # от прежней строки остаётся хвост.
    def spawn
      Thread.new do
        index = 0
        until @stop
          @ui.print("\r\e[K#{line(FRAMES[index % FRAMES.size])}")
          index += 1
          sleep(@interval)
        end
      rescue IOError
        # Поток вывода закрыли — анимация больше не нужна.
        nil
      end
    end

    # Бегущая строка приглушена серым: она справочная, и в одном цвете со
    # спиннером перетягивала бы взгляд на себя. Длины считаются до раскраски —
    # ANSI-коды занимают знаки в строке, но не на экране.
    def line(frame)
      head = "#{frame} #{text}"
      tail = ticker_tail(head.length)
      return @ui.paint(head, :cyan) if tail.empty?

      "#{@ui.paint(head, :cyan)} #{@ui.paint("#{TICKER_SEPARATOR}#{tail}", :gray)}"
    end

    def text
      [Messages::THINKING, @status, @progress].compact.join(" ")
    end

    # Хвост берётся с конца, а не с начала: интересно то, что модель думает
    # сейчас, начало мысли уже уехало. Отсюда и «бегущая» — движение даёт
    # сам приход текста, отдельного таймера для прокрутки не нужно.
    #
    # Пробельные последовательности схлопываются: строка одна и перерисовывает
    # себя по \r, а любой перевод строки внутри неё оставил бы на экране
    # обрывки, которые \e[K уже не достанет.
    def ticker_tail(head_length)
      return "" unless @ticker

      # Знак пробела перед разделителем и один столбец справа: строка,
      # заполнившая ширину ровно, переносится и рвёт перерисовку по \r.
      room = width - head_length - TICKER_SEPARATOR.length - 2
      return "" if room < MIN_TICKER

      flat = @ticker.gsub(/\s+/, " ").strip
      flat.length > room ? flat[-room..] : flat
    end

    # Ширина спрашивается на каждой отрисовке, а не запоминается: окно
    # терминала меняют посреди работы. Само определение переехало в Terminal,
    # когда за той же величиной пришёл рендерер разметки; @width остаётся
    # тестовым крючком.
    def width = @width || Terminal.width
  end
end
