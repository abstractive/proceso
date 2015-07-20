require 'json'
require 'celluloid/current'

class Cellumon

  include Celluloid

  class << self
    def start!(options={})
      name = options.fetch(:name, :cellumon)
      monitors = options.delete(:monitors)
      return unless monitors.is_a? Array
      Cellumon.supervise(as: name, args: [options])
      monitors.each { |monitor| Celluloid[name].send("start_#{monitor}!") }
      Celluloid[name]
    end
  end

  MONITORS = {
    thread_survey: 30,
    thread_report: 15,
    thread_summary: 3,
    memory_count: 13,
    threads_and_memory: 45
  }

  def initialize(options={})
    @semaphor = {}
    @status = {}
    @timers = {}
    @logger = options.fetch(:logger, nil)
    @mark = options.fetch(:mark, false)
    @intervals = MONITORS.dup
  end

  MONITORS.each { |m,i|
    define_method(:"start_#{m}!") { |interval=nil|
      async.send(:"starting_#{m}")
    }
    define_method(:"starting_#{m}") { |interval=nil|
      @intervals[m] = interval || MONITORS[m]
      @timers[m] = nil
      @semaphor[m] = Mutex.new
      @status[m] = :initializing
      async.send :"#{m}!"
      ready! m
    }
    define_method(:"stop_#{m}!") {
      stopped! m
      @timers[m].cancel if @timers[m]
    }
  }
    
  def memory_count!
    trigger!(:memory_count) { console memory }
  end

  def thread_survey!
    trigger!(:thread_survey) { Celluloid.stack_summary }
  end

  def thread_summary!
    trigger!(:thread_summary) { print " #{Thread.list.count} " }
  end

  def thread_report!
    trigger!(:thread_report) { console threads }
  end

  def threads_and_memory!
    trigger!(:thread_and_memory_report) { "#{threads}; #{memory}" }
  end

  private

  def threads
    threads = Thread.list.inject({}) { |l,t| l[t.object_id] = t.status; l }
    r = threads.select { |id,status| status == 'run' }.count
    s = threads.select { |id,status| status == 'sleep' }.count
    a = threads.select { |id,status| status == 'aborting' }.count
    nt = threads.select { |id,status| status === false }.count
    te = threads.select { |id,status| status.nil? }.count
    "Threads #{threads.count}: #{r}r #{s}s #{a}a #{nt}nt #{te}te"
  end

  def memory
    total = `pmap #{Process.pid} | tail -1`[10,40].strip[0..-1].to_i
    gb = (total / (1024 * 1024)).to_i
    mb = total % gb
    "Memory: #{'%0.2f' % "#{gb}.#{mb}"}gb" #de Very fuzzy math but fine for now.
  end

  def console(message)
    if @logger
      @logger.console("#{mark}#{message}", reporter: "Cellumon")
    else
      plain_output(message)
    end
  rescue
    plain_output(message)
  end

  def trigger!(monitor)
    if ready?(monitor)
      result = yield
      ready! monitor
    end
    @timers[monitor].cancel rescue nil
    @timers[monitor] = after(@intervals[monitor]) { send("#{monitor}!") }
    result
  end

  def mark
    @mark ? "Cellumon > " : ""
  end

  [:ready, :running, :stopped].each { |state|
    define_method("#{state}!") { |monitor|
      @semaphor[monitor].synchronize { @status[monitor] = state }
    }
    define_method("#{state}?") { |monitor|
      @semaphor[monitor].synchronize { @status[monitor] == state }
    }
  }

  def plain_output(message)
    message = "*, [#{Time.now.strftime('%FT%T.%L')}] #{mark}#{message}"
    STDERR.puts message
    STDOUT.puts message
  end

  def pretty_output object
    puts JSON.pretty_generate(object)
  end

end
