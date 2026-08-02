# frozen_string_literal: true

require "open3"

module MiniAgent
  # Запуск shell-команды с жёстким ограничением по времени.
  #
  # Namespace::Timeout.timeout здесь намеренно не используется: он бросает
  # исключение в поток, но не убивает порождённый процесс — тот остаётся
  # висеть в фоне. Вместо этого процесс убивается сигналом KILL явно.
  #
  # stdout и stderr читаются отдельными потоками: если читать их
  # последовательно, команда с большим выводом заблокируется на переполненном
  # буфере пайпа, а мы будем ждать её вечно.
  class ProcessRunner
    Result = Struct.new(:stdout, :stderr, :exit_code, keyword_init: true) do
      def success?
        exit_code.zero?
      end
    end

    def initialize(timeout: 120, poll_interval: 0.1, cwd: nil)
      @timeout = timeout
      @poll_interval = poll_interval
      @cwd = cwd
    end

    attr_reader :timeout, :cwd

    # Бросает MiniAgent::TimeoutError, если команда не уложилась в @timeout.
    #
    # Каталог задаётся через chdir: у самого процесса, а не Dir.chdir: тот
    # меняет каталог всего агента, а значит и то, куда пишет лог и где ищется
    # описание проекта. Побочный эффект на весь процесс ради одной команды —
    # обмен, которого здесь не нужно.
    def call(command)
      Open3.popen3("bash", "-c", command, **spawn_options) do |stdin, stdout_io, stderr_io, wait_thr|
        stdin.close
        out_reader = Thread.new { stdout_io.read }
        err_reader = Thread.new { stderr_io.read }

        wait_or_kill(wait_thr, out_reader, err_reader)

        Result.new(
          stdout: out_reader.value.to_s,
          stderr: err_reader.value.to_s,
          exit_code: exit_code_for(wait_thr.value)
        )
      end
    end

    private

    def spawn_options
      @cwd ? { chdir: @cwd } : {}
    end

    def wait_or_kill(wait_thr, out_reader, err_reader)
      deadline = monotonic_now + @timeout

      until wait_thr.join(@poll_interval)
        next if monotonic_now < deadline

        kill(wait_thr.pid)
        # Дожидаемся читателей, иначе потоки останутся висеть на закрытых пайпах.
        out_reader.join
        err_reader.join
        raise TimeoutError, format(Messages::EXECUTION_TIMEOUT, timeout: @timeout.round)
      end
    # Ctrl+C во время команды: процесс надо убить явно и здесь. Сигнал от
    # терминала уходит группе, но команда могла сменить группу сама
    # (`setsid`) или перехватить INT и продолжить работу — тогда без KILL
    # она пережила бы прерывание и осталась висеть в фоне. Ровно та же
    # причина, по которой здесь не используется Timeout.timeout.
    rescue Interrupt
      kill(wait_thr.pid)
      out_reader.join
      err_reader.join
      raise
    end

    def kill(pid)
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::EPERM
      # Процесс уже завершился сам — убивать нечего.
      nil
    end

    # После KILL exitstatus равен nil, поэтому берём номер сигнала + 128,
    # как это делает shell.
    def exit_code_for(status)
      status.exitstatus || (status.termsig ? 128 + status.termsig : -1)
    end

    # Монотонные часы: невосприимчивы к переводу системного времени.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
