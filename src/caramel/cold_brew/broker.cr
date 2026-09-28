require "log"
require "pg"
require "../database"

module Caramel::ColdBrew
  # Bridges PostgreSQL LISTEN/NOTIFY to Crystal channels (RFC-0003 §2.3)
  # over one dedicated connection per process. It LISTENs when a channel
  # gains its first subscriber and UNLISTENs when it loses its last, and
  # after a lost connection it reconnects with backoff and LISTENs again;
  # notifications sent while it is disconnected are lost. Each subscriber
  # receives payloads in publish order from a mailbox its own fiber drains;
  # a payload it does not receive within 1 s is dropped, so no subscriber
  # holds up the broker or the others. A subscription ends with
  # `unsubscribe`, a closed channel, or the end of the fiber that
  # subscribed, so an SSE action's subscription ends with its stream.
  class Broker
    Log = ::Log.for("cold_brew.pubsub")

    ACK_TIMEOUT         = 5.seconds
    DELIVERY_TIMEOUT    = 1.second
    MAILBOX_LIMIT       = 10_000
    MAX_RECONNECT_DELAY = 5.seconds

    # One subscription and its ordered mailbox. A fiber delivers while
    # payloads wait and gives each DELIVERY_TIMEOUT to be received.
    private class Subscriber
      getter channel : Channel(String)
      getter owner : Fiber

      def initialize(@broker : Broker, @name : String, @channel : Channel(String), @owner : Fiber)
        @mailbox = Deque(String).new
        @delivering = false
      end

      def offer(payload : String) : Nil
        if @mailbox.size >= MAILBOX_LIMIT
          Log.warn { "channel=#{@name} dropped a notification: #{MAILBOX_LIMIT} already wait for this subscriber" }
          return
        end
        @mailbox << payload
        return if @delivering
        @delivering = true
        spawn(name: "cold_brew:deliver:#{@name}") { deliver }
      end

      private def deliver : Nil
        while payload = @mailbox.shift?
          select
          when @channel.send(payload)
          when timeout(DELIVERY_TIMEOUT)
            Log.warn { "channel=#{@name} dropped a notification its subscriber did not receive within #{DELIVERY_TIMEOUT.total_seconds.to_i} s" }
          end
        end
      rescue Channel::ClosedError
        @mailbox.clear
        @broker.unsubscribe(@name, @channel)
      ensure
        @delivering = false
      end
    end

    # One LISTEN session. Only its reader fiber reads the socket; commands
    # are written by the caller and acknowledged by the reader in order.
    class Link
      getter pid : Int32

      def self.open(url : String, broker : Broker) : Link
        connection, pq = Caramel::Database.listener(url)
        begin
          pid = connection.scalar("SELECT pg_backend_pid()").as(Int32)
          link = new(connection, pq, pid, broker)
          spawn(name: "cold_brew:listen") { link.read }
          link
        rescue error
          connection.close rescue nil
          raise error
        end
      end

      def initialize(@connection : PG::Connection, @pq : PQ::Connection, @pid : Int32, @broker : Broker)
        @acks = Deque(Channel(Exception?)).new
        @listening = Set(String).new
        @writes = Mutex.new
        @closed = false
      end

      def open? : Bool
        !@closed
      end

      def listen(name : String) : Nil
        return if @listening.includes?(name)
        command(%(LISTEN "#{name}"))
        @listening << name
      end

      def unlisten(name : String) : Nil
        return unless @listening.delete(name)
        command(%(UNLISTEN "#{name}"))
      end

      def close : Nil
        @closed = true
        @connection.close rescue nil
      end

      # :nodoc:
      # Reads one frame at a time: a notification goes to the broker, and
      # ReadyForQuery acknowledges the oldest command with the error an
      # ErrorResponse before it reported, if any.
      def read : Nil
        failure = nil.as(PQ::PQError?)
        loop do
          type = @pq.soc.read_char || raise IO::EOFError.new("PostgreSQL closed the LISTEN connection")
          frame = PQ::Frame.new(type, @pq.read_bytes(@pq.read_i32 - 4))
          case frame
          when PQ::Frame::NotificationResponse
            @broker.dispatch(frame.as_notification)
          when PQ::Frame::ErrorResponse
            failure = PQ::PQError.new(frame.fields)
          when PQ::Frame::ReadyForQuery
            acknowledge(failure)
            failure = nil
          end
        end
      rescue error
        lost = !@closed
        @closed = true
        @acks.each(&.send(error))
        @acks.clear
        @connection.close rescue nil
        @broker.lost(self) if lost
      end

      private def acknowledge(error : Exception?) : Nil
        @acks.shift?.try(&.send(error))
      end

      private def command(sql : String) : Nil
        ack = Channel(Exception?).new(1)
        @writes.synchronize do
          raise IO::Error.new("The LISTEN connection is closed") if @closed
          @acks << ack
          begin
            @pq.send_query_message(sql)
          rescue error
            drop_connection
            raise error
          end
        end
        select
        when error = ack.receive
          raise error if error
        when timeout(ACK_TIMEOUT)
          drop_connection
          raise IO::TimeoutError.new("PostgreSQL did not acknowledge #{sql} within #{ACK_TIMEOUT.total_seconds.to_i} s")
        end
      end

      # Closes the socket under the reader, which then reports the loss.
      private def drop_connection : Nil
        @pq.soc.close rescue nil
      end
    end

    def initialize(@url : String)
      Caramel::Database::Config.parse(@url, 1)
      @subscribers = {} of String => Array(Subscriber)
      @lock = Mutex.new
      @link = nil.as(Link?)
      @closed = false
    end

    # Returns once PostgreSQL LISTENs to `name` for this subscriber.
    def subscribe(name : String, channel : Channel(String)) : Nil
      ColdBrew.validate_channel!(name)
      @lock.synchronize do
        raise IO::Error.new("Caramel::ColdBrew::Broker is closed") if @closed
        subscribers = @subscribers[name] ||= [] of Subscriber
        subscribers.reject!(&.owner.dead?)
        subscriber = Subscriber.new(self, name, channel, Fiber.current)
        subscribers << subscriber
        begin
          connect.listen(name)
        rescue error
          subscribers.delete(subscriber)
          @subscribers.delete(name) if subscribers.empty?
          raise error
        end
      end
    end

    def unsubscribe(name : String, channel : Channel(String)) : Nil
      @lock.synchronize do
        subscribers = @subscribers[name]? || return
        subscribers.reject! { |subscriber| subscriber.channel.same?(channel) || subscriber.owner.dead? }
        return unless subscribers.empty?
        @subscribers.delete(name)
        if (link = @link) && link.open?
          begin
            link.unlisten(name)
          rescue error
            Log.warn { "channel=#{name} UNLISTEN failed error_type=#{error.class}" }
          end
        end
      end
    end

    # The backend PID of the LISTEN connection; nil while disconnected.
    def pid : Int32?
      @link.try { |link| link.pid if link.open? }
    end

    def close : Nil
      @lock.synchronize do
        @closed = true
        @link.try(&.close)
        @link = nil
      end
    end

    # :nodoc:
    # Runs in the reader fiber, so it never waits: each subscriber's mailbox
    # keeps the order and its own fiber does the waiting.
    def dispatch(notification : PQ::Notification) : Nil
      subscribers = @subscribers[notification.channel]? || return
      subscribers.each do |subscriber|
        if subscriber.owner.dead?
          spawn unsubscribe(notification.channel, subscriber.channel)
        else
          subscriber.offer(notification.payload)
        end
      end
    end

    # :nodoc:
    def lost(link : Link) : Nil
      @link = nil if @link.same?(link)
      Log.warn { "LISTEN connection lost; reconnecting" }
      spawn reconnect
    end

    private def reconnect : Nil
      delay = 100.milliseconds
      loop do
        @lock.synchronize do
          return if @closed || @subscribers.empty?
          connect
        end
        return
      rescue error
        Log.warn { "LISTEN reconnect failed error_type=#{error.class}; retrying in #{delay.total_milliseconds.to_i} ms" }
        sleep delay
        delay = {delay * 2, MAX_RECONNECT_DELAY}.min
      end
    end

    # Callers hold @lock. A new link LISTENs to every subscribed channel.
    private def connect : Link
      if (link = @link) && link.open?
        return link
      end
      link = Link.open(@url, self)
      begin
        @subscribers.keys.each { |name| link.listen(name) }
      rescue error
        link.close
        raise error
      end
      @link = link
    end
  end
end
