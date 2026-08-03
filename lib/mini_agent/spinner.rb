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

    # Строка состояния (например, «ход 2/10»): ставится один раз на ход
    # и живёт до конца запроса.
    attr_writer :status

    # Ход самой генерации («размышления: 240 знаков»). Отдельно от status:
    # меняется десятки раз в секунду и гаснет вместе со спиннером.
    attr_writer :progress

    def initialize(ui:, enabled: true, interval: INTERVAL)
      @ui = ui
      @enabled = enabled
      @interval = interval
      @thread = nil
      @stop = false
      @status = nil
      @progress = nil
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
          @ui.print("\r\e[K#{@ui.paint("#{FRAMES[index % FRAMES.size]} #{text}", :cyan)}")
          index += 1
          sleep(@interval)
        end
      rescue IOError
        # Поток вывода закрыли — анимация больше не нужна.
        nil
      end
    end

    def text
      [Messages::THINKING, @status, @progress].compact.join(" ")
    end
  end
end
